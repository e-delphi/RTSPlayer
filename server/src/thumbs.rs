//! Miniaturas da linha do tempo: uma por minuto, do keyframe daquele instante.
//!
//! A cadeia é de peças trocáveis: quem acha o keyframe (`KeyframeSource`),
//! quem decodifica (`FrameGrabber`), quem codifica (`ImageEncoder`), onde mora o
//! JPEG (`DiskCache`, em `<exe>/cache/<câmera>/thumbs/<dia>/HHMM.jpg`) e quem
//! lembra que um minuto não tem imagem (`ThumbIndex`, tabela `thumb`). Sem
//! FFmpeg, a fonte é a nula e a barra fica sem miniatura.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use vms_core::clock::{local_from_utc_ms, Clock};
use vms_core::log::SharedLogger;
use vms_core::media::VideoCodec;
use vms_core::vms::format::{index_block_at_time, index_keyframe_at_or_before, IDX_FLAG_KEYFRAME};
use vms_core::vms::paths::camera_dir;
use vms_core::vms::VmsReader;

use crate::db::Db;
use crate::ffmpeg::{Decoder, Ffmpeg, RgbImage};
use crate::index_cache::{FileInfo, IndexCache};

pub const THUMB_W: i32 = 160;
pub const THUMB_H: i32 = 120;
const MISS_TTL_MS: u128 = 60_000;
/// Ausência só vira registro depois de 2 min: o minuto de agora ainda grava.
const MIN_IDADE_AUSENCIA_MS: i64 = 120_000;

pub fn minute_of(ms: i64) -> i64 {
    if ms < 0 {
        0
    } else {
        ms / 60_000 * 60_000
    }
}

pub fn default_cache_dir() -> PathBuf {
    crate::config::exe_dir().join("cache")
}

/// Um keyframe e o que precisa para decodificá-lo.
#[derive(Debug, Clone, Default)]
pub struct Keyframe {
    pub au: Vec<u8>,
    pub extra: Vec<u8>,
    pub codec: VideoCodec,
    /// O instante do quadro de verdade (não o pedido).
    pub actual_ms: i64,
}

pub trait KeyframeSource: Send + Sync {
    fn grab(&self, camera: &str, ms: i64) -> Option<Keyframe>;
}

pub trait FrameGrabber: Send + Sync {
    fn decode(&self, k: &Keyframe, max_w: i32, max_h: i32) -> Option<RgbImage>;
}

pub trait ImageEncoder: Send + Sync {
    fn encode(&self, img: &RgbImage) -> Option<Vec<u8>>;
    fn content_type(&self) -> &'static str {
        "image/jpeg"
    }
}

pub trait ThumbIndex: Send + Sync {
    fn note_hit(&self, camera: &str, minute: i64, path: &Path, bytes: usize, w: usize, h: usize);
    fn note_missing(&self, camera: &str, minute: i64);
    fn known_missing(&self, camera: &str, minute: i64) -> bool;
}

/// O que a rota `/api/thumb` enxerga.
pub trait ThumbSource: Send + Sync {
    /// (jpeg, minuto que a imagem representa).
    fn get(&self, camera: &str, ms: i64) -> Option<(Vec<u8>, i64)>;
    fn content_type(&self) -> &'static str {
        "image/jpeg"
    }
    fn available(&self) -> bool;
}

pub struct NullThumbSource;

impl ThumbSource for NullThumbSource {
    fn get(&self, _: &str, _: i64) -> Option<(Vec<u8>, i64)> {
        None
    }
    fn available(&self) -> bool {
        false
    }
}

// ------------------------------------------------------------ keyframe

/// O arquivo do instante; não havendo, o primeiro depois dele.
pub fn file_at(cache: &IndexCache, camera: &str, ms: i64) -> Option<FileInfo> {
    let files = cache.list_files(camera);
    files.iter().find(|f| ms >= f.start_ms && ms < f.end_ms).or_else(|| files.iter().find(|f| f.start_ms >= ms)).cloned()
}

pub struct VmsKeyframeSource {
    pub cache: Arc<IndexCache>,
}

