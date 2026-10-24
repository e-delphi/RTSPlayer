//! Leitura e escrita little-endian em buffers.
//!
//! O formato `.vms`, o sidecar e o DVRIP são todos little-endian. Um lugar só
//! para isso evita a família de erros em que cada módulo monta os seus bytes à
//! mão e um deles esquece um deslocamento.

/// Escreve no fim de um `Vec<u8>`.
pub trait PutLe {
    fn put_u8(&mut self, v: u8);
    fn put_u16_le(&mut self, v: u16);
    fn put_u32_le(&mut self, v: u32);
    fn put_i64_le(&mut self, v: i64);
    fn put_u64_le(&mut self, v: u64);
    fn put_bytes(&mut self, b: &[u8]);
}

impl PutLe for Vec<u8> {
    fn put_u8(&mut self, v: u8) {
        self.push(v);
    }
    fn put_u16_le(&mut self, v: u16) {
        self.extend_from_slice(&v.to_le_bytes());
    }
    fn put_u32_le(&mut self, v: u32) {
        self.extend_from_slice(&v.to_le_bytes());
    }
    fn put_i64_le(&mut self, v: i64) {
        self.extend_from_slice(&v.to_le_bytes());
    }
    fn put_u64_le(&mut self, v: u64) {
        self.extend_from_slice(&v.to_le_bytes());
    }
    fn put_bytes(&mut self, b: &[u8]) {
        self.extend_from_slice(b);
    }
}

/// Lê em sequência de um slice. Toda leitura confere o tamanho: `None` é "o
/// buffer acabou", que para quem lê arquivo corrompido é a resposta certa — e
/// não um pânico por índice fora da faixa.
#[derive(Debug, Clone)]
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    pub fn at(buf: &'a [u8], pos: usize) -> Self {
        Self { buf, pos }
    }
    pub fn pos(&self) -> usize {
        self.pos
    }
    pub fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }
    pub fn skip(&mut self, n: usize) -> Option<()> {
        if self.remaining() < n {
            return None;
        }
        self.pos += n;
        Some(())
    }
    pub fn bytes(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.remaining() < n {
            return None;
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Some(s)
    }
    pub fn u8(&mut self) -> Option<u8> {
        self.bytes(1).map(|b| b[0])
    }
    pub fn u16_le(&mut self) -> Option<u16> {
        self.bytes(2).map(|b| u16::from_le_bytes([b[0], b[1]]))
    }
    pub fn u32_le(&mut self) -> Option<u32> {
        self.bytes(4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub fn i64_le(&mut self) -> Option<i64> {
        self.bytes(8).map(|b| i64::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn u64_le(&mut self) -> Option<u64> {
        self.bytes(8).map(|b| u64::from_le_bytes(b.try_into().unwrap()))
    }
}

/// Lê um u32 LE numa posição, sem cursor.
pub fn le_u32(b: &[u8], at: usize) -> Option<u32> {
    Reader::at(b, at).u32_le()
}

/// Lê um i64 LE numa posição, sem cursor.
pub fn le_i64(b: &[u8], at: usize) -> Option<i64> {
    Reader::at(b, at).i64_le()
}

/// Lê um u16 big-endian (RTP, SPS, ADTS).
pub fn be_u16(b: &[u8], at: usize) -> Option<u16> {
    b.get(at..at + 2).map(|s| u16::from_be_bytes([s[0], s[1]]))
}

/// Lê um u32 big-endian.
pub fn be_u32(b: &[u8], at: usize) -> Option<u32> {
    b.get(at..at + 4).map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escreve_e_le_de_volta() {
        let mut v = Vec::new();
        v.put_u8(7);
        v.put_u16_le(0x1234);
        v.put_u32_le(0xDEADBEEF);
        v.put_i64_le(-2);
        v.put_u64_le(u64::MAX);
        let mut r = Reader::new(&v);
        assert_eq!(r.u8(), Some(7));
        assert_eq!(r.u16_le(), Some(0x1234));
        assert_eq!(r.u32_le(), Some(0xDEADBEEF));
        assert_eq!(r.i64_le(), Some(-2));
        assert_eq!(r.u64_le(), Some(u64::MAX));
        assert_eq!(r.u8(), None);
        assert_eq!(v[1..3], [0x34, 0x12]);
    }

    #[test]
    fn leitura_alem_do_fim_nao_avanca() {
        let v = [1u8, 2, 3];
        let mut r = Reader::new(&v);
        assert_eq!(r.u32_le(), None);
        assert_eq!(r.pos(), 0);
        assert_eq!(be_u16(&v, 1), Some(0x0203));
        assert_eq!(be_u16(&v, 2), None);
    }
}
