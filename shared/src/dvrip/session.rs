//! Sessão DVRIP: conecta → login → OPMonitor Claim/Start → recebe frames →
//! entrega samples ao mesmo [`MediaSink`] do RTSP.
//!
//! O lado de escrita fica num [`DvripControl`] separado, anunciado no
//! [`PtzRegistry`]: é por ele que a rota de PTZ manda comando pela conexão que
//! já está autenticada, enquanto esta thread continua lendo.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use super::media::{MediaFrame, MediaParser};
use super::protocol::*;
use super::talk::DvripTalk;
use crate::camera::CameraConfig;
use crate::clock::Clock;
use crate::error::{Error, Result};
use crate::h26x;
use crate::log::SharedLogger;
use crate::media::{AudioCodec, Sample, VideoCodec};
use crate::net::{self, TcpConn};
use crate::ptz::{FalaSession, PtzRegistry, PtzSession};
use crate::sink::SharedSink;
use crate::stop::StopToken;

/// `dvrip://usuario:senha@host:porta/sub` → (host, porta).
pub fn host_port(url: &str) -> Option<(String, u16)> {
    let mut s = url.trim();
    if let Some(p) = s.find("://") {
        s = &s[p + 3..];
    }
    let s = s.split('/').next().unwrap_or("");
    let s = match s.rfind('@') {
        Some(a) => &s[a + 1..],
        None => s,
    };
    let (h, p) = match s.find(':') {
        Some(c) => (&s[..c], s[c + 1..].parse().unwrap_or(34567)),
        None => (s, 34567),
    };
    (!h.is_empty()).then(|| (h.to_owned(), p))
}

/// O lado de escrita de uma sessão viva: PTZ, configuração e a porta da fala.
pub struct DvripControl {
    writer: Arc<DvripWriter>,
    host: String,
    port: u16,
    user: String,
    password: String,
    connect_timeout_ms: u64,
    log: SharedLogger,
    tag: String,
}

impl PtzSession for DvripControl {
    fn mover_ptz(&self, comando: &str, passo: i32, canal: i32, iniciar: bool) -> bool {
        if comando.trim().is_empty() {
            return false;
        }
        let j = ptz_json(comando, passo, canal, iniciar, &session_hex(self.writer.session()));
        match self.writer.send_cmd(PTZ, &j) {
            Ok(()) => true,
            Err(e) => {
                self.log.warn(&self.tag, &format!("ptz {comando}: {e}"));
                false
            }
        }
    }

    fn ir_para_preset(&self, preset: i32, canal: i32, comando: &str) -> bool {
        let qual = if comando.trim().is_empty() { PTZ_PRESET_IR } else { comando };
        let j = preset_json(preset, canal, &session_hex(self.writer.session()), qual);
        match self.writer.send_cmd(PTZ, &j) {
            Ok(()) => true,
            Err(e) => {
                self.log.warn(&self.tag, &format!("ptz {qual} {preset}: {e}"));
                false
            }
        }
    }

    fn perguntar_config(&self, nome: &str) -> bool {
        if nome.trim().is_empty() {
            return false;
        }
        let ok = self.writer.send_cmd(CONFIG_GET, &config_get_json(nome, self.writer.session())).is_ok();
        if ok {
            self.log.info(&self.tag, &format!("perguntei a configuracao {nome}"));
        }
        ok
    }

    fn abrir_fala(&self) -> std::result::Result<Arc<dyn FalaSession>, String> {
        // Conexão PRÓPRIA: a câmera abre um canal duplex e manda o microfone
        // dela por ali — no meio do vídeo seria áudio a mais no parser.
        let t = DvripTalk::abrir(&self.host, self.port, &self.user, &self.password, self.connect_timeout_ms, self.log.clone(), &format!("{}.fala", self.tag))?;
        Ok(t)
    }
}

