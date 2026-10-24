//! Os frames de mídia XM que vêm no payload das mensagens DVRIP:
//!
//! ```text
//! FC / FE  I-frame  00 00 01 FC | tipo | fps | res(2) | ts(4) | length LE32 (header 16)
//! FD       P-frame  00 00 01 FD | length LE32                         (header 8)
//! FA       áudio    00 00 01 FA | fmt | ? | length LE16               (header 8)
//! F8/F9/FB info     00 00 01 Fx | ... | length LE16 em 6              (header 8, ignorado)
//! ```
//!
//! O que vem depois do header já é Annex-B.

use std::collections::BTreeMap;

use crate::media::{AudioCodec, VideoCodec};

/// Teto sadio de um frame: length acima disto é header errado → ressincroniza.
const MAX_FRAME: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaFrame {
    Video { annexb: Vec<u8>, keyframe: bool, codec: VideoCodec },
    Audio { data: Vec<u8>, codec: AudioCodec },
}

pub struct MediaParser {
    buf: Vec<u8>,
    codec: Option<VideoCodec>,
    resyncs: u32,
    resync_win: u32,
    type_frames: BTreeMap<u8, (u32, u64)>,
    fed: u64,
    /// O que vale a pena avisar (tipo desconhecido, ressincronia), uma vez.
    pub warnings: Vec<String>,
    warned: [bool; 256],
}

fn is_marker(t: u8) -> bool {
    matches!(t, 0xFC | 0xFD | 0xFE | 0xFA | 0xF8 | 0xF9 | 0xFB)
}

impl Default for MediaParser {
    fn default() -> Self {
        Self::new()
    }
}

