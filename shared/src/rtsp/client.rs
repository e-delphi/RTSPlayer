//! O cliente RTSP: OPTIONS, DESCRIBE, SETUP, PLAY, keep-alive e TEARDOWN sobre
//! uma conexão já aberta. Refaz o pedido uma vez com credencial depois de um
//! 401, e guarda Session e Content-Base das respostas.

use std::time::Duration;

use super::auth::AuthHandler;
use super::message::{Request, Response};
use super::transport::TransportSpec;
use super::url::RtspUrl;
use super::wire::WireReader;
use crate::error::{Error, Result};
use crate::log::SharedLogger;
use crate::net::Conn;

pub const USER_AGENT: &str = "VMS-Rust/1.0";
pub const DEFAULT_TIMEOUT_MS: u64 = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KeepAliveMethod {
    #[default]
    GetParameter,
    Options,
}

pub struct RtspClient {
    pub conn: Box<dyn Conn>,
    pub reader: WireReader,
    auth: AuthHandler,
    log: SharedLogger,
    cseq: u32,
    session: String,
    session_timeout_s: u32,
    url: RtspUrl,
    content_base: String,
    pub timeout: Duration,
}

impl RtspClient {
    pub fn new(conn: Box<dyn Conn>, url: RtspUrl, user: &str, password: &str, log: SharedLogger) -> Self {
        let base = url.to_string_plain();
        Self {
            conn,
            reader: WireReader::new(),
            auth: AuthHandler::new(user, password),
            log,
            cseq: 0,
            session: String::new(),
            session_timeout_s: 60,
            url,
            content_base: base,
            timeout: Duration::from_millis(DEFAULT_TIMEOUT_MS),
        }
    }

    pub fn session(&self) -> &str {
        &self.session
    }
    pub fn session_timeout_s(&self) -> u32 {
        self.session_timeout_s
    }
    pub fn content_base(&self) -> &str {
        &self.content_base
    }
    pub fn url(&self) -> &RtspUrl {
        &self.url
    }

    fn apply_session(&mut self, r: &Response) {
        if let Some(v) = r.headers.get("Session") {
            let mut parts = v.split(';');
            self.session = parts.next().unwrap_or("").trim().to_owned();
            for p in parts {
                let p = p.trim().to_ascii_lowercase();
                if let Some(t) = p.strip_prefix("timeout=") {
                    if let Ok(n) = t.trim().parse() {
                        self.session_timeout_s = n;
                    }
                }
            }
        }
        if let Some(v) = r.headers.get("Content-Base").or_else(|| r.headers.get("Content-Location")) {
            self.content_base = v.trim().to_owned();
        }
    }

    /// Manda e espera a resposta. Com 401 e credencial, repete uma vez.
    pub fn send(&mut self, method: &str, uri: &str, extra: &[(&str, &str)], body: &[u8]) -> Result<Response> {
        let mut retried = false;
        loop {
            self.cseq += 1;
            let mut q = Request::new(method, uri);
            q.headers.add("CSeq", &self.cseq.to_string());
            q.headers.add("User-Agent", USER_AGENT);
            if !self.session.is_empty() {
                q.headers.add("Session", &self.session.clone());
            }
            if self.auth.has_challenge() {
                let a = self.auth.authorization(method, uri);
                if !a.is_empty() {
                    q.headers.add("Authorization", &a);
                }
            }
            for (n, v) in extra {
                q.headers.add(n, v);
            }
            if !body.is_empty() {
                q.body = body.to_vec();
            }
            let wire = q.serialize();
            self.log.debug("rtsp.tx", &format!("{method} {uri} (CSeq={}, {} bytes)", self.cseq, wire.len()));
            self.conn.send(&wire)?;
            let r = self.reader.read_response(&mut *self.conn, self.timeout)?;
            self.log.debug("rtsp.rx", &format!("{method} {uri} -> {} {}", r.status, r.reason));
            if r.status == 401 && !retried {
                self.auth.consume_challenge(r.headers.get("WWW-Authenticate").unwrap_or(""));
                if !self.auth.has_challenge() {
                    return Ok(r);
                }
                retried = true;
                continue;
            }
            self.apply_session(&r);
            return Ok(r);
        }
    }

