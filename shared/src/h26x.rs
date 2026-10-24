//! H.264/H.265 em Annex-B: percorrer NALs, achar os parâmetros in-band, dizer
//! se é keyframe e ler a resolução do SPS.

use crate::media::VideoCodec;

/// Os NALs de um buffer Annex-B (sem o start code), em ordem.
pub fn nals(data: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            starts.push((i, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (k, &(_, begin)) in starts.iter().enumerate() {
        let mut end = starts.get(k + 1).map(|s| s.0).unwrap_or(data.len());
        // O 0 extra do start code de 4 bytes pertence ao próximo NAL.
        while end > begin && data[end - 1] == 0 && k + 1 < starts.len() {
            end -= 1;
        }
        if end > begin {
            out.push(&data[begin..end]);
        }
    }
    out
}

pub fn h264_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| b & 0x1F).unwrap_or(0)
}

pub fn h265_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| (b >> 1) & 0x3F).unwrap_or(0)
}

/// O codec de um quadro pelo que está dentro dele: VPS/SPS do H.265 (32/33)
/// têm tipos que no H.264 não fazem sentido com o bit proibido zerado.
pub fn detect_codec(annexb: &[u8]) -> VideoCodec {
    for n in nals(annexb) {
        let t265 = h265_type(n);
        if (32..=34).contains(&t265) && n.len() > 1 && n[1] == 1 {
            return VideoCodec::H265;
        }
        let t264 = h264_type(n);
        if t264 == 7 || t264 == 5 {
            return VideoCodec::H264;
        }
    }
    VideoCodec::H264
}

pub fn is_keyframe(codec: VideoCodec, annexb: &[u8]) -> bool {
    nals(annexb).iter().any(|n| match codec {
        VideoCodec::H265 => (16..=21).contains(&h265_type(n)),
        VideoCodec::H264 => h264_type(n) == 5,
        _ => false,
    })
}

/// O csd-0 (VPS/SPS/PPS) de dentro de um keyframe que traz os parâmetros
/// in-band, cada NAL com start code de 4 bytes. Para no primeiro slice.
pub fn extract_inband_csd(annexb: &[u8], codec: VideoCodec) -> Vec<u8> {
    let mut out = Vec::new();
    for n in nals(annexb) {
        let (vcl, param) = match codec {
            VideoCodec::H265 => {
                let t = h265_type(n);
                (t <= 31, (32..=34).contains(&t))
            }
            _ => {
                let t = h264_type(n);
                ((1..=5).contains(&t), t == 7 || t == 8)
            }
        };
        if vcl {
            break;
        }
        if param {
            out.extend_from_slice(&[0, 0, 0, 1]);
            out.extend_from_slice(n);
        }
    }
    out
}

/// Tira os bytes de prevenção de emulação (00 00 03 → 00 00).
pub fn unescape_rbsp(nal: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(nal.len());
    let mut zeros = 0;
    for &b in nal {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

struct Bits<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Bits<'a> {
    fn new(b: &'a [u8]) -> Self {
        Self { b, pos: 0 }
    }
    fn bit(&mut self) -> Option<u32> {
        let byte = *self.b.get(self.pos / 8)?;
        let v = (byte >> (7 - (self.pos % 8))) & 1;
        self.pos += 1;
        Some(v as u32)
    }
    fn bits(&mut self, n: u32) -> Option<u32> {
        let mut v = 0;
        for _ in 0..n {
            v = (v << 1) | self.bit()?;
        }
        Some(v)
    }
    fn skip(&mut self, n: usize) -> Option<()> {
        if self.pos + n > self.b.len() * 8 {
            return None;
        }
        self.pos += n;
        Some(())
    }
    fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        Some((1u32 << zeros) - 1 + self.bits(zeros)?)
    }
    fn se(&mut self) -> Option<i32> {
        let k = self.ue()?;
        Some(if k % 2 == 1 { (k as i32 + 1) / 2 } else { -(k as i32 / 2) })
    }
}

