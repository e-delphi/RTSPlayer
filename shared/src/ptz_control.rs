//! Sessões DVRIP só de comando, para câmera cujo vídeo vem por RTSP mas cujo
//! PTZ e fala falam DVRIP (`ptz` = `dvrip://…` no cadastro).
//!
//! A sessão se anuncia no `PtzRegistry` ao conectar e é reaberta enquanto for
//! mantida aqui; o `/api/ptz` e o `/api/fala` a acham lá como acham a do vídeo
//! DVRIP. Servidor e app usam o mesmo guardião.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::camera::CameraConfig;
use crate::clock::Clock;
use crate::dvrip::session::DvripSession;
use crate::log::SharedLogger;
use crate::ptz::PtzRegistry;
use crate::stop::StopToken;

/// Quanto um pedido espera a sessão recém-aberta ficar pronta.
pub const ESPERA_PRONTA: Duration = Duration::from_secs(3);
const REABRIR_MS: u64 = 5000;

/// O endereço de PTZ do cadastro é de uma sessão DVRIP de comando?
pub fn is_dvrip_ptz(addr: &str) -> bool {
    addr.trim().to_ascii_lowercase().starts_with("dvrip://")
}

struct Sessao {
    url: String,
    stop: StopToken,
    thread: Option<JoinHandle<()>>,
}

impl Drop for Sessao {
    fn drop(&mut self) {
        self.stop.stop();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

pub struct ControlSessions {
    abertas: Mutex<HashMap<String, Sessao>>,
    log: SharedLogger,
    clock: Arc<dyn Clock>,
}

impl ControlSessions {
    pub fn new(log: SharedLogger, clock: Arc<dyn Clock>) -> Self {
        Self { abertas: Mutex::new(HashMap::new()), log, clock }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Sessao>> {
        self.abertas.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Garante a sessão de `cfg.name` em `cfg.url`. Já aberta no mesmo
    /// endereço: nada. Noutro: troca.
    pub fn ensure(&self, cfg: CameraConfig) {
        let k = cfg.name.to_lowercase();
        let mut g = self.lock();
        if g.get(&k).is_some_and(|s| s.url.eq_ignore_ascii_case(&cfg.url)) {
            return;
        }
        g.remove(&k);
        let stop = StopToken::new();
        let st = stop.clone();
        let (log, clock, url) = (self.log.clone(), self.clock.clone(), cfg.url.clone());
        let tag = format!("ptz.{}", cfg.name);
        log.info(&tag, &format!("abrindo sessao de comando em {url}"));
        let thread = std::thread::Builder::new()
            .name(tag.clone())
            .spawn(move || {
                while !st.is_stopped() {
                    let mut s = DvripSession::new(cfg.clone(), log.clone(), clock.clone(), st.clone(), None);
                    if let Err(e) = s.run_control() {
                        log.warn(&tag, &format!("sessao de comando caiu: {e}"));
                    }
                    if st.wait_ms(REABRIR_MS) {
                        break;
                    }
                }
            })
            .ok();
        g.insert(k, Sessao { url, stop, thread });
    }

    /// Fecha as que `keep` não quer mais (câmera saiu, PTZ mudou).
    pub fn retain(&self, keep: impl Fn(&str) -> bool) {
        let mut g = self.lock();
        let fora: Vec<String> = g.keys().filter(|k| !keep(k)).cloned().collect();
        for k in fora {
            g.remove(&k);
            self.log.info(&format!("ptz.{k}"), "sessao de comando encerrada");
        }
    }

    pub fn is_open(&self, camera: &str) -> bool {
        self.lock().contains_key(&camera.to_lowercase())
    }

    /// Espera a sessão de `camera` se anunciar no registro.
    pub fn wait_ready(camera: &str, timeout: Duration) -> bool {
        let ate = Instant::now() + timeout;
        while PtzRegistry::achar(camera).is_none() {
            if Instant::now() >= ate {
                return false;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        true
    }

    pub fn close_all(&self) {
        // Fora do lock: o Drop espera a thread.
        let todas: Vec<Sessao> = self.lock().drain().map(|(_, s)| s).collect();
        drop(todas);
    }
}

impl Drop for ControlSessions {
    fn drop(&mut self) {
        self.close_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abre_troca_e_fecha() {
        let c = ControlSessions::new(crate::log::null(), Arc::new(crate::clock::SystemClock));
        // Porta fechada: a sessão tenta e espera para reabrir, sem travar ninguém.
        let cfg = |url: &str| CameraConfig { name: "Ctl1".into(), url: url.into(), connect_timeout_ms: 200, ..Default::default() };
        c.ensure(cfg("dvrip://127.0.0.1:1"));
        assert!(c.is_open("ctl1"));
        c.ensure(cfg("dvrip://127.0.0.1:1"));
        c.ensure(cfg("dvrip://127.0.0.1:2"));
        assert!(!ControlSessions::wait_ready("ctl1", Duration::from_millis(200)), "nada responde");
        c.retain(|_| false);
        assert!(!c.is_open("ctl1"));
        assert!(is_dvrip_ptz(" DVRIP://x:34567") && !is_dvrip_ptz("10.0.0.2:5000"));
    }
}