    fn target(&self) -> String {
        if self.content_base.is_empty() {
            self.url.to_string_plain()
        } else {
            self.content_base.clone()
        }
    }

    pub fn options(&mut self) -> Result<Response> {
        let u = self.url.to_string_plain();
        self.send("OPTIONS", &u, &[], &[])
    }

    pub fn describe(&mut self) -> Result<Response> {
        let u = self.url.to_string_plain();
        self.send("DESCRIBE", &u, &[("Accept", "application/sdp")], &[])
    }

    /// SETUP de uma trilha. Devolve a resposta e o transporte negociado.
    pub fn setup(&mut self, track_uri: &str, req: &TransportSpec) -> Result<(Response, TransportSpec)> {
        let h = req.header();
        let r = self.send("SETUP", track_uri, &[("Transport", &h)], &[])?;
        let mut neg = req.clone();
        if r.status == 200 && !neg.apply_response(r.headers.get("Transport").unwrap_or("")) {
            return Err(Error::Protocol("SETUP: cabecalho Transport invalido".into()));
        }
        Ok((r, neg))
    }

    pub fn play(&mut self) -> Result<Response> {
        let t = self.target();
        self.send("PLAY", &t, &[("Range", "npt=0.000-")], &[])
    }

    pub fn teardown(&mut self) -> Result<Response> {
        let t = self.target();
        let r = self.send("TEARDOWN", &t, &[], &[]);
        self.session.clear();
        r
    }

    pub fn keep_alive(&mut self, m: KeepAliveMethod) -> Result<Response> {
        match m {
            KeepAliveMethod::GetParameter => {
                let t = self.target();
                self.send("GET_PARAMETER", &t, &[], &[])
            }
            KeepAliveMethod::Options => self.options(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::MemConn;
    use std::sync::{Arc, Mutex};

    /// Conexão que responde por roteiro: cada `send` libera a próxima resposta.
    struct Roteiro {
        respostas: Vec<Vec<u8>>,
        enviados: Arc<Mutex<Vec<String>>>,
        mem: MemConn,
    }
    impl crate::net::TimedRead for Roteiro {
        fn read_timeout(&mut self, b: &mut [u8], t: Duration) -> Result<usize> {
            self.mem.read_timeout(b, t)
        }
    }
    impl Conn for Roteiro {
        fn send(&mut self, d: &[u8]) -> Result<()> {
            self.enviados.lock().unwrap().push(String::from_utf8_lossy(d).into_owned());
            if !self.respostas.is_empty() {
                let r = self.respostas.remove(0);
                self.mem.push(&r);
            }
            Ok(())
        }
        fn shutdown(&mut self) {}
    }

    #[test]
    fn describe_com_digest_e_sessao() {
        let enviados = Arc::new(Mutex::new(Vec::new()));
        let conn = Roteiro {
            respostas: vec![
                b"RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"r\", nonce=\"n\"\r\n\r\n".to_vec(),
                b"RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Base: rtsp://h:554/live/\r\nContent-Length: 3\r\n\r\nv=0".to_vec(),
                b"RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: ABC;timeout=30\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n".to_vec(),
            ],
            enviados: enviados.clone(),
            mem: MemConn::default(),
        };
        let url = RtspUrl::parse("rtsp://h/live").unwrap();
        let mut c = RtspClient::new(Box::new(conn), url, "admin", "x", crate::log::null());
        let r = c.describe().unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body, b"v=0");
        assert_eq!(c.content_base(), "rtsp://h:554/live/");
        let (r, t) = c.setup("rtsp://h:554/live/track1", &TransportSpec::tcp(0)).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(t.interleaved_rtp, 0);
        assert_eq!(c.session(), "ABC");
        assert_eq!(c.session_timeout_s(), 30);
        let e = enviados.lock().unwrap();
        assert!(!e[0].contains("Authorization"));
        assert!(e[1].contains("Authorization: Digest username=\"admin\""));
        assert!(e[2].contains("Transport: RTP/AVP/TCP;unicast;interleaved=0-1"));
    }
}
