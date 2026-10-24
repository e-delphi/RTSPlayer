//! SDP: as trilhas que a câmera anuncia e, de cada uma, o codec, o relógio e
//! os parâmetros (SPS/PPS, AudioSpecificConfig).

use std::collections::HashMap;

use base64::Engine;

use crate::media::{AudioCodec, VideoCodec};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MediaKind {
    #[default]
    Unknown,
    Video,
    Audio,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SdpMedia {
    pub kind: MediaKind,
    pub proto: String,
    pub port: u16,
    pub payload_type: Option<u8>,
    pub rtpmap: String,
    pub fmtp: String,
    pub control: String,
    pub connection: String,
    pub extra: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SdpSession {
    pub version: i32,
    pub origin: String,
    pub name: String,
    pub connection: String,
    pub control: String,
    /// `a=x-vms-source:file` = o vmsserver está entregando GRAVAÇÃO, não a
    /// câmera. Câmera de verdade não manda nada, e o padrão é "ao vivo".
    pub source_is_live: bool,
    /// `a=x-vms-media-start:<ms>`: de quando é a primeira imagem da gravação.
    pub media_start_ms: i64,
    pub media: Vec<SdpMedia>,
}

impl Default for SdpSession {
    fn default() -> Self {
        Self {
            version: 0,
            origin: String::new(),
            name: String::new(),
            connection: String::new(),
            control: String::new(),
            source_is_live: true,
            media_start_ms: 0,
            media: Vec::new(),
        }
    }
}

impl SdpSession {
    pub fn first(&self, kind: MediaKind) -> Option<&SdpMedia> {
        self.media.iter().find(|m| m.kind == kind)
    }
}

pub fn parse(text: &str) -> SdpSession {
    let mut s = SdpSession::default();
    let mut cur: Option<usize> = None;
    for raw in text.split(['\n', '\r']) {
        let line = raw;
        if line.len() < 2 || line.as_bytes()[1] != b'=' {
            continue;
        }
        let field = line.as_bytes()[0];
        let value = &line[2..];
        match field {
            b'v' => s.version = value.trim().parse().unwrap_or(0),
            b'o' => s.origin = value.into(),
            b's' => s.name = value.into(),
            b'c' => match cur {
                Some(i) => s.media[i].connection = value.into(),
                None => s.connection = value.into(),
            },
            b'm' => {
                let mut m = SdpMedia::default();
                let parts: Vec<&str> = value.split(' ').filter(|p| !p.is_empty()).collect();
                if parts.len() >= 4 {
                    m.kind = match parts[0].to_ascii_lowercase().as_str() {
                        "video" => MediaKind::Video,
                        "audio" => MediaKind::Audio,
                        _ => MediaKind::Unknown,
                    };
                    m.port = parts[1].parse().unwrap_or(0);
                    m.proto = parts[2].into();
                    m.payload_type = parts[3].parse().ok();
                }
                s.media.push(m);
                cur = Some(s.media.len() - 1);
            }
            b'a' => {
                let (key, rest) = match value.find(':') {
                    Some(p) => (value[..p].trim(), value[p + 1..].trim()),
                    None => (value.trim(), ""),
                };
                match cur {
                    Some(i) => {
                        let m = &mut s.media[i];
                        match key.to_ascii_lowercase().as_str() {
                            "rtpmap" => m.rtpmap = rest.into(),
                            "fmtp" => m.fmtp = rest.into(),
                            "control" => m.control = rest.into(),
                            k => {
                                m.extra.insert(k.to_owned(), rest.to_owned());
                            }
                        }
                    }
                    None => match key.to_ascii_lowercase().as_str() {
                        "control" => s.control = rest.into(),
                        "x-vms-source" => s.source_is_live = !rest.eq_ignore_ascii_case("file"),
                        "x-vms-media-start" => s.media_start_ms = rest.parse().unwrap_or(0),
                        _ => {}
                    },
                }
            }
            _ => {}
        }
    }
    s
}

/// O `a=control` da trilha, absoluto a partir da base.
pub fn absolute_control(base: &str, control: &str) -> String {
    let c = control.trim();
    if c.is_empty() || c == "*" {
        return base.to_owned();
    }
    let lc = c.to_ascii_lowercase();
    if lc.starts_with("rtsp://") || lc.starts_with("rtsps://") {
        return c.to_owned();
    }
    if base.ends_with('/') {
        format!("{base}{c}")
    } else {
        format!("{base}/{c}")
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodecInfo {
    pub video: VideoCodec,
    pub audio: AudioCodec,
    pub timescale: u32,
    pub sample_rate: u32,
    pub channels: u8,
    pub extradata: Vec<u8>,
    pub width: u16,
    pub height: u16,
}

pub fn decode_base64(s: &str) -> Vec<u8> {
    let clean: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if clean.is_empty() {
        return Vec::new();
    }
    let e = base64::engine::general_purpose::STANDARD;
    e.decode(&clean)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(clean.trim_end_matches('=')))
        .unwrap_or_default()
}

fn parse_rtpmap(s: &str) -> Option<(String, u32, u8)> {
    let p = s.find(' ')?;
    let rest = s[p + 1..].trim();
    let parts: Vec<&str> = rest.split('/').filter(|x| !x.is_empty()).collect();
    if parts.len() < 2 {
        return None;
    }
    let clock: u32 = parts[1].parse().unwrap_or(0);
    let ch: u8 = parts.get(2).and_then(|c| c.parse().ok()).unwrap_or(1);
    (clock > 0).then(|| (parts[0].to_owned(), clock, ch))
}

/// Um parâmetro do `a=fmtp:96 a=1;b=2`.
pub fn fmtp_param(fmtp: &str, key: &str) -> Option<String> {
    let body = match fmtp.find(' ') {
        Some(p) => &fmtp[p + 1..],
        None => fmtp,
    };
    body.split(';').find_map(|item| {
        let p = item.find('=')?;
        item[..p].trim().eq_ignore_ascii_case(key).then(|| item[p + 1..].trim().to_owned())
    })
}

fn annexb_from_base64_list(list: &str, out: &mut Vec<u8>) {
    for item in list.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let nal = decode_base64(item);
        if !nal.is_empty() {
            out.extend_from_slice(&[0, 0, 0, 1]);
            out.extend_from_slice(&nal);
        }
    }
}

fn hex_to_bytes(h: &str) -> Vec<u8> {
    let s: String = h.chars().filter(|c| !c.is_whitespace()).collect();
    if s.len() % 2 != 0 {
        return Vec::new();
    }
    (0..s.len() / 2).map_while(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()).collect()
}

/// O codec e os parâmetros de uma trilha. `None` se não reconhecido.
pub fn codec_of(m: &SdpMedia) -> Option<CodecInfo> {
    let mut info = CodecInfo::default();
    let Some((enc, clock, ch)) = parse_rtpmap(&m.rtpmap) else {
        // Sem rtpmap: os tipos estáticos de G.711.
        if m.kind == MediaKind::Audio {
            let codec = match m.payload_type {
                Some(0) => AudioCodec::G711U,
                Some(8) => AudioCodec::G711A,
                _ => return None,
            };
            return Some(CodecInfo { audio: codec, timescale: 8000, sample_rate: 8000, channels: 1, ..Default::default() });
        }
        return None;
    };
    info.timescale = clock;
    info.sample_rate = clock;
    info.channels = ch;
    let e = enc.to_ascii_uppercase();
    match m.kind {
        MediaKind::Video => {
            match e.as_str() {
                "H264" => {
                    info.video = VideoCodec::H264;
                    if let Some(sp) = fmtp_param(&m.fmtp, "sprop-parameter-sets") {
                        annexb_from_base64_list(&sp, &mut info.extradata);
                    }
                }
                "H265" | "HEVC" => {
                    info.video = VideoCodec::H265;
                    for k in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                        if let Some(v) = fmtp_param(&m.fmtp, k) {
                            annexb_from_base64_list(&v, &mut info.extradata);
                        }
                    }
                }
                "JPEG" | "MJPEG" => info.video = VideoCodec::Mjpeg,
                _ => return None,
            }
            if let Some((w, h)) = crate::h26x::dimensions(info.video, &info.extradata) {
                info.width = w;
                info.height = h;
            }
        }
        MediaKind::Audio => {
            info.audio = match e.as_str() {
                "PCMU" => AudioCodec::G711U,
                "PCMA" => AudioCodec::G711A,
                "L16" => AudioCodec::Pcm,
                "MPEG4-GENERIC" => {
                    if let Some(c) = fmtp_param(&m.fmtp, "config") {
                        info.extradata = hex_to_bytes(&c);
                    }
                    AudioCodec::Aac
                }
                "G726-16" => AudioCodec::G726_16,
                "G726-24" => AudioCodec::G726_24,
                "G726-32" => AudioCodec::G726_32,
                "G726-40" => AudioCodec::G726_40,
                _ => return None,
            };
        }
        MediaKind::Unknown => return None,
    }
    Some(info)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SDP: &str = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\ns=Live\r\na=control:*\r\na=x-vms-source:file\r\na=x-vms-media-start:1786846215000\r\n\
m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0IAKeKQFAe2AtwEBAaQeJEV,aM48gA==\r\na=control:track1\r\n\
m=audio 0 RTP/AVP 8\r\na=control:track2\r\n";

    #[test]
    fn trilhas_e_extensoes_do_servidor() {
        let s = parse(SDP);
        assert!(!s.source_is_live);
        assert_eq!(s.media_start_ms, 1_786_846_215_000);
        assert_eq!(s.control, "*");
        let v = s.first(MediaKind::Video).unwrap();
        assert_eq!(v.payload_type, Some(96));
        assert_eq!(v.control, "track1");
        let info = codec_of(v).unwrap();
        assert_eq!(info.video, VideoCodec::H264);
        assert_eq!(info.timescale, 90000);
        assert_eq!(&info.extradata[..4], &[0, 0, 0, 1]);
        assert_eq!(info.extradata[4] & 0x1F, 7, "SPS");
        let a = codec_of(s.first(MediaKind::Audio).unwrap()).unwrap();
        assert_eq!(a.audio, AudioCodec::G711A);
        assert_eq!(a.sample_rate, 8000);
    }

    #[test]
    fn aac_e_controle_absoluto() {
        let m = SdpMedia {
            kind: MediaKind::Audio,
            rtpmap: "97 MPEG4-GENERIC/16000/1".into(),
            fmtp: "97 streamtype=5;mode=AAC-hbr;config=1408;sizelength=13".into(),
            ..Default::default()
        };
        let i = codec_of(&m).unwrap();
        assert_eq!(i.audio, AudioCodec::Aac);
        assert_eq!(i.extradata, vec![0x14, 0x08]);
        assert_eq!(i.sample_rate, 16000);
        assert_eq!(absolute_control("rtsp://h/x/", "track1"), "rtsp://h/x/track1");
        assert_eq!(absolute_control("rtsp://h/x", "track1"), "rtsp://h/x/track1");
        assert_eq!(absolute_control("rtsp://h/x", "rtsp://o/t"), "rtsp://o/t");
        assert_eq!(absolute_control("rtsp://h/x", "*"), "rtsp://h/x");
        assert_eq!(fmtp_param(&m.fmtp, "SIZELENGTH").as_deref(), Some("13"));
    }
}
