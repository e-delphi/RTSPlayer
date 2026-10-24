//! MJPEG (RFC 2435). O RTP leva só os dados entrópicos; o cabeçalho JPEG
//! (DQT, SOF0, DHT, SOS) é reconstruído a partir do tipo, do Q e do tamanho.
//!
//! Diferença do Delphi: lá as tabelas de quantização que vinham no pacote
//! (Q >= 128) eram lidas e logo apagadas pelo reset do acúmulo, e o quadro saía
//! sempre com as tabelas padrão. Aqui elas valem.

use super::Depacketizer;
use crate::media::{flags, Sample, TrackKind};
use crate::rtp::RtpPacket;

const STD_LUM: [u8; 64] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18,
    22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103,
    99,
];
const STD_CHROM: [u8; 64] = [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
];
const LUM_DC_BITS: [u8; 16] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const DC_VAL: [u8; 12] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const LUM_AC_BITS: [u8; 16] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D];
const LUM_AC_VAL: [u8; 162] = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81,
    0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18,
    0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
    0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
    0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5,
    0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
];
const CHROM_DC_BITS: [u8; 16] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const CHROM_AC_BITS: [u8; 16] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const CHROM_AC_VAL: [u8; 162] = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08,
    0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25,
    0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47,
    0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74,
    0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
    0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA,
    0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE2, 0xE3, 0xE4,
    0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
];

/// As tabelas padrão escaladas pelo Q (1..99), como a RFC manda.
pub fn std_quant_tables(q: u8) -> ([u8; 64], [u8; 64]) {
    let q = q.max(1) as i32;
    let factor = if q > 99 { 200 - q * 2 } else { 5000 / q };
    let scale = |t: &[u8; 64]| {
        let mut o = [0u8; 64];
        for i in 0..64 {
            o[i] = ((t[i] as i32 * factor + 50) / 100).clamp(1, 255) as u8;
        }
        o
    };
    (scale(&STD_LUM), scale(&STD_CHROM))
}

/// Cabeçalho JPEG completo até o SOS, pronto para os dados entrópicos.
pub fn build_jpeg_header(typ: u8, w: u16, h: u16, lum: &[u8], chrom: &[u8], restart: u16) -> Vec<u8> {
    let mut b = vec![0xFF, 0xD8];
    // DQT
    b.extend_from_slice(&[0xFF, 0xDB, 0x00, 0x84, 0x00]);
    b.extend_from_slice(lum);
    b.push(0x01);
    b.extend_from_slice(chrom);
    if restart > 0 {
        b.extend_from_slice(&[0xFF, 0xDD, 0x00, 0x04]);
        b.extend_from_slice(&restart.to_be_bytes());
    }
    // SOF0: tipo 1 = 4:2:0, tipo 0 = 4:2:2.
    let cy = if typ & 1 != 0 { 0x22 } else { 0x21 };
    b.extend_from_slice(&[0xFF, 0xC0, 0x00, 17, 0x08]);
    b.extend_from_slice(&h.to_be_bytes());
    b.extend_from_slice(&w.to_be_bytes());
    b.extend_from_slice(&[0x03, 0x01, cy, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
    // DHT
    let total = 2 + (1 + 16 + 12) + (1 + 16 + 162) + (1 + 16 + 12) + (1 + 16 + 162);
    b.extend_from_slice(&[0xFF, 0xC4]);
    b.extend_from_slice(&(total as u16).to_be_bytes());
    b.push(0x00);
    b.extend_from_slice(&LUM_DC_BITS);
    b.extend_from_slice(&DC_VAL);
    b.push(0x10);
    b.extend_from_slice(&LUM_AC_BITS);
    b.extend_from_slice(&LUM_AC_VAL);
    b.push(0x01);
    b.extend_from_slice(&CHROM_DC_BITS);
    b.extend_from_slice(&DC_VAL);
    b.push(0x11);
    b.extend_from_slice(&CHROM_AC_BITS);
    b.extend_from_slice(&CHROM_AC_VAL);
    // SOS
    b.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00]);
    b
}

pub struct MjpegDepacketizer {
    track_id: u8,
    buf: Vec<u8>,
    started: bool,
    pts: i64,
}

impl MjpegDepacketizer {
    pub fn new(track_id: u8) -> Self {
        Self { track_id, buf: Vec::with_capacity(128 * 1024), started: false, pts: 0 }
    }
}

