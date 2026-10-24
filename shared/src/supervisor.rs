//! Mantém uma câmera conectada: roda a sessão, e quando ela cai espera (backoff
//! exponencial) e tenta de novo, escolhendo o caminho a cada tentativa.
//!
//! Queda depois de a mídia ter chegado é transiente e zera o contador; falha
//! que nunca produziu mídia conta para o limite de tentativas da câmera.

use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use crate::camera::CameraConfig;
use crate::clock::Clock;
use crate::dvrip::DvripSession;
use crate::log::SharedLogger;
use crate::net;
use crate::session::{RtspSession, SessionRun, SourceKnown};
use crate::sink::SharedSink;
use crate::stop::StopToken;

#[derive(Debug, Clone)]
pub struct Backoff {
    initial: u64,
    max: u64,
    mult: f64,
    current: u64,
    attempts: u32,
}

impl Backoff {
    pub fn new(initial_ms: u64, max_ms: u64, mult: f64) -> Self {
        let initial = if initial_ms == 0 { 2000 } else { initial_ms };
        Self { initial, max: max_ms.max(initial), mult: mult.max(1.0), current: initial, attempts: 0 }
    }
    pub fn delay_ms(&self) -> u64 {
        self.current
    }
    pub fn attempts(&self) -> u32 {
        self.attempts
    }
    pub fn success(&mut self) {
        self.current = self.initial;
        self.attempts = 0;
    }
    pub fn failure(&mut self) {
        self.attempts += 1;
        self.current = ((self.current as f64 * self.mult) as u64).clamp(self.initial, self.max);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum State {
    #[default]
    Idle,
    Connecting,
    Streaming,
    Draining,
    Backoff,
    Stopping,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            State::Idle => "IDLE",
            State::Connecting => "CONNECT",
            State::Streaming => "STREAM",
            State::Draining => "DRAIN",
            State::Backoff => "BACKOFF",
            State::Stopping => "STOPPING",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Metrics {
    pub state: State,
    pub last_connected_ms: i64,
    pub last_disconnected_ms: i64,
    pub total_reconnects: u32,
    /// O SDP disse que é gravação, e não a câmera ao vivo?
    pub source_is_live: bool,
    pub media_start_ms: i64,
    /// Caminho usado na última tentativa (nome do endpoint).
    pub endpoint: String,
}

/// Cria a sessão de uma tentativa. Porta para o teste injetar uma falsa.
pub trait SessionFactory: Send + Sync {
    fn create(&self, cfg: &CameraConfig, stop: &StopToken, on_source: SourceKnown) -> Box<dyn SessionRun>;
}

/// RTSP ou DVRIP pela URL, entregando ao sink dado.
pub struct DefaultFactory {
    pub log: SharedLogger,
    pub clock: Arc<dyn Clock>,
    pub sink: Option<SharedSink>,
}

impl SessionFactory for DefaultFactory {
    fn create(&self, cfg: &CameraConfig, stop: &StopToken, on_source: SourceKnown) -> Box<dyn SessionRun> {
        if cfg.is_dvrip() {
            Box::new(DvripSession::new(cfg.clone(), self.log.clone(), self.clock.clone(), stop.clone(), self.sink.clone()))
        } else {
            Box::new(RtspSession::new(cfg.clone(), self.log.clone(), self.clock.clone(), stop.clone(), self.sink.clone()).on_source_known(on_source))
        }
    }
}

/// A config desta tentativa: o primeiro caminho que responde; ninguém
/// respondendo, o da tailnet (o túnel pode estar caído), senão o primeiro.
pub fn config_for_attempt(cfg: &CameraConfig, log: &SharedLogger, tag: &str) -> (CameraConfig, String) {
    if cfg.endpoints.is_empty() {
        return (cfg.clone(), String::new());
    }
    let urls: Vec<(&str, &str)> = cfg.endpoints.iter().map(|e| (e.name.as_str(), e.url.as_str())).collect();
    let idx = net::select_endpoint(&urls, &**log, tag, net::PROBE_TIMEOUT_MS).unwrap_or_else(|| {
        let i = cfg.endpoints.iter().position(|e| e.uses_tailscale).unwrap_or(0);
        log.warn(tag, &format!("nenhum dos {} caminhos respondeu; tentando \"{}\" assim mesmo", cfg.endpoints.len(), cfg.endpoints[i].name));
        i
    });
    (cfg.with_endpoint(&cfg.endpoints[idx]), cfg.endpoints[idx].name.clone())
}

pub struct Supervisor {
    camera: String,
    stop: StopToken,
    metrics: Arc<Mutex<Metrics>>,
    handle: Option<JoinHandle<()>>,
}

impl Supervisor {
    pub fn start(cfg: CameraConfig, log: SharedLogger, clock: Arc<dyn Clock>, factory: Arc<dyn SessionFactory>) -> Self {
        let stop = StopToken::new();
        let metrics = Arc::new(Mutex::new(Metrics { source_is_live: true, ..Default::default() }));
        let camera = cfg.name.clone();
        let (s, m) = (stop.clone(), metrics.clone());
        let handle = std::thread::Builder::new()
            .name(format!("sup-{camera}"))
            .spawn(move || run(cfg, log, clock, factory, s, m))
            .expect("thread do supervisor");
        Self { camera, stop, metrics, handle: Some(handle) }
    }

    pub fn camera(&self) -> &str {
        &self.camera
    }
    pub fn metrics(&self) -> Metrics {
        self.metrics.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
    pub fn state(&self) -> State {
        self.metrics().state
    }
    /// Pede para parar, sem esperar.
    pub fn signal_stop(&self) {
        self.stop.stop();
    }
    pub fn stop(mut self) {
        self.stop.stop();
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
    pub fn is_finished(&self) -> bool {
        self.handle.as_ref().is_none_or(|h| h.is_finished())
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        self.stop.stop();
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn set_state(m: &Mutex<Metrics>, log: &SharedLogger, tag: &str, s: State) {
    let mut g = m.lock().unwrap_or_else(|p| p.into_inner());
    if g.state != s {
        log.info(tag, &format!("{} -> {}", g.state.as_str(), s.as_str()));
        g.state = s;
    }
}

fn run(cfg: CameraConfig, log: SharedLogger, clock: Arc<dyn Clock>, factory: Arc<dyn SessionFactory>, stop: StopToken, m: Arc<Mutex<Metrics>>) {
    let tag = format!("supervisor.{}", cfg.name);
    let mut policy = Backoff::new(cfg.reconnect_initial_ms, cfg.reconnect_max_ms, cfg.reconnect_multiplier);
    while !stop.is_stopped() {
        set_state(&m, &log, &tag, State::Connecting);
        let (attempt, endpoint) = config_for_attempt(&cfg, &log, &tag);
        {
            let mut g = m.lock().unwrap_or_else(|p| p.into_inner());
            // Tentativa nova: até o SDP responder, a expectativa é ao vivo.
            g.source_is_live = true;
            g.media_start_ms = 0;
            g.endpoint = endpoint;
        }
        let m2 = m.clone();
        let on_source: SourceKnown = Arc::new(move |live, start| {
            let mut g = m2.lock().unwrap_or_else(|p| p.into_inner());
            g.source_is_live = live;
            g.media_start_ms = start;
        });
        let mut sess = factory.create(&attempt, &stop, on_source);
        set_state(&m, &log, &tag, State::Streaming);
        let r = sess.run();
        let ok = sess.streamed_ok();
        drop(sess);
        match r {
            Ok(()) => {
                m.lock().unwrap_or_else(|p| p.into_inner()).last_connected_ms = clock.now_utc_ms();
                policy.success();
            }
            Err(e) => {
                log.warn(&tag, &format!("Cycle ended: {e}"));
                if ok {
                    policy.success();
                } else {
                    policy.failure();
                }
            }
        }
        set_state(&m, &log, &tag, State::Draining);
        {
            let mut g = m.lock().unwrap_or_else(|p| p.into_inner());
            g.last_disconnected_ms = clock.now_utc_ms();
            if ok {
                g.total_reconnects += 1;
            }
        }
        if stop.is_stopped() {
            break;
        }
        if cfg.max_reconnect_attempts > 0 && policy.attempts() >= cfg.max_reconnect_attempts {
            log.warn(&tag, &format!("desistindo apos {} tentativa(s) sem sucesso (limite da camera)", policy.attempts()));
            break;
        }
        set_state(&m, &log, &tag, State::Backoff);
        log.info(&tag, &format!("Backoff {} ms (attempts={})", policy.delay_ms(), policy.attempts()));
        stop.wait_ms(policy.delay_ms());
    }
    set_state(&m, &log, &tag, State::Stopping);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::Error;
    use std::sync::atomic::{AtomicU32, Ordering};

    #[test]
    fn backoff_dobra_e_volta() {
        let mut b = Backoff::new(100, 350, 2.0);
        b.failure();
        assert_eq!(b.delay_ms(), 200);
        b.failure();
        assert_eq!(b.delay_ms(), 350);
        assert_eq!(b.attempts(), 2);
        b.success();
        assert_eq!((b.delay_ms(), b.attempts()), (100, 0));
        assert_eq!(Backoff::new(0, 0, 0.5).delay_ms(), 2000);
    }

    struct Falha(Arc<AtomicU32>);
    impl SessionRun for Falha {
        fn run(&mut self) -> crate::Result<()> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(Error::Io("recusou".into()))
        }
        fn streamed_ok(&self) -> bool {
            false
        }
    }
    struct FabricaFalha(Arc<AtomicU32>);
    impl SessionFactory for FabricaFalha {
        fn create(&self, _: &CameraConfig, _: &StopToken, _: SourceKnown) -> Box<dyn SessionRun> {
            Box::new(Falha(self.0.clone()))
        }
    }

    #[test]
    fn desiste_depois_do_limite() {
        let n = Arc::new(AtomicU32::new(0));
        let cfg = CameraConfig { name: "lim".into(), max_reconnect_attempts: 3, reconnect_initial_ms: 1, reconnect_max_ms: 2, ..Default::default() };
        let s = Supervisor::start(cfg, crate::log::null(), Arc::new(crate::clock::SystemClock), Arc::new(FabricaFalha(n.clone())));
        let t0 = std::time::Instant::now();
        while !s.is_finished() && t0.elapsed().as_secs() < 5 {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(n.load(Ordering::SeqCst), 3);
        assert_eq!(s.state(), State::Stopping);
    }

    #[test]
    fn caminho_que_responde_e_escolhido() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let ok = format!("rtsp://127.0.0.1:{}/x", l.local_addr().unwrap().port());
        let cfg = CameraConfig {
            name: "ep".into(),
            endpoints: vec![
                crate::camera::CameraEndpoint { name: "Local".into(), url: "rtsp://127.0.0.1:1/".into(), ..Default::default() },
                crate::camera::CameraEndpoint { name: "Online".into(), url: ok.clone(), ..Default::default() },
            ],
            ..Default::default()
        };
        let (a, nome) = config_for_attempt(&cfg, &crate::log::null(), "t");
        assert_eq!(a.url, ok);
        assert_eq!(nome, "Online");
    }
}
