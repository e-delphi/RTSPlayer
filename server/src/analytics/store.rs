//! Os eventos e o progresso da análise no banco (tabelas `event` e
//! `analysis_progress`). O mesmo objeto atende às três fronteiras: o
//! analisador escreve, a API consulta, o worker guarda até onde chegou.

use std::sync::Arc;

use vms_core::clock::Clock;
use vms_core::log::SharedLogger;

use super::{AnalysisProgress, EventBox, EventKind, EventSource, EventStore, VmsEvent};
use crate::db::{Db, Params};

const QUERY_DEFAULT_LIMIT: usize = 4000;

pub struct DbEventStore {
    db: Arc<Db>,
    clock: Arc<dyn Clock>,
    log: SharedLogger,
    /// O teto de duração dá o piso da consulta por sobreposição.
    max_event_ms: i64,
}

impl DbEventStore {
    pub fn new(db: Arc<Db>, clock: Arc<dyn Clock>, max_event_ms: i64, log: SharedLogger) -> Self {
        Self { db, clock, log, max_event_ms: if max_event_ms <= 0 { 300_000 } else { max_event_ms } }
    }
}

impl EventStore for DbEventStore {
    fn append(&self, camera: &str, ev: &VmsEvent) {
        if !ev.is_valid() {
            return;
        }
        let b = ev.bbox.clamped();
        self.db.post(
            "INSERT INTO event (camera_id, start_ms, end_ms, kind, name, score, obj_count, box_l, box_t, box_r, box_b, created_at_ms) \
             VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            p![
                camera,
                ev.start_ms,
                ev.end_ms,
                ev.kind as i64,
                ev.name.to_lowercase(),
                (ev.score as f64).clamp(0.0, 1.0),
                ev.count.max(0),
                b.l as f64,
                b.t as f64,
                b.r as f64,
                b.b as f64,
                self.clock.now_utc_ms()
            ],
        );
    }
}

impl EventSource for DbEventStore {
    fn available(&self) -> bool {
        true
    }

    fn query(&self, camera: &str, from: i64, to: i64, name: &str, kind: Option<EventKind>, min_score: f32, limit: usize) -> Vec<VmsEvent> {
        if camera.is_empty() || to <= from {
            return Vec::new();
        }
        let mut sql = String::from(
            "SELECT e.start_ms, e.end_ms, e.kind, e.name, e.score, e.obj_count, e.box_l, e.box_t, e.box_r, e.box_b \
             FROM event e JOIN camera c ON c.id = e.camera_id WHERE c.name = ? AND e.start_ms >= ? AND e.start_ms <= ? AND e.end_ms >= ?",
        );
        let mut ps: Params = p![camera, from - self.max_event_ms, to, from];
        if let Some(k) = kind {
            sql.push_str(" AND e.kind = ?");
            ps.push((k as i64).into());
        }
        let name = name.trim().to_lowercase();
        if !name.is_empty() {
            sql.push_str(" AND e.name = ?");
            ps.push(name.into());
        }
        if min_score > 0.0 {
            sql.push_str(" AND e.score >= ?");
            ps.push((min_score as f64).into());
        }
        sql.push_str(" ORDER BY e.start_ms LIMIT ?");
        ps.push((if limit == 0 { QUERY_DEFAULT_LIMIT } else { limit } as i64).into());
        self.db
            .query(&sql, ps, |r| {
                Ok(VmsEvent {
                    start_ms: r.get(0)?,
                    end_ms: r.get(1)?,
                    kind: if r.get::<_, i64>(2)? == 1 { EventKind::Object } else { EventKind::Motion },
                    name: r.get(3)?,
                    score: r.get::<_, f64>(4)? as f32,
                    count: r.get::<_, i64>(5)? as i32,
                    bbox: EventBox::new(r.get::<_, f64>(6)? as f32, r.get::<_, f64>(7)? as f32, r.get::<_, f64>(8)? as f32, r.get::<_, f64>(9)? as f32),
                })
            })
            .unwrap_or_else(|e| {
                self.log.warn("events", &format!("consulta falhou: {e}"));
                Vec::new()
            })
    }
}

