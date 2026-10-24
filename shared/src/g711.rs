//! G.711 A-law e µ-law (o `g711.c` clássico da Sun).

const SEG_END: [i32; 8] = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF];

/// Uma amostra linear de 16 bits → A-law.
pub fn linear_to_alaw(sample: i16) -> u8 {
    let s = sample as i32;
    let (pcm, mask) = if s >= 0 { (s >> 3, 0xD5) } else { ((-s - 1) >> 3, 0x55) };
    let seg = SEG_END.iter().position(|&e| pcm <= e).unwrap_or(8);
    if seg >= 8 {
        return (0x7F ^ mask) as u8;
    }
    let mut a = (seg as i32) << 4;
    a |= if seg < 2 { (pcm >> 1) & 0x0F } else { (pcm >> seg) & 0x0F };
    (a ^ mask) as u8
}

/// A-law → linear de 16 bits.
pub fn alaw_to_linear(a: u8) -> i16 {
    let a = (a ^ 0x55) as i32;
    let mut t = (a & 0x0F) << 4;
    let seg = (a & 0x70) >> 4;
    match seg {
        0 => t += 8,
        1 => t += 0x108,
        _ => {
            t += 0x108;
            t <<= seg - 1;
        }
    }
    (if a & 0x80 != 0 { t } else { -t }) as i16
}

/// µ-law → linear de 16 bits.
pub fn ulaw_to_linear(u: u8) -> i16 {
    let u = !u as i32;
    let mut t = ((u & 0x0F) << 3) + 0x84;
    t <<= (u & 0x70) >> 4;
    (if u & 0x80 != 0 { 0x84 - t } else { t - 0x84 }) as i16
}

/// PCM 16 bits LE → A-law. Byte ímpar no fim é ignorado.
pub fn pcm16le_to_alaw(pcm: &[u8]) -> Vec<u8> {
    pcm.chunks_exact(2).map(|c| linear_to_alaw(i16::from_le_bytes([c[0], c[1]]))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valores_conhecidos() {
        // Silêncio do A-law é 0xD5; os extremos saturam.
        assert_eq!(linear_to_alaw(0), 0xD5);
        assert_eq!(linear_to_alaw(-1), 0x55);
        assert_eq!(linear_to_alaw(i16::MAX), 0xAA);
        assert_eq!(linear_to_alaw(i16::MIN), 0x2A);
    }

    #[test]
    fn ida_e_volta_fica_perto() {
        // A-law tem ~13 bits efetivos: a volta erra pouco em relação ao valor.
        for v in (-32000i32..32000).step_by(997) {
            let back = alaw_to_linear(linear_to_alaw(v as i16)) as i32;
            let tol = (v.abs() / 16).max(16);
            assert!((back - v).abs() <= tol, "{v} -> {back}");
        }
        assert_eq!(pcm16le_to_alaw(&[0, 0, 1]), vec![0xD5]);
        assert_eq!(ulaw_to_linear(0xFF), 0);
    }
}
