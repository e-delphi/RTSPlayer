//! O ao vivo em memória: um anel de samples por câmera, com teto de tempo e de
//! bytes. A sessão da câmera publica; quem consome (o servidor RTSP, o
//! `/api/live` do servidor e do app) assina com um cursor e busca o que veio.
//!
//! Guardar alguns segundos dá ao cliente que chega um keyframe recente (senão a
//! tela fica preta até o próximo) e absorve um cliente lento sem segurar a
//! câmera: quem fica para trás é reposicionado no keyframe mais recente.
//!
//! O anel data por relógio monotônico (não anda para trás com acerto de hora);
//! para fora, a hora de parede sai de [`LiveStream::wall_of`], na mesma base
//! que o gravador escreve.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::clock::Clock;
use crate::log::SharedLogger;
use crate::media::{flags, AudioCodec, AudioTrackInfo, Sample, TrackKind, VideoCodec, VideoTrackInfo};
use crate::sink::MediaSink;
use crate::vms::format::{encode_block, encode_header, Block, Header, SampleEntry, FORMAT_VERSION};

pub const DEFAULT_BUFFER_MS: i64 = 4000;
pub const DEFAULT_MAX_BYTES: usize = 32 * 1024 * 1024;
const CAPACITY: usize = 8192;
const VIDEO_TIMESCALE: u32 = 90_000;

#[derive(Debug, Clone, Copy)]
pub struct LiveConfig {
    pub enabled: bool,
    pub buffer_ms: i64,
    pub max_bytes: usize,
}

impl Default for LiveConfig {
    fn default() -> Self {
        Self { enabled: true, buffer_ms: DEFAULT_BUFFER_MS, max_bytes: DEFAULT_MAX_BYTES }
    }
}

