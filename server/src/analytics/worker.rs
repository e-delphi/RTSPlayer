//! Uma thread por câmera, andando pela gravação atrás do presente (`lag_ms`)
//! e entregando ao analisador um quadro a cada `step_ms`.
//!
//! Começa de onde parou (`analysis_progress`), ou `backfill` para trás na
//! primeira vez. Com percurso (FFmpeg de sequência), anda de 30 em 30 s;
//! sem, pega keyframes soltos. Parâmetros novos valem na próxima volta.

use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use vms_core::clock::Clock;
use vms_core::log::SharedLogger;
use vms_core::stop::StopToken;

use super::analyzer::FrameAnalyzer;
use super::walk::{FrameWalk, WalkSource};
use super::AnalysisProgress;
use crate::config::AnalyticsConfig;
use crate::index_cache::IndexCache;
use crate::thumbs::{FrameGrabber, KeyframeSource};

const FRAME_MAX_W: i32 = 640;
const IDLE_MS: u64 = 5000;
const PROGRESS_EVERY: usize = 30;
/// Distância entre quadros a partir da qual não se compara mais.
const JUMP_MS: i64 = 15_000;
const PERCURSO_MS: i64 = 30_000;

pub struct WorkerDeps {
    pub keyframes: Arc<dyn KeyframeSource>,
    pub grabber: Arc<dyn FrameGrabber>,
    pub walk: Option<Arc<WalkSource>>,
    pub progress: Arc<dyn AnalysisProgress>,
    pub cache: Arc<IndexCache>,
    pub clock: Arc<dyn Clock>,
    pub log: SharedLogger,
}

struct State {
    camera: String,
    deps: WorkerDeps,
    analyzer: FrameAnalyzer,
    cfg: AnalyticsConfig,
    model: String,
    at_ms: i64,
    last_frame_ms: i64,
    frames: i64,
    falhas: i64,
    falhas_lote: usize,
    salvo_em: i64,
    passeio: Option<FrameWalk>,
    passeio_ate: i64,
}

impl State {
    fn tag(&self) -> String {
        format!("analytics.{}", self.camera)
    }

    fn first_recorded_ms(&self) -> i64 {
        self.deps.cache.list_files(&self.camera).iter().map(|f| f.start_ms).filter(|&s| s > 0).min().unwrap_or(0)
    }

    fn start_point(&self) -> i64 {
        let salvo = self.deps.progress.read_progress(&self.camera, &self.model);
        let mut primeiro = self.first_recorded_ms();
        if primeiro == 0 {
            primeiro = self.deps.clock.now_utc_ms();
        }
        if salvo > 0 {
            return salvo.max(primeiro);
        }
        if self.cfg.backfill_ms <= 0 {
            return primeiro;
        }
        primeiro.max(self.deps.clock.now_utc_ms() - self.cfg.backfill_ms)
    }

    fn save_progress(&mut self) {
        if self.at_ms <= self.salvo_em {
            return;
        }
        self.deps.progress.write_progress(&self.camera, self.at_ms, self.frames, self.falhas, &self.model);
        self.salvo_em = self.at_ms;
    }

    fn jumped(&mut self, ms: i64) {
        if self.last_frame_ms > 0 && ms - self.last_frame_ms > JUMP_MS {
            self.analyzer.flush();
            self.analyzer.rewind();
        }
    }

    /// (achou gravação?, avançou?)
    /// `alvo` é o limite da volta (agora − lag): a janela não passa dele.
    /// Passando, ela tocava a ponta do arquivo que ainda grava, o percurso
    /// acabava "sem gravação" antes da hora, e o salto para o fim da janela
    /// deixava segundos de vídeo sem análise (uma câmera ficava presa em um
    /// quadro a cada 30 s).
    fn step_percurso(&mut self, walk: &WalkSource, alvo: i64) -> (bool, bool) {
        if self.passeio.is_none() {
            // Já no alvo: nada a percorrer nesta volta.
            if self.at_ms >= alvo {
                return (true, false);
            }
            self.passeio_ate = (self.at_ms + PERCURSO_MS).min(alvo);
            self.passeio = walk.walk(&self.camera, self.at_ms, self.passeio_ate, self.cfg.step_ms, FRAME_MAX_W, FRAME_MAX_W);
            if self.passeio.is_none() {
                self.at_ms = self.passeio_ate;
                return (true, true);
            }
        }
        let Some((img, ms)) = self.passeio.as_mut().and_then(|p| p.next_frame()) else {
            self.passeio = None;
            self.at_ms = self.at_ms.max(self.passeio_ate);
            return (true, true);
        };
        self.jumped(ms);
        if img.is_valid() {
            self.analyzer.feed(ms, &img);
            self.frames += 1;
        } else {
            self.falhas += 1;
            self.falhas_lote += 1;
        }
        self.last_frame_ms = ms;
        self.at_ms = self.at_ms.max(ms + 1);
        (true, true)
    }

