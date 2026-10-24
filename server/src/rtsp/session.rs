//! Uma conexão RTSP de um player: DESCRIBE/SETUP/PLAY sobre `/live/<câmera>`
//! (do anel em memória enquanto a câmera publica; senão da cauda do `.vms`
//! mais recente) ou sobre um arquivo (`<nome>.vms`, tocado no ritmo dos PTS).
//!
//! Só TCP interleaved: SETUP em UDP leva 461 e o player tenta TCP (o caminho
//! da tailnet não passa UDP de volta de forma confiável).

use std::io::Write;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use vms_core::clock::Clock;
use vms_core::live::{Fetch, LiveCursor, LiveHub, LiveStream};
use vms_core::log::{Level, SharedLogger};
use vms_core::net::TcpConn;
use vms_core::rtsp::message::{Request, Response};
use vms_core::rtsp::wire::{as_request, WireEvent, WireReader};
use vms_core::vms::reader::find_most_recent_vms_for_camera;
use vms_core::vms::{Header, VmsReader};

use super::packetizer::{self, Packetizer};
use super::sdp::{build_sdp, parameter_sets_complete, parameter_sets_of};

const PACE_MAX_WAIT_MS: i64 = 1000;
const PACE_MAX_LAG_MS: i64 = 2000;
const LIVE_READ_WAIT_MS: u64 = 2000;
const LIVE_FETCH_WAIT_MS: u64 = 200;
const LIVE_STALL_MS: i64 = 5000;

const ST_INIT: u8 = 0;
const ST_DESCRIBED: u8 = 1;
const ST_SETUP: u8 = 2;
const ST_PLAYING: u8 = 3;
const ST_PAUSED: u8 = 4;

#[derive(Default)]
struct Track {
    active: bool,
    codec: u8,
    timescale: u32,
    channel: u8,
    pkt: Option<Box<dyn Packetizer>>,
    first_pts: Option<i64>,
    anchor_wall: i64,
}

/// O que o pacer usa; a thread de pedidos só mexe nisso no SETUP/PLAY.
#[derive(Default)]
struct Media {
    live: Option<Arc<LiveStream>>,
    cursor: Option<LiveCursor>,
    reader: Option<VmsReader>,
    vms_file: PathBuf,
    live_mode: bool,
    camera: String,
    header: Header,
    media_start_ms: i64,
    video: Track,
    audio: Track,
    anchor_wall: i64,
    last_block_mono: i64,
    rejected: PathBuf,
}

pub struct Shared {
    pub storage: PathBuf,
    pub hub: Option<Arc<LiveHub>>,
    pub log: SharedLogger,
    pub clock: Arc<dyn Clock>,
}

struct Session {
    sh: Arc<Shared>,
    out: Arc<Mutex<TcpStream>>,
    stop: Arc<AtomicBool>,
    state: Arc<AtomicU8>,
    media: Arc<Mutex<Media>>,
    id: String,
    pacer: Option<std::thread::JoinHandle<()>>,
}

fn rand_u32() -> u32 {
    let mut b = [0u8; 4];
    let _ = getrandom::getrandom(&mut b);
    u32::from_le_bytes(b)
}

fn tag_of(cam: &str) -> String {
    if cam.is_empty() {
        "tx.session".into()
    } else {
        format!("tx.session.{cam}")
    }
}

/// O caminho da rota sem esquema, host, `/trackID=` e query.
pub fn parse_route(uri: &str) -> (String, bool, String) {
    let mut p = match uri.find("://") {
        Some(i) => uri[i + 3..].find('/').map(|j| &uri[i + 3 + j..]).unwrap_or("/"),
        None => uri,
    }
    .trim_start_matches('/')
    .to_owned();
    if let Some(i) = p.find("/trackID=") {
        p.truncate(i);
    }
    if let Some(i) = p.find('?') {
        p.truncate(i);
    }
    let live = p.len() >= 5 && p[..5].eq_ignore_ascii_case("live/");
    let cam = if live { vms_core::http::url_decode(&p[5..]) } else { String::new() };
    (p, live, cam)
}

