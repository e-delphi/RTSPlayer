//! DVRIP / Sofia (Xiongmai): protocolo, frames de mídia, a sessão de vídeo e
//! controle, e a fala para o alto-falante.

pub mod media;
pub mod protocol;
pub mod session;
pub mod talk;

pub use session::{DvripControl, DvripSession};
pub use talk::DvripTalk;
