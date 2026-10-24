//! A sessão RTSP de uma câmera: handshake (OPTIONS, DESCRIBE, SETUP, PLAY)
//! tentando os transportes em ordem, e o laço de recepção com keep-alive.
//!
//! A sessão não grava nem desenha: entrega samples ao [`MediaSink`]. Quem
//! grava é o [`crate::recorder::Recorder`], ligado como sink.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::camera::CameraConfig;
use crate::clock::Clock;
use crate::depk::{self, Depacketizer};
use crate::error::{Error, Result};
use crate::log::SharedLogger;
use crate::media::{Sample, TrackKind, Transport};
use crate::net::{self, TcpConn, UdpPair};
use crate::rtp::{Demux, RtpPacket};
use crate::rtsp::{RtspClient, RtspUrl, TransportSpec, WireEvent};
use crate::sdp::{self, CodecInfo, MediaKind, SdpMedia, SdpSession};
use crate::sink::SharedSink;
use crate::stop::StopToken;

/// Executado por um supervisor: uma tentativa de conexão inteira.
pub trait SessionRun: Send {
    fn run(&mut self) -> Result<()>;
    /// Chegou mídia? Queda depois disso é transiente e não conta tentativa.
    fn streamed_ok(&self) -> bool;
}

/// Avisa de onde vem a mídia, assim que o SDP responde.
pub type SourceKnown = Arc<dyn Fn(bool, i64) + Send + Sync>;

const POLL_MS: u64 = 200;
const UDP_DRAIN_MAX: usize = 256;

struct Track {
    media: SdpMedia,
    info: CodecInfo,
    spec: Option<TransportSpec>,
    udp: Option<UdpPair>,
}

pub struct RtspSession {
    cfg: CameraConfig,
    log: SharedLogger,
    clock: Arc<dyn Clock>,
    stop: StopToken,
    sink: Option<SharedSink>,
    on_source: Option<SourceKnown>,
    tag: String,
    client: Option<RtspClient>,
    sdp: SdpSession,
    video: Option<Track>,
    audio: Option<Track>,
    used: Transport,
    demux: Demux,
    vdepk: Option<Box<dyn Depacketizer>>,
    adepk: Option<Box<dyn Depacketizer>>,
    streamed: AtomicBool,
    format_notified: bool,
    last_rtp_ms: i64,
    last_keepalive_ms: i64,
    stats: Stats,
}

#[derive(Default)]
struct Stats {
    last_ms: i64,
    vid: (u64, u64, u64),
    aud: (u64, u64),
    vseq: Option<u16>,
    aseq: Option<u16>,
}

impl RtspSession {
    pub fn new(cfg: CameraConfig, log: SharedLogger, clock: Arc<dyn Clock>, stop: StopToken, sink: Option<SharedSink>) -> Self {
        let tag = format!("session.{}", cfg.name);
        Self {
            cfg,
            log,
            clock,
            stop,
            sink,
            on_source: None,
            tag,
            client: None,
            sdp: SdpSession::default(),
            video: None,
            audio: None,
            used: Transport::Tcp,
            demux: Demux::new(),
            vdepk: None,
            adepk: None,
            streamed: AtomicBool::new(false),
            format_notified: false,
            last_rtp_ms: 0,
            last_keepalive_ms: 0,
            stats: Stats::default(),
        }
    }

    pub fn on_source_known(mut self, f: SourceKnown) -> Self {
        self.on_source = Some(f);
        self
    }

    fn want_audio(&self) -> bool {
        self.cfg.record_audio || self.sink.is_some()
    }

    fn client(&mut self) -> &mut RtspClient {
        self.client.as_mut().expect("conexao aberta")
    }

    fn open(&mut self) -> Result<()> {
        let url = RtspUrl::parse(&self.cfg.url).ok_or_else(|| Error::Config(format!("URL RTSP invalida: {}", self.cfg.url)))?;
        if self.cfg.uses_tailscale {
            net::ensure_tailnet_up(&url.host, url.port, &*self.log, Some(&self.stop), net::TAILNET_WAIT_MS);
        } else if net::looks_like_tailnet_host(&url.host) {
            self.log.warn(&self.tag, &format!("{} parece ser endereco de tailnet, mas a opcao Tailscale desta camera esta desligada", url.host));
        }
        let conn = TcpConn::connect(&url.host, url.port, self.cfg.connect_timeout_ms)?;
        // Usuário e senha do cadastro valem mais que os da URL.
        let (u, p) = if self.cfg.user.is_empty() { (url.user.clone(), url.password.clone()) } else { (self.cfg.user.clone(), self.cfg.password.clone()) };
        let mut c = RtspClient::new(Box::new(conn), url, &u, &p, self.log.clone());
        c.timeout = Duration::from_millis(self.cfg.rtsp_timeout_ms.max(1000));
        self.client = Some(c);
        Ok(())
    }

