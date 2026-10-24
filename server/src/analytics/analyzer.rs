//! Junta o que cada quadro mostrou em EVENTOS: o mesmo nome visto de novo a
//! menos de `merge_gap_ms` estica o evento aberto; parado mais que isso (ou
//! passado o teto `max_event_ms`), fecha e vai para o store.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use super::{EventBox, EventKind, EventStore, MotionDetector, ObjectDetector, VmsEvent, MOTION_NAME};
use crate::config::AnalyticsConfig;
use crate::ffmpeg::RgbImage;

struct Open {
    ev: VmsEvent,
    last_seen: i64,
}

pub struct FrameAnalyzer {
    camera: String,
    motion: Box<dyn MotionDetector>,
    objects: Arc<dyn ObjectDetector>,
    store: Arc<dyn EventStore>,
    cfg: AnalyticsConfig,
    wanted: Option<HashSet<String>>,
    open: HashMap<String, Open>,
    last_object_ms: i64,
    pub closed: usize,
}

impl FrameAnalyzer {
    pub fn new(camera: &str, motion: Box<dyn MotionDetector>, objects: Arc<dyn ObjectDetector>, store: Arc<dyn EventStore>, cfg: AnalyticsConfig) -> Self {
        let wanted = (!cfg.classes.is_empty()).then(|| cfg.classes.iter().map(|c| c.trim().to_lowercase()).collect());
        Self { camera: camera.into(), motion, objects, store, cfg, wanted, open: HashMap::new(), last_object_ms: 0, closed: 0 }
    }

    fn emit(&mut self, ev: &VmsEvent) {
        self.store.append(&self.camera, ev);
        self.closed += 1;
    }

    fn note(&mut self, ms: i64, name: &str, kind: EventKind, score: f32, count: i32, bbox: EventBox) {
        if let Some(o) = self.open.get_mut(name) {
            if self.cfg.max_event_ms > 0 && ms - o.ev.start_ms >= self.cfg.max_event_ms {
                let ev = self.open.remove(name).map(|o| o.ev).unwrap_or_default();
                self.emit(&ev);
            } else {
                o.ev.end_ms = ms;
                o.last_seen = ms;
                if score > o.ev.score {
                    o.ev.score = score;
                    o.ev.bbox = bbox;
                }
                o.ev.count = o.ev.count.max(count);
                return;
            }
        }
        self.open.insert(name.to_owned(), Open { ev: VmsEvent { start_ms: ms, end_ms: ms, kind, name: name.into(), score, count, bbox }, last_seen: ms });
    }

    fn close_stale(&mut self, ms: i64) {
        let gap = self.cfg.merge_gap_ms;
        let vencidos: Vec<String> = self.open.iter().filter(|(_, o)| ms - o.last_seen > gap).map(|(k, _)| k.clone()).collect();
        for k in vencidos {
            if let Some(o) = self.open.remove(&k) {
                self.emit(&o.ev);
            }
        }
    }

    /// Fecha e grava o que estiver aberto.
    pub fn flush(&mut self) {
        let abertos: Vec<VmsEvent> = self.open.drain().map(|(_, o)| o.ev).collect();
        for ev in abertos {
            self.emit(&ev);
        }
    }

    /// Descarta o aberto sem gravar e esquece a referência (salto no tempo).
    pub fn rewind(&mut self) {
        self.open.clear();
        self.last_object_ms = 0;
        self.motion.reset();
    }

    pub fn ajustar(&mut self, cfg: &AnalyticsConfig) {
        self.cfg = cfg.clone();
        self.motion.ajustar(cfg.motion_threshold as f32, cfg.scene_change_threshold as f32, cfg.grid_scale as f32, cfg.cell_delta as i32);
    }

