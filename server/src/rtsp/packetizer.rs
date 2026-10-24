//! Samples → RTP, o caminho inverso dos depacketizadores do `vms-core`: H.264
//! (single NAL / FU-A), H.265 (single / FU), MJPEG (RFC 2435, com as tabelas Q
//! no primeiro fragmento), AAC (RFC 3640 AAC-hbr, um AU por pacote) e áudio
//! "cru" (PCM, G.711, G.726) fatiado no MTU.
//!
//! O timestamp RTP é o PTS do sample (já está no clock da trilha).

use vms_core::media::{AudioCodec, VideoCodec};
use vms_core::rtp::RtpPacket;

pub const DEFAULT_MTU: usize = 1400;
const H264_FUA: u8 = 28;
const H265_FU: u8 = 49;

pub trait Packetizer: Send {
    /// Os pacotes RTP (serializados) de um sample.
    fn push(&mut self, pts: i64, data: &[u8], keyframe: bool) -> Vec<Vec<u8>>;
}

/// O que todo empacotador compartilha: número de sequência, SSRC e PT.
pub struct RtpOut {
    pub payload_type: u8,
    pub ssrc: u32,
    pub seq: u16,
    pub mtu: usize,
}

impl RtpOut {
    pub fn new(payload_type: u8, ssrc: u32, seq: u16) -> Self {
        Self { payload_type, ssrc, seq, mtu: DEFAULT_MTU }
    }

    fn emit(&mut self, out: &mut Vec<Vec<u8>>, marker: bool, ts: u32, payload: Vec<u8>) {
        out.push(RtpPacket { marker, payload_type: self.payload_type, sequence: self.seq, timestamp: ts, ssrc: self.ssrc, payload }.serialize());
        self.seq = self.seq.wrapping_add(1);
    }
}

/// Os NALs sem start code.
pub fn split_annexb(data: &[u8]) -> Vec<&[u8]> {
    vms_core::h26x::nals(data).into_iter().filter(|n| !n.is_empty()).collect()
}

pub struct H264Packetizer(pub RtpOut);

impl Packetizer for H264Packetizer {
    fn push(&mut self, pts: i64, data: &[u8], _: bool) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let nals = split_annexb(data);
        let ts = pts as u32;
        for (i, nal) in nals.iter().enumerate() {
            let marker = i + 1 == nals.len();
            if nal.len() <= self.0.mtu {
                self.0.emit(&mut out, marker, ts, nal.to_vec());
                continue;
            }
            if nal.len() < 2 {
                continue;
            }
            let (hdr, typ) = (nal[0], nal[0] & 0x1F);
            let ind = (hdr & 0xE0) | H264_FUA;
            let max = self.0.mtu - 2;
            let mut off = 1;
            while off < nal.len() {
                let n = (nal.len() - off).min(max);
                let end = off + n >= nal.len();
                let fu = typ | if off == 1 { 0x80 } else { 0 } | if end { 0x40 } else { 0 };
                let mut p = Vec::with_capacity(2 + n);
                p.extend_from_slice(&[ind, fu]);
                p.extend_from_slice(&nal[off..off + n]);
                self.0.emit(&mut out, end && marker, ts, p);
                off += n;
            }
        }
        out
    }
}

pub struct H265Packetizer(pub RtpOut);

impl Packetizer for H265Packetizer {
    fn push(&mut self, pts: i64, data: &[u8], _: bool) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let nals = split_annexb(data);
        let ts = pts as u32;
        for (i, nal) in nals.iter().enumerate() {
            let marker = i + 1 == nals.len();
            if nal.len() <= self.0.mtu {
                self.0.emit(&mut out, marker, ts, nal.to_vec());
                continue;
            }
            if nal.len() < 3 {
                continue;
            }
            let typ = (nal[0] >> 1) & 0x3F;
            let h0 = (nal[0] & 0x81) | (H265_FU << 1);
            let max = self.0.mtu - 3;
            let mut off = 2;
            while off < nal.len() {
                let n = (nal.len() - off).min(max);
                let end = off + n >= nal.len();
                let fu = typ | if off == 2 { 0x80 } else { 0 } | if end { 0x40 } else { 0 };
                let mut p = Vec::with_capacity(3 + n);
                p.extend_from_slice(&[h0, nal[1], fu]);
                p.extend_from_slice(&nal[off..off + n]);
                self.0.emit(&mut out, end && marker, ts, p);
                off += n;
            }
        }
        out
    }
}

pub struct AacPacketizer(pub RtpOut);

impl Packetizer for AacPacketizer {
    fn push(&mut self, pts: i64, data: &[u8], _: bool) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if data.is_empty() {
            return out;
        }
        // AU-headers-length = 16 bits; um AU-header: 13 de tamanho + 3 de índice.
        let au = ((data.len() & 0x1FFF) << 3) as u16;
        let mut p = vec![0x00, 0x10, (au >> 8) as u8, au as u8];
        p.extend_from_slice(data);
        self.0.emit(&mut out, true, pts as u32, p);
        out
    }
}

