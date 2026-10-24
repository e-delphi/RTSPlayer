//! Os erros do sistema, separados pelo que quem chama faz com eles.
//!
//! `Timeout` e `Io` são de rede e levam a reconectar; `Auth` e `Config` não
//! adiantam repetir sem mexer no cadastro; `Protocol` é a câmera falando algo
//! que não entendemos.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Config(String),
    Protocol(String),
    Io(String),
    Auth(String),
    Timeout(String),
    /// Pediram para parar: não é falha.
    Stopped,
}

impl Error {
    pub fn is_timeout(&self) -> bool {
        matches!(self, Error::Timeout(_))
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Config(m) => write!(f, "configuracao: {m}"),
            Error::Protocol(m) => write!(f, "protocolo: {m}"),
            Error::Io(m) => write!(f, "{m}"),
            Error::Auth(m) => write!(f, "autenticacao: {m}"),
            Error::Timeout(m) => write!(f, "tempo esgotado: {m}"),
            Error::Stopped => f.write_str("parada pedida"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        match e.kind() {
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => Error::Timeout(e.to_string()),
            _ => Error::Io(e.to_string()),
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