    pub fn feed(&mut self, ms: i64, img: &RgbImage) {
        if !img.is_valid() {
            return;
        }
        let m = self.motion.feed(ms, img);
        if m.scene_changed {
            self.flush();
            return;
        }
        self.close_stale(ms);
        if m.moved {
            self.note(ms, MOTION_NAME, EventKind::Motion, m.score, 1, m.bbox);
        }
        if !self.objects.available() {
            return;
        }
        // A rede é cara: no máximo uma vez por intervalo, mais espaçada parada.
        let iv = if m.moved { self.cfg.object_interval_ms } else { self.cfg.object_idle_interval_ms };
        if !m.moved && iv <= 0 {
            return;
        }
        if self.last_object_ms > 0 && (ms - self.last_object_ms).abs() < iv {
            return;
        }
        self.last_object_ms = ms;
        let Some(hits) = self.objects.detect(img, self.cfg.object_threshold as f32) else { return };
        let mut vistos = HashSet::new();
        for (i, h) in hits.iter().enumerate() {
            if h.name.is_empty() || !self.wanted.as_ref().map(|w| w.contains(&h.name.to_lowercase())).unwrap_or(true) || !vistos.insert(h.name.clone()) {
                continue;
            }
            let (mut best, mut bx, mut n) = (h.score, h.bbox, 1);
            for o in &hits[i + 1..] {
                if o.name == h.name {
                    n += 1;
                    if o.score > best {
                        best = o.score;
                        bx = o.bbox;
                    }
                }
            }
            let name = h.name.clone();
            self.note(ms, &name, EventKind::Object, best, n, bx);
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::analytics::motion::tests::quadro;
    use crate::analytics::motion::FrameDiffMotionDetector;
    use crate::analytics::ObjectHit;
    use std::sync::Mutex;

    #[derive(Default)]
    pub struct StoreMem(pub Mutex<Vec<VmsEvent>>);
    impl EventStore for StoreMem {
        fn append(&self, _: &str, ev: &VmsEvent) {
            self.0.lock().unwrap().push(ev.clone());
        }
    }

    struct Pessoa;
    impl ObjectDetector for Pessoa {
        fn detect(&self, _: &RgbImage, _: f32) -> Option<Vec<ObjectHit>> {
            Some(vec![
                ObjectHit { name: "person".into(), score: 0.5, bbox: EventBox::new(0.0, 0.0, 0.1, 0.1) },
                ObjectHit { name: "person".into(), score: 0.9, bbox: EventBox::new(0.5, 0.5, 0.6, 0.6) },
                ObjectHit { name: "cat".into(), score: 0.9, bbox: EventBox::default() },
            ])
        }
        fn available(&self) -> bool {
            true
        }
        fn describe(&self) -> String {
            "teste".into()
        }
    }

    #[test]
    fn junta_em_eventos() {
        let store = Arc::new(StoreMem::default());
        let cfg = AnalyticsConfig { classes: vec!["person".into()], ..Default::default() };
        let mut a = FrameAnalyzer::new("cam", Box::new(FrameDiffMotionDetector::new(0.006, 0.85, 10_000, 1.0, 0)), Arc::new(Pessoa), store.clone(), cfg);
        let calmo = quadro(64, 36, 100, None);
        a.feed(1000, &calmo);
        a.feed(3000, &quadro(64, 36, 100, Some((0, 0, 4, 4, 250))));
        a.feed(5000, &quadro(64, 36, 100, Some((0, 0, 4, 4, 250))));
        // 8 s parado (> merge_gap) fecha o movimento.
        a.feed(14_000, &calmo);
        // O primeiro evento de movimento fechou quando o parado passou de 8 s.
        let evs = store.0.lock().unwrap().clone();
        let m = evs.iter().find(|e| e.name == MOTION_NAME).expect("movimento");
        assert_eq!((m.start_ms, m.end_ms), (3000, 5000));
        a.flush();
        let evs = store.0.lock().unwrap().clone();
        let p = evs.iter().find(|e| e.name == "person").expect("pessoa");
        assert_eq!(p.count, 2);
        assert!((p.score - 0.9).abs() < 1e-6);
        assert!(evs.iter().all(|e| e.name != "cat"), "fora das classes");
    }
}