pub struct DvripSession {
    cfg: CameraConfig,
    log: SharedLogger,
    clock: Arc<dyn Clock>,
    stop: StopToken,
    sink: Option<SharedSink>,
    tag: String,
    streamed: AtomicBool,
    parser: MediaParser,
    video_notified: bool,
    audio_notified: bool,
    pts_base_ms: Option<i64>,
    audio_pts: i64,
    stream_type: String,
    media_msg_id: Option<u16>,
    warned: Vec<u16>,
    framing_resyncs: u32,
    framing_win: u32,
    win: (u32, u32, u32, u64),
    stats_tick: i64,
}

impl DvripSession {
    pub fn new(cfg: CameraConfig, log: SharedLogger, clock: Arc<dyn Clock>, stop: StopToken, sink: Option<SharedSink>) -> Self {
        let tag = format!("dvrip.{}", cfg.name);
        Self {
            cfg,
            log,
            clock,
            stop,
            sink,
            tag,
            streamed: AtomicBool::new(false),
            parser: MediaParser::new(),
            video_notified: false,
            audio_notified: false,
            pts_base_ms: None,
            audio_pts: 0,
            stream_type: "Main".into(),
            media_msg_id: None,
            warned: Vec::new(),
            framing_resyncs: 0,
            framing_win: 0,
            win: (0, 0, 0, 0),
            stats_tick: 0,
        }
    }

    pub fn streamed_ok(&self) -> bool {
        self.streamed.load(Ordering::SeqCst)
    }

    fn timeout(&self) -> Duration {
        Duration::from_millis(self.cfg.rtsp_timeout_ms.max(1000))
    }

    fn connect(&self) -> Result<(String, u16, DvripReader, Arc<DvripWriter>)> {
        let (host, port) = host_port(&self.cfg.url).ok_or_else(|| Error::Config(format!("URL DVRIP invalida: {}", self.cfg.url)))?;
        if self.cfg.uses_tailscale {
            net::ensure_tailnet_up(&host, port, &*self.log, Some(&self.stop), net::TAILNET_WAIT_MS);
        } else if net::looks_like_tailnet_host(&host) {
            self.log.warn(&self.tag, &format!("{host} parece ser endereco de tailnet, mas a opcao Tailscale desta camera esta desligada"));
        }
        let c = TcpConn::connect(&host, port, self.cfg.connect_timeout_ms)?;
        let w = c.try_clone()?;
        Ok((host, port, DvripReader::new(Box::new(c)), Arc::new(DvripWriter::new(Box::new(w)))))
    }

    fn control(&self, host: &str, port: u16, writer: &Arc<DvripWriter>) -> Arc<dyn PtzSession> {
        Arc::new(DvripControl {
            writer: writer.clone(),
            host: host.into(),
            port,
            user: self.cfg.user.clone(),
            password: self.cfg.password.clone(),
            connect_timeout_ms: self.cfg.connect_timeout_ms,
            log: self.log.clone(),
            tag: self.tag.clone(),
        })
    }

    /// Consulta "Simplify.Encode"; devolve true se o substream tem vídeo.
    fn query_encode_config(&self, r: &mut DvripReader, w: &DvripWriter) -> bool {
        let j = format!("{{ \"Name\" : \"Simplify.Encode\", \"SessionID\" : \"0x{:X}\" }}", w.session());
        if w.send_cmd(CONFIG_GET, &j).is_err() {
            return false;
        }
        let Ok((_, p)) = r.recv(Duration::from_millis(3000)) else {
            self.log.warn(&self.tag, "Simplify.Encode: sem resposta (MsgID pode diferir)");
            return false;
        };
        let resp = String::from_utf8_lossy(&p).into_owned();
        self.log.info(&self.tag, &format!("Encode config: {}", resp.trim_end_matches(['\n', '\0'])));
        let main = extract_section(&resp, "MainFormat");
        let extra = extract_section(&resp, "ExtraFormat");
        for (n, s) in [("Main ", &main), ("Extra", &extra)] {
            if !s.is_empty() {
                self.log.info(
                    &self.tag,
                    &format!(
                        "  {n}: enable={} compression={} res={}",
                        json_get_str(s, "VideoEnable"),
                        json_get_str(s, "Compression"),
                        json_get_str(s, "Resolution")
                    ),
                );
            }
        }
        !extra.is_empty() && json_get_str(&extra, "VideoEnable").eq_ignore_ascii_case("true")
    }

