//! A análise de imagem sobre a gravação: eventos de movimento (e de objeto,
//! quando houver detector) que a linha do tempo pinta.
//!
//! Cada peça atrás de uma fronteira de um método: achar quadros (`walk`),
//! decidir se mexeu (`motion`), o que é (`ObjectDetector`), juntar em eventos
//! (`analyzer`), guardar (`store`). O detector de objetos do Delphi (ONNX)
//! entra como `ObjectDetector`; sem ele, a análise roda só com movimento — o
//! mesmo regime de quando o modelo não está no disco.

pub mod analyzer;
pub mod motion;
pub mod onnx;
pub mod probe;
pub mod store;
pub mod walk;
pub mod worker;

use crate::ffmpeg::RgbImage;

pub const MOTION_NAME: &str = "movimento";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EventKind {
    #[default]
    Motion = 0,
    Object = 1,
}

impl EventKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EventKind::Motion => "motion",
            EventKind::Object => "object",
        }
    }

    pub fn parse(s: &str) -> Option<EventKind> {
        match s.trim().to_ascii_lowercase().as_str() {
            "motion" => Some(EventKind::Motion),
            "object" => Some(EventKind::Object),
            _ => None,
        }
    }
}

/// Caixa normalizada 0..1 sobre o quadro.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct EventBox {
    pub l: f32,
    pub t: f32,
    pub r: f32,
    pub b: f32,
}

impl EventBox {
    pub fn new(l: f32, t: f32, r: f32, b: f32) -> Self {
        Self { l, t, r, b }
    }

    pub fn is_empty(&self) -> bool {
        self.r <= self.l || self.b <= self.t
    }

