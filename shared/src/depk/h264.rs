//! H.264 (RFC 6184): NAL único, STAP-A e FU-A.

use super::{annexb, Depacketizer};
use crate::media::{flags, Sample, TrackKind};
use crate::rtp::RtpPacket;

const STAP_A: u8 = 24;
const FU_A: u8 = 28;

pub struct H264Depacketizer {
    track_id: u8,
    fu: Vec<u8>,
    fu_started: bool,
    fu_pts: i64,
}

impl H264Depacketizer {
    pub fn new(track_id: u8) -> Self {
        Self { track_id, fu: Vec::with_capacity(64 * 1024), fu_started: false, fu_pts: 0 }
    }

    fn emit(&self, nal: &[u8], pts: i64, out: &mut Vec<Sample>) {
        if nal.is_empty() {
            return;
        }
        out.push(Sample {
            kind: TrackKind::Video,
            track_id: self.track_id,
            pts,
            flags: if unit_is_keyframe(nal) { flags::KEYFRAME } else { 0 },
            data: annexb(nal),
        });
    }
}

/// Ponto de entrada para o decodificador? IDR (5), ou uma unidade que abre com
/// SPS/PPS e traz um slice dentro — há câmera que manda o access unit inteiro
/// numa unidade só, declarando o tipo da PRIMEIRA NAL.
pub fn unit_is_keyframe(nal: &[u8]) -> bool {
    let Some(&first) = nal.first() else { return false };
    let t = first & 0x1F;
    if t == 5 {
        return true;
    }
    if t != 7 && t != 8 {
        return false;
    }
    let mut i = 0;
    while i + 5 <= nal.len() {
        if nal[i] == 0 && nal[i + 1] == 0 {
            let t = if nal[i + 2] == 1 {
                Some(nal[i + 3] & 0x1F)
            } else if nal[i + 2] == 0 && nal[i + 3] == 1 {
                Some(nal[i + 4] & 0x1F)
            } else {
                None
            };
            if matches!(t, Some(1) | Some(5)) {
                return true;
            }
        }
        i += 1;
    }
    false
}

impl Depacketizer for H264Depacketizer {
    fn kind(&self) -> TrackKind {
        TrackKind::Video
    }

    fn feed(&mut self, p: &RtpPacket, out: &mut Vec<Sample>) {
        let pl = &p.payload;
        let Some(&b0) = pl.first() else { return };
        let pts = p.timestamp as i64;
        match b0 & 0x1F {
            1..=23 => self.emit(pl, pts, out),
            STAP_A => {
                let mut off = 1;
                while off + 2 <= pl.len() {
                    let n = u16::from_be_bytes([pl[off], pl[off + 1]]) as usize;
                    off += 2;
                    if n == 0 {
                        continue;
                    }
                    if off + n > pl.len() {
                        break;
                    }
                    self.emit(&pl[off..off + n], pts, out);
                    off += n;
                }
            }
            FU_A => {
                if pl.len() < 2 {
                    return;
                }
                let (ind, hdr) = (pl[0], pl[1]);
                if hdr & 0x80 != 0 {
                    self.fu.clear();
                    self.fu.push((ind & 0xE0) | (hdr & 0x1F));
                    self.fu_started = true;
                    self.fu_pts = pts;
                }
                if !self.fu_started {
                    return;
                }
                self.fu.extend_from_slice(&pl[2..]);
                if hdr & 0x40 != 0 || p.marker {
                    let nal = std::mem::take(&mut self.fu);
                    self.emit(&nal, self.fu_pts, out);
                    self.fu = nal;
                    self.fu.clear();
                    self.fu_started = false;
                }
            }
            _ => {}
        }
    }

    fn reset(&mut self) {
        self.fu.clear();
        self.fu_started = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pkt(ts: u32, marker: bool, payload: Vec<u8>) -> RtpPacket {
        RtpPacket { timestamp: ts, marker, payload, ..Default::default() }
    }

    #[test]
    fn nal_unico_e_stap_a() {
        let mut d = H264Depacketizer::new(0);
        let mut out = Vec::new();
        d.feed(&pkt(100, true, vec![0x65, 1, 2]), &mut out);
        let stap = vec![24, 0, 2, 0x67, 9, 0, 1, 0x68];
        d.feed(&pkt(200, true, stap), &mut out);
        assert_eq!(out.len(), 3);
        assert!(out[0].is_keyframe());
        assert_eq!(out[0].data, vec![0, 0, 0, 1, 0x65, 1, 2]);
        assert_eq!(out[1].data, vec![0, 0, 0, 1, 0x67, 9]);
        assert_eq!(out[2].pts, 200);
        assert!(!out[2].is_keyframe());
    }

    #[test]
    fn fu_a_remonta_o_quadro() {
        let mut d = H264Depacketizer::new(0);
        let mut out = Vec::new();
        // FU-A de um IDR (tipo 5), nri 3.
        d.feed(&pkt(9, false, vec![0x7C, 0x85, 1, 2]), &mut out);
        d.feed(&pkt(9, false, vec![0x7C, 0x05, 3]), &mut out);
        assert!(out.is_empty());
        d.feed(&pkt(9, true, vec![0x7C, 0x45, 4]), &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].data, vec![0, 0, 0, 1, 0x65, 1, 2, 3, 4]);
        assert!(out[0].is_keyframe());
        // Fragmento do meio sem o começo: descartado.
        d.feed(&pkt(10, true, vec![0x7C, 0x45, 7]), &mut out);
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn unidade_que_comeca_por_sps_e_traz_idr() {
        assert!(unit_is_keyframe(&[0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 3]));
        assert!(!unit_is_keyframe(&[0x67, 1, 2, 3]));
        assert!(!unit_is_keyframe(&[0x41, 1]));
    }
}
