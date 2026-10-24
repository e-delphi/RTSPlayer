//! Mexeu? — aritmética de inteiros sobre uma grade de 64×36 células.
//!
//! 1. A referência é um FUNDO que se adapta devagar (média exponencial), e não
//!    o quadro anterior: a luz do dia mudaria o quadro inteiro em 2 s.
//! 2. Quadro que muda INTEIRO é cena nova (luz, IR, câmera movida): refaz o
//!    fundo e não gera evento.
//! 3. Salto no tempo zera a referência: a retomada da gravação não é movimento.

use super::{EventBox, MotionDetector, MotionResult};
use crate::ffmpeg::RgbImage;

pub const GRID_W: usize = 64;
pub const GRID_H: usize = 36;
const GRID_MIN_W: usize = 8;
const GRID_MIN_H: usize = 5;
/// Quanto o fundo anda a cada análise, em 1/256 (~10%).
const BG_ALPHA: i32 = 26;
/// Diferença de luma que faz uma célula contar como mexida.
pub const CELL_DELTA: i32 = 14;

pub struct FrameDiffMotionDetector {
    threshold: f32,
    scene: f32,
    cell_delta: i32,
    gw: usize,
    gh: usize,
    /// Fundo, luma × 256.
    bg: Vec<i32>,
    cur: Vec<u8>,
    has_bg: bool,
    last_ms: i64,
    max_gap_ms: i64,
}

impl FrameDiffMotionDetector {
    pub fn new(threshold: f32, scene: f32, max_gap_ms: i64, grid_scale: f32, cell_delta: i32) -> Self {
        let mut d = Self {
            threshold: 0.0,
            scene: 0.0,
            cell_delta: 0,
            gw: GRID_W,
            gh: GRID_H,
            bg: vec![0; GRID_W * GRID_H],
            cur: vec![0; GRID_W * GRID_H],
            has_bg: false,
            last_ms: 0,
            max_gap_ms: if max_gap_ms <= 0 { 15_000 } else { max_gap_ms },
        };
        d.set_params(threshold, scene, grid_scale, cell_delta);
        d
    }

    fn set_params(&mut self, threshold: f32, scene: f32, grid_scale: f32, cell_delta: i32) {
        self.threshold = if threshold <= 0.0 { 0.012 } else { threshold };
        self.scene = if scene <= self.threshold { 0.55 } else { scene };
        self.cell_delta = if cell_delta <= 0 || cell_delta > 255 { CELL_DELTA } else { cell_delta };
        let (mut w, mut h) = (GRID_W, GRID_H);
        if grid_scale > 0.0 && grid_scale < 1.0 {
            w = (GRID_W as f32 * grid_scale).round() as usize;
            h = (GRID_H as f32 * grid_scale).round() as usize;
        }
        self.gw = w.max(GRID_MIN_W);
        self.gh = h.max(GRID_MIN_H);
    }

    fn cells(&self) -> usize {
        self.gw * self.gh
    }

    /// Média de caixa da luma (BT.601 em ponto fixo) por célula.
    fn downsample(&mut self, img: &RgbImage) {
        let n = self.cells();
        let mut somas = vec![0u32; n];
        let mut contas = vec![0u32; n];
        let (w, h) = (img.width, img.height);
        let p = &img.pixels;
        for y in 0..h {
            let gy = (y * self.gh / h).min(self.gh - 1);
            let base = gy * self.gw;
            let row = y * w * 3;
            for x in 0..w {
                let gx = (x * self.gw / w).min(self.gw - 1);
                let i = row + x * 3;
                let luma = (77 * p[i] as u32 + 150 * p[i + 1] as u32 + 29 * p[i + 2] as u32) >> 8;
                somas[base + gx] += luma;
                contas[base + gx] += 1;
            }
        }
        for c in 0..n {
            self.cur[c] = if contas[c] > 0 { (somas[c] / contas[c]) as u8 } else { 0 };
        }
    }

    fn seed_background(&mut self) {
        for i in 0..self.cells() {
            self.bg[i] = (self.cur[i] as i32) << 8;
        }
        self.has_bg = true;
    }
}