impl LiveConfig {
    pub fn describe(&self) -> String {
        if !self.enabled {
            return "desligado (ao vivo lido do arquivo)".into();
        }
        format!("buffer {} ms, teto {:.0} MB", self.buffer_ms, self.max_bytes as f64 / (1024.0 * 1024.0))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveSample {
    /// 0 = vídeo, 1 = áudio (a numeração do `.vms`).
    pub track_id: u8,
    pub pts: i64,
    pub keyframe: bool,
    /// Chegada, no relógio monotônico.
    pub mono_ms: i64,
    pub data: Arc<Vec<u8>>,
}

/// Posição de um cliente no anel. Fica com quem consome: o anel não guarda
/// lista de assinantes, então cliente que morre não deixa rastro.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LiveCursor {
    pub next_seq: i64,
    pub epoch: u32,
    pub wait_keyframe: bool,
    pub valid: bool,
}

impl LiveCursor {
    /// `L<seq>-<epoch>-<espera>`: a marca que separa o cursor do anel do de
    /// arquivo. O cliente devolve o que recebeu sem olhar.
    pub fn to_text(&self) -> String {
        format!("L{}-{}-{}", self.next_seq, self.epoch, self.wait_keyframe as u8)
    }
    pub fn parse(s: &str) -> Option<Self> {
        let rest = s.trim().strip_prefix('L').or_else(|| s.trim().strip_prefix('l'))?;
        let p: Vec<&str> = rest.split('-').collect();
        if p.len() != 3 {
            return None;
        }
        Some(Self { next_seq: p[0].parse().ok()?, epoch: p[1].parse().ok()?, wait_keyframe: p[2] != "0", valid: true })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fetch {
    /// Nada novo no prazo.
    None,
    Samples(Vec<LiveSample>),
    /// O cliente ficou para trás e foi reposicionado.
    Resync(Vec<LiveSample>),
    /// A câmera voltou com outro codec: o formato entregue caducou.
    FormatChanged,
}

struct Ring {
    items: Vec<Option<LiveSample>>,
    first: i64,
    next: i64,
    bytes: usize,
    epoch: u32,
    video: Option<VideoTrackInfo>,
    audio: Option<AudioTrackInfo>,
    last_sample_ms: i64,
}

pub struct LiveStream {
    name: String,
    log: SharedLogger,
    clock: Arc<dyn Clock>,
    buffer_ms: i64,
    max_bytes: usize,
    ring: Mutex<Ring>,
    cv: Condvar,
}

impl LiveStream {
    pub fn new(name: &str, buffer_ms: i64, max_bytes: usize, log: SharedLogger, clock: Arc<dyn Clock>) -> Self {
        Self {
            name: name.into(),
            log,
            clock,
            buffer_ms: if buffer_ms <= 0 { DEFAULT_BUFFER_MS } else { buffer_ms },
            max_bytes: if max_bytes == 0 { DEFAULT_MAX_BYTES } else { max_bytes },
            ring: Mutex::new(Ring { items: vec![None; CAPACITY], first: 0, next: 0, bytes: 0, epoch: 1, video: None, audio: None, last_sample_ms: 0 }),
            cv: Condvar::new(),
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Ring> {
        self.ring.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn slot(seq: i64) -> usize {
        (seq.rem_euclid(CAPACITY as i64)) as usize
    }

    fn drop_oldest(r: &mut Ring) {
        if r.first >= r.next {
            return;
        }
        if let Some(it) = r.items[Self::slot(r.first)].take() {
            r.bytes -= it.data.len();
        }
        r.first += 1;
    }

    fn clear(r: &mut Ring) {
        while r.first < r.next {
            Self::drop_oldest(r);
        }
        r.bytes = 0;
    }

    fn trim(&self, r: &mut Ring) {
        if r.next <= r.first {
            return;
        }
        let newest = r.items[Self::slot(r.next - 1)].as_ref().map(|i| i.mono_ms).unwrap_or(0);
        while r.first < r.next {
            let oldest = r.items[Self::slot(r.first)].as_ref().map(|i| i.mono_ms).unwrap_or(newest);
            if (r.next - r.first) as usize > CAPACITY || r.bytes > self.max_bytes || newest - oldest > self.buffer_ms {
                Self::drop_oldest(r);
            } else {
                break;
            }
        }
    }

    pub fn publish_video_format(&self, codec: VideoCodec, w: u16, h: u16, extradata: &[u8]) {
        let mut r = self.lock();
        // Só é troca quando muda codec ou resolução: reconexão da mesma câmera
        // reanuncia os mesmos valores, e derrubar quem assiste seria gratuito.
        let changed = r.video.as_ref().is_none_or(|v| v.codec != codec || v.width != w || v.height != h);
        r.video = Some(VideoTrackInfo { codec, timescale: VIDEO_TIMESCALE, width: w, height: h, extradata: extradata.to_vec() });
        if changed {
            r.epoch += 1;
            Self::clear(&mut r);
            self.log.info(&format!("live.{}", self.name), &format!("formato de video: {codec} {w}x{h}"));
        }
        self.cv.notify_all();
    }

    pub fn publish_audio_format(&self, codec: AudioCodec, rate: u32, ch: u8, extradata: &[u8]) {
        let mut r = self.lock();
        let changed = r.audio.as_ref().is_none_or(|a| a.codec != codec || a.sample_rate != rate);
        r.audio = Some(AudioTrackInfo { codec, timescale: rate, sample_rate: rate, channels: ch, bits_per_sample: 16, extradata: extradata.to_vec() });
        if changed {
            r.epoch += 1;
            Self::clear(&mut r);
            self.log.info(&format!("live.{}", self.name), &format!("formato de audio: {codec} {rate}Hz {ch}ch"));
        }
        self.cv.notify_all();
    }

    pub fn publish(&self, s: &Sample) {
        if s.data.is_empty() {
            return;
        }
        let now = self.clock.monotonic_ms();
        let mut r = self.lock();
        if (r.next - r.first) as usize >= CAPACITY {
            Self::drop_oldest(&mut r);
        }
        let slot = Self::slot(r.next);
        r.items[slot] = Some(LiveSample { track_id: s.track_id, pts: s.pts, keyframe: s.is_keyframe(), mono_ms: now, data: Arc::new(s.data.clone()) });
        r.bytes += s.data.len();
        r.next += 1;
        r.last_sample_ms = now;
        self.trim(&mut r);
        self.cv.notify_all();
    }

    /// A câmera caiu: os formatos ficam, a mídia velha sai.
    pub fn notify_stopped(&self) {
        let mut r = self.lock();
        Self::clear(&mut r);
        self.cv.notify_all();
    }

    /// O header com os formatos correntes. `None` = ainda sem vídeo.
    pub fn header(&self) -> Option<Header> {
        let r = self.lock();
        let v = r.video.clone().filter(|v| v.codec != VideoCodec::None)?;
        let mut h = Header { version: FORMAT_VERSION, creation_unix_ms: self.clock.now_utc_ms(), video_present: true, video: v, ..Default::default() };
        if let Some(a) = r.audio.clone().filter(|a| a.codec != AudioCodec::None) {
            h.audio_present = true;
            h.audio = a;
        }
        Some(h)
    }

    /// O instante de parede de um carimbo monotônico do anel.
    pub fn wall_of(&self, mono_ms: i64) -> i64 {
        self.clock.now_utc_ms() - (self.clock.monotonic_ms() - mono_ms)
    }

    /// Entregou mídia há pouco? (Os formatos ficam depois que a câmera cai.)
    pub fn is_publishing(&self, within_ms: i64) -> bool {
        let r = self.lock();
        r.last_sample_ms > 0 && self.clock.monotonic_ms() - r.last_sample_ms <= within_ms
    }

    fn last_keyframe(r: &Ring) -> Option<i64> {
        (r.first..r.next).rev().find(|&s| r.items[Self::slot(s)].as_ref().is_some_and(|i| i.track_id == 0 && i.keyframe))
    }

    /// Os samples de vídeo do keyframe mais recente em diante.
    pub fn recent_video(&self, max: usize) -> Vec<Arc<Vec<u8>>> {
        let r = self.lock();
        let from = Self::last_keyframe(&r).unwrap_or(r.first);
        (from..r.next).filter_map(|s| r.items[Self::slot(s)].as_ref()).filter(|i| i.track_id == 0).take(max).map(|i| i.data.clone()).collect()
    }

    fn position(r: &Ring, c: &mut LiveCursor) {
        c.epoch = r.epoch;
        c.valid = true;
        match Self::last_keyframe(r) {
            Some(k) => {
                c.next_seq = k;
                c.wait_keyframe = false;
            }
            None => {
                // Sem keyframe guardado: segura o vídeo até vir um.
                c.next_seq = r.next;
                c.wait_keyframe = r.video.is_some();
            }
        }
    }

    /// No keyframe mais recente. `None` = câmera sem formato nesta execução.
    pub fn subscribe(&self) -> Option<LiveCursor> {
        let r = self.lock();
        if r.video.is_none() && r.audio.is_none() {
            return None;
        }
        let mut c = LiveCursor::default();
        Self::position(&r, &mut c);
        Some(c)
    }

    pub fn fetch(&self, c: &mut LiveCursor, timeout_ms: u64) -> Fetch {
        if !c.valid {
            return Fetch::None;
        }
        let mut r = self.lock();
        if c.epoch != r.epoch {
            return Fetch::FormatChanged;
        }
        if c.next_seq >= r.next {
            let (g, _) = self.cv.wait_timeout_while(r, Duration::from_millis(timeout_ms), |r| r.epoch == c.epoch && c.next_seq >= r.next).unwrap_or_else(|p| p.into_inner());
            r = g;
            if c.epoch != r.epoch {
                return Fetch::FormatChanged;
            }
            if c.next_seq >= r.next {
                return Fetch::None;
            }
        }
        let resynced = c.next_seq < r.first;
        if resynced {
            Self::position(&r, c);
        }
        let mut out = Vec::new();
        for s in c.next_seq..r.next {
            let Some(it) = r.items[Self::slot(s)].as_ref() else { continue };
            if c.wait_keyframe && it.track_id == 0 {
                if it.keyframe {
                    c.wait_keyframe = false;
                } else {
                    continue;
                }
            }
            out.push(it.clone());
        }
        c.next_seq = r.next;
        if resynced {
            Fetch::Resync(out)
        } else {
            Fetch::Samples(out)
        }
    }
}

/// Um anel por câmera.
pub struct LiveHub {
    pub config: LiveConfig,
    log: SharedLogger,
    clock: Arc<dyn Clock>,
    streams: Mutex<HashMap<String, Arc<LiveStream>>>,
}

impl LiveHub {
    pub fn new(config: LiveConfig, log: SharedLogger, clock: Arc<dyn Clock>) -> Self {
        Self { config, log, clock, streams: Mutex::new(HashMap::new()) }
    }

    pub fn get_or_create(&self, camera: &str) -> Arc<LiveStream> {
        let k = camera.trim().to_lowercase();
        self.streams
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .entry(k)
            .or_insert_with(|| Arc::new(LiveStream::new(camera, self.config.buffer_ms, self.config.max_bytes, self.log.clone(), self.clock.clone())))
            .clone()
    }

    pub fn find(&self, camera: &str) -> Option<Arc<LiveStream>> {
        self.streams.lock().unwrap_or_else(|p| p.into_inner()).get(&camera.trim().to_lowercase()).cloned()
    }
}

/// Publica no anel o que a sessão entrega.
pub struct LiveSink {
    pub stream: Arc<LiveStream>,
    pub publish_audio: bool,
}

impl MediaSink for LiveSink {
    fn on_video_format(&self, c: VideoCodec, w: u16, h: u16, e: &[u8]) {
        self.stream.publish_video_format(c, w, h, e);
    }
    fn on_audio_format(&self, c: AudioCodec, r: u32, ch: u8, e: &[u8]) {
        if self.publish_audio {
            self.stream.publish_audio_format(c, r, ch, e);
        }
    }
    fn on_sample(&self, s: &Sample) {
        if self.publish_audio || s.kind != TrackKind::Audio {
            self.stream.publish(s);
        }
    }
    fn on_stream_stopped(&self) {
        self.stream.notify_stopped();
    }
}

/// Quanto o pedido do ao vivo espera por sample novo antes de responder "nada
/// ainda": troca uma pergunta a cada meio segundo por uma entrega na hora.
pub const LIVE_WAIT_MS: u64 = 1500;
pub const LIVE_MAX_SAMPLES: usize = 600;

/// A resposta do `/api/live`: um `.vms` com o header e UM bloco com o que veio,
/// e os cabeçalhos `X-Vms-*` que o player usa para continuar.
pub struct LiveFragment {
    pub status: u16,
    pub body: Vec<u8>,
    pub headers: Vec<(String, String)>,
}

pub fn live_fragment(stream: Option<&LiveStream>, cursor_text: &str, wait_ms: u64) -> LiveFragment {
    let sem_ao_vivo = || LiveFragment { status: 204, body: Vec::new(), headers: vec![("X-Vms-Live".into(), "0".into())] };
    let Some(st) = stream.filter(|s| s.is_publishing(10_000)) else { return sem_ao_vivo() };
    let nada = |c: &LiveCursor| LiveFragment {
        status: 204,
        body: Vec::new(),
        headers: vec![("X-Vms-Cursor".into(), c.to_text()), ("X-Vms-Growing".into(), "1".into())],
    };
    let mut desc = false;
    // Cursor de arquivo aqui é cliente que estava no plano B e a câmera voltou:
    // assina de novo, com a marca de descontinuidade.
    let mut c = match LiveCursor::parse(cursor_text) {
        Some(c) => c,
        None => {
            desc = true;
            match st.subscribe() {
                Some(c) => c,
                None => return nada(&LiveCursor::default()),
            }
        }
    };
    let items = match st.fetch(&mut c, wait_ms) {
        Fetch::Samples(v) => v,
        Fetch::Resync(v) => {
            desc = true;
            v
        }
        Fetch::FormatChanged => {
            // Reassina já: o cursor velho não serve mais para nada.
            desc = true;
            match st.subscribe() {
                Some(nc) => c = nc,
                None => return nada(&c),
            }
            match st.fetch(&mut c, 0) {
                Fetch::Samples(v) | Fetch::Resync(v) => v,
                _ => return nada(&c),
            }
        }
        Fetch::None => return nada(&c),
    };
    let items: Vec<_> = items.into_iter().take(LIVE_MAX_SAMPLES).collect();
    if items.is_empty() {
        return nada(&c);
    }
    let Some(header) = st.header() else { return nada(&c) };
    let mut blk = Block::default();
    for it in &items {
        blk.samples.push(SampleEntry {
            track_id: it.track_id,
            flags: if it.keyframe { flags::KEYFRAME } else { 0 },
            pts: it.pts,
            payload_offset: blk.payload.len() as u32,
            payload_size: it.data.len() as u32,
        });
        blk.payload.extend_from_slice(&it.data);
        if it.track_id == 0 && blk.video_anchor_ms == 0 {
            blk.video_anchor_ms = st.wall_of(it.mono_ms);
        }
        if it.track_id == 1 && blk.audio_anchor_ms == 0 {
            blk.audio_anchor_ms = st.wall_of(it.mono_ms);
        }
    }
    blk.seq = (c.next_seq - items.len() as i64).max(0) as u32;
    blk.start_unix_ms = if blk.video_anchor_ms != 0 { blk.video_anchor_ms } else { blk.audio_anchor_ms };
    let mut body = encode_header(&header);
    body.extend(encode_block(&blk));
    let h = |k: &str, v: String| (k.to_owned(), v);
    LiveFragment {
        status: 200,
        body,
        headers: vec![
            h("X-Vms-Cursor", c.to_text()),
            h("X-Vms-Block-Count", "1".into()),
            h("X-Vms-Start-Ms", blk.start_unix_ms.to_string()),
            h("X-Vms-End-Ms", blk.start_unix_ms.to_string()),
            h("X-Vms-Next-Ms", "-1".into()),
            h("X-Vms-Gap-Ms", "0".into()),
            h("X-Vms-Discontinuity", (desc as u8).to_string()),
            h("X-Vms-Keyframe", (items[0].keyframe as u8).to_string()),
            h("X-Vms-Growing", "1".into()),
            h("X-Vms-Thinned", "0".into()),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use crate::vms::VmsReader;

    fn stream(clock: Arc<ManualClock>) -> LiveStream {
        LiveStream::new("cam", 1000, 1 << 20, crate::log::null(), clock)
    }

    #[test]
    fn assinante_entra_no_keyframe_e_recebe_o_resto() {
        let clock = Arc::new(ManualClock::new(5_000_000));
        let s = stream(clock.clone());
        s.publish_video_format(VideoCodec::H264, 0, 0, &[]);
        s.publish(&Sample::video(0, false, vec![1]));
        s.publish(&Sample::video(1, true, vec![2]));
        s.publish(&Sample::video(2, false, vec![3]));
        let mut c = s.subscribe().unwrap();
        let Fetch::Samples(v) = s.fetch(&mut c, 0) else { panic!() };
        assert_eq!(v.iter().map(|x| x.pts).collect::<Vec<_>>(), vec![1, 2]);
        assert_eq!(s.fetch(&mut c, 10), Fetch::None);
        s.publish(&Sample::audio(9, vec![4]));
        assert!(matches!(s.fetch(&mut c, 0), Fetch::Samples(v) if v.len() == 1));
    }

    #[test]
    fn sem_keyframe_segura_o_video_e_teto_de_tempo_descarta() {
        let clock = Arc::new(ManualClock::new(1));
        let s = stream(clock.clone());
        s.publish_video_format(VideoCodec::H264, 0, 0, &[]);
        let mut c = s.subscribe().unwrap();
        assert!(c.wait_keyframe);
        s.publish(&Sample::video(0, false, vec![1]));
        s.publish(&Sample::video(1, true, vec![2]));
        let Fetch::Samples(v) = s.fetch(&mut c, 0) else { panic!() };
        assert_eq!(v.len(), 1);
        assert!(v[0].keyframe);
        // O cliente para de ler; o anel anda além do teto de 1 s.
        for k in 0..30 {
            clock.advance(100);
            s.publish(&Sample::video(10 + k, k % 10 == 0, vec![0; 10]));
        }
        assert!(matches!(s.fetch(&mut c, 0), Fetch::Resync(v) if v[0].keyframe));
    }

    #[test]
    fn troca_de_formato_avisa_e_cursor_ida_e_volta() {
        let clock = Arc::new(ManualClock::new(1));
        let s = stream(clock.clone());
        s.publish_video_format(VideoCodec::H264, 640, 480, &[]);
        let mut c = s.subscribe().unwrap();
        s.publish_video_format(VideoCodec::H264, 640, 480, &[1]);
        assert_eq!(s.fetch(&mut c, 0), Fetch::None, "mesmo formato não derruba");
        s.publish_video_format(VideoCodec::H265, 640, 480, &[]);
        assert_eq!(s.fetch(&mut c, 0), Fetch::FormatChanged);
        let t = c.to_text();
        assert_eq!(LiveCursor::parse(&t), Some(c));
        assert!(LiveCursor::parse("123:abc").is_none());
    }

    #[test]
    fn fragmento_do_api_live_e_um_vms_valido() {
        let clock = Arc::new(ManualClock::new(1_786_846_215_000));
        let s = stream(clock.clone());
        assert_eq!(live_fragment(Some(&s), "", 0).status, 204);
        s.publish_video_format(VideoCodec::H264, 0, 0, &[]);
        s.publish(&Sample::video(0, true, vec![0, 0, 0, 1, 0x65]));
        clock.advance(40);
        s.publish(&Sample::video(3600, false, vec![0, 0, 0, 1, 0x41]));
        let f = live_fragment(Some(&s), "", 0);
        assert_eq!(f.status, 200);
        let get = |k: &str| f.headers.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()).unwrap();
        assert_eq!(get("X-Vms-Discontinuity"), "1");
        assert_eq!(get("X-Vms-Keyframe"), "1");
        let cur = get("X-Vms-Cursor");
        let mut r = VmsReader::from_bytes(f.body.clone());
        assert!(r.read_header());
        let b = r.read_next_block().unwrap();
        assert_eq!(b.samples.len(), 2);
        assert_eq!(b.start_unix_ms, 1_786_846_215_000);
        let f2 = live_fragment(Some(&s), &cur, 0);
        assert_eq!(f2.status, 204, "nada novo");
        assert!(f2.headers.iter().any(|(n, _)| n == "X-Vms-Cursor"));
    }
}
