//! O vocabulário de mídia: codecs, sample e descrição das trilhas.
//!
//! Os números dos codecs são os que vão gravados no header do `.vms` — mudar um
//! deles é mudar o formato.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum VideoCodec {
    #[default]
    None = 0,
    H264 = 1,
    H265 = 2,
    Mjpeg = 3,
}

impl VideoCodec {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::H264,
            2 => Self::H265,
            3 => Self::Mjpeg,
            _ => Self::None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::H264 => "H264",
            Self::H265 => "H265",
            Self::Mjpeg => "MJPEG",
            Self::None => "None",
        }
    }
}

impl fmt::Display for VideoCodec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(u8)]
pub enum AudioCodec {
    #[default]
    None = 0,
    Pcm = 1,
    Aac = 2,
    G711U = 3,
    G711A = 4,
    G726_16 = 5,
    G726_24 = 6,
    G726_32 = 7,
    G726_40 = 8,
}

impl AudioCodec {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Pcm,
            2 => Self::Aac,
            3 => Self::G711U,
            4 => Self::G711A,
            5 => Self::G726_16,
            6 => Self::G726_24,
            7 => Self::G726_32,
            8 => Self::G726_40,
            _ => Self::None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pcm => "PCM",
            Self::Aac => "AAC",
            Self::G711U => "G711U",
            Self::G711A => "G711A",
            Self::G726_16 => "G726-16",
            Self::G726_24 => "G726-24",
            Self::G726_32 => "G726-32",
            Self::G726_40 => "G726-40",
            Self::None => "None",
        }
    }
}

impl fmt::Display for AudioCodec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TrackKind {
    Video,
    Audio,
}

/// Bits do campo `flags` de cada sample, como vão no `.vms`.
pub mod flags {
    pub const KEYFRAME: u8 = 0x01;
    pub const START_OF_FRAME: u8 = 0x02;
    pub const END_OF_FRAME: u8 = 0x04;
}

/// Um quadro (vídeo, em Annex-B) ou pedaço de áudio, com o PTS na escala da
/// trilha.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sample {
    pub kind: TrackKind,
    pub track_id: u8,
    pub pts: i64,
    pub flags: u8,
    pub data: Vec<u8>,
}

impl Sample {
    pub fn video(pts: i64, keyframe: bool, data: Vec<u8>) -> Self {
        Self { kind: TrackKind::Video, track_id: 0, pts, flags: if keyframe { flags::KEYFRAME } else { 0 }, data }
    }
    pub fn audio(pts: i64, data: Vec<u8>) -> Self {
        Self { kind: TrackKind::Audio, track_id: 1, pts, flags: 0, data }
    }
    pub fn is_keyframe(&self) -> bool {
        self.flags & flags::KEYFRAME != 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct VideoTrackInfo {
    pub codec: VideoCodec,
    pub timescale: u32,
    pub width: u16,
    pub height: u16,
    /// csd-0 em Annex-B (VPS/SPS/PPS), ou vazio quando vem in-band.
    pub extradata: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AudioTrackInfo {
    pub codec: AudioCodec,
    pub timescale: u32,
    pub sample_rate: u32,
    pub channels: u8,
    pub bits_per_sample: u8,
    /// AudioSpecificConfig no AAC.
    pub extradata: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Transport {
    Tcp,
    Udp,
}

impl Transport {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Tcp => "tcp",
            Self::Udp => "udp",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "tcp" => Some(Self::Tcp),
            "udp" => Some(Self::Udp),
            _ => None,
        }
    }
    /// `"tcp,udp"`, `"udp"`, `"auto"`... Vazio, `auto` ou nada reconhecível vira
    /// o padrão `tcp,udp` — o mesmo formato que o cadastro grava.
    pub fn parse_list(s: &str) -> Vec<Transport> {
        let v: Vec<Transport> = s.split(',').filter_map(Transport::parse).collect();
        if v.is_empty() {
            vec![Transport::Tcp, Transport::Udp]
        } else {
            v
        }
    }
    pub fn list_to_string(list: &[Transport]) -> String {
        list.iter().map(|t| t.as_str()).collect::<Vec<_>>().join(",")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codecs_ida_e_volta() {
        for v in 0..=3u8 {
            assert_eq!(VideoCodec::from_u8(v) as u8, v);
        }
        for a in 0..=8u8 {
            assert_eq!(AudioCodec::from_u8(a) as u8, a);
        }
        assert_eq!(VideoCodec::from_u8(99), VideoCodec::None);
        assert_eq!(AudioCodec::G726_24.as_str(), "G726-24");
    }

    #[test]
    fn lista_de_transporte() {
        assert_eq!(Transport::parse_list("udp, tcp"), vec![Transport::Udp, Transport::Tcp]);
        assert_eq!(Transport::parse_list("auto"), vec![Transport::Tcp, Transport::Udp]);
        assert_eq!(Transport::parse_list(""), vec![Transport::Tcp, Transport::Udp]);
        assert_eq!(Transport::list_to_string(&[Transport::Tcp]), "tcp");
    }
}