    fn close(&mut self) {
        if let Some(mut c) = self.client.take() {
            c.conn.shutdown();
        }
        self.video = None;
        self.audio = None;
        self.vdepk = None;
        self.adepk = None;
    }

    fn describe(&mut self) -> Result<()> {
        let r = self.client().options()?;
        if r.status != 200 && r.status != 401 {
            return Err(Error::Protocol(format!("OPTIONS {} {}", r.status, r.reason)));
        }
        let r = self.client().describe()?;
        if r.status == 401 {
            return Err(Error::Auth("autenticacao falhou (usuario/senha?)".into()));
        }
        if r.status != 200 {
            return Err(Error::Protocol(format!("DESCRIBE {} {}", r.status, r.reason)));
        }
        self.sdp = sdp::parse(&r.body_text());
        if !self.sdp.source_is_live {
            self.log.warn(&self.tag, "o servidor esta entregando GRAVACAO, nao a camera ao vivo");
        }
        if let Some(f) = &self.on_source {
            f(self.sdp.source_is_live, self.sdp.media_start_ms);
        }
        let mk = |m: &SdpMedia| sdp::codec_of(m).map(|info| Track { media: m.clone(), info, spec: None, udp: None });
        self.video = self.sdp.first(MediaKind::Video).and_then(mk);
        self.audio = self.sdp.first(MediaKind::Audio).and_then(mk);
        if self.video.is_none() && self.audio.is_none() {
            return Err(Error::Protocol("SDP sem trilha de video/audio reconhecida".into()));
        }
        Ok(())
    }

    fn setup_track(&mut self, kind: TrackKind, tx: Transport) -> Result<bool> {
        let base = self.client().content_base().to_owned();
        let url = self.cfg.url.clone();
        let channel = if kind == TrackKind::Video { 0 } else { 2 };
        let t = match kind {
            TrackKind::Video => self.video.as_mut(),
            TrackKind::Audio => self.audio.as_mut(),
        };
        let Some(t) = t else { return Ok(true) };
        let req = match tx {
            Transport::Tcp => TransportSpec::tcp(channel),
            Transport::Udp => {
                let u = UdpPair::bind("0.0.0.0")?;
                let spec = TransportSpec::udp(u.rtp_port(), u.rtcp_port());
                t.udp = Some(u);
                spec
            }
        };
        let mut control = sdp::absolute_control(&base, &t.media.control);
        if control.is_empty() {
            control = url;
        }
        let (r, neg) = self.client().setup(&control, &req)?;
        if r.status != 200 {
            self.log.warn(&self.tag, &format!("SETUP {:?} ({}) {} {}", kind, tx.as_str(), r.status, r.reason));
            return Ok(false);
        }
        let t = match kind {
            TrackKind::Video => self.video.as_mut().unwrap(),
            TrackKind::Audio => self.audio.as_mut().unwrap(),
        };
        t.spec = Some(neg);
        Ok(true)
    }

    fn try_transport(&mut self, tx: Transport) -> bool {
        self.used = tx;
        match self.setup_track(TrackKind::Video, tx) {
            Ok(true) => {}
            Ok(false) => return false,
            Err(e) => {
                self.log.warn(&self.tag, &format!("SETUP video ({}) falhou: {e}", tx.as_str()));
                return false;
            }
        }
        if self.want_audio() && self.audio.is_some() {
            match self.setup_track(TrackKind::Audio, tx) {
                Ok(true) => {}
                Ok(false) | Err(_) => {
                    self.log.warn(&self.tag, "SETUP do audio falhou (seguindo sem audio)");
                    self.audio = None;
                }
            }
        }
        true
    }

