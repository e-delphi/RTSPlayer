//! CRC-32 (IEEE 802.3, polinômio refletido 0xEDB88320) — o mesmo do zlib, e o
//! mesmo que o `.vms`, o sidecar e o `vmsreader.js` da página calculam.
//!
//! A atualização é encadeável como no Delphi: `update(update(0, a), b)` é o CRC
//! de `a ++ b`.

const fn table() -> [u32; 256] {
    let mut t = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut j = 0;
        while j < 8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            j += 1;
        }
        t[i] = c;
        i += 1;
    }
    t
}

static TABLE: [u32; 256] = table();

/// Continua um CRC já calculado sobre mais bytes.
pub fn update(crc: u32, data: &[u8]) -> u32 {
    let mut c = crc ^ 0xFFFF_FFFF;
    for &b in data {
        c = TABLE[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    c ^ 0xFFFF_FFFF
}

/// CRC de um buffer inteiro.
pub fn compute(data: &[u8]) -> u32 {
    update(0, data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valor_de_referencia() {
        // O "check" clássico do CRC-32.
        assert_eq!(compute(b"123456789"), 0xCBF4_3926);
        assert_eq!(compute(b""), 0);
    }

    #[test]
    fn encadeia() {
        assert_eq!(update(update(0, b"12345"), b"6789"), compute(b"123456789"));
    }
}