impl KeyframeSource for VmsKeyframeSource {
    fn grab(&self, camera: &str, ms: i64) -> Option<Keyframe> {
        let info = file_at(&self.cache, camera, ms)?;
        let index = self.cache.index(&info.path)?;
        let b = index_block_at_time(&index, ms).unwrap_or(0);
        let k = index_keyframe_at_or_before(&index, b)?;
        let mut r = VmsReader::open(&info.path).ok()?;
        if !r.read_header() || !r.header().video_present {
            return None;
        }
        let codec = r.header().video.codec;
        let extra = r.header().video.extradata.clone();
        let ts = if r.header().video.timescale == 0 { 90_000 } else { r.header().video.timescale } as i64;
        r.seed_index(&index, index[index.len() - 1].offset);
        if !r.seek_to_block(k) {
            return None;
        }
        let blk = r.read_next_block()?;
        let anchor = if blk.video_anchor_ms != 0 { blk.video_anchor_ms } else { blk.start_unix_ms };
        let mut first = None;
        for s in &blk.samples {
            if s.track_id != 0 {
                continue;
            }
            let fp = *first.get_or_insert(s.pts);
            if s.flags & IDX_FLAG_KEYFRAME == 0 || s.payload_size == 0 {
                continue;
            }
            let au = blk.sample_data(s)?.to_vec();
            return Some(Keyframe { au, extra, codec, actual_ms: anchor + (s.pts - fp) * 1000 / ts });
        }
        None
    }
}

// ------------------------------------------------------------ decodificação

pub struct FfmpegGrabber {
    pub ff: Arc<Ffmpeg>,
}

impl FrameGrabber for FfmpegGrabber {
    fn decode(&self, k: &Keyframe, max_w: i32, max_h: i32) -> Option<RgbImage> {
        Decoder::open(self.ff.clone(), k.codec, &k.extra, max_w, max_h)?.decode_one(&k.au)
    }
}

pub struct JpegEncoder {
    pub quality: u8,
}

impl ImageEncoder for JpegEncoder {
    fn encode(&self, img: &RgbImage) -> Option<Vec<u8>> {
        if !img.is_valid() || img.width > u16::MAX as usize || img.height > u16::MAX as usize {
            return None;
        }
        let mut out = Vec::new();
        let enc = jpeg_encoder::Encoder::new(&mut out, self.quality.clamp(1, 100));
        enc.encode(&img.pixels[..img.width * img.height * 3], img.width as u16, img.height as u16, jpeg_encoder::ColorType::Rgb).ok()?;
        (!out.is_empty()).then_some(out)
    }
}

// ------------------------------------------------------------ disco

pub struct DiskCache {
    root: PathBuf,
}

impl DiskCache {
    pub fn new(root: &Path) -> Self {
        Self { root: root.to_path_buf() }
    }

    fn day_dir(&self, camera: &str, minute: i64) -> PathBuf {
        let t = local_from_utc_ms(minute);
        camera_dir(&self.root, camera).join("thumbs").join(format!("{:04}-{:02}-{:02}", t.year, t.month, t.day))
    }

    pub fn path_of(&self, camera: &str, minute: i64) -> PathBuf {
        let t = local_from_utc_ms(minute);
        self.day_dir(camera, minute).join(format!("{:02}{:02}.jpg", t.hour, t.minute))
    }

    pub fn try_read(&self, camera: &str, minute: i64) -> Option<Vec<u8>> {
        std::fs::read(self.path_of(camera, minute)).ok().filter(|d| !d.is_empty())
    }