    fn setup_depacketizers(&mut self) {
        self.demux = Demux::new();
        self.vdepk = None;
        self.adepk = None;
        if let Some(v) = &self.video {
            if let Some(d) = depk::for_video(v.info.video) {
                let ch = v.spec.as_ref().filter(|_| self.used == Transport::Tcp).map(|s| s.interleaved_rtp);
                self.demux.register(TrackKind::Video, v.media.payload_type.unwrap_or(96), ch);
                self.vdepk = Some(d);
            }
        }
        if self.want_audio() {
            if let Some(a) = &self.audio {
                if let Some(d) = depk::for_audio(a.info.audio, &a.media.fmtp) {
                    let ch = a.spec.as_ref().filter(|_| self.used == Transport::Tcp).map(|s| s.interleaved_rtp);
                    self.demux.register(TrackKind::Audio, a.media.payload_type.unwrap_or(0), ch);
                    self.adepk = Some(d);
                }
            }
        }
    }

    fn notify_format(&mut self) {
        if self.format_notified {
            return;
        }
        self.format_notified = true;
        let Some(sink) = self.sink.clone() else { return };
        match &self.video {
            Some(v) if v.info.video != crate::media::VideoCodec::None => {
                let i = &v.info;
                self.log.info(&self.tag, &format!("Video: {} {}x{} extradata={} bytes", i.video, i.width, i.height, i.extradata.len()));
                sink.on_video_format(i.video, i.width, i.height, &i.extradata);
            }
            _ => self.log.warn(&self.tag, "Sem track de video reconhecida no SDP (somente audio sera exibido)"),
        }
        if self.want_audio() {
            if let Some(a) = &self.audio {
                let i = &a.info;
                self.log.info(&self.tag, &format!("Audio: {} {}Hz {}ch", i.audio, i.sample_rate, i.channels));
                sink.on_audio_format(i.audio, i.sample_rate, i.channels, &i.extradata);
            }
        }
    }

    fn handle_rtp(&mut self, kind: TrackKind, p: RtpPacket) {
        self.streamed.store(true, Ordering::SeqCst);
        self.last_rtp_ms = self.clock.monotonic_ms();
        let (seq, lost) = match kind {
            TrackKind::Video => {
                self.stats.vid.0 += 1;
                self.stats.vid.2 += p.payload.len() as u64;
                (&mut self.stats.vseq, &mut self.stats.vid.1)
            }
            TrackKind::Audio => {
                self.stats.aud.0 += 1;
                (&mut self.stats.aseq, &mut self.stats.aud.1)
            }
        };
        if let Some(last) = *seq {
            let d = p.sequence.wrapping_sub(last);
            if d > 1 && d < 32768 {
                *lost += (d - 1) as u64;
            }
        }
        *seq = Some(p.sequence);
        let mut out: Vec<Sample> = Vec::new();
        let d = match kind {
            TrackKind::Video => self.vdepk.as_mut(),
            TrackKind::Audio => self.adepk.as_mut(),
        };
        if let Some(d) = d {
            d.feed(&p, &mut out);
        }
        if let Some(s) = &self.sink {
            for x in &out {
                s.on_sample(x);
            }
        }
    }

    fn validate_first_rtp(&mut self, timeout_ms: u64) -> bool {
        let deadline = self.clock.monotonic_ms() + timeout_ms as i64;
        let mut buf = vec![0u8; 65536];
        while self.clock.monotonic_ms() < deadline {
            if self.stop.is_stopped() {
                return false;
            }
            if self.used == Transport::Udp {
                for kind in [TrackKind::Video, TrackKind::Audio] {
                    let n = {
                        let t = if kind == TrackKind::Video { self.video.as_ref() } else { self.audio.as_ref() };
                        t.and_then(|t| t.udp.as_ref()).and_then(|u| u.recv_rtp(&mut buf, if kind == TrackKind::Video { 100 } else { 1 }))
                    };
                    if let Some(n) = n {
                        if let Some((k, p)) = self.demux.route_udp(kind, &buf[..n]) {
                            self.handle_rtp(k, p);
                        }
                        self.streamed.store(true, Ordering::SeqCst);
                        return true;
                    }
                }
            } else {
                let c = self.client.as_mut().unwrap();
                match c.reader.read_next(&mut *c.conn, Duration::from_millis(100)) {
                    Ok(WireEvent::Interleaved { channel, data }) => {
                        if let Some((k, p)) = self.demux.route_interleaved(channel, &data) {
                            self.handle_rtp(k, p);
                        }
                        self.streamed.store(true, Ordering::SeqCst);
                        return true;
                    }
                    Ok(_) | Err(Error::Timeout(_)) => {}
                    Err(_) => return false,
                }
            }
        }
        false
    }

