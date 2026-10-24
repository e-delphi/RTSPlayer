//! H.265 (RFC 7798): NAL único, AP e FU.

use super::{annexb, Depacketizer};
use crate::media::{flags, Sample, TrackKind};
use crate::rtp::RtpPacket;

const AP: u8 = 48;
const FU: u8 = 49;

pub struct H265Depacketizer {
    track_id: u8,
    fu: Vec<u8>,
    fu_started: bool,
    fu_pts: i64,
}

impl H265Depacketizer {
    pub fn new(track_id: u8) -> Self {
        Self { track_id, fu: Vec::with_capacity(64 * 1024), fu_started: false, fu_pts: 0 }
    }

    fn emit(&self, nal: &[u8], pts: i64, out: &mut Vec<Sample>) {
        if nal.len() < 2 {
            return;
        }
        let t = (nal[0] >> 1) & 0x3F;
        out.push(Sample {
            kind: TrackKind::Video,
            track_id: self.track_id,
            pts,
            // BLA, IDR e CRA: 16..21.
            flags: if (16..=21).contains(&t) { flags::KEYFRAME } else { 0 },
            data: annexb(nal),
        });
    }
}

impl Depacketizer for H265Depacketizer {
    fn kind(&self) -> TrackKind {
        TrackKind::Video
    }

    fn feed(&mut self, p: &RtpPacket, out: &mut Vec<Sample>) {
        let pl = &p.payload;
        if pl.len() < 2 {
            return;
        }
        let pts = p.timestamp as i64;
        match (pl[0] >> 1) & 0x3F {
            0..=47 => self.emit(pl, pts, out),
            AP => {
                let mut off = 2;
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
            FU => {
                if pl.len() < 3 {
                    return;
                }
                let fh = pl[2];
                if fh & 0x80 != 0 {
                    self.fu.clear();
                    self.fu.push((pl[0] & 0x81) | ((fh & 0x3F) << 1));
                    self.fu.push(pl[1]);
                    self.fu_started = true;
                    self.fu_pts = pts;
                }
                if !self.fu_started {
                    return;
                }
                self.fu.extend_from_slice(&pl[3..]);
                if fh & 0x40 != 0 || p.marker {
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

    #[test]
    fn fu_remonta_cabecalho_de_dois_bytes() {
        let mut d = H265Depacketizer::new(0);
        let mut out = Vec::new();
        let p = |m: bool, pl: Vec<u8>| RtpPacket { timestamp: 7, marker: m, payload: pl, ..Default::default() };
        // FU (49<<1 = 0x62), tipo original 19 (IDR_W_RADL).
        d.feed(&p(false, vec![0x62, 0x01, 0x80 | 19, 0xAA]), &mut out);
        d.feed(&p(true, vec![0x62, 0x01, 0x40 | 19, 0xBB]), &mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].data, vec![0, 0, 0, 1, 19 << 1, 0x01, 0xAA, 0xBB]);
        assert!(out[0].is_keyframe());
        // AP com VPS e SPS.
        out.clear();
        d.feed(&p(true, vec![AP << 1, 1, 0, 2, 0x40, 1, 0, 2, 0x42, 1]), &mut out);
        assert_eq!(out.len(), 2);
        assert!(!out[0].is_keyframe());
    }
}