    fn start_monitor(&self, r: &mut DvripReader, w: &DvripWriter, combin: &str) -> Result<()> {
        w.send_cmd(OPMONITOR_CLAIM, &monitor_json("Claim", combin, &self.stream_type, w.session()))?;
        if let Ok((_, p)) = r.recv(self.timeout()) {
            let ret = json_get_int(&String::from_utf8_lossy(&p), "Ret", -1);
            self.log.info(&self.tag, &format!("OPMonitor Claim ({}) Ret={ret}", self.stream_type));
            if ret != 100 {
                self.log.warn(&self.tag, &format!("Claim recusado (Ret={ret}); a camera pode nao aceitar esse StreamType"));
            }
        }
        w.send_cmd(OPMONITOR, &monitor_json("Start", combin, &self.stream_type, w.session()))
    }

    fn warn_once(&mut self, msg_id: u16) -> bool {
        if self.warned.contains(&msg_id) || self.warned.len() >= 8 {
            return false;
        }
        self.warned.push(msg_id);
        true
    }

    fn feed_media(&mut self, msg_id: u16, p: &[u8]) {
        if self.media_msg_id.is_none() {
            self.media_msg_id = Some(msg_id);
            self.log.info(&self.tag, &format!("midia no MsgID {msg_id} (0x{msg_id:04x})"));
        }
        let frames = self.parser.feed(p);
        for w in std::mem::take(&mut self.parser.warnings) {
            self.log.warn(&self.tag, &w);
        }
        for f in frames {
            match f {
                MediaFrame::Video { annexb, keyframe, codec } => self.handle_video(annexb, keyframe, codec),
                MediaFrame::Audio { data, codec } => self.handle_audio(data, codec),
            }
        }
    }

    fn dispatch(&mut self, msg_id: u16, p: &[u8]) {
        if p.is_empty() {
            return;
        }
        let mut kind = classify(msg_id);
        if kind == MsgKind::Unknown && self.media_msg_id == Some(msg_id) {
            kind = MsgKind::Media;
        }
        if kind == MsgKind::Media {
            self.feed_media(msg_id, p);
            return;
        }
        if p.len() < 4 {
            return;
        }
        let warn = |s: &mut Self, why: &str| {
            if s.warn_once(msg_id) {
                s.log.warn(&s.tag, &format!("{why}: MsgID={msg_id} (0x{msg_id:04x}) len={} [{}]", p.len(), bytes_to_hex(p, 12)));
            }
        };
        if looks_like_json(p) {
            if kind == MsgKind::Unknown {
                warn(self, "MsgID desconhecido");
            }
            self.log.debug(&self.tag, &format!("ctrl: {}", String::from_utf8_lossy(p).trim_end_matches(['\n', '\0'])));
        } else {
            warn(self, if kind == MsgKind::Control { "MsgID de controle com payload binario" } else { "MsgID desconhecido" });
            self.feed_media(msg_id, p);
        }
    }