impl MotionDetector for FrameDiffMotionDetector {
    fn feed(&mut self, ms: i64, img: &RgbImage) -> MotionResult {
        let mut r = MotionResult::default();
        if !img.is_valid() {
            return r;
        }
        let saltou = self.last_ms > 0 && (ms - self.last_ms).abs() > self.max_gap_ms;
        self.last_ms = ms;
        self.downsample(img);
        if !self.has_bg || saltou {
            self.seed_background();
            return r;
        }
        let n = self.cells();
        let (mut movidas, mut min_x, mut min_y, mut max_x, mut max_y) = (0usize, self.gw, self.gh, 0usize, 0usize);
        for i in 0..n {
            let diff = (self.cur[i] as i32 - (self.bg[i] >> 8)).abs();
            if diff < self.cell_delta {
                continue;
            }
            movidas += 1;
            let (gx, gy) = (i % self.gw, i / self.gw);
            min_x = min_x.min(gx);
            max_x = max_x.max(gx);
            min_y = min_y.min(gy);
            max_y = max_y.max(gy);
        }
        let fracao = movidas as f32 / n as f32;
        r.score = fracao;
        if fracao >= self.scene {
            r.scene_changed = true;
            self.seed_background();
            return r;
        }
        // O fundo só anda sem mudança brusca: absorver quem passa o ensinaria.
        for i in 0..n {
            self.bg[i] += (((self.cur[i] as i32) << 8) - self.bg[i]) * BG_ALPHA / 256;
        }
        if fracao < self.threshold {
            return r;
        }
        r.moved = true;
        r.bbox = EventBox::new(min_x as f32 / self.gw as f32, min_y as f32 / self.gh as f32, (max_x + 1) as f32 / self.gw as f32, (max_y + 1) as f32 / self.gh as f32);
        r
    }

    fn reset(&mut self) {
        self.has_bg = false;
        self.last_ms = 0;
    }

    fn ajustar(&mut self, threshold: f32, scene: f32, grid_scale: f32, cell_delta: i32) {
        let (w, h) = (self.gw, self.gh);
        self.set_params(threshold, scene, grid_scale, cell_delta);
        // Grade nova cobre outra área: o fundo antigo não serve.
        if (w, h) != (self.gw, self.gh) {
            self.has_bg = false;
        }
    }

    fn ultima_grade(&self) -> Option<(Vec<u8>, usize, usize)> {
        self.has_bg.then(|| (self.cur[..self.cells()].to_vec(), self.gw, self.gh))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn quadro(w: usize, h: usize, cinza: u8, caixa: Option<(usize, usize, usize, usize, u8)>) -> RgbImage {
        let mut p = vec![cinza; w * h * 3];
        if let Some((x0, y0, x1, y1, v)) = caixa {
            for y in y0..y1 {
                for x in x0..x1 {
                    let i = (y * w + x) * 3;
                    p[i..i + 3].fill(v);
                }
            }
        }
        RgbImage { width: w, height: h, pixels: p }
    }

    #[test]
    fn movimento_cena_nova_e_salto() {
        let mut d = FrameDiffMotionDetector::new(0.006, 0.85, 10_000, 1.0, 0);
        assert!(!d.feed(1000, &quadro(128, 72, 100, None)).moved, "primeiro vira fundo");
        assert!(!d.feed(3000, &quadro(128, 72, 100, None)).moved);
        let r = d.feed(5000, &quadro(128, 72, 100, Some((0, 0, 16, 8, 250))));
        assert!(r.moved);
        assert_eq!(r.bbox, EventBox::new(0.0, 0.0, 8.0 / 64.0, 4.0 / 36.0));
        let r = d.feed(7000, &quadro(128, 72, 250, None));
        assert!(r.scene_changed && !r.moved, "tudo mudou");
        // Salto de mais de 10 s: referência nova, nada de movimento.
        let r = d.feed(60_000, &quadro(128, 72, 10, Some((0, 0, 64, 36, 200))));
        assert!(!r.moved && !r.scene_changed);
        let (g, w, h) = d.ultima_grade().unwrap();
        assert_eq!((g.len(), w, h), (64 * 36, 64, 36));
        d.ajustar(0.006, 0.85, 0.5, 0);
        assert!(d.ultima_grade().is_none(), "grade nova descarta o fundo");
    }
}
