//! O sinal de parada compartilhado entre o supervisor, a sessão e quem espera
//! (o `TEvent` do Delphi). Esperar nele acorda na hora em que alguém para.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

#[derive(Clone, Default)]
pub struct StopToken(Arc<(Mutex<bool>, Condvar)>);

impl StopToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn stop(&self) {
        let (m, c) = &*self.0;
        *m.lock().unwrap_or_else(|p| p.into_inner()) = true;
        c.notify_all();
    }

    pub fn is_stopped(&self) -> bool {
        *self.0 .0.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Dorme até `ms` ou até alguém parar. Devolve `true` se parou.
    pub fn wait_ms(&self, ms: u64) -> bool {
        let (m, c) = &*self.0;
        let g = m.lock().unwrap_or_else(|p| p.into_inner());
        if *g {
            return true;
        }
        let (g, _) = c.wait_timeout_while(g, Duration::from_millis(ms), |s| !*s).unwrap_or_else(|p| p.into_inner());
        *g
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parar_acorda_quem_espera() {
        let t = StopToken::new();
        assert!(!t.wait_ms(1));
        let t2 = t.clone();
        let h = std::thread::spawn(move || t2.wait_ms(10_000));
        std::thread::sleep(Duration::from_millis(20));
        t.stop();
        assert!(h.join().unwrap());
        assert!(t.is_stopped());
    }
}
