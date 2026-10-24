//! Os eventos da análise e o ensaio do detector de movimento.

use std::time::Instant;

use vms_core::http::{Request, Response};

use super::{ApiRouter, MS_PER_DAY};
use crate::analytics::probe::{probe_json, ProbeParams};
use crate::analytics::store::events_json;
use crate::analytics::EventKind;

fn num(req: &Request, k: &str, d: f64) -> f64 {
    req.param(k).trim().parse().unwrap_or(d)
}

impl ApiRouter {
    pub(super) fn events_route(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let Some(ev) = self.d.events.as_ref().filter(|e| e.available()) else { return Response::error(503, "servidor sem analise de imagem") };
        let (from, to) = (req.param_i64("fromMs", 0), req.param_i64("toMs", 0));
        if from <= 0 || to <= from {
            return Response::error(400, "informe fromMs e toMs");
        }
        if to - from > 7 * MS_PER_DAY {
            return Response::error(400, "janela maior que 7 dias");
        }
        let k = req.param("kind");
        let kind = if k.trim().is_empty() {
            None
        } else {
            match EventKind::parse(&k) {
                Some(k) => Some(k),
                None => return Response::error(400, "kind invalido: use motion ou object"),
            }
        };
        let min = req.param_i64("minScorePct", 0) as f32 / 100.0;
        let lista = ev.query(&cam, from, to, &req.param("name").trim().to_lowercase(), kind, min, req.param_i64("limit", 0).max(0) as usize);
        Response::json(&events_json(&cam, from, to, &lista))
    }

    pub(super) fn motion_probe(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let Some(probe) = &self.d.probe else { return Response::error(503, "servidor sem como decodificar video") };
        let (from, to) = (req.param_i64("fromMs", 0), req.param_i64("toMs", 0));
        if from <= 0 || to <= from {
            return Response::error(400, "informe fromMs e toMs");
        }
        let mut grid = num(req, "gridScale", 1.0);
        if grid <= 0.0 || grid > 1.0 {
            grid = 1.0;
        }
        let mut delta = req.param_i64("cellDelta", 0);
        if !(0..=255).contains(&delta) {
            delta = 0;
        }
        let p = ProbeParams {
            from_ms: from,
            to_ms: to,
            step_ms: req.param_i64("stepMs", 2000),
            threshold: num(req, "threshold", 0.006) as f32,
            scene: num(req, "sceneThreshold", 0.85) as f32,
            grid_scale: grid as f32,
            cell_delta: delta as i32,
            max_samples: req.param_i64("max", 0).max(0) as usize,
            grade_ms: req.param_i64("gradeMs", 0),
        };
        let t = Instant::now();
        let r = probe.run(&cam, &p);
        Response::json(&probe_json(&cam, &p, &r, t.elapsed().as_millis()))
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{local, router};
    use vms_core::http::Handler;

    #[test]
    fn sem_analise_responde_503() {
        let d = vms_core::testutil::TempDir::new("api-an");
        let (r, _db) = router("api-an", d.path(), &["cam"]);
        assert_eq!(r.handle(&local("GET", "/api/events?camera=cam&fromMs=1&toMs=2")).status, 503);
        assert_eq!(r.handle(&local("GET", "/api/motion/probe?camera=cam&fromMs=1&toMs=2")).status, 503);
        assert_eq!(r.handle(&local("GET", "/api/events?camera=x")).status, 404);
    }
}
