//! Grava o que chega num [`MediaSink`] em `.vms`. É o único gravador: RTSP e
//! DVRIP entregam os mesmos samples, e os dois geram o mesmo arquivo.
//!
//! O header fixa as trilhas e é escrito uma vez; como vídeo e áudio são
//! anunciados em momentos diferentes, o começo espera um pouco pelo áudio,
//! guardando os samples (o arquivo começa onde a mídia começou).
//!
//! Roda de arquivo a cada `rotate_ms`, esperando um bloco com keyframe para o
//! arquivo novo começar por um ponto de entrada.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use crate::camera::format_filename;
use crate::clock::Clock;
use crate::log::SharedLogger;
use crate::media::{AudioCodec, AudioTrackInfo, Sample, TrackKind, VideoCodec, VideoTrackInfo};
use crate::sink::MediaSink;
use crate::vms::format::{samples_have_keyframe, Block, Header, FORMAT_VERSION};
use crate::vms::paths::{ensure_camera_dir, unique_recording_path};
use crate::vms::{BlockBuilder, BlockLimits, FileRecordingWriter, RecordingWriter};

/// RTP de vídeo é 90 kHz, e é a base em que o DVRIP numera os PTS.
const VIDEO_TIMESCALE: u32 = 90_000;
const MAX_PENDING_BYTES: usize = 8 * 1024 * 1024;
const ROTATE_KEYFRAME_GRACE_MS: i64 = 60_000;

#[derive(Debug, Clone)]
pub struct RecorderConfig {
    pub camera: String,
    pub storage_dir: PathBuf,
    pub filename_pattern: String,
    pub source_uri: String,
    pub record_audio: bool,
    pub block: BlockLimits,
    pub wait_audio_ms: i64,
    pub rotate_ms: i64,
}

/// Quem abre o arquivo: existe como porta para o teste gravar em memória.
pub trait WriterFactory: Send + Sync {
    fn create(&self, path: &Path) -> std::io::Result<Box<dyn RecordingWriter>>;
}

pub struct FileWriterFactory;

impl WriterFactory for FileWriterFactory {
    fn create(&self, path: &Path) -> std::io::Result<Box<dyn RecordingWriter>> {
        Ok(Box::new(FileRecordingWriter::create(path)?))
    }
}

#[derive(Default)]
struct Formatos {
    video: Option<(VideoCodec, u16, u16, Vec<u8>)>,
    audio: Option<(AudioCodec, u32, u8, Vec<u8>)>,
}

struct Inner {
    fmt: Formatos,
    first_format_ms: i64,
    pending: Vec<Sample>,
    pending_bytes: usize,
    writer: Option<Box<dyn RecordingWriter>>,
    builder: Option<BlockBuilder>,
    open: bool,
    file_started_ms: i64,
    current: Option<PathBuf>,
}

pub struct Recorder {
    cfg: RecorderConfig,
    clock: Arc<dyn Clock>,
    log: SharedLogger,
    factory: Arc<dyn WriterFactory>,
    inner: Mutex<Inner>,
}

impl Recorder {
    pub fn new(cfg: RecorderConfig, clock: Arc<dyn Clock>, log: SharedLogger) -> Self {
        Self::with_factory(cfg, clock, log, Arc::new(FileWriterFactory))
    }

    pub fn with_factory(cfg: RecorderConfig, clock: Arc<dyn Clock>, log: SharedLogger, factory: Arc<dyn WriterFactory>) -> Self {
        Self {
            cfg,
            clock,
            log,
            factory,
            inner: Mutex::new(Inner {
                fmt: Formatos::default(),
                first_format_ms: 0,
                pending: Vec::new(),
                pending_bytes: 0,
                writer: None,
                builder: None,
                open: false,
                file_started_ms: 0,
                current: None,
            }),
        }
    }

    fn tag(&self) -> String {
        format!("recsink.{}", self.cfg.camera)
    }