    pub fn clamped(&self) -> Self {
        let c = |v: f32| v.clamp(0.0, 1.0);
        Self { l: c(self.l), t: c(self.t), r: c(self.r), b: c(self.b) }
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({ "l": self.l, "t": self.t, "r": self.r, "b": self.b })
    }
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VmsEvent {
    pub start_ms: i64,
    pub end_ms: i64,
    pub kind: EventKind,
    pub name: String,
    /// O maior visto durante o evento, 0..1.
    pub score: f32,
    pub count: i32,
    /// A caixa do quadro de pico.
    pub bbox: EventBox,
}

impl VmsEvent {
    pub fn is_valid(&self) -> bool {
        self.start_ms > 0 && self.end_ms >= self.start_ms && !self.name.is_empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct MotionResult {
    pub moved: bool,
    pub score: f32,
    /// Mudou tudo (luz, IR, câmera movida): não é evento.
    pub scene_changed: bool,
    pub bbox: EventBox,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ObjectHit {
    pub name: String,
    pub score: f32,
    pub bbox: EventBox,
}

pub trait MotionDetector: Send {
    fn feed(&mut self, ms: i64, img: &RgbImage) -> MotionResult;
    fn reset(&mut self);
    fn ajustar(&mut self, threshold: f32, scene: f32, grid_scale: f32, cell_delta: i32);
    /// A grade do último quadro (diagnóstico): (células, largura, altura).
    fn ultima_grade(&self) -> Option<(Vec<u8>, usize, usize)>;
}

pub trait ObjectDetector: Send + Sync {
    fn detect(&self, img: &RgbImage, min_score: f32) -> Option<Vec<ObjectHit>>;
    fn available(&self) -> bool;
    fn describe(&self) -> String;
}

pub struct NullObjectDetector;

impl ObjectDetector for NullObjectDetector {
    fn detect(&self, _: &RgbImage, _: f32) -> Option<Vec<ObjectHit>> {
        None
    }
    fn available(&self) -> bool {
        false
    }
    fn describe(&self) -> String {
        "sem deteccao de objetos".into()
    }
}

pub trait EventStore: Send + Sync {
    fn append(&self, camera: &str, ev: &VmsEvent);
}

pub trait EventSource: Send + Sync {
    /// Em ordem de início; entra o que SE SOBREPÕE à janela. `kind` None = os
    /// dois; `name` vazio = todos.
    #[allow(clippy::too_many_arguments)]
    fn query(&self, camera: &str, from: i64, to: i64, name: &str, kind: Option<EventKind>, min_score: f32, limit: usize) -> Vec<VmsEvent>;
    fn available(&self) -> bool;
}

pub trait AnalysisProgress: Send + Sync {
    /// 0 = nunca rodou (ou rodou com outro modelo: não vale).
    fn read_progress(&self, camera: &str, model: &str) -> i64;
    fn write_progress(&self, camera: &str, analyzed_to: i64, frames: i64, failures: i64, model: &str);
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct MotionSample {
    pub ms: i64,
    pub score: f32,
    pub moved: bool,
    pub scene_changed: bool,
    pub bbox: EventBox,
}

// ------------------------------------------------------------ montagem

use std::sync::{Arc, Mutex};

use vms_core::clock::Clock;
use vms_core::log::SharedLogger;
use vms_core::stop::StopToken;

use crate::config::AnalyticsConfig;
use crate::db::Db;
use crate::index_cache::IndexCache;

/// A análise montada: a fonte que a API consulta, o ensaio, e um worker por
/// câmera (cada um com seu detector de movimento: eles têm estado de cena).
pub struct AnalyticsRig {
    pub events: Option<Arc<dyn EventSource>>,
    pub probe: Option<Arc<probe::MotionProbe>>,
    workers: Mutex<Vec<worker::AnalyticsWorker>>,
    builder: Option<Box<dyn Fn(&str) -> worker::AnalyticsWorker + Send + Sync>>,
}

impl AnalyticsRig {
    pub fn empty() -> Self {
        Self { events: None, probe: None, workers: Mutex::new(Vec::new()), builder: None }
    }

    /// Com FFmpeg monta tudo; sem ele, nem o ensaio (não há como decodificar).
    pub fn build(cfg: &AnalyticsConfig, db: Option<Arc<Db>>, cameras: &[String], cache: Arc<IndexCache>, clock: Arc<dyn Clock>, log: SharedLogger) -> Self {
        let mut rig = Self::empty();
        let Some(ff) = crate::ffmpeg::Ffmpeg::shared() else {
            if cfg.enabled {
                log.warn("analytics", "ligada na config, mas nao ha como decodificar video nesta maquina (FFmpeg ausente). A analise nao vai subir.");
            }
            return rig;
        };
        let keyframes: Arc<dyn crate::thumbs::KeyframeSource> = Arc::new(crate::thumbs::VmsKeyframeSource { cache: cache.clone() });
        let grabber: Arc<dyn crate::thumbs::FrameGrabber> = Arc::new(crate::thumbs::FfmpegGrabber { ff: ff.clone() });
        let walk = Arc::new(walk::WalkSource { cache: cache.clone(), opener: Arc::new(walk::FfmpegOpener(ff)) });
        rig.probe = Some(Arc::new(probe::MotionProbe { keyframes: keyframes.clone(), grabber: grabber.clone(), walk: Some(walk.clone()) }));
        let Some(db) = db else { return rig };
        let store = Arc::new(store::DbEventStore::new(db, clock.clone(), cfg.max_event_ms, log.clone()));
        rig.events = Some(store.clone());
        if !cfg.enabled {
            return rig;
        }
        // Um detector para TODAS as câmeras (o modelo ocupa memória demais para
        // ter um por câmera). Modelo ou DLL ausente: segue só com movimento.
        let objects: Arc<dyn ObjectDetector> = if cfg.model_path.is_empty() {
            Arc::new(NullObjectDetector)
        } else {
            let d = onnx::OnnxObjectDetector::new(std::path::Path::new(&cfg.model_path), &cfg.onnx_dll, onnx::threads_for_inference(), log.clone());
            if d.available() {
                Arc::new(d)
            } else {
                Arc::new(NullObjectDetector)
            }
        };
        log.info("analytics", &objects.describe());
        log.info("analytics", &cfg.describe());
        let cfg = cfg.clone();
        let builder = move |camera: &str| {
            let analyzer = analyzer::FrameAnalyzer::new(
                camera,
                Box::new(motion::FrameDiffMotionDetector::new(cfg.motion_threshold as f32, cfg.scene_change_threshold as f32, cfg.step_ms * 4, cfg.grid_scale as f32, cfg.cell_delta as i32)),
                objects.clone(),
                store.clone(),
                cfg.clone(),
            );
            worker::AnalyticsWorker::start(
                camera,
                analyzer,
                cfg.clone(),
                worker::WorkerDeps { keyframes: keyframes.clone(), grabber: grabber.clone(), walk: Some(walk.clone()), progress: store.clone(), cache: cache.clone(), clock: clock.clone(), log: log.clone() },
                // Parada própria: parar um worker não pode parar o servidor.
                StopToken::new(),
            )
        };
        rig.workers = Mutex::new(cameras.iter().map(|c| builder(c)).collect());
        rig.builder = Some(Box::new(builder));
        rig
    }

    /// Põe uma câmera nova sob análise, sem parar as outras.
    pub fn add_camera(&self, camera: &str) {
        let Some(b) = &self.builder else { return };
        let mut w = self.workers.lock().unwrap_or_else(|p| p.into_inner());
        if w.iter().any(|x| x.camera.eq_ignore_ascii_case(camera)) {
            return;
        }
        w.push(b(camera));
    }

    /// Parâmetros novos para todas, sem parar nada.
    pub fn ajustar(&self, cfg: &AnalyticsConfig) {
        for w in self.workers.lock().unwrap_or_else(|p| p.into_inner()).iter() {
            w.ajustar(cfg);
        }
    }

    pub fn stop(&self) {
        let mut ws = std::mem::take(&mut *self.workers.lock().unwrap_or_else(|p| p.into_inner()));
        for w in ws.iter_mut() {
            w.join();
        }
    }
}
