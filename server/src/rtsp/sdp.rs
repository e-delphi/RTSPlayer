//! O SDP que o servidor anuncia, montado do header do `.vms` (ou do ao vivo).
//!
//! `a=x-vms-source:live|file` diz ao app se é ao vivo de verdade ou arquivo,
//! e `a=x-vms-media-start` o instante da primeira imagem no caso de arquivo
//! (o `vms-core::sdp` lê os dois).

use base64::Engine;
use vms_core::media::{AudioCodec, AudioTrackInfo, VideoCodec, VideoTrackInfo};
use vms_core::vms::Header;

use super::packetizer::{audio_payload_type, video_payload_type};

pub const VIDEO_CTRL: &str = "trackID=0";
pub const AUDIO_CTRL: &str = "trackID=1";

fn b64(d: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(d)
}

fn is_parameter_set(nal: &[u8], codec: VideoCodec) -> bool {
    match codec {
        VideoCodec::H265 => nal.len() >= 2 && matches!((nal[0] >> 1) & 0x3F, 32..=34),
        _ => !nal.is_empty() && matches!(nal[0] & 0x1F, 7 | 8),
    }
}

/// Só os parameter sets de um AU, em Annex-B.
pub fn parameter_sets_of(sample: &[u8], codec: VideoCodec) -> Vec<u8> {
    if !matches!(codec, VideoCodec::H264 | VideoCodec::H265) {
        return Vec::new();
    }
    let mut out = Vec::new();
    for n in vms_core::h26x::nals(sample).into_iter().filter(|n| is_parameter_set(n, codec)) {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(n);
    }
    out
}

/// SPS+PPS (e VPS no H.265) presentes.
pub fn parameter_sets_complete(ps: &[u8], codec: VideoCodec) -> bool {
    let (mut v, mut s, mut p) = (false, false, false);
    for n in vms_core::h26x::nals(ps) {
        if codec == VideoCodec::H265 {
            if n.len() < 2 {
                continue;
            }
            match (n[0] >> 1) & 0x3F {
                32 => v = true,
                33 => s = true,
                34 => p = true,
                _ => {}
            }
        } else if let Some(&h) = n.first() {
            match h & 0x1F {
                7 => s = true,
                8 => p = true,
                _ => {}
            }
        }
    }
    if codec == VideoCodec::H265 {
        v && s && p
    } else {
        s && p
    }
}

fn video_sdp(out: &mut String, v: &VideoTrackInfo) {
    let pt = video_payload_type(v.codec);
    let nals = vms_core::h26x::nals(&v.extradata);
    match v.codec {
        VideoCodec::H264 => {
            out.push_str(&format!("m=video 0 RTP/AVP {pt}\r\na=rtpmap:{pt} H264/{}\r\n", v.timescale));
            let (mut sps, mut pps, mut pli) = (Vec::new(), Vec::new(), String::new());
            for n in nals.iter().filter(|n| !n.is_empty()) {
                match n[0] & 0x1F {
                    7 => {
                        if pli.is_empty() && n.len() >= 4 {
                            pli = format!("{:02x}{:02x}{:02x}", n[1], n[2], n[3]);
                        }
                        sps.push(b64(n));
                    }
                    8 => pps.push(b64(n)),
                    _ => {}
                }
            }
            let sprop: Vec<String> = sps.into_iter().chain(pps).collect();
            out.push_str(&format!("a=fmtp:{pt} packetization-mode=1"));
            if !pli.is_empty() {
                out.push_str(&format!("; profile-level-id={pli}"));
            }
            if !sprop.is_empty() {
                out.push_str(&format!("; sprop-parameter-sets={}", sprop.join(",")));
            }
            out.push_str("\r\n");
        }
        VideoCodec::H265 => {
            out.push_str(&format!("m=video 0 RTP/AVP {pt}\r\na=rtpmap:{pt} H265/{}\r\n", v.timescale));
            let (mut vps, mut sps, mut pps) = (String::new(), String::new(), String::new());
            for n in nals.iter().filter(|n| n.len() >= 2) {
                match (n[0] >> 1) & 0x3F {
                    32 => vps = b64(n),
                    33 => sps = b64(n),
                    34 => pps = b64(n),
                    _ => {}
                }
            }
            out.push_str(&format!("a=fmtp:{pt}"));
            for (k, val) in [("vps", vps), ("sps", sps), ("pps", pps)] {
                if !val.is_empty() {
                    out.push_str(&format!(" sprop-{k}={val};"));
                }
            }
            out.push_str("\r\n");
        }
        VideoCodec::Mjpeg => out.push_str("m=video 0 RTP/AVP 26\r\n"),
        VideoCodec::None => return,
    }
    out.push_str(&format!("a=control:{VIDEO_CTRL}\r\n"));
}