    /// Escreve num .tmp e renomeia: quem lê nunca vê JPEG pela metade.
    pub fn write(&self, camera: &str, minute: i64, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        let p = self.path_of(camera, minute);
        let tmp = p.with_extension("jpg.tmp");
        let ok = std::fs::create_dir_all(self.day_dir(camera, minute)).is_ok() && std::fs::write(&tmp, data).is_ok() && std::fs::rename(&tmp, &p).is_ok();
        if !ok {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

/// Apaga as pastas de dia anteriores ao dia de `keep_from_ms`, em todas as
/// câmeras sob `root`. Devolve quantas foram.
pub fn prune_cache_older_than(root: &Path, keep_from_ms: i64) -> usize {
    let t = local_from_utc_ms(keep_from_ms);
    let limite = format!("{:04}-{:02}-{:02}", t.year, t.month, t.day);
    let mut n = 0;
    let Ok(cams) = std::fs::read_dir(root) else { return 0 };
    for cam in cams.flatten() {
        let Ok(days) = std::fs::read_dir(cam.path().join("thumbs")) else { continue };
        for d in days.flatten() {
            let name = d.file_name().to_string_lossy().into_owned();
            let b = name.as_bytes();
            let is_day = name.len() == 10 && b[4] == b'-' && b[7] == b'-' && name.chars().filter(|c| c.is_ascii_digit()).count() == 8;
            // Comparação de texto vale para yyyy-mm-dd.
            if is_day && name < limite && std::fs::remove_dir_all(d.path()).is_ok() {
                n += 1;
            }
        }
    }
    n
}

// ------------------------------------------------------------ banco

pub struct DbThumbIndex {
    pub db: Arc<Db>,
    pub clock: Arc<dyn Clock>,
}

impl ThumbIndex for DbThumbIndex {
    fn note_hit(&self, camera: &str, minute: i64, path: &Path, bytes: usize, w: usize, h: usize) {
        self.db.post(
            "INSERT INTO thumb (camera_id, minute_ms, state, path, bytes, width, height, created_at_ms) \
             VALUES ((SELECT id FROM camera WHERE name = ?), ?, 0, ?, ?, ?, ?, ?) \
             ON CONFLICT(camera_id, minute_ms) DO UPDATE SET state = 0, path = excluded.path, bytes = excluded.bytes, \
               width = excluded.width, height = excluded.height, created_at_ms = excluded.created_at_ms",
            p![camera, minute, path.to_string_lossy().into_owned(), bytes, w, h, self.clock.now_utc_ms()],
        );
    }

    fn note_missing(&self, camera: &str, minute: i64) {
        if self.clock.now_utc_ms() - minute < MIN_IDADE_AUSENCIA_MS {
            return;
        }
        self.db.post(
            "INSERT INTO thumb (camera_id, minute_ms, state, created_at_ms) VALUES ((SELECT id FROM camera WHERE name = ?), ?, 1, ?) \
             ON CONFLICT(camera_id, minute_ms) DO UPDATE SET state = 1, created_at_ms = excluded.created_at_ms",
            p![camera, minute, self.clock.now_utc_ms()],
        );
    }

    fn known_missing(&self, camera: &str, minute: i64) -> bool {
        self.db.query_i64("SELECT t.state FROM thumb t JOIN camera c ON c.id = t.camera_id WHERE c.name = ? AND t.minute_ms = ?", p![camera, minute], 0) == 1
    }
}

// ------------------------------------------------------------ serviço

pub struct ThumbService {
    pub keyframes: Arc<dyn KeyframeSource>,
    pub grabber: Arc<dyn FrameGrabber>,
    pub encoder: Arc<dyn ImageEncoder>,
    pub cache: DiskCache,
    pub index: Option<Arc<dyn ThumbIndex>>,
    pub width: i32,
    pub height: i32,
    pub log: SharedLogger,
    misses: Mutex<HashMap<String, Instant>>,
    gen: Mutex<()>,
}

impl ThumbService {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        keyframes: Arc<dyn KeyframeSource>,
        grabber: Arc<dyn FrameGrabber>,
        encoder: Arc<dyn ImageEncoder>,
        cache: DiskCache,
        index: Option<Arc<dyn ThumbIndex>>,
        width: i32,
        height: i32,
        log: SharedLogger,
    ) -> Self {
        Self { keyframes, grabber, encoder, cache, index, width, height, log, misses: Mutex::new(HashMap::new()), gen: Mutex::new(()) }
    }

    fn recent_miss(&self, key: &str) -> bool {
        self.misses.lock().unwrap_or_else(|p| p.into_inner()).get(key).map(|t| t.elapsed().as_millis() < MISS_TTL_MS).unwrap_or(false)
    }

    fn note_miss(&self, key: String) {
        let mut m = self.misses.lock().unwrap_or_else(|p| p.into_inner());
        if m.len() > 5000 {
            m.clear();
        }
        m.insert(key, Instant::now());
    }

    fn generate(&self, camera: &str, minute: i64) -> Option<(Vec<u8>, i64, usize, usize)> {
        let passo = |m: &str| self.log.debug("thumb", &format!("{camera} {minute}: {m}"));
        let Some(k) = self.keyframes.grab(camera, minute) else {
            passo("sem keyframe na gravacao para este instante");
            return None;
        };
        if k.au.is_empty() {
            passo("keyframe vazio");
            return None;
        }
        let Some(img) = self.grabber.decode(&k, self.width, self.height).filter(RgbImage::is_valid) else {
            passo(&format!("decodificacao falhou (codec {:?}, {} bytes, extradata {})", k.codec, k.au.len(), k.extra.len()));
            return None;
        };
        let Some(jpg) = self.encoder.encode(&img) else {
            passo(&format!("encode falhou ({}x{})", img.width, img.height));
            return None;
        };
        passo(&format!("gerada {}x{}, {} bytes", img.width, img.height, jpg.len()));
        Some((jpg, k.actual_ms, img.width, img.height))
    }
}

impl ThumbSource for ThumbService {
    fn available(&self) -> bool {
        true
    }

    fn content_type(&self) -> &'static str {
        self.encoder.content_type()
    }

    fn get(&self, camera: &str, ms: i64) -> Option<(Vec<u8>, i64)> {
        let minute = minute_of(ms);
        if camera.is_empty() {
            return None;
        }
        if let Some(d) = self.cache.try_read(camera, minute) {
            return Some((d, minute));
        }
        let key = format!("{}|{minute}", camera.to_lowercase());
        if self.recent_miss(&key) {
            return None;
        }
        if self.index.as_ref().map(|i| i.known_missing(camera, minute)).unwrap_or(false) {
            self.note_miss(key);
            return None;
        }
        // Uma geração por vez: o FFmpeg é CPU, e duas da mesma barra brigam.
        let r = {
            let _g = self.gen.lock().unwrap_or_else(|p| p.into_inner());
            if let Some(d) = self.cache.try_read(camera, minute) {
                return Some((d, minute));
            }
            self.generate(camera, minute)
        };
        match r {
            Some((jpg, actual, w, h)) => {
                self.cache.write(camera, minute, &jpg);
                if let Some(i) = &self.index {
                    i.note_hit(camera, minute, &self.cache.path_of(camera, minute), jpg.len(), w, h);
                }
                Some((jpg, actual))
            }
            None => {
                self.note_miss(key);
                if let Some(i) = &self.index {
                    i.note_missing(camera, minute);
                }
                None
            }
        }
    }
}

/// A montagem: com FFmpeg, o serviço inteiro; sem, a fonte nula.
pub fn build_thumb_source(cache: Arc<IndexCache>, db: Option<Arc<Db>>, clock: Arc<dyn Clock>, log: SharedLogger) -> Arc<dyn ThumbSource> {
    match Ffmpeg::shared() {
        Some(ff) => {
            log.info("thumb", &format!("FFmpeg disponivel (avcodec {}.{}); miniaturas ligadas", ff.version >> 16, (ff.version >> 8) & 0xFF));
            Arc::new(ThumbService::new(
                Arc::new(VmsKeyframeSource { cache }),
                Arc::new(FfmpegGrabber { ff }),
                Arc::new(JpegEncoder { quality: 70 }),
                DiskCache::new(&default_cache_dir()),
                db.map(|db| Arc::new(DbThumbIndex { db, clock }) as Arc<dyn ThumbIndex>),
                THUMB_W,
                THUMB_H,
                log,
            ))
        }
        None => {
            log.info("thumb", "FFmpeg ausente; nao ha como decodificar video nesta maquina (sem miniaturas)");
            Arc::new(NullThumbSource)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    struct Cinza(AtomicUsize);
    impl FrameGrabber for Cinza {
        fn decode(&self, k: &Keyframe, w: i32, h: i32) -> Option<RgbImage> {
            self.0.fetch_add(1, Ordering::SeqCst);
            (k.au.len() > 4).then(|| RgbImage { width: w as usize, height: h as usize, pixels: vec![128; (w * h * 3) as usize] })
        }
    }

    #[test]
    fn gera_guarda_e_lembra_ausencia() {
        vms_core::clock::force_local_offset_ms(0);
        let d = TempDir::new("thumbs");
        let rec = d.path().join("rec");
        let dir = ensure_camera_dir(&rec, "cam").unwrap();
        write_vms(&dir.join("cam_1.vms"), 600_000, 8, 1000, true);
        let cache = Arc::new(IndexCache::new(&rec, None, vms_core::log::null()));
        let kf = VmsKeyframeSource { cache: cache.clone() };
        let k = kf.grab("cam", 605_500).unwrap();
        assert_eq!(k.actual_ms, 604_000, "o keyframe de antes");
        assert_eq!(k.codec, VideoCodec::H264);

        let dec = Arc::new(Cinza(AtomicUsize::new(0)));
        let s = ThumbService::new(Arc::new(kf), dec.clone(), Arc::new(JpegEncoder { quality: 70 }), DiskCache::new(&d.path().join("cache")), None, 32, 24, vms_core::log::null());
        let (jpg, _) = s.get("cam", 600_000 + 30_000).unwrap();
        assert_eq!(&jpg[..2], &[0xFF, 0xD8], "JPEG");
        assert!(s.get("cam", 600_000).is_some());
        assert_eq!(dec.0.load(Ordering::SeqCst), 1, "o segundo veio do disco");
        assert!(s.get("cam", 10_000_000).is_none());
        assert!(s.get("cam", 10_000_000).is_none());

        let thumbs = d.path().join("cache");
        std::fs::create_dir_all(thumbs.join("cam/thumbs/1969-12-31")).unwrap();
        assert_eq!(prune_cache_older_than(&thumbs, 1), 1);
        assert!(thumbs.join("cam/thumbs/1970-01-01").exists());
    }
}

#[cfg(test)]
pub(crate) mod tests_support {
    use super::*;

    /// Nunca decodifica: para quem só quer o caminho do percurso.
    pub struct NoDecode;
    impl FrameGrabber for NoDecode {
        fn decode(&self, _: &Keyframe, _: i32, _: i32) -> Option<RgbImage> {
            None
        }
    }
}