    fn handle_video(&mut self, annexb: Vec<u8>, keyframe: bool, codec: VideoCodec) {
        if !self.video_notified {
            // Espera o 1º keyframe: dele sai o csd-0 in-band.
            if !keyframe {
                return;
            }
            self.video_notified = true;
            self.streamed.store(true, Ordering::SeqCst);
            let csd = h26x::extract_inband_csd(&annexb, codec);
            let (w, h) = h26x::dimensions(codec, &csd).unwrap_or((0, 0));
            if let Some(s) = &self.sink {
                s.on_video_format(codec, w, h, &csd);
            }
            self.log.info(&self.tag, &format!("Video: {codec} (stream {}) csd={} bytes", self.stream_type, csd.len()));
        }
        if keyframe {
            self.win.0 += 1;
        } else {
            self.win.1 += 1;
        }
        self.win.3 += annexb.len() as u64;
        // PTS pelo relógio de chegada, em 90 kHz: só o header de I-frame traz
        // timestamp da câmera, o de P-frame não.
        let now = self.clock.monotonic_ms();
        let base = *self.pts_base_ms.get_or_insert(now);
        let s = Sample::video((now - base) * 90, keyframe, annexb);
        if let Some(k) = &self.sink {
            k.on_sample(&s);
        }
    }

    fn handle_audio(&mut self, data: Vec<u8>, codec: AudioCodec) {
        if !self.audio_notified {
            self.audio_notified = true;
            self.streamed.store(true, Ordering::SeqCst);
            if let Some(s) = &self.sink {
                s.on_audio_format(codec, 8000, 1, &[]);
            }
            self.log.info(&self.tag, &format!("Audio: {codec}"));
        }
        self.win.2 += 1;
        let s = Sample::audio(self.audio_pts, data);
        // G.711 a 8 kHz: um byte por amostra, a duração É o tamanho.
        self.audio_pts += s.data.len() as i64;
        if let Some(k) = &self.sink {
            k.on_sample(&s);
        }
    }

    fn log_stats_if_due(&mut self) {
        let now = self.clock.monotonic_ms();
        if self.stats_tick == 0 {
            self.stats_tick = now;
            return;
        }
        let el = now - self.stats_tick;
        if el < 5000 {
            return;
        }
        let frames = self.parser.take_stats();
        let enq = if self.framing_win > 0 { format!(" | enquadramento={}", self.framing_win) } else { String::new() };
        self.framing_win = 0;
        let (i, p, a, vb) = self.win;
        if i + p + a > 0 {
            self.log.info(
                &self.tag,
                &format!("stats {}s: vid I={i} P={p} ({} kbps) | audio={a} frames | parser: {frames}{enq}", el / 1000, vb * 8 / el.max(1) as u64),
            );
        } else {
            self.log.warn(&self.tag, &format!("stats {}s: SEM midia nessa janela{enq}", el / 1000));
        }
        self.win = (0, 0, 0, 0);
        self.stats_tick = now;
    }

    fn keepalive(&self, w: &DvripWriter, alive_s: i64, last: &mut i64) {
        let now = self.clock.monotonic_ms();
        if (now - *last) / 1000 < (alive_s / 2).max(1) {
            return;
        }
        let _ = w.send_cmd(KEEPALIVE, &keepalive_json(w.session()));
        *last = now;
    }

    /// Conecta e fica recebendo mídia até a parada ou a conexão cair.
    pub fn run(&mut self) -> Result<()> {
        let result = self.run_inner();
        if let Some(s) = &self.sink {
            s.on_stream_stopped();
        }
        result
    }

    fn run_inner(&mut self) -> Result<()> {
        self.parser.reset();
        let (host, port, mut r, w) = self.connect()?;
        self.log.info(&self.tag, &format!("conectado {host}:{port}"));
        let (sid, alive, resp) = login(&mut r, &w, &self.cfg.user, &self.cfg.password, self.timeout())?;
        self.log.debug(&self.tag, &format!("login resp: {}", resp.trim_end_matches(['\n', '\0'])));
        self.log.info(&self.tag, &format!("login OK (SessionID=0x{sid:x}, alive={alive}s)"));
        let url = self.cfg.url.to_ascii_lowercase();
        let force_sub = url.contains("/sub") || url.contains("/extra");
        let has_extra = self.query_encode_config(&mut r, &w);
        let combin = if force_sub && has_extra {
            self.stream_type = "Extra1".into();
            "NONE"
        } else {
            self.stream_type = "Main".into();
            "CONNECT_ALL"
        };
        self.log.info(&self.tag, &format!("StreamType={} CombinMode={combin}", self.stream_type));
        self.start_monitor(&mut r, &w, combin)?;
        let ctl = self.control(&host, port, &w);
        PtzRegistry::anunciar(&self.cfg.name, ctl.clone());
        let res = self.receive_loop(&mut r, &w, alive);
        PtzRegistry::apagar(&self.cfg.name, &ctl);
        w.close();
        res
    }

