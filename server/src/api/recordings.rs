//! As rotas das gravações: lista das câmeras, dias, faixas, mídia, ao vivo,
//! índice, inventário e miniatura.

use serde_json::json;
use vms_core::clock::{local_day_of, local_day_start_ms, utc_offset_str};
use vms_core::http::{Request, Response};
use vms_core::vms::paths::is_safe_vms_name;

use super::{ApiRouter, API_DEFAULT_GAP_MS, MS_PER_DAY};
use crate::index_cache::{clip_ranges, merge_ranges};
use crate::media::{MediaCursor, MediaRequest, MEDIA_DEFAULT_BLOCKS};

const LIVE_ESPERA_MS: u64 = 1500;

fn tz() -> String {
    utc_offset_str(vms_core::clock::unix_ms())
}

fn x_vms(body: Vec<u8>, status: u16, headers: Vec<(String, String)>) -> Response {
    let mut r = Response::new(status, "application/x-vms", body);
    r.headers.extend(headers);
    r
}

/// O dia seguinte em texto (`2026-10-20` → `2026-10-21`).
fn next_day(day: &str) -> String {
    let start = local_day_start_ms(day).unwrap_or(0);
    // 26 h adiante cai no dia seguinte mesmo com horário de verão.
    local_day_of(start + 26 * 3_600_000)
}

impl ApiRouter {
    pub(super) fn cameras_list(&self) -> Response {
        let cams: Vec<_> = self
            .cameras_agora()
            .iter()
            .map(|c| {
                let files = self.d.cache.list_files(c);
                let mut o = json!({ "name": c, "live": self.is_live(c), "files": files.len(), "bytes": files.iter().map(|f| f.bytes).sum::<i64>() });
                if let (Some(a), Some(b)) = (files.first(), files.last()) {
                    o["firstMs"] = json!(a.start_ms);
                    o["lastMs"] = json!(b.end_ms);
                }
                o
            })
            .collect();
        Response::json(&json!({
            "tz": tz(),
            "events": self.d.events.as_ref().map(|e| e.available()).unwrap_or(false),
            "thumbs": self.d.thumbs.available(),
            "cameras": cams,
        }))
    }

    pub(super) fn days(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let gap = req.param_i64("gapMs", API_DEFAULT_GAP_MS).max(0);
        let files = self.d.cache.list_files(&cam);
        let exact = merge_ranges(&files, 0);
        let glued = merge_ranges(&files, gap);
        let mut days = Vec::new();
        if let (Some(first), Some(last)) = (exact.first(), exact.last()) {
            let mut day = local_day_of(first.start_ms);
            let last_day = local_day_of(last.end_ms);
            while day <= last_day {
                let (Some(a), nd) = (local_day_start_ms(&day), next_day(&day)) else { break };
                let b = local_day_start_ms(&nd).unwrap_or(a + MS_PER_DAY);
                let de = clip_ranges(&exact, a, b);
                if let (Some(s), Some(e)) = (de.first(), de.last()) {
                    let rec: i64 = de.iter().map(|r| r.end_ms - r.start_ms).sum();
                    days.push(json!({
                        "day": day,
                        "startMs": s.start_ms,
                        "endMs": e.end_ms,
                        "recordedMs": rec,
                        "coverage": rec as f64 / MS_PER_DAY as f64,
                        "segments": clip_ranges(&glued, a, b).len(),
                    }));
                }
                day = nd;
            }
        }
        Response::json(&json!({ "camera": cam, "tz": tz(), "days": days }))
    }

    pub(super) fn segments(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let mut day = req.param("day").trim().to_owned();
        if day.is_empty() {
            day = local_day_of(vms_core::clock::unix_ms());
        }
        let Some(a) = local_day_start_ms(&day) else { return Response::error(400, "day precisa ser YYYY-MM-DD") };
        let b = local_day_start_ms(&next_day(&day)).unwrap_or(a + MS_PER_DAY);
        let gap = req.param_i64("gapMs", API_DEFAULT_GAP_MS).max(0);
        let ranges = clip_ranges(&merge_ranges(&self.d.cache.list_files(&cam), gap), a, b);
        Response::json(&json!({
            "camera": cam, "day": day, "tz": tz(), "dayStartMs": a, "dayEndMs": b, "gapMs": gap,
            "segments": ranges.iter().map(|r| json!({ "startMs": r.start_ms, "endMs": r.end_ms })).collect::<Vec<_>>(),
        }))
    }

    pub(super) fn media_route(&self, req: &Request) -> Response {
        let mut mr = MediaRequest::default();
        let file = req.param("file").trim().to_owned();
        if !file.is_empty() {
            if !is_safe_vms_name(&file) {
                return Response::error(400, "nome de arquivo invalido");
            }
            mr.file = file;
        } else {
            match self.known_camera(&req.param("camera")) {
                Some(c) => mr.camera = c,
                None => return Response::error(404, "camera desconhecida"),
            }
        }
        let cur = req.param("cursor").trim().to_owned();
        if !cur.is_empty() {
            match MediaCursor::decode(&cur) {
                Some(c) => mr.cursor = c,
                None => return Response::error(400, "cursor invalido"),
            }
        }
        if req.has_param("fromMs") && !req.param("fromMs").trim().is_empty() {
            mr.from_ms = Some(req.param_i64("fromMs", 0));
        }
        if req.has_param("fromBlock") && !req.param("fromBlock").trim().is_empty() {
            mr.from_block = Some(req.param_i64("fromBlock", 0));
        }
        mr.blocks = req.param_i64("blocks", MEDIA_DEFAULT_BLOCKS as i64).max(0) as usize;
        mr.step_ms = req.param_i64("stepMs", 0).max(0);
        let f = self.media.fetch(&mr);
        if !f.ok {
            return Response::error(f.status, &f.error);
        }
        let h = f.headers();
        x_vms(f.data, f.status, h)
    }