/// `Transport:` do SETUP → (é TCP?, canal RTP, canal RTCP).
pub fn parse_transport(h: &str) -> Option<(bool, u8, u8)> {
    let (mut ok, mut tcp, mut rtp, mut rtcp) = (false, false, 0u8, 1u8);
    for t in h.split(';').map(str::trim) {
        if t.eq_ignore_ascii_case("RTP/AVP/TCP") {
            ok = true;
            tcp = true;
        } else if t.eq_ignore_ascii_case("RTP/AVP") || t.eq_ignore_ascii_case("RTP/AVP/UDP") {
            ok = true;
        } else if let Some(v) = t.strip_prefix("interleaved=") {
            let mut it = v.split('-');
            rtp = it.next().and_then(|x| x.trim().parse().ok()).unwrap_or(0);
            rtcp = it.next().and_then(|x| x.trim().parse().ok()).unwrap_or(rtp.wrapping_add(1));
            tcp = true;
        }
    }
    ok.then_some((tcp, rtp, rtcp))
}

/// `Range: npt=12.5-` → 12.5
pub fn parse_range_start(h: &str) -> Option<f64> {
    let l = h.to_ascii_lowercase();
    let i = l.find("npt=")?;
    let s = l[i + 4..].split('-').next()?.trim();
    if s.is_empty() || s == "now" {
        return None;
    }
    s.parse().ok()
}

impl Media {
    fn log(&self, sh: &Shared, l: Level, m: &str) {
        sh.log.log(l, &tag_of(&self.camera), m);
    }

    fn open_reader(&mut self, sh: &Shared, path: &Path) -> bool {
        let Ok(mut r) = VmsReader::open(path) else { return false };
        r.set_logger(sh.log.clone());
        if !r.read_header() {
            return false;
        }
        self.vms_file = path.to_path_buf();
        if self.live_mode {
            r.enable_live_mode(LIVE_READ_WAIT_MS);
            if r.seek_to_last_keyframe() {
                self.log(sh, Level::Info, "live: comecando no keyframe mais recente");
            } else {
                self.log(sh, Level::Warn, "live: nenhum keyframe no arquivo; comecando do inicio");
                r.seek_to_start();
            }
        } else {
            r.build_index();
            r.seek_to_start();
        }
        self.reader = Some(r);
        true
    }

    /// O SDP deve levar os parameter sets que o fluxo usa de verdade: câmera
    /// que troca SPS no meio deixa o do header velho.
    fn prefer_inband_parameter_sets(&mut self) {
        let codec = self.header.video.codec;
        if !self.header.video_present || !matches!(codec, vms_core::media::VideoCodec::H264 | vms_core::media::VideoCodec::H265) {
            return;
        }
        let mut samples: Vec<Vec<u8>> = Vec::new();
        if let Some(l) = &self.live {
            samples = l.recent_video(24).into_iter().map(|a| a.to_vec()).collect();
        } else if let Ok(mut r) = VmsReader::open(&self.vms_file) {
            if r.read_header() && (r.seek_to_last_keyframe() || r.seek_to_start()) {
                while samples.len() < 24 {
                    let Some(b) = r.read_next_block() else { break };
                    for s in b.samples.iter().filter(|s| s.track_id == 0) {
                        if samples.len() < 24 {
                            samples.push(b.sample_data(s).unwrap_or(&[]).to_vec());
                        }
                    }
                }
            }
        }
        let mut found = Vec::new();
        for s in &samples {
            found.extend(parameter_sets_of(s, codec));
            if parameter_sets_complete(&found, codec) {
                self.header.video.extradata = found;
                return;
            }
        }
    }

    fn live_header_matches(&self, h: &Header) -> bool {
        if self.video.active && (!h.video_present || h.video.codec as u8 != self.video.codec || h.video.width != self.header.video.width || h.video.height != self.header.video.height) {
            return false;
        }
        if self.audio.active && (!h.audio_present || h.audio.codec as u8 != self.audio.codec || h.audio.timescale != self.audio.timescale) {
            return false;
        }
        true
    }

