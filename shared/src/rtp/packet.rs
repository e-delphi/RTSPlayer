//! Pacote RTP (RFC 3550): cabeçalho fixo, CSRC, extensão e padding.

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RtpPacket {
    pub marker: bool,
    pub payload_type: u8,
    pub sequence: u16,
    pub timestamp: u32,
    pub ssrc: u32,
    pub payload: Vec<u8>,
}

impl RtpPacket {
    pub fn parse(b: &[u8]) -> Option<Self> {
        if b.len() < 12 || b[0] >> 6 != 2 {
            return None;
        }
        let padding = b[0] & 0x20 != 0;
        let extension = b[0] & 0x10 != 0;
        let cc = (b[0] & 0x0F) as usize;
        let mut off = 12 + cc * 4;
        if b.len() < off {
            return None;
        }
        if extension {
            if b.len() < off + 4 {
                return None;
            }
            let ext_len = u16::from_be_bytes([b[off + 2], b[off + 3]]) as usize * 4;
            off += 4 + ext_len;
            if b.len() < off {
                return None;
            }
        }
        let mut end = b.len();
        if padding {
            let pad = *b.last()? as usize;
            if pad == 0 || pad > end - off {
                return None;
            }
            end -= pad;
        }
        Some(Self {
            marker: b[1] & 0x80 != 0,
            payload_type: b[1] & 0x7F,
            sequence: u16::from_be_bytes([b[2], b[3]]),
            timestamp: u32::from_be_bytes([b[4], b[5], b[6], b[7]]),
            ssrc: u32::from_be_bytes([b[8], b[9], b[10], b[11]]),
            payload: b[off..end].to_vec(),
        })
    }

    /// O pacote no fio (sem CSRC, sem extensão): o que o servidor RTSP manda.
    pub fn serialize(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(12 + self.payload.len());
        v.push(0x80);
        v.push((self.payload_type & 0x7F) | if self.marker { 0x80 } else { 0 });
        v.extend_from_slice(&self.sequence.to_be_bytes());
        v.extend_from_slice(&self.timestamp.to_be_bytes());
        v.extend_from_slice(&self.ssrc.to_be_bytes());
        v.extend_from_slice(&self.payload);
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ida_e_volta() {
        let p = RtpPacket { marker: true, payload_type: 96, sequence: 65535, timestamp: 90000, ssrc: 0xDEADBEEF, payload: vec![1, 2, 3] };
        let b = p.serialize();
        assert_eq!(RtpPacket::parse(&b), Some(p));
    }

    #[test]
    fn csrc_extensao_e_padding() {
        let mut b = vec![0x80 | 0x20 | 0x10 | 1, 8, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3];
        b.extend_from_slice(&[9, 9, 9, 9]); // 1 CSRC
        b.extend_from_slice(&[0xBE, 0xDE, 0, 1, 7, 7, 7, 7]); // extensão de 1 palavra
        b.extend_from_slice(&[0xAA, 0xBB]); // payload
        b.extend_from_slice(&[0, 0, 3]); // 3 de padding
        let p = RtpPacket::parse(&b).unwrap();
        assert_eq!(p.payload, vec![0xAA, 0xBB]);
        assert_eq!(p.payload_type, 8);
        assert!(RtpPacket::parse(&b[..11]).is_none());
        let mut v1 = b.clone();
        v1[0] = 0x40;
        assert!(RtpPacket::parse(&v1).is_none(), "versão 1");
    }
}