    fn step(&mut self, alvo: i64) -> (bool, bool) {
        if let Some(w) = self.deps.walk.clone() {
            return self.step_percurso(&w, alvo);
        }
        let Some(k) = self.deps.keyframes.grab(&self.camera, self.at_ms) else { return (false, false) };
        let step = self.cfg.step_ms;
        if k.au.is_empty() {
            self.at_ms += step;
            return (true, true);
        }
        if self.last_frame_ms > 0 && k.actual_ms <= self.last_frame_ms {
            self.at_ms = (self.at_ms + step).max(self.last_frame_ms + 1);
            return (true, true);
        }
        self.jumped(k.actual_ms);
        match self.deps.grabber.decode(&k, FRAME_MAX_W, FRAME_MAX_W).filter(|i| i.is_valid()) {
            Some(img) => {
                self.analyzer.feed(k.actual_ms, &img);
                self.frames += 1;
            }
            None => {
                self.falhas += 1;
                self.falhas_lote += 1;
            }
        }
        self.last_frame_ms = k.actual_ms;
        self.at_ms = (self.at_ms + step).max(k.actual_ms + 1);
        (true, true)
    }

    /// Uma volta: até o alvo (agora − lag) ou até a gravação acabar.
    fn round(&mut self, stop: &StopToken) -> usize {
        let alvo = self.deps.clock.now_utc_ms() - self.cfg.lag_ms;
        let mut n = 0;
        while !stop.is_stopped() && self.at_ms <= alvo {
            let (achou, avancou) = self.step(alvo);
            if !achou {
                self.analyzer.flush();
                self.at_ms = self.at_ms.max(alvo);
                break;
            }
            if !avancou {
                break;
            }
            n += 1;
            if n % PROGRESS_EVERY == 0 {
                self.save_progress();
            }
        }
        self.analyzer.flush();
        self.save_progress();
        if n > 0 {
            let quando = vms_core::clock::local_from_utc_ms(self.at_ms);
            let extra = if self.falhas_lote > 0 { format!(" ({} nao decodificaram)", self.falhas_lote) } else { String::new() };
            self.deps.log.info(&self.tag(), &format!("{n} quadros analisados{extra}; ate {:02}/{:02} {:02}:{:02}:{:02}", quando.day, quando.month, quando.hour, quando.minute, quando.second));
        }
        self.falhas_lote = 0;
        n
    }
}

pub struct AnalyticsWorker {
    pub camera: String,
    cfg_nova: Arc<Mutex<Option<AnalyticsConfig>>>,
    stop: StopToken,
    thread: Option<JoinHandle<()>>,
}

impl AnalyticsWorker {
    pub fn start(camera: &str, analyzer: FrameAnalyzer, cfg: AnalyticsConfig, deps: WorkerDeps, stop: StopToken) -> AnalyticsWorker {
        let cfg_nova: Arc<Mutex<Option<AnalyticsConfig>>> = Arc::new(Mutex::new(None));
        let pend = cfg_nova.clone();
        let st = stop.clone();
        let model = std::path::Path::new(&cfg.model_path).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let mut s = State {
            camera: camera.into(),
            deps,
            analyzer,
            cfg,
            model,
            at_ms: 0,
            last_frame_ms: 0,
            frames: 0,
            falhas: 0,
            falhas_lote: 0,
            salvo_em: 0,
            passeio: None,
            passeio_ate: 0,
        };
        let thread = std::thread::Builder::new()
            .name(format!("analytics.{camera}"))
            .spawn(move || {
                s.at_ms = s.start_point();
                s.salvo_em = s.at_ms;
                let q = vms_core::clock::local_from_utc_ms(s.at_ms);
                s.deps.log.info(&s.tag(), &format!("comecando em {:02}/{:02} {:02}:{:02}:{:02} ({})", q.day, q.month, q.hour, q.minute, q.second, s.cfg.describe()));
                while !st.is_stopped() {
                    if let Some(mut nova) = pend.lock().unwrap_or_else(|p| p.into_inner()).take() {
                        nova.enabled = s.cfg.enabled;
                        s.analyzer.ajustar(&nova);
                        s.cfg = nova;
                        s.deps.log.info(&s.tag(), &format!("parametros novos em uso: {}", s.cfg.describe()));
                    }
                    s.round(&st);
                    if st.wait_ms(IDLE_MS) {
                        break;
                    }
                }
                s.analyzer.flush();
                s.save_progress();
                s.deps.log.info(&s.tag(), &format!("parou; {} quadros analisados nesta subida, {} descartados por nao decodificarem", s.frames, s.falhas));
            })
            .expect("thread de analise");
        AnalyticsWorker { camera: camera.into(), cfg_nova, stop, thread: Some(thread) }
    }

    /// Parâmetros novos, sem parar.
    pub fn ajustar(&self, cfg: &AnalyticsConfig) {
        *self.cfg_nova.lock().unwrap_or_else(|p| p.into_inner()) = Some(cfg.clone());
    }