fn h264_sps_dims(nal: &[u8]) -> Option<(u16, u16)> {
    let rbsp = unescape_rbsp(nal.get(1..)?);
    let mut r = Bits::new(&rbsp);
    let profile = r.bits(8)?;
    r.skip(16)?; // constraints + level
    r.ue()?; // sps id
    let mut chroma = 1;
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(&profile) {
        chroma = r.ue()?;
        if chroma == 3 {
            r.bit()?;
        }
        r.ue()?;
        r.ue()?;
        r.bit()?;
        if r.bit()? == 1 {
            let lists = if chroma != 3 { 8 } else { 12 };
            for i in 0..lists {
                if r.bit()? == 1 {
                    let size = if i < 6 { 16 } else { 64 };
                    let (mut last, mut next) = (8i32, 8i32);
                    for _ in 0..size {
                        if next != 0 {
                            next = (last + r.se()? + 256) % 256;
                        }
                        if next != 0 {
                            last = next;
                        }
                    }
                }
            }
        }
    }
    r.ue()?; // log2_max_frame_num
    match r.ue()? {
        0 => {
            r.ue()?;
        }
        1 => {
            r.bit()?;
            r.se()?;
            r.se()?;
            for _ in 0..r.ue()? {
                r.se()?;
            }
        }
        _ => {}
    }
    r.ue()?; // max_num_ref_frames
    r.bit()?;
    let w_mbs = r.ue()? + 1;
    let h_units = r.ue()? + 1;
    let frame_mbs_only = r.bit()?;
    if frame_mbs_only == 0 {
        r.bit()?;
    }
    r.bit()?;
    let (mut cl, mut cr, mut ct, mut cb) = (0, 0, 0, 0);
    if r.bit()? == 1 {
        cl = r.ue()?;
        cr = r.ue()?;
        ct = r.ue()?;
        cb = r.ue()?;
    }
    let (sub_w, sub_h) = match chroma {
        0 => (1, 1),
        1 => (2, 2),
        2 => (2, 1),
        _ => (1, 1),
    };
    let crop_x = sub_w;
    let crop_y = sub_h * (2 - frame_mbs_only);
    let w = (w_mbs * 16).checked_sub((cl + cr) * crop_x)?;
    let h = ((2 - frame_mbs_only) * h_units * 16).checked_sub((ct + cb) * crop_y)?;
    Some((w.min(u16::MAX as u32) as u16, h.min(u16::MAX as u32) as u16))
}

fn h265_sps_dims(nal: &[u8]) -> Option<(u16, u16)> {
    let rbsp = unescape_rbsp(nal.get(2..)?);
    let mut r = Bits::new(&rbsp);
    r.bits(4)?; // vps id
    let max_sub = r.bits(3)?;
    r.bit()?;
    // profile_tier_level: o geral tem 88 bits + level (8).
    r.skip(96)?;
    let mut prof = [false; 8];
    let mut lev = [false; 8];
    for i in 0..max_sub as usize {
        prof[i] = r.bit()? == 1;
        lev[i] = r.bit()? == 1;
    }
    if max_sub > 0 {
        for _ in max_sub..8 {
            r.skip(2)?;
        }
    }
    for i in 0..max_sub as usize {
        if prof[i] {
            r.skip(88)?;
        }
        if lev[i] {
            r.skip(8)?;
        }
    }
    r.ue()?; // sps id
    let chroma = r.ue()?;
    if chroma == 3 {
        r.bit()?;
    }
    let w = r.ue()?;
    let h = r.ue()?;
    let (sub_w, sub_h) = match chroma {
        1 => (2, 2),
        2 => (2, 1),
        _ => (1, 1),
    };
    let (mut w, mut h) = (w, h);
    if r.bit()? == 1 {
        let (l, rr, t, b) = (r.ue()?, r.ue()?, r.ue()?, r.ue()?);
        w = w.checked_sub((l + rr) * sub_w)?;
        h = h.checked_sub((t + b) * sub_h)?;
    }
    Some((w.min(u16::MAX as u32) as u16, h.min(u16::MAX as u32) as u16))
}

