//! O log do sistema: uma porta (`Logger`) e as implementações que o app e o
//! servidor ligam nela.
//!
//! Não há filtro por nível — o que o código registra, sai (a mesma regra do
//! Delphi). A TAG diz de onde veio (`session.frente`, `dvrip.isis`, `api`); o
//! servidor usa o sufixo de câmera dela para separar o log por câmera.

use std::fmt;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Debug,
    Info,
    Warn,
    Error,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
        }
    }
}

impl fmt::Display for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

pub trait Logger: Send + Sync {
    fn log(&self, level: Level, tag: &str, msg: &str);

    fn debug(&self, tag: &str, msg: &str) {
        self.log(Level::Debug, tag, msg)
    }
    fn info(&self, tag: &str, msg: &str) {
        self.log(Level::Info, tag, msg)
    }
    fn warn(&self, tag: &str, msg: &str) {
        self.log(Level::Warn, tag, msg)
    }
    fn error(&self, tag: &str, msg: &str) {
        self.log(Level::Error, tag, msg)
    }
}

pub type SharedLogger = Arc<dyn Logger>;

/// Não registra nada. Para quem não quer saber (testes, ferramentas).
pub struct NullLogger;

impl Logger for NullLogger {
    fn log(&self, _: Level, _: &str, _: &str) {}
}

pub fn null() -> SharedLogger {
    Arc::new(NullLogger)
}

/// Uma linha no formato de sempre: `HH:MM:SS.mmm [INFO ] tag: mensagem`.
pub fn format_line(level: Level, tag: &str, msg: &str) -> String {
    let now = crate::clock::local_now();
    format!(
        "{:02}:{:02}:{:02}.{:03} [{:<5}] {}: {}",
        now.hour, now.minute, now.second, now.millis, level.as_str(), tag, msg
    )
}

/// Escreve no stderr. É o log do console do servidor e o do app em debug.
pub struct ConsoleLogger;

impl Logger for ConsoleLogger {
    fn log(&self, level: Level, tag: &str, msg: &str) {
        eprintln!("{}", format_line(level, tag, msg));
    }
}

/// Repassa para vários (console + arquivo + memória, por exemplo).
pub struct TeeLogger(pub Vec<SharedLogger>);

impl Logger for TeeLogger {
    fn log(&self, level: Level, tag: &str, msg: &str) {
        for l in &self.0 {
            l.log(level, tag, msg);
        }
    }
}

/// Guarda as últimas linhas em memória, numeradas. É o que a página lê pelo
/// `/api/app/log` para despejar no console do navegador.
pub struct MemoryLogger {
    inner: Mutex<MemoryLog>,
    cap: usize,
}

struct MemoryLog {
    lines: std::collections::VecDeque<(u64, String)>,
    next: u64,
}

impl MemoryLogger {
    pub fn new(cap: usize) -> Self {
        Self { inner: Mutex::new(MemoryLog { lines: Default::default(), next: 1 }), cap: cap.max(1) }
    }

    /// As linhas a partir da posição `from` (exclusiva) e a posição da última.
    /// `from = 0` traz tudo que ainda está guardado.
    pub fn read_since(&self, from: u64) -> (Vec<String>, u64) {
        let g = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let v = g.lines.iter().filter(|(n, _)| *n > from).map(|(_, s)| s.clone()).collect();
        (v, g.next - 1)
    }
}

impl Logger for MemoryLogger {
    fn log(&self, level: Level, tag: &str, msg: &str) {
        let line = format_line(level, tag, msg);
        let mut g = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let n = g.next;
        g.next += 1;
        g.lines.push_back((n, line));
        while g.lines.len() > self.cap {
            g.lines.pop_front();
        }
    }
}

/// Junta o que foi registrado, para teste conferir.
#[derive(Default)]
pub struct CaptureLogger(pub Mutex<Vec<(Level, String, String)>>);

impl CaptureLogger {
    pub fn lines(&self) -> Vec<(Level, String, String)> {
        self.0.lock().unwrap().clone()
    }
    pub fn contains(&self, needle: &str) -> bool {
        self.lines().iter().any(|(_, _, m)| m.contains(needle))
    }
}

impl Logger for CaptureLogger {
    fn log(&self, level: Level, tag: &str, msg: &str) {
        self.0.lock().unwrap().push((level, tag.to_owned(), msg.to_owned()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memoria_guarda_as_ultimas_numeradas() {
        let m = MemoryLogger::new(2);
        m.info("a", "um");
        m.info("a", "dois");
        m.warn("a", "tres");
        let (v, ult) = m.read_since(0);
        assert_eq!(ult, 3);
        assert_eq!(v.len(), 2);
        assert!(v[0].contains("dois") && v[1].contains("[WARN ] a: tres"));
        let (v, _) = m.read_since(2);
        assert_eq!(v.len(), 1);
    }
}