    /// O gravador trocou de arquivo (rotação, reconexão): segue no novo, se
    /// tiver os mesmos codecs.
    fn switch_to_newer_live_file(&mut self, sh: &Shared) -> bool {
        if !self.live_mode || self.camera.is_empty() {
            return false;
        }
        let closed = self.reader.as_ref().map(|r| r.at_closed_end()).unwrap_or(true);
        if !closed && sh.clock.monotonic_ms() - self.last_block_mono < LIVE_STALL_MS {
            return false;
        }
        let Some(p) = find_most_recent_vms_for_camera(&sh.storage, &self.camera) else { return false };
        if p == self.vms_file || p == self.rejected {
            return false;
        }
        let Ok(mut probe) = VmsReader::open(&p) else { return false };
        if !probe.read_header() {
            return false;
        }
        let h = probe.header().clone();
        drop(probe);
        if (self.video.active && h.video.codec as u8 != self.video.codec) || (self.audio.active && h.audio.codec as u8 != self.audio.codec) {
            self.rejected = p;
            self.log(sh, Level::Warn, "arquivo novo tem outro codec; nao vou trocar no meio da sessao");
            return false;
        }
        if !self.open_reader(sh, &p) {
            return false;
        }
        self.video.first_pts = None;
        self.audio.first_pts = None;
        self.anchor_wall = sh.clock.monotonic_ms();
        self.last_block_mono = self.anchor_wall;
        self.log(sh, Level::Info, &format!("gravacao trocou de arquivo; seguindo em {}", p.file_name().unwrap_or_default().to_string_lossy()));
        true
    }
}

fn send_interleaved(out: &Mutex<TcpStream>, ch: u8, rtp: &[u8], stop: &AtomicBool) {
    if rtp.len() > 0xFFFF {
        return;
    }
    let mut f = Vec::with_capacity(4 + rtp.len());
    f.extend_from_slice(&[b'$', ch, (rtp.len() >> 8) as u8, rtp.len() as u8]);
    f.extend_from_slice(rtp);
    let mut s = out.lock().unwrap_or_else(|p| p.into_inner());
    if s.write_all(&f).is_err() {
        stop.store(true, Ordering::SeqCst);
    }
}

/// Espera em fatias, para o TEARDOWN não esperar o ritmo inteiro.
fn nap(ms: i64, stop: &AtomicBool) {
    let mut left = ms;
    while left > 0 && !stop.load(Ordering::SeqCst) {
        let n = left.min(50);
        std::thread::sleep(Duration::from_millis(n as u64));
        left -= n;
    }
}

fn pace_once(m: &mut Media, sh: &Shared, out: &Mutex<TcpStream>, stop: &AtomicBool) {
    if let Some(live) = m.live.clone() {
        if m.cursor.is_none() {
            m.cursor = live.subscribe();
            if m.cursor.is_none() {
                nap(50, stop);
                return;
            }
        }
        let Some(c) = m.cursor.as_mut() else { return };
        let items = match live.fetch(c, LIVE_FETCH_WAIT_MS) {
            Fetch::None => return,
            Fetch::FormatChanged => {
                match live.header() {
                    Some(h) if m.live_header_matches(&h) => {
                        m.cursor = live.subscribe();
                        m.log(sh, Level::Info, "camera reanunciou o formato; seguindo ao vivo");
                    }
                    _ => {
                        m.log(sh, Level::Warn, "formato da camera mudou; encerrando para o cliente refazer o DESCRIBE");
                        stop.store(true, Ordering::SeqCst);
                    }
                }
                return;
            }
            Fetch::Resync(v) => {
                m.log(sh, Level::Warn, "reposicionado no keyframe mais recente (cliente atrasado ou camera reconectou)");
                v
            }
            Fetch::Samples(v) => v,
        };
        for it in items {
            if stop.load(Ordering::SeqCst) {
                return;
            }
            let t = if it.track_id == 0 { &mut m.video } else { &mut m.audio };
            if !t.active {
                continue;
            }
            let ch = t.channel;
            if let Some(p) = t.pkt.as_mut() {
                for rtp in p.push(it.pts, &it.data, it.keyframe) {
                    send_interleaved(out, ch, &rtp, stop);
                }
            }
        }
        return;
    }
    let Some(block) = m.reader.as_mut().and_then(|r| r.read_next_block()) else {
        if m.reader.is_none() || !m.live_mode {
            // Arquivo acabou: encerra a sessão (não há loop no servidor).
            if m.reader.is_some() {
                stop.store(true, Ordering::SeqCst);
            }
            nap(50, stop);
            return;
        }
        if !m.switch_to_newer_live_file(sh) {
            nap(50, stop);
        }
        return;
    };
    m.last_block_mono = sh.clock.monotonic_ms();
    let video_active = m.video.active;
    for s in &block.samples {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let anchor = m.anchor_wall;
        let t = match s.track_id {
            0 => &mut m.video,
            1 => &mut m.audio,
            _ => continue,
        };
        if !t.active || t.pkt.is_none() {
            continue;
        }
        if t.first_pts.is_none() {
            t.first_pts = Some(s.pts);
            t.anchor_wall = anchor;
            // O áudio começa deslocado do vídeo o quanto as âncoras dizem.
            if s.track_id == 1 && block.audio_anchor_ms > 0 && block.video_anchor_ms > 0 {
                t.anchor_wall = anchor + (block.audio_anchor_ms - block.video_anchor_ms);
            }
        }
        // Quem dita o ritmo é o vídeo; o áudio só quando é a única trilha.
        if s.track_id == 0 || !video_active {
            let rel = if t.timescale > 0 { (s.pts - t.first_pts.unwrap_or(s.pts)) * 1000 / t.timescale as i64 } else { 0 };
            let now = sh.clock.monotonic_ms();
            let mut wait = t.anchor_wall + rel - now;
            if !(-PACE_MAX_LAG_MS..=PACE_MAX_WAIT_MS).contains(&wait) {
                t.first_pts = Some(s.pts);
                t.anchor_wall = now;
                wait = 0;
            }
            if wait > 0 {
                nap(wait, stop);
            }
        }
        let data = block.sample_data(s).unwrap_or(&[]);
        let ch = t.channel;
        if let Some(p) = t.pkt.as_mut() {
            for rtp in p.push(s.pts, data, s.flags & 1 != 0) {
                send_interleaved(out, ch, &rtp, stop);
            }
        }
    }
}