    fn handshake(&mut self) -> Result<()> {
        self.describe()?;
        for tx in self.cfg.transports.clone() {
            self.log.info(&self.tag, &format!("Trying transport: {}", tx.as_str()));
            if !self.try_transport(tx) {
                self.cleanup_attempt();
                continue;
            }
            let ok = match self.client().play() {
                Ok(r) if r.status == 200 => true,
                Ok(r) => {
                    self.log.warn(&self.tag, &format!("PLAY ({}) {} {}", tx.as_str(), r.status, r.reason));
                    false
                }
                // Em UDP a resposta do PLAY às vezes não volta; quem decide é o RTP.
                Err(e) if tx == Transport::Udp => {
                    self.log.info(&self.tag, &format!("PLAY sem resposta em UDP (valida pela chegada do RTP): {e}"));
                    true
                }
                Err(e) => {
                    self.log.warn(&self.tag, &format!("PLAY ({}) falhou: {e}", tx.as_str()));
                    false
                }
            };
            if !ok {
                let _ = self.client().teardown();
                self.cleanup_attempt();
                continue;
            }
            self.setup_depacketizers();
            // Formato ANTES do primeiro RTP: o sink precisa saber configurar o
            // decodificador antes de receber mídia.
            self.notify_format();
            if self.validate_first_rtp(self.cfg.transport_fallback_timeout_ms) {
                self.log.info(&self.tag, &format!("First RTP received on {}", tx.as_str()));
                return Ok(());
            }
            self.log.warn(&self.tag, &format!("No RTP within {} ms on {}, trying next transport", self.cfg.transport_fallback_timeout_ms, tx.as_str()));
            let _ = self.client().teardown();
            self.cleanup_attempt();
        }
        Err(Error::Protocol("nenhum transporte entregou RTP".into()))
    }

    fn cleanup_attempt(&mut self) {
        for t in [self.video.as_mut(), self.audio.as_mut()].into_iter().flatten() {
            t.udp = None;
            t.spec = None;
        }
        self.vdepk = None;
        self.adepk = None;
    }

    fn check_keepalive(&mut self) -> Result<()> {
        let to = self.client().session_timeout_s();
        if to == 0 {
            return Ok(());
        }
        let interval = ((to as i64 * 1000) / 2).max(5000);
        let now = self.clock.monotonic_ms();
        if now - self.last_keepalive_ms < interval {
            return Ok(());
        }
        // TCP com mídia chegando: a própria mídia mantém a sessão viva, e a
        // resposta do GET_PARAMETER competiria com ela.
        if self.used == Transport::Tcp && now - self.last_rtp_ms < interval {
            self.last_keepalive_ms = now;
            return Ok(());
        }
        let m = self.cfg.keep_alive;
        match self.client().keep_alive(m) {
            Ok(r) if r.status >= 400 => self.log.warn(&self.tag, &format!("Keepalive {} {}", r.status, r.reason)),
            Ok(_) => {}
            Err(e) if self.used == Transport::Udp => self.log.info(&self.tag, &format!("Keepalive falhou em UDP (ignorado): {e}")),
            Err(e) => return Err(Error::Io(format!("Keepalive falhou: {e}"))),
        }
        self.last_keepalive_ms = self.clock.monotonic_ms();
        Ok(())
    }

    fn log_stats(&mut self) {
        let now = self.clock.monotonic_ms();
        if self.stats.last_ms == 0 {
            self.stats.last_ms = now;
            return;
        }
        let el = now - self.stats.last_ms;
        if el < 5000 {
            return;
        }
        let (vp, vl, vb) = self.stats.vid;
        let (ap, al) = self.stats.aud;
        let loss = if vp + vl > 0 { vl as f64 * 100.0 / (vp + vl) as f64 } else { 0.0 };
        let kbps = vb as f64 * 8.0 / el as f64;
        self.log.info(&self.tag, &format!("RTP video={vp} pkts perda={vl} ({loss:.1}%) {kbps:.0}kbps | audio={ap} pkts perda={al}"));
        self.stats.vid = (0, 0, 0);
        self.stats.aud = (0, 0);
        self.stats.last_ms = now;
    }