impl MediaParser {
    pub fn new() -> Self {
        Self {
            buf: Vec::new(),
            codec: None,
            resyncs: 0,
            resync_win: 0,
            type_frames: BTreeMap::new(),
            fed: 0,
            warnings: Vec::new(),
            warned: [false; 256],
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    fn find_marker(&self, from: usize) -> Option<usize> {
        let b = &self.buf;
        (from..b.len().saturating_sub(3)).find(|&i| b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 && is_marker(b[i + 3]))
    }

    fn count(&mut self, t: u8, len: usize) {
        let e = self.type_frames.entry(t).or_default();
        e.0 += 1;
        e.1 += len as u64;
    }

    fn warn_once(&mut self, t: u8, msg: String) {
        if !self.warned[t as usize] {
            self.warned[t as usize] = true;
            self.warnings.push(msg);
        }
    }

    /// Junta os bytes e devolve os frames que completaram.
    pub fn feed(&mut self, data: &[u8]) -> Vec<MediaFrame> {
        self.fed += data.len() as u64;
        self.buf.extend_from_slice(data);
        let mut out = Vec::new();
        let mut p = 0usize;
        while self.buf.len() - p >= 8 {
            let b = &self.buf;
            if !(b[p] == 0 && b[p + 1] == 0 && b[p + 2] == 1) {
                let Some(q) = self.find_marker(p + 1) else { break };
                self.resyncs += 1;
                self.resync_win += 1;
                if self.resyncs <= 20 {
                    self.warnings.push(format!("ressincronizou (pulou {} bytes de lixo)", q - p));
                }
                p = q;
                continue;
            }
            let t = b[p + 3];
            let le32 = |o: usize| u32::from_le_bytes(self.buf[o..o + 4].try_into().unwrap()) as usize;
            let le16 = |o: usize| u16::from_le_bytes([self.buf[o], self.buf[o + 1]]) as usize;
            match t {
                0xFC | 0xFE | 0xFD => {
                    let hl = if t == 0xFD { 8 } else { 16 };
                    if self.buf.len() - p < hl {
                        break;
                    }
                    let len = if t == 0xFD { le32(p + 4) } else { le32(p + 12) };
                    if len > MAX_FRAME {
                        self.resyncs += 1;
                        self.resync_win += 1;
                        if self.resyncs <= 20 {
                            self.warnings.push(format!("frame {t:02X} com length insano ({len}) -> ressync"));
                        }
                        let Some(q) = self.find_marker(p + 1) else { break };
                        p = q;
                        continue;
                    }
                    if self.buf.len() - p < hl + len {
                        break;
                    }
                    self.count(t, len);
                    let nal = self.buf[p + hl..p + hl + len].to_vec();
                    let key = t != 0xFD;
                    if self.codec.is_none() && key {
                        self.codec = Some(detect_codec(&nal));
                    }
                    if !nal.is_empty() {
                        out.push(MediaFrame::Video { annexb: nal, keyframe: key, codec: self.codec.unwrap_or(VideoCodec::H264) });
                    }
                    p += hl + len;
                }
                0xFA => {
                    let len = le16(p + 6);
                    if self.buf.len() - p < 8 + len {
                        break;
                    }
                    self.count(t, len);
                    let fmt = self.buf[p + 4];
                    let codec = match fmt {
                        0x0A | 0x07 => AudioCodec::G711U,
                        _ => AudioCodec::G711A,
                    };
                    if len > 0 {
                        out.push(MediaFrame::Audio { data: self.buf[p + 8..p + 8 + len].to_vec(), codec });
                    }
                    p += 8 + len;
                }
                0xF8 | 0xF9 | 0xFB => {
                    let len = le16(p + 6);
                    if self.buf.len() - p < 8 + len {
                        break;
                    }
                    self.count(t, len);
                    let hex = crate::dvrip::protocol::bytes_to_hex(&self.buf[p..], 24);
                    self.warn_once(t, format!("frame 00 00 01 {t:02x} descartado (len={len}) [{hex}]"));
                    p += 8 + len;
                }
                _ => {
                    self.resync_win += 1;
                    self.count(t, 0);
                    let hex = crate::dvrip::protocol::bytes_to_hex(&self.buf[p..], 16);
                    self.warn_once(t, format!("marcador de frame desconhecido: 00 00 01 {t:02x} [{hex}]"));
                    let Some(q) = self.find_marker(p + 1) else { break };
                    p = q;
                }
            }
        }
        if p > 0 {
            self.buf.drain(..p);
        }
        out
    }

    /// `in=612000B fc=2(184320B) fd=48(390000B)`, e zera a janela.
    pub fn take_stats(&mut self) -> String {
        let mut s = format!("in={}B", self.fed);
        self.fed = 0;
        if self.resync_win > 0 {
            s.push_str(&format!(" ressync={}", self.resync_win));
        }
        self.resync_win = 0;
        for (t, (n, b)) in std::mem::take(&mut self.type_frames) {
            s.push_str(&format!(" {t:02x}={n}({b}B)"));
        }
        s
    }
}

/// O primeiro NAL do I-frame é sempre um param set: 32/33/34 só no H.265.
pub fn detect_codec(annexb: &[u8]) -> VideoCodec {
    let mut i = 0;
    while i < annexb.len() && annexb[i] == 0 {
        i += 1;
    }
    if i < annexb.len() && annexb[i] == 1 {
        i += 1;
    }
    match annexb.get(i) {
        Some(&b) if matches!((b >> 1) & 0x3F, 32..=34) => VideoCodec::H265,
        _ => VideoCodec::H264,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn iframe(nal: &[u8]) -> Vec<u8> {
        let mut v = vec![0, 0, 1, 0xFC, 2, 25, 0, 0, 0, 0, 0, 0];
        v.extend_from_slice(&(nal.len() as u32).to_le_bytes());
        v.extend_from_slice(nal);
        v
    }

    #[test]
    fn i_p_e_audio_mesmo_cortados() {
        let mut s = iframe(&[0, 0, 0, 1, 0x40, 1, 9]);
        s.extend_from_slice(&[0, 0, 1, 0xFD, 3, 0, 0, 0, 0xAA, 0xBB, 0xCC]);
        s.extend_from_slice(&[0, 0, 1, 0xFA, 0x0E, 0, 2, 0, 0xD5, 0xD5]);
        let mut m = MediaParser::new();
        let mut frames = Vec::new();
        for c in s.chunks(5) {
            frames.extend(m.feed(c));
        }
        assert_eq!(frames.len(), 3);
        assert!(matches!(&frames[0], MediaFrame::Video { keyframe: true, codec: VideoCodec::H265, .. }));
        assert!(matches!(&frames[1], MediaFrame::Video { keyframe: false, codec: VideoCodec::H265, annexb } if annexb == &vec![0xAA, 0xBB, 0xCC]));
        assert!(matches!(&frames[2], MediaFrame::Audio { codec: AudioCodec::G711A, .. }));
        let st = m.take_stats();
        assert!(st.contains("fc=1(7B)") && st.contains("fa=1(2B)"), "{st}");
    }

    #[test]
    fn lixo_e_marcador_desconhecido() {
        let mut s = vec![1, 2, 3, 4, 5, 6, 7, 8, 9];
        s.extend_from_slice(&[0, 0, 1, 0xF9, 0, 0, 1, 0, 0x77]);
        s.extend(iframe(&[0, 0, 0, 1, 0x67, 1]));
        let mut m = MediaParser::new();
        let f = m.feed(&s);
        assert_eq!(f.len(), 1);
        assert!(m.warnings.iter().any(|w| w.contains("ressincronizou")));
        assert!(m.warnings.iter().any(|w| w.contains("f9 descartado")));
        assert_eq!(detect_codec(&[0, 0, 0, 1, 0x67]), VideoCodec::H264);
    }
}