impl Session {
    fn camera(&self) -> String {
        self.media.lock().unwrap_or_else(|p| p.into_inner()).camera.clone()
    }

    fn send(&self, r: &Response) {
        let mut s = self.out.lock().unwrap_or_else(|p| p.into_inner());
        if s.write_all(&r.serialize()).is_err() {
            self.stop.store(true, Ordering::SeqCst);
        }
    }

    fn reply(&self, req: &Request, status: u16) -> Response {
        let mut r = Response::new(status);
        r.headers.add("CSeq", req.headers.get("CSeq").unwrap_or("0"));
        r
    }

    fn describe(&self, req: &Request) {
        let (route, live_mode, cam) = parse_route(&req.uri);
        let mut m = self.media.lock().unwrap_or_else(|p| p.into_inner());
        m.live_mode = live_mode;
        m.camera = cam.clone();
        m.live = None;
        let mut name = cam.clone();
        if live_mode && !cam.is_empty() {
            if let Some(s) = self.sh.hub.as_ref().and_then(|h| h.find(&cam)) {
                if let Some(h) = s.header() {
                    m.header = h;
                    m.live = Some(s);
                }
            }
        }
        if m.live.is_none() {
            let path = if live_mode {
                find_most_recent_vms_for_camera(&self.sh.storage, &cam)
            } else {
                let mut base = route.clone();
                if !base.to_ascii_lowercase().ends_with(".vms") {
                    base.push_str(".vms");
                }
                vms_core::vms::paths::is_safe_vms_name(&base).then(|| {
                    let root = self.sh.storage.join(&base);
                    let by_cam = base.find('_').map(|p| vms_core::vms::paths::camera_dir(&self.sh.storage, &base[..p]).join(&base));
                    match by_cam {
                        Some(p) if p.is_file() => p,
                        _ => root,
                    }
                })
            };
            let Some(path) = path.filter(|p| p.is_file()) else {
                m.log(&self.sh, Level::Warn, &format!("DESCRIBE sem arquivo para {}", req.uri));
                drop(m);
                self.send(&self.reply(req, 404));
                return;
            };
            if !m.open_reader(&self.sh, &path) {
                m.log(&self.sh, Level::Error, &format!("nao consegui abrir {}", path.display()));
                drop(m);
                self.send(&self.reply(req, 500));
                return;
            }
            let r = m.reader.as_mut().expect("aberto");
            let (h, start) = (r.header().clone(), r.last_keyframe_ms());
            m.header = h;
            m.media_start_ms = start;
            name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
            if live_mode {
                m.log(&self.sh, Level::Info, "ao vivo pelo arquivo (camera sem publicacao na memoria)");
            }
        } else {
            m.log(&self.sh, Level::Info, "ao vivo pela memoria");
        }
        m.prefer_inband_parameter_sets();
        let sdp = build_sdp(&m.header, &name, m.live.is_some(), m.media_start_ms);
        drop(m);
        let mut r = self.reply(req, 200);
        r.headers.add("Content-Type", "application/sdp");
        r.headers.add("Content-Base", &format!("{}/", req.uri.trim_end_matches('/')));
        r.body = sdp.into_bytes();
        self.send(&r);
        self.state.store(ST_DESCRIBED, Ordering::SeqCst);
    }