/// A resolução pelo SPS que estiver no buffer Annex-B.
pub fn dimensions(codec: VideoCodec, annexb: &[u8]) -> Option<(u16, u16)> {
    for n in nals(annexb) {
        match codec {
            VideoCodec::H264 if h264_type(n) == 7 => return h264_sps_dims(n),
            VideoCodec::H265 if h265_type(n) == 33 => return h265_sps_dims(n),
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Monta um SPS baseline à mão (bits), para o teste não depender de
    /// bytes copiados de algum lugar.
    fn sps_baseline(w_mbs: u32, h_mbs: u32, crop_bottom: Option<u32>) -> Vec<u8> {
        let mut bits: Vec<u8> = Vec::new();
        let mut put = |v: u32, n: u32| {
            for i in (0..n).rev() {
                bits.push(((v >> i) & 1) as u8);
            }
        };
        let ue = |v: u32| -> Vec<(u32, u32)> {
            let x = v + 1;
            let len = 32 - x.leading_zeros();
            vec![(0, len - 1), (x, len)]
        };
        put(66, 8);
        put(0, 8);
        put(31, 8);
        let ues = |v: u32, put: &mut dyn FnMut(u32, u32)| {
            for (val, n) in ue(v) {
                put(val, n);
            }
        };
        ues(0, &mut put); // sps id
        ues(0, &mut put); // log2_max_frame_num
        ues(0, &mut put); // poc type 0
        ues(0, &mut put); // log2_max_poc
        ues(1, &mut put); // refs
        put(0, 1);
        ues(w_mbs - 1, &mut put);
        ues(h_mbs - 1, &mut put);
        put(1, 1); // frame_mbs_only
        put(1, 1); // direct_8x8
        match crop_bottom {
            Some(cb) => {
                put(1, 1);
                ues(0, &mut put);
                ues(0, &mut put);
                ues(0, &mut put);
                ues(cb, &mut put);
            }
            None => put(0, 1),
        }
        put(0, 1); // vui
        put(1, 1); // stop bit
        while bits.len() % 8 != 0 {
            bits.push(0);
        }
        let mut out = vec![0, 0, 0, 1, 0x67];
        out.extend(bits.chunks(8).map(|c| c.iter().fold(0u8, |a, &b| (a << 1) | b)));
        out
    }

    #[test]
    fn nals_com_start_codes_de_3_e_4() {
        let b = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9];
        let n = nals(&b);
        assert_eq!(n, vec![&[0x67, 1, 2][..], &[0x68, 3][..], &[0x65, 9][..]]);
        assert!(is_keyframe(VideoCodec::H264, &b));
        assert_eq!(detect_codec(&b), VideoCodec::H264);
        let csd = extract_inband_csd(&b, VideoCodec::H264);
        assert_eq!(csd, vec![0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3]);
    }

    #[test]
    fn h265_e_tipo() {
        let b = [0, 0, 0, 1, 0x40, 0x01, 7, 0, 0, 0, 1, 0x26, 0x01, 8];
        assert_eq!(detect_codec(&b), VideoCodec::H265);
        assert!(is_keyframe(VideoCodec::H265, &b), "IDR_W_RADL");
        assert_eq!(extract_inband_csd(&b, VideoCodec::H265), vec![0, 0, 0, 1, 0x40, 0x01, 7]);
    }

    #[test]
    fn resolucao_do_sps() {
        assert_eq!(dimensions(VideoCodec::H264, &sps_baseline(80, 45, None)), Some((1280, 720)));
        // 1080p de verdade é 1088 de macroblocos menos 8 linhas de corte.
        assert_eq!(dimensions(VideoCodec::H264, &sps_baseline(120, 68, Some(4))), Some((1920, 1080)));
        assert_eq!(unescape_rbsp(&[0, 0, 3, 1, 0, 0, 3]), vec![0, 0, 1, 0, 0]);
    }
}