    fn receive_loop(&mut self, r: &mut DvripReader, w: &DvripWriter, alive: i64) -> Result<()> {
        let mut last_ka = self.clock.monotonic_ms();
        while !self.stop.is_stopped() {
            let (h, p, skipped, reject) = r.recv_resync(Duration::from_millis(4000), w.session()).map_err(|e| match e {
                Error::Timeout(_) => Error::Timeout("DVRIP sem dados em 4 s".into()),
                e => e,
            })?;
            if skipped > 0 {
                self.framing_resyncs += 1;
                self.framing_win += 1;
                if self.framing_resyncs <= 20 {
                    self.log.warn(
                        &self.tag,
                        &format!(
                            "enquadramento: pulou {skipped} bytes ate o proximo header (MsgID={}, {} ocorrencia(s)) recusado: {}",
                            h.msg_id,
                            self.framing_resyncs,
                            reject.unwrap_or_default()
                        ),
                    );
                }
            }
            self.dispatch(h.msg_id, &p);
            self.log_stats_if_due();
            self.keepalive(w, alive, &mut last_ka);
        }
        Ok(())
    }

    /// Conecta e fica viva SÓ para comandar: login e keepalive, sem vídeo. É o
    /// que dá PTZ a uma câmera gravada por RTSP.
    pub fn run_control(&mut self) -> Result<()> {
        let (host, port, mut r, w) = self.connect()?;
        self.log.info(&self.tag, &format!("controle conectado {host}:{port}"));
        let (sid, alive, _) = login(&mut r, &w, &self.cfg.user, &self.cfg.password, self.timeout())?;
        self.log.info(&self.tag, &format!("controle pronto (SessionID=0x{sid:x}, alive={alive}s)"));
        let ctl = self.control(&host, port, &w);
        PtzRegistry::anunciar(&self.cfg.name, ctl.clone());
        let mut last_ka = self.clock.monotonic_ms();
        let res = (|| {
            while !self.stop.is_stopped() {
                match r.recv_resync(Duration::from_millis(2000), w.session()) {
                    Ok((_, p, _, _)) => {
                        if !p.is_empty() {
                            self.log.debug(&self.tag, &format!("ctrl: {}", String::from_utf8_lossy(&p).trim_end_matches(['\n', '\0'])));
                        }
                    }
                    // Silêncio aqui é o normal: sem OPMonitor não há fluxo.
                    Err(Error::Timeout(_)) => {}
                    Err(e) => return Err(Error::Io(format!("DVRIP controle: {e}"))),
                }
                self.keepalive(&w, alive, &mut last_ka);
            }
            Ok(())
        })();
        PtzRegistry::apagar(&self.cfg.name, &ctl);
        w.close();
        res
    }

