//! RTP → samples. Um depacketizador por codec, atrás de uma interface só.
//!
//! O PTS que sai é o timestamp RTP do pacote, como veio (32 bits): quem grava e
//! quem toca trabalham com diferenças, e a âncora de parede cobre as voltas.

mod h264;
mod h265;
mod mjpeg;
mod simple;

pub use h264::H264Depacketizer;
pub use h265::H265Depacketizer;
pub use mjpeg::MjpegDepacketizer;
pub use simple::{AacDepacketizer, PassthroughAudio};

use crate::media::{AudioCodec, Sample, TrackKind, VideoCodec};
use crate::rtp::RtpPacket;

pub trait Depacketizer: Send {
    fn kind(&self) -> TrackKind;
    /// Junta o pacote; os samples que completarem vão para `out`.
    fn feed(&mut self, p: &RtpPacket, out: &mut Vec<Sample>);
    /// Esquece o quadro pela metade (reconexão).
    fn reset(&mut self) {}
}

pub fn for_video(codec: VideoCodec) -> Option<Box<dyn Depacketizer>> {
    match codec {
        VideoCodec::H264 => Some(Box::new(H264Depacketizer::new(0))),
        VideoCodec::H265 => Some(Box::new(H265Depacketizer::new(0))),
        VideoCodec::Mjpeg => Some(Box::new(MjpegDepacketizer::new(0))),
        VideoCodec::None => None,
    }
}

pub fn for_audio(codec: AudioCodec, fmtp: &str) -> Option<Box<dyn Depacketizer>> {
    match codec {
        AudioCodec::Aac => {
            let mut d = AacDepacketizer::new(1);
            let get = |k: &str| crate::sdp::fmtp_param(fmtp, k).and_then(|v| v.parse::<i32>().ok());
            d.set_mode(get("sizelength").unwrap_or(13), get("indexlength").unwrap_or(3), get("indexdeltalength").unwrap_or(3));
            Some(Box::new(d))
        }
        AudioCodec::None => None,
        _ => Some(Box::new(PassthroughAudio::new(1))),
    }
}

/// Embrulha um NAL em Annex-B (start code de 4 bytes).
pub(crate) fn annexb(nal: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(4 + nal.len());
    v.extend_from_slice(&[0, 0, 0, 1]);
    v.extend_from_slice(nal);
    v
}