pub struct PassthroughPacketizer(pub RtpOut);

impl Packetizer for PassthroughPacketizer {
    fn push(&mut self, pts: i64, data: &[u8], _: bool) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let chunks: Vec<&[u8]> = data.chunks(self.0.mtu.max(1)).collect();
        for (i, c) in chunks.iter().enumerate() {
            self.0.emit(&mut out, i + 1 == chunks.len(), pts as u32, c.to_vec());
        }
        out
    }
}

#[derive(Debug, Default, PartialEq)]
struct JpegMeta {
    width: u16,
    height: u16,
    typ: u8,
    restart: u16,
    qtables: Vec<u8>,
    data_off: usize,
    data_end: usize,
}

fn be16(d: &[u8], i: usize) -> u16 {
    ((d[i] as u16) << 8) | d[i + 1] as u16
}

/// O que o cabeçalho RTP/JPEG precisa: tamanho, tipo (4:2:0 = 1), DRI, as
/// tabelas Q de 8 bits e onde começa a parte entrópica.
fn parse_jpeg(d: &[u8]) -> Option<JpegMeta> {
    if d.len() < 4 || d[0] != 0xFF || d[1] != 0xD8 {
        return None;
    }
    let mut m = JpegMeta::default();
    let mut p = 2;
    while p + 1 < d.len() {
        if d[p] != 0xFF {
            return None;
        }
        let mut marker = d[p + 1];
        p += 2;
        while p < d.len() && marker == 0xFF {
            marker = d[p];
            p += 1;
        }
        match marker {
            0xD8 | 0x01 | 0xD0..=0xD7 => continue,
            0xD9 => break,
            _ => {}
        }
        if p + 2 > d.len() {
            return None;
        }
        let len = be16(d, p) as usize;
        if len < 2 || p + len > d.len() {
            return None;
        }
        match marker {
            0xDB => {
                let mut t = p + 2;
                for _ in 0..(len - 2) / 65 {
                    if t + 64 >= d.len() {
                        break;
                    }
                    if d[t] >> 4 != 0 {
                        return None; // tabela de 16 bits: o RTP/JPEG não leva
                    }
                    m.qtables.extend_from_slice(&d[t + 1..t + 65]);
                    t += 65;
                }
            }
            0xDD => {
                if len != 4 {
                    return None;
                }
                m.restart = be16(d, p + 2);
            }
            0xC0 => {
                if len < 8 {
                    return None;
                }
                m.height = be16(d, p + 3);
                m.width = be16(d, p + 5);
                let ys = if d[p + 7] >= 1 { d[p + 9] } else { 0x11 };
                m.typ = if ys == 0x22 { 1 } else { 0 };
            }
            0xDA => {
                m.data_off = p + len;
                m.data_end = (m.data_off..d.len().saturating_sub(1)).rev().find(|&k| d[k] == 0xFF && d[k + 1] == 0xD9).unwrap_or(d.len());
                if m.restart > 0 {
                    m.typ |= 0x40;
                }
                return Some(m);
            }
            _ => {}
        }
        p += len;
    }
    None
}

pub struct MjpegPacketizer(pub RtpOut);

impl Packetizer for MjpegPacketizer {
    fn push(&mut self, pts: i64, data: &[u8], _: bool) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let Some(m) = parse_jpeg(data) else { return out };
        if m.data_end <= m.data_off {
            return out;
        }
        let (w8, h8) = ((m.width / 8) as u8, (m.height / 8) as u8);
        let mut frag = 0usize;
        let total = m.data_end - m.data_off;
        while frag < total {
            let extra = if m.restart > 0 { 4 } else { 0 };
            let qt = if frag == 0 && !m.qtables.is_empty() { 4 + m.qtables.len() } else { 0 };
            let Some(max) = self.0.mtu.checked_sub(8 + extra + qt).filter(|&x| x >= 64) else { return out };
            let n = (total - frag).min(max);
            let mut p = Vec::with_capacity(8 + extra + qt + n);
            // Q = 255: as tabelas vão no próprio pacote (primeiro fragmento).
            p.extend_from_slice(&[0, (frag >> 16) as u8, (frag >> 8) as u8, frag as u8, m.typ, 255, w8, h8]);
            if m.restart > 0 {
                p.extend_from_slice(&[(m.restart >> 8) as u8, m.restart as u8, 0xFF, 0xFF]);
            }
            if qt > 0 {
                p.extend_from_slice(&[0, 0, (m.qtables.len() >> 8) as u8, m.qtables.len() as u8]);
                p.extend_from_slice(&m.qtables);
            }
            p.extend_from_slice(&data[m.data_off + frag..m.data_off + frag + n]);
            frag += n;
            self.0.emit(&mut out, frag >= total, pts as u32, p);
        }
        out
    }
}

pub fn video_payload_type(c: VideoCodec) -> u8 {
    if c == VideoCodec::Mjpeg {
        26
    } else {
        96
    }
}

pub fn audio_payload_type(c: AudioCodec) -> u8 {
    match c {
        AudioCodec::G711U => 0,
        AudioCodec::G711A => 8,
        _ => 97,
    }
}

