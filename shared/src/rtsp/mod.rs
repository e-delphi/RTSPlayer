//! RTSP falado na mão: URL, autenticação, mensagens, o fio interleaved e o
//! cliente. O servidor RTSP do vmsserver usa as mesmas mensagens e o mesmo fio.

pub mod auth;
pub mod client;
pub mod message;
pub mod transport;
pub mod url;
pub mod wire;

pub use client::{KeepAliveMethod, RtspClient};
pub use message::{Headers, Request, Response};
pub use transport::TransportSpec;
pub use url::RtspUrl;
pub use wire::{WireEvent, WireReader};
