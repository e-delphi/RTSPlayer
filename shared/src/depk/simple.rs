//! Áudio: AAC (RFC 3640, AU headers) e os que passam o payload direto (G.711,
//! G.726, PCM L16).

use super::Depacketizer;
use crate::media::{Sample, TrackKind};
use crate::rtp::RtpPacket;

/// G.711, G.726 e PCM: o payload É o áudio.
pub struct PassthroughAudio {
    track_id: u8,
}

impl PassthroughAudio {
    pub fn new(track_id: u8) -> Self {
        Self { track_id }
    }
}

impl Depacketizer for PassthroughAudio {
    fn kind(&self) -> TrackKind {
        TrackKind::Audio
    }
    fn feed(&mut self, p: &RtpPacket, out: &mut Vec<Sample>) {
        if !p.payload.is_empty() {
            out.push(Sample { kind: TrackKind::Audio, track_id: self.track_id, pts: p.timestamp as i64, flags: 0, data: p.payload.clone() });
        }
    }
}

pub struct AacDepacketizer {
    track_id: u8,
    size_len: u32,
    index_len: u32,
    index_delta_len: u32,
}

impl AacDepacketizer {
    pub fn new(track_id: u8) -> Self {
        Self { track_id, size_len: 13, index_len: 3, index_delta_len: 3 }
    }

    pub fn set_mode(&mut self, size_len: i32, index_len: i32, index_delta_len: i32) {
        if size_len > 0 {
            self.size_len = size_len as u32;
        }
        if index_len >= 0 {
            self.index_len = index_len as u32;
        }
        if index_delta_len >= 0 {
            self.index_delta_len = index_delta_len as u32;
        }
    }
}

fn read_bits(b: &[u8], off: usize, n: u32) -> u32 {
    let mut v = 0;
    for i in 0..n as usize {
        let byte = (off + i) >> 3;
        if byte >= b.len() {
            return v;
        }
        v = (v << 1) | ((b[byte] >> (7 - ((off + i) & 7))) & 1) as u32;
    }
    v
}

impl Depacketizer for AacDepacketizer {
    fn kind(&self) -> TrackKind {
        TrackKind::Audio
    }

    fn feed(&mut self, p: &RtpPacket, out: &mut Vec<Sample>) {
        let pl = &p.payload;
        if pl.len() < 2 {
            return;
        }
        let headers_bits = u16::from_be_bytes([pl[0], pl[1]]) as usize;
        let header_bytes = headers_bits.div_ceil(8);
        if 2 + header_bytes > pl.len() {
            return;
        }
        let per = (self.size_len + self.index_len) as usize;
        if per == 0 {
            return;
        }
        let n = headers_bits / per;
        let mut sizes = Vec::with_capacity(n);
        let mut bit = 16;
        for i in 0..n {
            sizes.push(read_bits(pl, bit, self.size_len) as usize);
            bit += (self.size_len + if i == 0 { self.index_len } else { self.index_delta_len }) as usize;
        }
        let mut at = 2 + header_bytes;
        for (i, len) in sizes.into_iter().enumerate() {
            if len == 0 {
                continue;
            }
            if at + len > pl.len() {
                break;
            }
            out.push(Sample {
                kind: TrackKind::Audio,
                track_id: self.track_id,
                pts: p.timestamp as i64 + i as i64 * 1024,
                flags: 0,
                data: pl[at..at + len].to_vec(),
            });
            at += len;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aac_com_dois_au() {
        // AU-headers-length = 32 bits; dois headers de 16 bits (13 de tamanho + 3 de índice).
        let mut pl = vec![0x00, 0x20];
        pl.extend_from_slice(&((3u16 << 3).to_be_bytes()));
        pl.extend_from_slice(&((2u16 << 3).to_be_bytes()));
        pl.extend_from_slice(&[1, 2, 3, 4, 5]);
        let mut d = AacDepacketizer::new(1);
        let mut out = Vec::new();
        d.feed(&RtpPacket { timestamp: 1000, payload: pl, ..Default::default() }, &mut out);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].data, vec![1, 2, 3]);
        assert_eq!(out[1].data, vec![4, 5]);
        assert_eq!(out[1].pts, 2024);
        assert_eq!(out[1].track_id, 1);
    }

    #[test]
    fn g711_passa_direto() {
        let mut d = PassthroughAudio::new(1);
        let mut out = Vec::new();
        d.feed(&RtpPacket { timestamp: 5, payload: vec![0xD5; 160], ..Default::default() }, &mut out);
        assert_eq!(out[0].data.len(), 160);
        assert_eq!(out[0].kind, TrackKind::Audio);
    }
}