    fn setup(&self, req: &Request) {
        if self.state.load(Ordering::SeqCst) == ST_INIT {
            self.send(&self.reply(req, 455));
            return;
        }
        let low = req.uri.to_ascii_lowercase();
        let is_audio = low.contains("trackid=1") || low.contains("/track2");
        let Some((tcp, rtp, rtcp)) = parse_transport(req.headers.get("Transport").unwrap_or("")) else {
            self.send(&self.reply(req, 461));
            return;
        };
        if !tcp {
            self.sh.log.info(&tag_of(&self.camera()), "SETUP em UDP recusado (461); o cliente deve tentar TCP interleaved");
            self.send(&self.reply(req, 461));
            return;
        }
        let mut m = self.media.lock().unwrap_or_else(|p| p.into_inner());
        let h = m.header.clone();
        let (present, track) = if is_audio { (h.audio_present, &mut m.audio) } else { (h.video_present, &mut m.video) };
        if !present {
            drop(m);
            self.send(&self.reply(req, 404));
            return;
        }
        track.active = true;
        track.channel = rtp;
        track.first_pts = None;
        if is_audio {
            track.codec = h.audio.codec as u8;
            track.timescale = h.audio.timescale;
            track.pkt = packetizer::for_audio(h.audio.codec, rand_u32() & 0x7FFF_FFFF, rand_u32() as u16);
        } else {
            track.codec = h.video.codec as u8;
            track.timescale = h.video.timescale;
            track.pkt = packetizer::for_video(h.video.codec, rand_u32() & 0x7FFF_FFFF, rand_u32() as u16);
        }
        drop(m);
        let mut r = self.reply(req, 200);
        r.headers.add("Session", &format!("{};timeout=60", self.id));
        r.headers.add("Transport", &format!("RTP/AVP/TCP;unicast;interleaved={rtp}-{rtcp}"));
        self.send(&r);
        self.state.store(ST_SETUP, Ordering::SeqCst);
    }

    fn play(&mut self, req: &Request) {
        let st = self.state.load(Ordering::SeqCst);
        let mut m = self.media.lock().unwrap_or_else(|p| p.into_inner());
        if (m.reader.is_none() && m.live.is_none()) || (st != ST_SETUP && st != ST_PAUSED) {
            drop(m);
            self.send(&self.reply(req, 455));
            return;
        }
        if let Some(l) = m.live.clone() {
            m.cursor = l.subscribe();
            if m.cursor.is_none() {
                m.log(&self.sh, Level::Warn, "camera parou de publicar; aguardando ela voltar");
            }
        }
        if !m.live_mode {
            if let Some(start) = req.headers.get("Range").and_then(parse_range_start) {
                if let Some(r) = m.reader.as_mut() {
                    if let Some(first) = r.index().first().map(|e| e.start_unix_ms) {
                        r.seek_to_time(first + (start * 1000.0) as i64);
                    }
                }
                m.video.first_pts = None;
                m.audio.first_pts = None;
            }
        }
        m.anchor_wall = self.sh.clock.monotonic_ms();
        m.last_block_mono = m.anchor_wall;
        let mut info = Vec::new();
        let base = format!("{}/", req.uri.trim_end_matches('/'));
        if m.video.active {
            info.push(format!("url={base}trackID=0;seq=0;rtptime=0"));
        }
        if m.audio.active {
            info.push(format!("url={base}trackID=1;seq=0;rtptime=0"));
        }
        drop(m);
        let mut r = self.reply(req, 200);
        r.headers.add("Session", &self.id);
        if !info.is_empty() {
            r.headers.add("RTP-Info", &info.join(","));
        }
        self.send(&r);
        self.state.store(ST_PLAYING, Ordering::SeqCst);
        if self.pacer.is_none() {
            let (media, sh, out, stop, state) = (self.media.clone(), self.sh.clone(), self.out.clone(), self.stop.clone(), self.state.clone());
            self.pacer = std::thread::Builder::new()
                .name("tx-pacer".into())
                .spawn(move || {
                    while !stop.load(Ordering::SeqCst) {
                        if state.load(Ordering::SeqCst) != ST_PLAYING {
                            nap(50, &stop);
                            continue;
                        }
                        let mut m = media.lock().unwrap_or_else(|p| p.into_inner());
                        pace_once(&mut m, &sh, &out, &stop);
                    }
                })
                .ok();
        }
    }