fn audio_sdp(out: &mut String, a: &AudioTrackInfo) {
    let pt = audio_payload_type(a.codec);
    match a.codec {
        AudioCodec::Aac => {
            out.push_str(&format!("m=audio 0 RTP/AVP {pt}\r\na=rtpmap:{pt} MPEG4-GENERIC/{}/{}\r\n", a.timescale, a.channels));
            out.push_str(&format!("a=fmtp:{pt} streamtype=5; profile-level-id=1; mode=AAC-hbr; sizelength=13; indexlength=3; indexdeltalength=3"));
            if !a.extradata.is_empty() {
                out.push_str("; config=");
                for b in &a.extradata {
                    out.push_str(&format!("{b:02x}"));
                }
            }
            out.push_str("\r\n");
        }
        AudioCodec::G711U => out.push_str(&format!("m=audio 0 RTP/AVP 0\r\na=rtpmap:0 PCMU/{}\r\n", a.timescale)),
        AudioCodec::G711A => out.push_str(&format!("m=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/{}\r\n", a.timescale)),
        AudioCodec::Pcm => out.push_str(&format!("m=audio 0 RTP/AVP {pt}\r\na=rtpmap:{pt} L16/{}/{}\r\n", a.timescale, a.channels)),
        AudioCodec::G726_16 | AudioCodec::G726_24 | AudioCodec::G726_32 | AudioCodec::G726_40 => {
            let name = match a.codec {
                AudioCodec::G726_16 => "G726-16",
                AudioCodec::G726_24 => "G726-24",
                AudioCodec::G726_32 => "G726-32",
                _ => "G726-40",
            };
            out.push_str(&format!("m=audio 0 RTP/AVP {pt}\r\na=rtpmap:{pt} {name}/{}\r\n", a.timescale));
        }
        AudioCodec::None => return,
    }
    out.push_str(&format!("a=control:{AUDIO_CTRL}\r\n"));
}

pub fn build_sdp(h: &Header, session_name: &str, from_live: bool, media_start_ms: i64) -> String {
    let name = if session_name.is_empty() { "VMS Stream" } else { session_name };
    let mut s = format!("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns={name}\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\na=control:*\r\n");
    if from_live {
        s.push_str("a=x-vms-source:live\r\n");
    } else {
        s.push_str("a=x-vms-source:file\r\n");
        if media_start_ms > 0 {
            s.push_str(&format!("a=x-vms-media-start:{media_start_ms}\r\n"));
        }
    }
    if h.video_present {
        video_sdp(&mut s, &h.video);
    }
    if h.audio_present {
        audio_sdp(&mut s, &h.audio);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sdp_lido_pelo_parser_do_app() {
        let h = Header {
            video_present: true,
            video: VideoTrackInfo { codec: VideoCodec::H264, timescale: 90_000, width: 0, height: 0, extradata: vec![0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x1E, 0, 0, 0, 1, 0x68, 0xCE] },
            audio_present: true,
            audio: AudioTrackInfo { codec: AudioCodec::Aac, timescale: 16_000, sample_rate: 16_000, channels: 1, bits_per_sample: 16, extradata: vec![0x14, 0x08] },
            ..Default::default()
        };
        let s = build_sdp(&h, "frente", false, 1234);
        assert!(s.contains("profile-level-id=42c01e"));
        assert!(s.contains("config=1408"));
        let p = vms_core::sdp::parse(&s);
        assert!(!p.source_is_live);
        assert_eq!(p.media_start_ms, 1234);
        assert_eq!(p.media.len(), 2);
        let ps = parameter_sets_of(&h.video.extradata, VideoCodec::H264);
        assert!(parameter_sets_complete(&ps, VideoCodec::H264));
        assert!(!parameter_sets_complete(&[0, 0, 0, 1, 0x67, 1], VideoCodec::H264));
    }
}