    fn stream_loop(&mut self) -> Result<()> {
        let mut buf = vec![0u8; 65536];
        while !self.stop.is_stopped() {
            if self.used == Transport::Tcp {
                let c = self.client.as_mut().unwrap();
                match c.reader.read_next(&mut *c.conn, Duration::from_millis(POLL_MS)) {
                    Ok(WireEvent::Interleaved { channel, data }) => {
                        if let Some((k, p)) = self.demux.route_interleaved(channel, &data) {
                            self.handle_rtp(k, p);
                        }
                    }
                    Ok(WireEvent::Message { .. }) | Err(Error::Timeout(_)) => {}
                    Err(e) => return Err(e),
                }
            } else {
                let mut got = false;
                for kind in [TrackKind::Video, TrackKind::Audio] {
                    let mut drained = 0;
                    loop {
                        let n = {
                            let t = if kind == TrackKind::Video { self.video.as_ref() } else { self.audio.as_ref() };
                            let wait = if drained > 0 { 0 } else if kind == TrackKind::Video { POLL_MS / 4 } else { 1 };
                            t.and_then(|t| t.udp.as_ref()).and_then(|u| u.recv_rtp(&mut buf, wait))
                        };
                        let Some(n) = n else { break };
                        got = true;
                        if let Some((k, p)) = self.demux.route_udp(kind, &buf[..n]) {
                            self.handle_rtp(k, p);
                        }
                        drained += 1;
                        if drained > UDP_DRAIN_MAX {
                            break;
                        }
                    }
                    // RTCP: descartado.
                    let t = if kind == TrackKind::Video { self.video.as_ref() } else { self.audio.as_ref() };
                    if let Some(u) = t.and_then(|t| t.udp.as_ref()) {
                        let _ = u.recv_rtcp(&mut buf, 0);
                    }
                }
                // O canal de controle: respostas de keepalive, ou fechou.
                if let Some(c) = self.client.as_mut() {
                    if let Err(Error::Io(e)) = c.reader.read_next(&mut *c.conn, Duration::from_millis(1)) {
                        self.log.info(&self.tag, &format!("canal TCP de controle fechou (o RTP em UDP continua): {e}"));
                    }
                }
                if !got {
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
            if self.clock.monotonic_ms() - self.last_rtp_ms > self.cfg.no_rtp_timeout_ms as i64 {
                return Err(Error::Timeout(format!("sem RTP em {} ms", self.cfg.no_rtp_timeout_ms)));
            }
            self.check_keepalive()?;
            self.log_stats();
        }
        Ok(())
    }

    /// Só o handshake até o SETUP, sem PLAY: o teste da tela de cadastro.
    pub fn test_connection(&mut self) -> std::result::Result<String, String> {
        let r = (|| -> Result<String> {
            self.open()?;
            self.describe()?;
            let tx = self.cfg.transports.first().copied().unwrap_or(Transport::Tcp);
            if !self.try_transport(tx) {
                return Err(Error::Protocol(format!("SETUP falhou ({})", tx.as_str())));
            }
            let mut info = "OK".to_owned();
            if let Some(v) = &self.video {
                info.push_str(&format!(" | video {}", v.info.video));
            }
            if let Some(a) = &self.audio {
                info.push_str(&format!(" | audio {}", a.info.audio));
            }
            info.push_str(&format!(" | {}", tx.as_str()));
            Ok(info)
        })();
        self.close();
        r.map_err(|e| e.to_string())
    }
}

impl SessionRun for RtspSession {
    fn run(&mut self) -> Result<()> {
        self.streamed.store(false, Ordering::SeqCst);
        let now = self.clock.monotonic_ms();
        self.last_rtp_ms = now;
        self.last_keepalive_ms = now;
        let r = (|| {
            self.open()?;
            self.handshake()?;
            self.last_rtp_ms = self.clock.monotonic_ms();
            self.last_keepalive_ms = self.last_rtp_ms;
            self.stream_loop()
        })();
        if r.is_ok() {
            if let Some(c) = self.client.as_mut() {
                let _ = c.teardown();
            }
        } else if let Err(e) = &r {
            self.log.warn(&self.tag, &format!("Stream loop: {e}"));
        }
        self.close();
        if let Some(s) = &self.sink {
            s.on_stream_stopped();
        }
        r
    }

    fn streamed_ok(&self) -> bool {
        self.streamed.load(Ordering::SeqCst)
    }
}

impl SessionRun for crate::dvrip::DvripSession {
    fn run(&mut self) -> Result<()> {
        crate::dvrip::DvripSession::run(self)
    }
    fn streamed_ok(&self) -> bool {
        crate::dvrip::DvripSession::streamed_ok(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rtsp::message::{parse_request_head, Response};
    use std::io::{Read, Write};

    fn ler_pedido(s: &mut std::net::TcpStream) -> crate::rtsp::Request {
        let mut buf = Vec::new();
        let mut b = [0u8; 1];
        while !buf.ends_with(b"\r\n\r\n") {
            s.read_exact(&mut b).unwrap();
            buf.push(b[0]);
        }
        parse_request_head(&String::from_utf8_lossy(&buf)).unwrap()
    }

    /// Uma câmera RTSP falsa: responde ao handshake em TCP e manda RTP H.264
    /// interleaved. A sessão tem de anunciar o formato e entregar os quadros.
    #[test]
    fn sessao_tcp_contra_camera_falsa() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let srv = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let responder = |s: &mut std::net::TcpStream, q: &crate::rtsp::Request, extra: &[(&str, &str)], body: &str| {
                let mut r = Response::new(200);
                r.headers.add("CSeq", q.headers.get("CSeq").unwrap());
                for (n, v) in extra {
                    r.headers.add(n, v);
                }
                r.body = body.as_bytes().to_vec();
                s.write_all(&r.serialize()).unwrap();
            };
            let q = ler_pedido(&mut s);
            assert_eq!(q.method, "OPTIONS");
            responder(&mut s, &q, &[], "");
            let q = ler_pedido(&mut s);
            assert_eq!(q.method, "DESCRIBE");
            let sdp = "v=0\r\ns=x\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:trackID=0\r\n";
            responder(&mut s, &q, &[("Content-Base", &format!("rtsp://127.0.0.1:{port}/live/"))], sdp);
            let q = ler_pedido(&mut s);
            assert_eq!(q.method, "SETUP");
            assert!(q.uri.ends_with("/live/trackID=0"));
            responder(&mut s, &q, &[("Session", "77;timeout=60"), ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")], "");
            let q = ler_pedido(&mut s);
            assert_eq!(q.method, "PLAY");
            assert_eq!(q.headers.get("Session"), Some("77"));
            responder(&mut s, &q, &[], "");
            for i in 0..5u16 {
                let p = RtpPacket { marker: true, payload_type: 96, sequence: i, timestamp: i as u32 * 3600, ssrc: 1, payload: vec![if i == 0 { 0x65 } else { 0x41 }, 1, 2] };
                let d = p.serialize();
                let mut f = vec![b'$', 0];
                f.extend_from_slice(&(d.len() as u16).to_be_bytes());
                f.extend_from_slice(&d);
                s.write_all(&f).unwrap();
            }
            std::thread::sleep(Duration::from_millis(300));
        });
        let sink = Arc::new(crate::sink::RecordingSink::default());
        let stop = StopToken::new();
        let cfg = CameraConfig { name: "rtspfake".into(), url: format!("rtsp://127.0.0.1:{port}/live"), transports: vec![Transport::Tcp], ..Default::default() };
        let seen = Arc::new(std::sync::Mutex::new(None));
        let seen2 = seen.clone();
        let mut sess = RtspSession::new(cfg, crate::log::null(), Arc::new(crate::clock::SystemClock), stop.clone(), Some(sink.clone()))
            .on_source_known(Arc::new(move |live, ms| *seen2.lock().unwrap() = Some((live, ms))));
        let h = std::thread::spawn(move || {
            let r = sess.run();
            (r, sess.streamed_ok())
        });
        srv.join().unwrap();
        stop.stop();
        let (r, ok) = h.join().unwrap();
        assert!(ok, "{r:?}");
        assert_eq!(*seen.lock().unwrap(), Some((true, 0)));
        let ev = sink.events.lock().unwrap().clone();
        assert_eq!(ev[0], "video H264 0x0 0");
        assert_eq!(ev.last().unwrap(), "stopped");
        let s = sink.samples.lock().unwrap();
        assert_eq!(s.len(), 5);
        assert!(s[0].is_keyframe());
        assert_eq!(s[4].pts, 4 * 3600);
    }
}