    /// connect + login + config, sem OPMonitor.
    pub fn test_connection(&mut self) -> std::result::Result<String, String> {
        let (_, _, mut r, w) = self.connect().map_err(|e| e.to_string())?;
        let res = login(&mut r, &w, &self.cfg.user, &self.cfg.password, self.timeout());
        let out = match res {
            Ok((sid, alive, _)) => {
                self.query_encode_config(&mut r, &w);
                Ok(format!("OK: login DVRIP (SessionID=0x{sid:x}, alive={alive}s)"))
            }
            Err(Error::Auth(_)) => Err("login falhou (usuario/senha?)".to_owned()),
            Err(e) => Err(e.to_string()),
        };
        w.close();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_e_porta() {
        assert_eq!(host_port("dvrip://admin:x@10.0.0.5:34568/sub"), Some(("10.0.0.5".into(), 34568)));
        assert_eq!(host_port("dvrip://cam"), Some(("cam".into(), 34567)));
        assert_eq!(host_port("dvrip://"), None);
    }

    /// Uma câmera DVRIP falsa num socket local: login, encode config, monitor
    /// e um I-frame H.264. A sessão tem de anunciar o formato e entregar o
    /// sample, e a rota de PTZ tem de achar a sessão e escrever por ela.
    #[test]
    fn sessao_contra_camera_falsa() {
        use std::io::{Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let srv = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let rd = |s: &mut std::net::TcpStream| -> (u16, Vec<u8>) {
                let mut h = [0u8; 20];
                s.read_exact(&mut h).unwrap();
                let hd = decode_header(&h);
                let mut p = vec![0u8; hd.data_len as usize];
                s.read_exact(&mut p).unwrap();
                (hd.msg_id, p)
            };
            assert_eq!(rd(&mut s).0, LOGIN);
            s.write_all(&encode_cmd(0x10, 0, LOGIN_RSP, "{ \"Ret\" : 100, \"SessionID\" : \"0x00000010\", \"AliveInterval\" : 20 }")).unwrap();
            assert_eq!(rd(&mut s).0, CONFIG_GET);
            s.write_all(&encode_cmd(0x10, 0, CONFIG_GET_RSP, "{ \"Simplify.Encode\" : [ { \"MainFormat\" : { \"Video\" : { \"Compression\" : \"H.264\" } } } ] }")).unwrap();
            assert_eq!(rd(&mut s).0, OPMONITOR_CLAIM);
            s.write_all(&encode_cmd(0x10, 0, OPMONITOR_CLAIM_RSP, "{ \"Ret\" : 100 }")).unwrap();
            assert_eq!(rd(&mut s).0, OPMONITOR);
            let nal = [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x65, 0x88];
            let mut fr = vec![0, 0, 1, 0xFC, 2, 25, 0, 0, 0, 0, 0, 0];
            fr.extend_from_slice(&(nal.len() as u32).to_le_bytes());
            fr.extend_from_slice(&nal);
            s.write_all(&encode(0x10, 1, OPMONITOR_DATA, &fr)).unwrap();
            // Espera o comando de PTZ que o teste manda.
            let (id, p) = rd(&mut s);
            assert_eq!(id, PTZ);
            assert!(String::from_utf8_lossy(&p).contains("DirectionLeft"));
        });
        let sink = Arc::new(crate::sink::RecordingSink::default());
        let stop = StopToken::new();
        let cfg = CameraConfig { name: "dvripfake".into(), url: format!("dvrip://127.0.0.1:{port}"), ..Default::default() };
        let mut sess = DvripSession::new(cfg, crate::log::null(), Arc::new(crate::clock::SystemClock), stop.clone(), Some(sink.clone()));
        let h = std::thread::spawn(move || {
            let r = sess.run();
            (r, sess.streamed_ok())
        });
        let t0 = std::time::Instant::now();
        while sink.samples.lock().unwrap().is_empty() && t0.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(10));
        }
        let ptz = PtzRegistry::achar("dvripfake").expect("sessao anunciada");
        assert!(ptz.mover_ptz(PTZ_DIREITA, 5, 0, true));
        srv.join().unwrap();
        stop.stop();
        let (_, ok) = h.join().unwrap();
        assert!(ok);
        let ev = sink.events.lock().unwrap().clone();
        assert!(ev[0].starts_with("video H264"), "{ev:?}");
        assert_eq!(ev.last().unwrap(), "stopped");
        assert!(sink.samples.lock().unwrap()[0].is_keyframe());
        assert!(PtzRegistry::achar("dvripfake").is_none(), "saiu do registro");
    }
}