    fn handle(&mut self, req: &Request) {
        let method = req.method.to_ascii_uppercase();
        match method.as_str() {
            "OPTIONS" => {
                let mut r = self.reply(req, 200);
                r.headers.add("Public", "OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER");
                self.send(&r);
            }
            "DESCRIBE" => self.describe(req),
            "SETUP" => self.setup(req),
            "PLAY" => self.play(req),
            "PAUSE" => {
                let _ = self.state.compare_exchange(ST_PLAYING, ST_PAUSED, Ordering::SeqCst, Ordering::SeqCst);
                let mut r = self.reply(req, 200);
                r.headers.add("Session", &self.id);
                self.send(&r);
            }
            "TEARDOWN" => {
                let mut r = self.reply(req, 200);
                r.headers.add("Session", &self.id);
                self.send(&r);
                self.stop.store(true, Ordering::SeqCst);
            }
            "GET_PARAMETER" | "SET_PARAMETER" => {
                let mut r = self.reply(req, 200);
                r.headers.add("Session", &self.id);
                self.send(&r);
            }
            _ => self.send(&self.reply(req, 501)),
        }
    }
}

/// Atende a conexão RTSP até o TEARDOWN, o fim do arquivo ou o socket cair.
/// `initial` são os bytes já lidos por quem decidiu que era RTSP.
pub fn serve_rtsp(stream: TcpStream, initial: Vec<u8>, sh: Arc<Shared>, server_stop: vms_core::stop::StopToken) {
    let _ = stream.set_nodelay(true);
    let Ok(out) = stream.try_clone() else { return };
    let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_default();
    sh.log.info("tx.listener", &format!("cliente RTSP conectado: {peer}"));
    let mut s = Session {
        sh: sh.clone(),
        out: Arc::new(Mutex::new(out)),
        stop: Arc::new(AtomicBool::new(false)),
        state: Arc::new(AtomicU8::new(ST_INIT)),
        media: Arc::new(Mutex::new(Media::default())),
        id: format!("{:08X}{:08X}", rand_u32(), rand_u32()),
        pacer: None,
    };
    let mut conn = TcpConn::from_stream(stream);
    let mut wire = WireReader::new();
    wire.push_initial(&initial);
    while !s.stop.load(Ordering::SeqCst) && !server_stop.is_stopped() {
        match wire.read_next(&mut conn, Duration::from_millis(500)) {
            Ok(WireEvent::Message { head, body }) => match as_request(&head, body) {
                Some(req) => s.handle(&req),
                None => break,
            },
            Ok(WireEvent::Interleaved { .. }) => {} // RTCP do player: não se usa
            Err(vms_core::Error::Timeout(_)) => {}
            Err(_) => break,
        }
    }
    s.stop.store(true, Ordering::SeqCst);
    if let Some(p) = s.pacer.take() {
        let _ = p.join();
    }
    use vms_core::net::Conn;
    conn.shutdown();
    sh.log.info("tx.listener", &format!("cliente RTSP desconectado: {peer}"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotas_transporte_e_range() {
        assert_eq!(parse_route("rtsp://h:8554/live/Frente/trackID=0"), ("live/Frente".into(), true, "Frente".into()));
        assert_eq!(parse_route("rtsp://h:8554/live/Sala%20A?x=1"), ("live/Sala%20A".into(), true, "Sala A".into()));
        assert_eq!(parse_route("/arquivo.vms").1, false);
        assert_eq!(parse_transport("RTP/AVP/TCP;unicast;interleaved=2-3"), Some((true, 2, 3)));
        assert_eq!(parse_transport("RTP/AVP;unicast;client_port=5000-5001"), Some((false, 0, 1)));
        assert_eq!(parse_transport("x"), None);
        assert_eq!(parse_range_start("npt=12.5-"), Some(12.5));
        assert_eq!(parse_range_start("npt=now-"), None);
    }
}