    /// O arquivo que está sendo gravado agora (a retenção não pode apagá-lo).
    pub fn current_file(&self) -> Option<PathBuf> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner()).current.clone()
    }

    fn output_path(&self) -> std::io::Result<PathBuf> {
        let dir = ensure_camera_dir(&self.cfg.storage_dir, &self.cfg.camera)?;
        let name = format_filename(&self.cfg.filename_pattern, &self.cfg.camera, self.clock.now_utc_ms());
        Ok(unique_recording_path(&dir.join(name)))
    }

    fn header(&self, f: &Formatos) -> Header {
        let mut h = Header { version: FORMAT_VERSION, creation_unix_ms: self.clock.now_utc_ms(), source_uri: self.cfg.source_uri.clone(), ..Default::default() };
        if let Some((c, w, hh, e)) = &f.video {
            if *c != VideoCodec::None {
                h.video_present = true;
                h.video = VideoTrackInfo { codec: *c, timescale: VIDEO_TIMESCALE, width: *w, height: *hh, extradata: e.clone() };
            }
        }
        if self.cfg.record_audio {
            if let Some((c, rate, ch, e)) = &f.audio {
                if *c != AudioCodec::None {
                    h.audio_present = true;
                    h.audio = AudioTrackInfo { codec: *c, timescale: *rate, sample_rate: *rate, channels: *ch, bits_per_sample: 16, extradata: e.clone() };
                }
            }
        }
        h
    }

    fn ready_to_open(&self, i: &Inner) -> bool {
        if i.fmt.video.is_none() {
            return false;
        }
        if i.fmt.audio.is_some() || !self.cfg.record_audio || i.pending_bytes >= MAX_PENDING_BYTES {
            return true;
        }
        self.clock.monotonic_ms() - i.first_format_ms >= self.cfg.wait_audio_ms
    }

    fn open_writer(&self, i: &mut Inner) {
        let h = self.header(&i.fmt);
        let res = self.output_path().and_then(|p| {
            let mut w = self.factory.create(&p)?;
            w.write_header(&h)?;
            Ok((p, w))
        });
        match res {
            Ok((p, w)) => {
                self.log.info(&self.tag(), &format!("gravando em {}", p.display()));
                let mut b = BlockBuilder::new(self.cfg.block);
                b.set_timescales(h.video.timescale, h.audio.timescale);
                i.writer = Some(w);
                i.builder = Some(b);
                i.current = Some(p);
                i.file_started_ms = self.clock.monotonic_ms();
                i.open = true;
            }
            Err(e) => self.log.warn(&self.tag(), &format!("nao consegui abrir a gravacao: {e}")),
        }
    }

    fn rotate_due(&self, i: &Inner, b: &Block) -> bool {
        if self.cfg.rotate_ms <= 0 {
            return false;
        }
        let age = self.clock.monotonic_ms() - i.file_started_ms;
        age >= self.cfg.rotate_ms && (samples_have_keyframe(&b.samples) || age >= self.cfg.rotate_ms + ROTATE_KEYFRAME_GRACE_MS)
    }

    fn rotate(&self, i: &mut Inner) {
        if let Some(mut w) = i.writer.take() {
            w.close(true);
        }
        let h = self.header(&i.fmt);
        match self.output_path().and_then(|p| {
            let mut w = self.factory.create(&p)?;
            w.write_header(&h)?;
            Ok((p, w))
        }) {
            Ok((p, w)) => {
                self.log.info(&self.tag(), &format!("rodando de arquivo; seguindo em {}", p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
                i.writer = Some(w);
                i.current = Some(p);
                i.file_started_ms = self.clock.monotonic_ms();
            }
            Err(e) => {
                i.current = None;
                self.log.warn(&self.tag(), &format!("falha ao abrir o arquivo novo: {e}"));
            }
        }
    }

    fn write_block(&self, i: &mut Inner, b: Block) {
        // Roda ANTES de gravar este bloco: o arquivo novo começa por ele.
        if self.rotate_due(i, &b) {
            self.rotate(i);
        }
        if let Some(w) = i.writer.as_mut() {
            if let Err(e) = w.write_block(&b) {
                self.log.warn(&self.tag(), &format!("WriteBlock falhou: {e}"));
                i.writer = None;
            }
        }
    }

    fn add(&self, i: &mut Inner, s: &Sample) {
        let (now, mono) = (self.clock.now_utc_ms(), self.clock.monotonic_ms());
        let blk = i.builder.as_mut().and_then(|b| b.add(s, now, mono));
        if let Some(b) = blk {
            self.write_block(i, b);
        }
    }

    fn close(&self, i: &mut Inner, clean: bool) {
        if let Some(b) = i.builder.as_mut().and_then(|b| b.flush()) {
            self.write_block(i, b);
        }
        i.builder = None;
        if let Some(mut w) = i.writer.take() {
            w.close(clean);
        }
        i.open = false;
        i.current = None;
    }

    fn reset(i: &mut Inner) {
        i.fmt = Formatos::default();
        i.first_format_ms = 0;
        i.pending.clear();
        i.pending_bytes = 0;
    }
}

impl MediaSink for Recorder {
    fn on_video_format(&self, codec: VideoCodec, w: u16, h: u16, extradata: &[u8]) {
        let mut i = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        // Formato novo no meio do stream: recomeça um arquivo.
        if i.open {
            self.close(&mut i, true);
            Self::reset(&mut i);
        }
        i.fmt.video = Some((codec, w, h, extradata.to_vec()));
        if i.first_format_ms == 0 {
            i.first_format_ms = self.clock.monotonic_ms();
        }
    }

    fn on_audio_format(&self, codec: AudioCodec, rate: u32, ch: u8, extradata: &[u8]) {
        let mut i = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if i.open {
            return; // arquivo aberto: a trilha de áudio não entra mais
        }
        i.fmt.audio = Some((codec, rate, ch, extradata.to_vec()));
        if i.first_format_ms == 0 {
            i.first_format_ms = self.clock.monotonic_ms();
        }
    }

    fn on_sample(&self, s: &Sample) {
        let mut i = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if !i.open {
            if i.fmt.video.is_none() {
                return;
            }
            if i.pending_bytes < MAX_PENDING_BYTES {
                i.pending_bytes += s.data.len();
                i.pending.push(s.clone());
            }
            if !self.ready_to_open(&i) {
                return;
            }
            self.open_writer(&mut i);
            if !i.open {
                return;
            }
            let keep_audio = self.cfg.record_audio && i.fmt.audio.is_some();
            let pend = std::mem::take(&mut i.pending);
            i.pending_bytes = 0;
            for p in pend.iter().filter(|p| keep_audio || p.kind != TrackKind::Audio) {
                self.add(&mut i, p);
            }
            return;
        }
        if s.kind == TrackKind::Audio && !(self.cfg.record_audio && i.fmt.audio.is_some()) {
            return;
        }
        self.add(&mut i, s);
        // Rotação que não abriu o arquivo novo: desmonta e reabre no próximo.
        if i.open && i.writer.is_none() {
            self.close(&mut i, true);
        }
    }

    fn on_stream_stopped(&self) {
        let mut i = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        self.close(&mut i, true);
        Self::reset(&mut i);
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        let mut i = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        self.close(&mut i, true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::testutil::TempDir;
    use crate::vms::VmsReader;

    fn cfg(dir: &Path, rotate: i64) -> RecorderConfig {
        RecorderConfig {
            camera: "cam".into(),
            storage_dir: dir.into(),
            filename_pattern: "{name}_{yyyy}{MM}{dd}{HH}{mm}{ss}.vms".into(),
            source_uri: "rtsp://x".into(),
            record_audio: true,
            block: BlockLimits { max_samples: 2, max_duration_ms: 100_000, max_size_bytes: 1 << 20 },
            wait_audio_ms: 1500,
            rotate_ms: rotate,
        }
    }

    #[test]
    fn espera_o_audio_e_grava_tudo() {
        crate::clock::force_local_offset_ms(0);
        let d = TempDir::new("rec1");
        let clock = Arc::new(ManualClock::new(1_000_000));
        let r = Recorder::new(cfg(d.path(), 0), clock.clone(), crate::log::null());
        r.on_video_format(VideoCodec::H264, 640, 480, &[0, 0, 0, 1, 0x67]);
        r.on_sample(&Sample::video(0, true, vec![1]));
        assert!(r.current_file().is_none(), "segurando à espera do áudio");
        r.on_audio_format(AudioCodec::G711A, 8000, 1, &[]);
        r.on_sample(&Sample::audio(0, vec![2; 160]));
        let f = r.current_file().unwrap();
        for k in 1..6 {
            clock.advance(40);
            r.on_sample(&Sample::video(k * 3600, false, vec![k as u8]));
        }
        r.on_stream_stopped();
        assert!(r.current_file().is_none());
        let mut rd = VmsReader::open(&f).unwrap();
        assert!(rd.read_header());
        assert!(rd.header().audio_present && rd.header().video_present);
        assert_eq!(rd.header().video.width, 640);
        assert_eq!(rd.ensure_index(), 4);
        assert!(rd.index_from_footer());
    }

    #[test]
    fn sem_audio_abre_depois_da_janela_e_roda_no_keyframe() {
        crate::clock::force_local_offset_ms(0);
        let d = TempDir::new("rec2");
        let clock = Arc::new(ManualClock::new(2_000_000));
        let r = Recorder::new(cfg(d.path(), 1000), clock.clone(), crate::log::null());
        r.on_video_format(VideoCodec::H264, 0, 0, &[]);
        r.on_sample(&Sample::video(0, true, vec![1]));
        clock.advance(1600);
        r.on_sample(&Sample::video(3600, false, vec![2]));
        let a = r.current_file().unwrap();
        // Passa do prazo; o bloco seguinte com keyframe começa outro arquivo.
        clock.advance(2000);
        r.on_sample(&Sample::video(7200, true, vec![3]));
        r.on_sample(&Sample::video(10800, false, vec![4]));
        let b = r.current_file().unwrap();
        assert_ne!(a, b);
        drop(r);
        let n = std::fs::read_dir(crate::vms::paths::camera_dir(d.path(), "cam")).unwrap().filter(|e| e.as_ref().unwrap().path().extension().is_some_and(|x| x == "vms")).count();
        assert_eq!(n, 2);
    }
}
