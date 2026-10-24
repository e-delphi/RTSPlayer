//! vms-core — o que o RTSPlayer (cliente) e o vmsserver compartilham.
//!
//! Camadas, de baixo para cima:
//! 1. bytes e formato — [`bytes`], [`crc32`], [`vms`]
//! 2. vocabulário — [`media`], [`clock`], [`log`], [`error`], [`stop`]
//! 3. protocolos — [`net`], [`rtsp`], [`sdp`], [`rtp`], [`depk`], [`h26x`], [`dvrip`], [`g711`]
//! 4. domínio — [`camera`], [`sink`], [`ptz`], [`session`], [`supervisor`], [`recorder`]
//!
//! Nada aqui conhece janela, banco ou disco de configuração: isso é de quem usa.

pub mod bytes;
pub mod camera;
pub mod camera_json;
pub mod clock;
pub mod crc32;
pub mod depk;
pub mod dvrip;
pub mod error;
pub mod g711;
pub mod h26x;
pub mod http;
pub mod live;
pub mod log;
pub mod media;
pub mod net;
pub mod onvif;
pub mod ptz;
pub mod ptz_api;
pub mod ptz_control;
pub mod recorder;
pub mod rtp;
pub mod rtsp;
pub mod sdp;
pub mod session;
pub mod sink;
pub mod stop;
pub mod supervisor;
pub mod testutil;
pub mod ui;
pub mod vms;

pub use error::{Error, Result};
