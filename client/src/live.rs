//! O ao vivo do app: UMA câmera por vez. A página pede `/api/live?camera=X`;
//! sendo outra câmera, a anterior cai e a nova conecta (um aparelho tem um
//! decodificador e uma bateria). Os samples vão para o mesmo anel em memória
//! do servidor (`vms-core::live`), e a resposta sai pelo mesmo
//! `live_fragment` — o player lê os dois do mesmo jeito.
//!
//! O PTZ e a fala andam junto: a sessão DVRIP do ao vivo se anuncia no
//! registro de PTZ, e o `/api/ptz` do app a encontra ali.

use std::sync::{Arc, Mutex};

use vms_core::camera::CameraConfig;
use vms_core::camera_json::CameraEntry;
use vms_core::clock::Clock;
use vms_core::live::{live_fragment, LiveConfig, LiveFragment, LiveSink, LiveStream};
use vms_core::log::SharedLogger;
use vms_core::supervisor::{DefaultFactory, SessionFactory, Supervisor};

/// Quem cria o supervisor da câmera (o teste troca por um falso).
pub type Starter = Box<dyn Fn(&CameraEntry, Arc<LiveStream>) -> Option<Supervisor> + Send + Sync>;

struct Atual {
    camera: String,
    stream: Arc<LiveStream>,
    sup: Option<Supervisor>,
}

pub struct LiveViewer {
    atual: Mutex<Option<Atual>>,
    starter: Starter,
    log: SharedLogger,
    clock: Arc<dyn Clock>,
    cfg: LiveConfig,
}

/// O supervisor de verdade: RTSP ou DVRIP, sem gravar, entregando ao anel.
pub fn default_starter(log: SharedLogger, clock: Arc<dyn Clock>) -> Starter {
    Box::new(move |cam: &CameraEntry, stream: Arc<LiveStream>| {
        let cfg = cam.to_session_config(&CameraConfig::default());
        let sink = Arc::new(LiveSink { stream, publish_audio: cam.record_audio });
        let factory: Arc<dyn SessionFactory> = Arc::new(DefaultFactory { log: log.clone(), clock: clock.clone(), sink: Some(sink) });
        Some(Supervisor::start(cfg, log.clone(), clock.clone(), factory))
    })
}

impl LiveViewer {
    pub fn new(starter: Starter, log: SharedLogger, clock: Arc<dyn Clock>) -> Self {
        Self { atual: Mutex::new(None), starter, log, clock, cfg: LiveConfig::default() }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<Atual>> {
        self.atual.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn camera(&self) -> Option<String> {
        self.lock().as_ref().map(|a| a.camera.clone())
    }

    /// Para a câmera atual (sair, ou trocar).
    pub fn parar(&self) {
        let velho = self.lock().take();
        if let Some(mut a) = velho {
            if let Some(s) = a.sup.take() {
                s.stop();
            }
            self.log.info("live", &format!("ao vivo de {} encerrado", a.camera));
        }
    }

    /// Garante que `cam` é a câmera do ao vivo. Devolve o anel dela.
    pub fn garantir(&self, cam: &CameraEntry) -> Arc<LiveStream> {
        if let Some(a) = self.lock().as_ref() {
            if a.camera.eq_ignore_ascii_case(&cam.name) {
                return a.stream.clone();
            }
        }
        self.parar();
        let stream = Arc::new(LiveStream::new(&cam.name, self.cfg.buffer_ms, self.cfg.max_bytes, self.log.clone(), self.clock.clone()));
        let sup = (self.starter)(cam, stream.clone());
        self.log.info("live", &format!("ao vivo de {} iniciado", cam.name));
        *self.lock() = Some(Atual { camera: cam.name.clone(), stream: stream.clone(), sup });
        stream
    }

    /// A resposta de `/api/live` para esta câmera.
    pub fn fragment(&self, cam: &CameraEntry, cursor: &str, wait_ms: u64) -> LiveFragment {
        let stream = self.garantir(cam);
        live_fragment(Some(&stream), cursor, wait_ms)
    }
}

impl Drop for LiveViewer {
    fn drop(&mut self) {
        self.parar();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use vms_core::clock::SystemClock;
    use vms_core::media::{Sample, VideoCodec};

    #[test]
    fn uma_camera_por_vez_e_fragmento_do_anel() {
        let n = Arc::new(AtomicUsize::new(0));
        let n2 = n.clone();
        let v = LiveViewer::new(
            Box::new(move |_, s: Arc<LiveStream>| {
                n2.fetch_add(1, Ordering::SeqCst);
                s.publish_video_format(VideoCodec::H264, 640, 360, &[0, 0, 0, 1, 0x67, 1]);
                s.publish(&Sample::video(0, true, vec![0, 0, 0, 1, 0x65, 9]));
                None
            }),
            vms_core::log::null(),
            Arc::new(SystemClock),
        );
        let a = CameraEntry { name: "A".into(), ..Default::default() };
        let f = v.fragment(&a, "", 100);
        assert_eq!(f.status, 200, "keyframe ja publicado sai na hora");
        let cur = f.headers.iter().find(|(k, _)| k == "X-Vms-Cursor").unwrap().1.clone();
        assert!(cur.starts_with('L'));
        assert_eq!(v.fragment(&a, &cur, 50).status, 204, "nada novo");
        assert_eq!(n.load(Ordering::SeqCst), 1, "mesma camera nao reconecta");
        v.fragment(&CameraEntry { name: "B".into(), ..Default::default() }, "", 10);
        assert_eq!(n.load(Ordering::SeqCst), 2);
        assert_eq!(v.camera().as_deref(), Some("B"));
        v.parar();
        assert!(v.camera().is_none());
    }
}