    pub fn join(&mut self) {
        self.stop.stop();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for AnalyticsWorker {
    fn drop(&mut self) {
        self.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analytics::analyzer::tests::StoreMem;
    use crate::analytics::motion::FrameDiffMotionDetector;
    use crate::analytics::walk::tests::AbreFalsa;
    use crate::analytics::NullObjectDetector;
    use vms_core::clock::ManualClock;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    #[derive(Default)]
    struct Prog(Mutex<i64>);
    impl AnalysisProgress for Prog {
        fn read_progress(&self, _: &str, _: &str) -> i64 {
            *self.0.lock().unwrap()
        }
        fn write_progress(&self, _: &str, to: i64, _: i64, _: i64, _: &str) {
            *self.0.lock().unwrap() = to;
        }
    }

    /// Uma gravação de 20 blocos de 1 s a partir de 1_000 s, e o estado do
    /// worker com o relógio em `agora` e o `lag` dado.
    fn estado(tag: &str, agora: i64, lag: i64) -> (State, Arc<StoreMem>, Arc<Prog>, Arc<ManualClock>, TempDir) {
        let d = TempDir::new(tag);
        let dir = ensure_camera_dir(d.path(), "cam").unwrap();
        write_vms(&dir.join("cam_1.vms"), 1_000_000, 20, 1000, true);
        let cache = Arc::new(IndexCache::new(d.path(), None, vms_core::log::null()));
        let store = Arc::new(StoreMem::default());
        let prog = Arc::new(Prog::default());
        let clock = Arc::new(ManualClock::new(agora));
        let cfg = AnalyticsConfig { enabled: true, step_ms: 1000, lag_ms: lag, backfill_ms: 0, ..Default::default() };
        let analyzer = FrameAnalyzer::new("cam", Box::new(FrameDiffMotionDetector::new(0.006, 0.85, 4000, 1.0, 0)), Arc::new(NullObjectDetector), store.clone(), cfg.clone());
        let mut s = State {
            camera: "cam".into(),
            deps: WorkerDeps {
                keyframes: Arc::new(crate::thumbs::VmsKeyframeSource { cache: cache.clone() }),
                grabber: Arc::new(NoGrab),
                walk: Some(Arc::new(WalkSource { cache: cache.clone(), opener: Arc::new(AbreFalsa) })),
                progress: prog.clone(),
                cache,
                clock: clock.clone(),
                log: vms_core::log::null(),
            },
            analyzer,
            cfg,
            model: String::new(),
            at_ms: 0,
            last_frame_ms: 0,
            frames: 0,
            falhas: 0,
            falhas_lote: 0,
            salvo_em: 0,
            passeio: None,
            passeio_ate: 0,
        };
        s.at_ms = s.start_point();
        (s, store, prog, clock, d)
    }

    #[test]
    fn uma_volta_acha_o_movimento_e_guarda_o_progresso() {
        let (mut s, store, prog, _c, _d) = estado("worker", 1_030_000, 0);
        assert_eq!(s.at_ms, 1_000_000, "sem progresso: do comeco da gravacao");
        let n = s.round(&StopToken::new());
        assert!(n >= 20, "{n}");
        assert_eq!(s.frames, 20);
        assert!(*prog.0.lock().unwrap() >= 1_019_000);
        // Cinza de 0..19, um nível por quadro: abaixo do delta, nada de evento.
        assert!(store.0.lock().unwrap().is_empty());
    }

    /// A janela do percurso para no alvo (agora − lag): passar dele tocava a
    /// ponta do arquivo e pulava o que ainda ia ser gravado (visto na câmera
    /// real: um quadro a cada 30 s).
    #[test]
    fn a_volta_nao_passa_do_alvo() {
        // Agora 1_045 s, lag 30 s: o alvo é 1_015 s, no meio da gravação.
        let (mut s, _store, _prog, clock, _d) = estado("worker-alvo", 1_045_000, 30_000);
        s.round(&StopToken::new());
        assert!(s.at_ms <= 1_016_000, "parou em {}, depois do alvo", s.at_ms);
        let antes = s.frames;
        // Mais 10 s: a volta seguinte continua de onde parou, sem buraco.
        clock.advance(10_000);
        s.round(&StopToken::new());
        assert_eq!(s.frames, 20, "todos os quadros, nas duas voltas (antes {antes})");
        // O alvo agora é 1_025 s. Sem o teto, o percurso aberto na 1ª volta ia
        // até 1_030 s, batia na ponta do arquivo e saltava para lá: o que fosse
        // gravado até 1_030 s nunca seria analisado.
        assert!(s.at_ms <= 1_025_001, "saltou para {}, depois do alvo", s.at_ms);
    }

    struct NoGrab;
    impl FrameGrabber for NoGrab {
        fn decode(&self, _: &crate::thumbs::Keyframe, _: i32, _: i32) -> Option<crate::ffmpeg::RgbImage> {
            None
        }
    }
}
