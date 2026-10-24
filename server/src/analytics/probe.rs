//! O ENSAIO da página `/ui/motion`: reprocessa um trecho com os parâmetros do
//! pedido e devolve o score de cada quadro, sem gravar nada. O banco só guarda
//! o pico do que passou do limiar; daqui se vê também o que o limiar comeu.

use std::sync::Arc;

use super::motion::FrameDiffMotionDetector;
use super::walk::WalkSource;
use super::{MotionDetector, MotionSample};
use crate::thumbs::{FrameGrabber, KeyframeSource};

const FRAME_MAX_W: i32 = 640;
const MAX_SAMPLES_HARD: usize = 4000;
const MAX_WINDOW_MS: i64 = 6 * 3_600_000;
const MIN_STEP_MS: i64 = 250;

#[derive(Debug, Clone, Default)]
pub struct ProbeParams {
    pub from_ms: i64,
    pub to_ms: i64,
    pub step_ms: i64,
    pub threshold: f32,
    pub scene: f32,
    pub grid_scale: f32,
    pub cell_delta: i32,
    pub max_samples: usize,
    /// Guarda a grade crua do quadro mais próximo deste instante (0 = não).
    pub grade_ms: i64,
}

#[derive(Debug, Clone, Default)]
pub struct ProbeResult {
    pub samples: Vec<MotionSample>,
    pub motivo_fim: String,
    /// (células, largura, altura, instante)
    pub grade: Option<(Vec<u8>, usize, usize, i64)>,
}

pub struct MotionProbe {
    pub keyframes: Arc<dyn KeyframeSource>,
    pub grabber: Arc<dyn FrameGrabber>,
    pub walk: Option<Arc<WalkSource>>,
}

fn talvez_guardar(res: &mut ProbeResult, alvo: i64, m: &dyn MotionDetector, ms: i64) {
    if alvo <= 0 {
        return;
    }
    if let Some((_, _, _, prev)) = &res.grade {
        if (ms - alvo).abs() >= (prev - alvo).abs() {
            return;
        }
    }
    if let Some((c, w, h)) = m.ultima_grade() {
        res.grade = Some((c, w, h, ms));
    }
}

impl MotionProbe {
    pub fn run(&self, camera: &str, p: &ProbeParams) -> ProbeResult {
        let mut res = ProbeResult::default();
        if camera.is_empty() || p.to_ms <= p.from_ms {
            return res;
        }
        let step = p.step_ms.max(MIN_STEP_MS);
        let to = p.to_ms.min(p.from_ms + MAX_WINDOW_MS);
        let max = if p.max_samples == 0 || p.max_samples > MAX_SAMPLES_HARD { MAX_SAMPLES_HARD } else { p.max_samples };
        let mut motion = FrameDiffMotionDetector::new(p.threshold, p.scene, step * 4, p.grid_scale, p.cell_delta);
        let push = |res: &mut ProbeResult, m: &mut FrameDiffMotionDetector, ms: i64, img: &crate::ffmpeg::RgbImage| {
            let r = m.feed(ms, img);
            talvez_guardar(res, p.grade_ms, m, ms);
            res.samples.push(MotionSample { ms, score: r.score, moved: r.moved, scene_changed: r.scene_changed, bbox: r.bbox });
        };
        if let Some(w) = &self.walk {
            match w.walk(camera, p.from_ms, to, step, FRAME_MAX_W, FRAME_MAX_W) {
                Some(mut pass) => {
                    while res.samples.len() < max {
                        let Some((img, ms)) = pass.next_frame() else { break };
                        if img.is_valid() {
                            push(&mut res, &mut motion, ms, &img);
                        }
                    }
                    res.motivo_fim = if res.samples.len() >= max { "teto de amostras".into() } else { pass.motivo_do_fim().to_owned() };
                }
                None => res.motivo_fim = "sem por onde percorrer".into(),
            }
        }
        if !res.samples.is_empty() {
            return res;
        }
        // Sem percurso (ou vazio): keyframes soltos.
        let (mut at, mut ultimo) = (p.from_ms, 0i64);
        while at <= to && res.samples.len() < max {
            let Some(k) = self.keyframes.grab(camera, at) else { break };
            if k.au.is_empty() {
                at += step;
                continue;
            }
            if ultimo > 0 && k.actual_ms <= ultimo {
                at = (at + step).max(ultimo + 1);
                continue;
            }
            if k.actual_ms > to {
                break;
            }
            if let Some(img) = self.grabber.decode(&k, FRAME_MAX_W, FRAME_MAX_W).filter(|i| i.is_valid()) {
                push(&mut res, &mut motion, k.actual_ms, &img);
            }
            ultimo = k.actual_ms;
            at = (at + step).max(k.actual_ms + 1);
        }
        res
    }
}

pub fn probe_json(camera: &str, p: &ProbeParams, r: &ProbeResult, elapsed_ms: u128) -> serde_json::Value {
    let mut j = serde_json::json!({
        "camera": camera,
        "fromMs": p.from_ms,
        "toMs": p.to_ms,
        "stepMs": p.step_ms,
        "threshold": p.threshold,
        "sceneThreshold": p.scene,
        "gridScale": p.grid_scale,
        "cellDelta": p.cell_delta,
        "count": r.samples.len(),
        "walkEnd": r.motivo_fim,
        "elapsedMs": elapsed_ms as u64,
        "samples": r.samples.iter().map(|s| {
            let mut o = serde_json::json!({ "ms": s.ms, "score": s.score, "moved": s.moved, "sceneChanged": s.scene_changed });
            if !s.bbox.is_empty() {
                o["box"] = s.bbox.to_json();
            }
            o
        }).collect::<Vec<_>>(),
    });
    if p.grade_ms > 0 {
        if let Some((c, w, h, ms)) = &r.grade {
            j["grid"] = serde_json::json!({ "ms": ms, "w": w, "h": h, "cells": c });
        }
    }
    j
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analytics::walk::tests::AbreFalsa;
    use crate::index_cache::IndexCache;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    #[test]
    fn ensaio_pelo_percurso() {
        let d = TempDir::new("probe");
        let dir = ensure_camera_dir(d.path(), "cam").unwrap();
        write_vms(&dir.join("cam_1.vms"), 1_000_000, 12, 1000, true);
        let cache = Arc::new(IndexCache::new(d.path(), None, vms_core::log::null()));
        let pr = MotionProbe {
            keyframes: Arc::new(crate::thumbs::VmsKeyframeSource { cache: cache.clone() }),
            grabber: Arc::new(crate::thumbs::tests_support::NoDecode),
            walk: Some(Arc::new(WalkSource { cache, opener: Arc::new(AbreFalsa) })),
        };
        let p = ProbeParams { from_ms: 1_000_000, to_ms: 1_011_000, step_ms: 1000, threshold: 0.006, scene: 0.85, grid_scale: 1.0, grade_ms: 1_005_000, ..Default::default() };
        let r = pr.run("cam", &p);
        assert_eq!(r.samples.len(), 12);
        assert_eq!(r.grade.as_ref().map(|g| g.3), Some(1_005_000));
        let j = probe_json("cam", &p, &r, 1);
        assert_eq!(j["count"], 12);
        assert_eq!(j["grid"]["w"], 64);
        assert!(pr.run("cam", &ProbeParams::default()).samples.is_empty());
    }
}