    pub(super) fn live(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let st = self.d.hub.as_ref().and_then(|h| h.find(&cam));
        let f = vms_core::live::live_fragment(st.as_deref(), req.param("cursor").trim(), LIVE_ESPERA_MS);
        x_vms(f.body, f.status, f.headers)
    }

    pub(super) fn index_route(&self, req: &Request) -> Response {
        let file = req.param("file").trim().to_owned();
        if !is_safe_vms_name(&file) {
            return Response::error(400, "nome de arquivo invalido");
        }
        let Some(ix) = self.d.cache.index(&self.d.cache.path_of(req.param("camera").trim(), &file)) else { return Response::error(404, "arquivo sem indice legivel") };
        let mut b = Vec::with_capacity(ix.len() * 17);
        for e in ix.iter() {
            b.extend_from_slice(&e.offset.to_le_bytes());
            b.extend_from_slice(&e.start_unix_ms.to_le_bytes());
            b.push(e.flags);
        }
        Response::new(200, "application/octet-stream", b).with_header("X-Vms-Block-Count", &ix.len().to_string())
    }

    pub(super) fn recordings(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let from = req.param_i64("fromMs", i64::MIN);
        let to = req.param_i64("toMs", i64::MAX);
        let files: Vec<_> = self
            .d
            .cache
            .list_files(&cam)
            .into_iter()
            .filter(|f| f.end_ms > from && f.start_ms < to)
            .map(|f| {
                let mut o = json!({
                    "file": f.name, "startMs": f.start_ms, "endMs": f.end_ms, "durationMs": f.duration_ms,
                    "bytes": f.bytes, "blocks": f.blocks, "closed": f.closed, "indexed": f.indexed,
                });
                if f.has_video {
                    o["video"] = json!({ "codec": f.video_codec.as_str(), "width": f.width, "height": f.height });
                }
                if f.has_audio {
                    o["audio"] = json!({ "codec": f.audio_codec.as_str(), "rate": f.sample_rate, "channels": f.channels });
                }
                o
            })
            .collect();
        Response::json(&json!({ "camera": cam, "tz": tz(), "files": files }))
    }

    pub(super) fn thumb(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        if req.param("ms").trim().is_empty() {
            return Response::error(400, "informe ms");
        }
        let ms = req.param_i64("ms", 0);
        if ms <= 0 {
            return Response::error(400, "ms invalido");
        }
        if !self.d.thumbs.available() {
            return Response::error(503, "servidor sem gerador de miniaturas");
        }
        match self.d.thumbs.get(&cam, ms) {
            Some((jpg, actual)) => Response::new(200, self.d.thumbs.content_type(), jpg).with_header("X-Vms-Thumb-Ms", &actual.to_string()).with_header("Cache-Control", "max-age=86400"),
            None => Response::error(404, "sem imagem para este instante"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{local, router};
    use vms_core::http::Handler;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    #[test]
    fn lista_dias_faixas_e_midia() {
        vms_core::clock::force_local_offset_ms(0);
        let d = TempDir::new("api-rec");
        let dir = ensure_camera_dir(d.path(), "cam").unwrap();
        let t0 = vms_core::clock::days_from_civil(2026, 10, 19) * 86_400_000 + 3_600_000;
        write_vms(&dir.join("cam_1.vms"), t0, 10, 1000, true);
        write_vms(&dir.join("cam_2.vms"), t0 + 60_000, 5, 1000, true);
        let (r, _db) = router("api-rec", d.path(), &["cam"]);

        let c = r.handle(&local("GET", "/api/cameras")).json_value();
        assert_eq!(c["cameras"][0]["files"], 2);
        assert_eq!(c["cameras"][0]["firstMs"], t0);

        let days = r.handle(&local("GET", "/api/days?camera=CAM")).json_value();
        assert_eq!(days["days"][0]["day"], "2026-10-19");
        assert_eq!(days["days"][0]["segments"], 2);

        let s = r.handle(&local("GET", "/api/segments?camera=cam&day=2026-10-19&gapMs=60000")).json_value();
        assert_eq!(s["segments"].as_array().unwrap().len(), 1, "colados pelo gap");
        assert_eq!(r.handle(&local("GET", "/api/segments?camera=cam&day=ontem")).status, 400);

        let m = r.handle(&local("GET", &format!("/api/media?camera=cam&fromMs={}&blocks=3", t0 + 500)));
        assert_eq!(m.status, 200);
        assert_eq!(m.header("X-Vms-Block-Count"), Some("3"));
        let cur = m.header("X-Vms-Cursor").unwrap().to_owned();
        let m2 = r.handle(&local("GET", &format!("/api/media?camera=cam&cursor={cur}")));
        assert_eq!(m2.header("X-Vms-Discontinuity"), Some("0"));
        assert_eq!(r.handle(&local("GET", "/api/media?camera=cam&cursor=lixo")).status, 400);

        let rec = r.handle(&local("GET", "/api/recordings?camera=cam")).json_value();
        assert_eq!(rec["files"][0]["video"]["codec"], "H264");
        let ix = r.handle(&local("GET", "/api/index?file=cam_1.vms"));
        assert_eq!(ix.body.len(), 10 * 17);
        assert_eq!(r.handle(&local("GET", "/api/index?file=..%2Fx.vms")).status, 400);
        assert_eq!(r.handle(&local("GET", "/api/live?camera=cam")).header("X-Vms-Live"), Some("0"));
        assert_eq!(r.handle(&local("GET", "/api/thumb?camera=cam&ms=5")).status, 503);
        assert_eq!(r.handle(&local("GET", "/api/days?camera=outra")).status, 404);
    }
}