pub fn for_video(c: VideoCodec, ssrc: u32, seq: u16) -> Option<Box<dyn Packetizer>> {
    let o = RtpOut::new(video_payload_type(c), ssrc, seq);
    match c {
        VideoCodec::H264 => Some(Box::new(H264Packetizer(o))),
        VideoCodec::H265 => Some(Box::new(H265Packetizer(o))),
        VideoCodec::Mjpeg => Some(Box::new(MjpegPacketizer(o))),
        VideoCodec::None => None,
    }
}

pub fn for_audio(c: AudioCodec, ssrc: u32, seq: u16) -> Option<Box<dyn Packetizer>> {
    let o = RtpOut::new(audio_payload_type(c), ssrc, seq);
    match c {
        AudioCodec::Aac => Some(Box::new(AacPacketizer(o))),
        AudioCodec::None => None,
        _ => Some(Box::new(PassthroughPacketizer(o))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::depk;

    fn ida_e_volta(p: &mut dyn Packetizer, d: &mut dyn depk::Depacketizer, data: &[u8]) -> Vec<Vec<u8>> {
        let mut samples = Vec::new();
        for pkt in p.push(90_000, data, true) {
            d.feed(&RtpPacket::parse(&pkt).unwrap(), &mut samples);
        }
        assert!(samples.iter().all(|s| s.pts == 90_000));
        samples.into_iter().map(|s| s.data).collect()
    }

    #[test]
    fn h264_nal_grande_vira_fu_a_e_volta_igual() {
        let mut au = vec![0, 0, 0, 1, 0x67, 1, 2, 3, 0, 0, 0, 1, 0x65];
        au.extend((0..5000u32).map(|i| (i % 251) as u8 | 1));
        let mut p = for_video(VideoCodec::H264, 1, 65534).unwrap();
        let pkts = p.push(0, &au, true);
        assert!(pkts.len() > 4, "fatiado");
        assert!(pkts.iter().all(|b| b.len() <= 12 + DEFAULT_MTU));
        assert_eq!(pkts.iter().filter(|b| b[1] & 0x80 != 0).count(), 1, "um marcador, no fim");
        let mut d = depk::for_video(VideoCodec::H264).unwrap();
        let out = ida_e_volta(p.as_mut(), d.as_mut(), &au);
        assert_eq!(out.concat(), au);
    }

    #[test]
    fn h265_e_aac_e_passthrough() {
        let mut au = vec![0, 0, 0, 1, 0x26, 0x01];
        au.extend(std::iter::repeat(7u8).take(3000));
        let mut p = for_video(VideoCodec::H265, 1, 0).unwrap();
        let mut d = depk::for_video(VideoCodec::H265).unwrap();
        assert_eq!(ida_e_volta(p.as_mut(), d.as_mut(), &au).concat(), au);

        let mut p = for_audio(AudioCodec::Aac, 1, 0).unwrap();
        let mut d = depk::for_audio(AudioCodec::Aac, "sizelength=13;indexlength=3;indexdeltalength=3").unwrap();
        assert_eq!(ida_e_volta(p.as_mut(), d.as_mut(), &[9u8; 300]).concat(), vec![9u8; 300]);

        let mut p = for_audio(AudioCodec::G711A, 1, 0).unwrap();
        assert_eq!(p.push(5, &[1u8; 3000], false).len(), 3);
        assert_eq!(audio_payload_type(AudioCodec::G711U), 0);
    }

    #[test]
    fn jpeg_meta() {
        // SOI, DQT (1 tabela), SOF0 4:2:0, SOS, dados, EOI
        let mut j = vec![0xFF, 0xD8, 0xFF, 0xDB, 0, 67, 0];
        j.extend(1..=64u8);
        j.extend_from_slice(&[0xFF, 0xC0, 0, 17, 8, 0, 16, 0, 32, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
        j.extend_from_slice(&[0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0]);
        j.extend(std::iter::repeat(0x55).take(4000));
        j.extend_from_slice(&[0xFF, 0xD9]);
        let m = parse_jpeg(&j).unwrap();
        assert_eq!((m.width, m.height, m.typ, m.qtables.len()), (32, 16, 1, 64));
        assert_eq!(m.data_end - m.data_off, 4000);
        let mut p = MjpegPacketizer(RtpOut::new(26, 1, 0));
        let pkts = p.push(0, &j, true);
        assert!(pkts.len() >= 3);
        // Primeiro fragmento leva Q=255 e as tabelas.
        assert_eq!(pkts[0][12 + 5], 255);
        assert_eq!(&pkts[0][12 + 8..12 + 12], &[0, 0, 0, 64]);
        let mut d = depk::for_video(VideoCodec::Mjpeg).unwrap();
        let mut s = Vec::new();
        for b in &pkts {
            d.feed(&RtpPacket::parse(b).unwrap(), &mut s);
        }
        assert_eq!(s.len(), 1, "o depacketizador remonta o quadro");
    }
}