impl Depacketizer for MjpegDepacketizer {
    fn kind(&self) -> TrackKind {
        TrackKind::Video
    }

    fn feed(&mut self, p: &RtpPacket, out: &mut Vec<Sample>) {
        let pl = &p.payload;
        if pl.len() < 8 {
            return;
        }
        let frag = u32::from_be_bytes([0, pl[1], pl[2], pl[3]]);
        let (typ, q, w8, h8) = (pl[4], pl[5], pl[6], pl[7]);
        let mut off = 8;
        let mut restart = 0u16;
        if typ >= 64 {
            if pl.len() < off + 4 {
                return;
            }
            restart = u16::from_be_bytes([pl[off], pl[off + 1]]);
            off += 4;
        }
        let mut tables: Option<Vec<u8>> = None;
        if frag == 0 && q >= 128 {
            if pl.len() < off + 4 {
                return;
            }
            let len = u16::from_be_bytes([pl[off + 2], pl[off + 3]]) as usize;
            off += 4;
            if pl.len() < off + len {
                return;
            }
            tables = Some(pl[off..off + len].to_vec());
            off += len;
        }
        if frag == 0 {
            self.buf.clear();
            self.started = true;
            self.pts = p.timestamp as i64;
            let (lum, chrom) = match &tables {
                Some(t) if t.len() == 128 => {
                    let mut l = [0u8; 64];
                    let mut c = [0u8; 64];
                    l.copy_from_slice(&t[..64]);
                    c.copy_from_slice(&t[64..]);
                    (l, c)
                }
                _ => std_quant_tables(q),
            };
            let hdr = build_jpeg_header(typ & 0x3F, w8 as u16 * 8, h8 as u16 * 8, &lum, &chrom, restart);
            self.buf.extend_from_slice(&hdr);
        } else if !self.started {
            return;
        }
        self.buf.extend_from_slice(&pl[off..]);
        if p.marker {
            self.buf.extend_from_slice(&[0xFF, 0xD9]);
            out.push(Sample { kind: TrackKind::Video, track_id: self.track_id, pts: self.pts, flags: flags::KEYFRAME, data: std::mem::take(&mut self.buf) });
            self.buf = Vec::with_capacity(128 * 1024);
            self.started = false;
        }
    }

    fn reset(&mut self) {
        self.buf.clear();
        self.started = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quadro_em_dois_pacotes_vira_jpeg() {
        let mut d = MjpegDepacketizer::new(0);
        let mut out = Vec::new();
        let hdr = |frag: u32| {
            let f = frag.to_be_bytes();
            vec![0, f[1], f[2], f[3], 1, 50, 80, 60]
        };
        let mut a = hdr(0);
        a.extend_from_slice(&[1, 2, 3]);
        let mut b = hdr(3);
        b.extend_from_slice(&[4, 5]);
        d.feed(&RtpPacket { timestamp: 3000, payload: a, ..Default::default() }, &mut out);
        d.feed(&RtpPacket { timestamp: 3000, marker: true, payload: b, ..Default::default() }, &mut out);
        assert_eq!(out.len(), 1);
        let j = &out[0].data;
        assert_eq!(&j[..2], &[0xFF, 0xD8]);
        assert_eq!(&j[j.len() - 7..], &[1, 2, 3, 4, 5, 0xFF, 0xD9]);
        // SOF0 com 640x480.
        let sof = j.windows(2).position(|w| w == [0xFF, 0xC0]).unwrap();
        assert_eq!(u16::from_be_bytes([j[sof + 5], j[sof + 6]]), 480);
        assert_eq!(u16::from_be_bytes([j[sof + 7], j[sof + 8]]), 640);
    }

    #[test]
    fn tabelas_do_pacote_valem() {
        let mut d = MjpegDepacketizer::new(0);
        let mut out = Vec::new();
        let mut p = vec![0, 0, 0, 0, 1, 255, 10, 10, 0, 0, 0, 128];
        p.extend(std::iter::repeat(7u8).take(128));
        p.push(0xAB);
        d.feed(&RtpPacket { marker: true, payload: p, ..Default::default() }, &mut out);
        let j = &out[0].data;
        assert_eq!(&j[2..7], &[0xFF, 0xDB, 0x00, 0x84, 0x00]);
        assert_eq!(j[7], 7, "a tabela que veio no pacote");
        assert_eq!(std_quant_tables(50).0[0], 16);
    }
}