impl AnalysisProgress for DbEventStore {
    fn read_progress(&self, camera: &str, model: &str) -> i64 {
        let r = self
            .db
            .query("SELECT p.analyzed_to_ms, p.model FROM analysis_progress p JOIN camera c ON c.id = p.camera_id WHERE c.name = ?", p![camera], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })
            .unwrap_or_default();
        let Some((ate, gravado)) = r.into_iter().next() else { return 0 };
        if !gravado.trim().eq_ignore_ascii_case(model.trim()) {
            self.log.info("analytics", &format!("{camera}: progresso era do modelo \"{gravado}\" e agora e \"{model}\"; vai reanalisar"));
            return 0;
        }
        ate
    }

    fn write_progress(&self, camera: &str, analyzed_to: i64, frames: i64, failures: i64, model: &str) {
        self.db.post(
            "INSERT INTO analysis_progress (camera_id, analyzed_to_ms, frames, decode_failures, model, updated_at_ms) \
             VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?) \
             ON CONFLICT(camera_id) DO UPDATE SET analyzed_to_ms = excluded.analyzed_to_ms, frames = excluded.frames, \
               decode_failures = excluded.decode_failures, model = excluded.model, updated_at_ms = excluded.updated_at_ms",
            p![camera, analyzed_to, frames, failures, model, self.clock.now_utc_ms()],
        );
    }
}

pub fn events_json(camera: &str, from: i64, to: i64, evs: &[VmsEvent]) -> serde_json::Value {
    serde_json::json!({
        "camera": camera,
        "tz": vms_core::clock::utc_offset_str(vms_core::clock::unix_ms()),
        "fromMs": from,
        "toMs": to,
        "count": evs.len(),
        "events": evs.iter().map(|e| serde_json::json!({
            "startMs": e.start_ms, "endMs": e.end_ms, "kind": e.kind.as_str(), "name": e.name,
            "score": e.score, "count": e.count, "box": e.bbox.to_json(),
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::clock::ManualClock;

    #[test]
    fn grava_consulta_e_progresso() {
        let db = Db::memory("evstore");
        crate::db::ensure_schema(&db, 1).unwrap();
        db.exec("INSERT INTO camera (name, created_at_ms, updated_at_ms) VALUES ('cam', 0, 0)", p![]).unwrap();
        let s = DbEventStore::new(db.clone(), Arc::new(ManualClock::new(1)), 60_000, vms_core::log::null());
        let ev = |a, b, n: &str, k| VmsEvent { start_ms: a, end_ms: b, name: n.into(), kind: k, score: 0.5, count: 1, bbox: EventBox::new(-1.0, 0.0, 2.0, 1.0) };
        s.append("cam", &ev(1000, 5000, "movimento", EventKind::Motion));
        s.append("cam", &ev(4000, 4500, "Person", EventKind::Object));
        s.append("cam", &ev(0, 0, "invalido", EventKind::Motion));
        db.flush();
        let all = s.query("cam", 4200, 10_000, "", None, 0.0, 0);
        assert_eq!(all.len(), 2, "o que comecou antes e ainda durava entra");
        assert_eq!(all[0].bbox, EventBox::new(0.0, 0.0, 1.0, 1.0), "caixa recortada");
        assert_eq!(s.query("cam", 1, 10_000, "person", Some(EventKind::Object), 0.0, 0).len(), 1);
        assert_eq!(s.query("cam", 1, 10_000, "", None, 0.9, 0).len(), 0);
        let j = events_json("cam", 1, 2, &all);
        assert_eq!(j["events"][1]["kind"], "object");

        assert_eq!(s.read_progress("cam", ""), 0);
        s.write_progress("cam", 777, 3, 0, "m.onnx");
        db.flush();
        assert_eq!(s.read_progress("cam", "m.onnx"), 777);
        assert_eq!(s.read_progress("cam", "outro.onnx"), 0, "modelo trocado reanalisa");
        db.close();
    }
}
