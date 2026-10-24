//! HTTP do jeito que o sistema usa: um pedido vira uma resposta, e o roteador
//! não sabe de onde o pedido veio.
//!
//! É isso que deixa as rotas do vmsserver e as do app testáveis sem socket, e
//! que deixa o app servir as mesmas páginas pelo WebView2 (o pedido chega pelo
//! `WebResourceRequested`) e o servidor por TCP.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Arc;
use std::time::Duration;

use crate::error::{Error, Result};
use crate::rtsp::message::{find_header_end, parse_request_head, status_text, Headers};

#[derive(Debug, Clone, Default)]
pub struct Request {
    pub method: String,
    /// Só o caminho, sem a query: `/api/days`.
    pub path: String,
    /// A query crua, sem o `?`.
    pub query: String,
    pub headers: Headers,
    pub body: Vec<u8>,
    pub peer: Option<SocketAddr>,
}

impl Request {
    pub fn new(method: &str, uri: &str) -> Self {
        let (path, query) = split_uri(uri);
        Self { method: method.to_ascii_uppercase(), path, query, ..Default::default() }
    }

    pub fn with_body(mut self, body: Vec<u8>) -> Self {
        self.body = body;
        self
    }

    /// Um parâmetro da query, decodificado. Vazio quando não veio.
    pub fn param(&self, name: &str) -> String {
        query_value(&self.query, name)
    }

    pub fn has_param(&self, name: &str) -> bool {
        query_pairs(&self.query).any(|(k, _)| k.eq_ignore_ascii_case(name))
    }

    pub fn param_i64(&self, name: &str, default: i64) -> i64 {
        self.param(name).trim().parse().unwrap_or(default)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name)
    }

    pub fn uri(&self) -> String {
        if self.query.is_empty() {
            self.path.clone()
        } else {
            format!("{}?{}", self.path, self.query)
        }
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn is_loopback(&self) -> bool {
        self.peer.is_some_and(|p| p.ip().is_loopback())
    }
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub content_type: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16, content_type: &str, body: Vec<u8>) -> Self {
        Self { status, content_type: content_type.into(), headers: Vec::new(), body }
    }

    pub fn json(v: &serde_json::Value) -> Self {
        Self::new(200, "application/json; charset=utf-8", v.to_string().into_bytes())
    }

    pub fn json_status(status: u16, v: &serde_json::Value) -> Self {
        Self::new(status, "application/json; charset=utf-8", v.to_string().into_bytes())
    }

    /// `{"error": "..."}` com o status dado.
    pub fn error(status: u16, msg: &str) -> Self {
        Self::json_status(status, &serde_json::json!({ "error": msg }))
    }

    pub fn text(status: u16, ctype: &str, s: &str) -> Self {
        Self::new(status, ctype, s.as_bytes().to_vec())
    }

    pub fn empty(status: u16) -> Self {
        Self::new(status, "", Vec::new())
    }

    pub fn with_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn json_value(&self) -> serde_json::Value {
        serde_json::from_slice(&self.body).unwrap_or(serde_json::Value::Null)
    }

    /// No fio, HTTP/1.1.
    pub fn serialize(&self, head_only: bool) -> Vec<u8> {
        let mut s = format!("HTTP/1.1 {} {}\r\n", self.status, status_text(self.status));
        if !self.content_type.is_empty() {
            s.push_str(&format!("Content-Type: {}\r\n", self.content_type));
        }
        for (n, v) in &self.headers {
            s.push_str(&format!("{n}: {v}\r\n"));
        }
        // 204/304 não levam corpo nem Content-Length.
        if self.status != 204 && self.status != 304 {
            s.push_str(&format!("Content-Length: {}\r\n", self.body.len()));
        }
        s.push_str("\r\n");
        let mut b = s.into_bytes();
        if !head_only && self.status != 204 && self.status != 304 {
            b.extend_from_slice(&self.body);
        }
        b
    }
}

/// O que atende os pedidos. Implementado pelos roteadores do app e do servidor.
pub trait Handler: Send + Sync {
    fn handle(&self, req: &Request) -> Response;
}

impl<F: Fn(&Request) -> Response + Send + Sync> Handler for F {
    fn handle(&self, req: &Request) -> Response {
        self(req)
    }
}

pub fn split_uri(uri: &str) -> (String, String) {
    let uri = uri.split('#').next().unwrap_or("");
    match uri.find('?') {
        Some(p) => (uri[..p].to_owned(), uri[p + 1..].to_owned()),
        None => (uri.to_owned(), String::new()),
    }
}

/// `%XX` e `+` decodificados (em UTF-8).
pub fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => {
                match u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("zz"), 16) {
                    Ok(v) => {
                        out.push(v);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn url_encode(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for &c in s.as_bytes() {
        if c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b'~') {
            o.push(c as char);
        } else {
            o.push_str(&format!("%{c:02X}"));
        }
    }
    o
}

pub fn query_pairs(q: &str) -> impl Iterator<Item = (String, String)> + '_ {
    q.split('&').filter(|p| !p.is_empty()).map(|p| match p.find('=') {
        Some(i) => (url_decode(&p[..i]), url_decode(&p[i + 1..])),
        None => (url_decode(p), String::new()),
    })
}

pub fn query_value(q: &str, name: &str) -> String {
    query_pairs(q).find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v).unwrap_or_default()
}

/// Troca (ou acrescenta) um parâmetro da query.
pub fn query_set(q: &str, name: &str, value: &str) -> String {
    let mut parts: Vec<String> = q.split('&').filter(|p| !p.is_empty()).filter(|p| !p.split('=').next().unwrap_or("").eq_ignore_ascii_case(name)).map(str::to_owned).collect();
    parts.push(format!("{}={}", url_encode(name), url_encode(value)));
    parts.join("&")
}

/// Tira um parâmetro da query.
pub fn query_remove(q: &str, name: &str) -> String {
    q.split('&').filter(|p| !p.is_empty() && !url_decode(p.split('=').next().unwrap_or("")).eq_ignore_ascii_case(name)).collect::<Vec<_>>().join("&")
}

pub const MAX_BODY: usize = 64 * 1024 * 1024;

/// Lê um pedido HTTP inteiro. `initial` são bytes já lidos por quem decidiu
/// que era HTTP (o listener do vmsserver, que divide a porta com o RTSP).
pub fn read_request(s: &mut TcpStream, initial: &mut Vec<u8>, idle: Duration) -> Result<Option<Request>> {
    let mut chunk = [0u8; 16 * 1024];
    let head_len = loop {
        if let Some(n) = find_header_end(initial) {
            break n;
        }
        if initial.len() > 64 * 1024 {
            return Err(Error::Protocol("cabecalho HTTP grande demais".into()));
        }
        s.set_read_timeout(Some(idle))?;
        let n = match s.read(&mut chunk) {
            Ok(0) => return Ok(None),
            Ok(n) => n,
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                return if initial.is_empty() { Ok(None) } else { Err(Error::Timeout("pedido HTTP".into())) };
            }
            Err(e) => return Err(e.into()),
        };
        initial.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&initial[..head_len]).into_owned();
    let q = parse_request_head(&head).ok_or_else(|| Error::Protocol("pedido HTTP invalido".into()))?;
    let clen = q.headers.content_length();
    if clen > MAX_BODY {
        return Err(Error::Protocol("corpo grande demais".into()));
    }
    while initial.len() < head_len + clen {
        s.set_read_timeout(Some(Duration::from_secs(30)))?;
        let n = s.read(&mut chunk)?;
        if n == 0 {
            return Err(Error::Io("conexao fechada no corpo".into()));
        }
        initial.extend_from_slice(&chunk[..n]);
    }
    let body = initial[head_len..head_len + clen].to_vec();
    initial.drain(..head_len + clen);
    let (path, query) = split_uri(&q.uri);
    Ok(Some(Request { method: q.method.to_ascii_uppercase(), path, query, headers: q.headers, body, peer: s.peer_addr().ok() }))
}

/// Atende uma conexão até ela fechar (keep-alive).
pub fn serve_connection(mut s: TcpStream, mut initial: Vec<u8>, handler: &dyn Handler) {
    let _ = s.set_nodelay(true);
    loop {
        let req = match read_request(&mut s, &mut initial, Duration::from_secs(60)) {
            Ok(Some(r)) => r,
            Ok(None) => return,
            Err(_) => {
                let _ = s.write_all(&Response::error(400, "pedido invalido").serialize(false));
                return;
            }
        };
        let close = req.header("Connection").is_some_and(|c| c.eq_ignore_ascii_case("close"));
        let resp = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler.handle(&req)))
            .unwrap_or_else(|_| Response::error(500, "falha interna"));
        let bytes = resp.serialize(req.method == "HEAD");
        let _ = s.set_write_timeout(Some(Duration::from_secs(60)));
        if s.write_all(&bytes).is_err() || close {
            return;
        }
    }
}

/// Um servidor HTTP simples: uma thread por conexão.
pub struct Server {
    addr: SocketAddr,
    stop: crate::stop::StopToken,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Server {
    pub fn start(bind: &str, handler: Arc<dyn Handler>) -> Result<Self> {
        let l = std::net::TcpListener::bind(bind).map_err(|e| Error::Io(format!("bind {bind}: {e}")))?;
        let addr = l.local_addr()?;
        l.set_nonblocking(true)?;
        let stop = crate::stop::StopToken::new();
        let st = stop.clone();
        let handle = std::thread::Builder::new()
            .name("http-accept".into())
            .spawn(move || {
                while !st.is_stopped() {
                    match l.accept() {
                        Ok((s, _)) => {
                            let _ = s.set_nonblocking(false);
                            let h = handler.clone();
                            let _ = std::thread::Builder::new().name("http-conn".into()).spawn(move || serve_connection(s, Vec::new(), &*h));
                        }
                        Err(_) => {
                            st.wait_ms(20);
                        }
                    }
                }
            })
            .map_err(|e| Error::Io(e.to_string()))?;
        Ok(Self { addr, stop, handle: Some(handle) })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn stop(&mut self) {
        self.stop.stop();
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}

// ------------------------------------------------------------------ cliente

/// Um pedido HTTP/1.1 simples (sem TLS): o que o app usa para falar com o
/// vmsserver e com o ONVIF das câmeras.
pub fn fetch(method: &str, url: &str, headers: &[(&str, &str)], body: &[u8], timeout: Duration) -> Result<Response> {
    let rest = url.strip_prefix("http://").ok_or_else(|| Error::Config(format!("so http:// e suportado: {url}")))?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    let (host, port) = match authority.rfind(':') {
        Some(c) if !authority.contains(']') => (&authority[..c], authority[c + 1..].parse().unwrap_or(80)),
        _ => (authority, 80),
    };
    let addr = crate::net::resolve(host, port)?;
    let mut s = TcpStream::connect_timeout(&addr, timeout).map_err(|e| Error::Io(format!("conectar {host}:{port}: {e}")))?;
    s.set_read_timeout(Some(timeout))?;
    s.set_write_timeout(Some(timeout))?;
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\nUser-Agent: vms-rust\r\n");
    for (n, v) in headers {
        req.push_str(&format!("{n}: {v}\r\n"));
    }
    if !body.is_empty() || method.eq_ignore_ascii_case("POST") || method.eq_ignore_ascii_case("PUT") {
        req.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    req.push_str("\r\n");
    s.write_all(req.as_bytes())?;
    s.write_all(body)?;
    let mut buf = Vec::new();
    s.read_to_end(&mut buf).or_else(|e| if buf.is_empty() { Err(e) } else { Ok(0) })?;
    // Câmera que não implementa a operação costuma só derrubar a conexão:
    // dizer isso é mais útil que "resposta sem cabeçalho".
    if buf.is_empty() {
        return Err(Error::Io(format!("{host}:{port} fechou a conexao sem responder (a operacao pode nao ser suportada)")));
    }
    parse_response(&buf)
}

fn parse_response(buf: &[u8]) -> Result<Response> {
    let n = find_header_end(buf).ok_or_else(|| Error::Protocol("resposta HTTP sem cabecalho".into()))?;
    let head = String::from_utf8_lossy(&buf[..n]).into_owned();
    let r = crate::rtsp::message::parse_response_head(&head).ok_or_else(|| Error::Protocol("resposta HTTP invalida".into()))?;
    let mut body = buf[n..].to_vec();
    if r.headers.get("Transfer-Encoding").is_some_and(|t| t.to_ascii_lowercase().contains("chunked")) {
        body = dechunk(&body);
    } else if let Some(cl) = r.headers.get("Content-Length").and_then(|v| v.trim().parse::<usize>().ok()) {
        body.truncate(cl);
    }
    let ctype = r.headers.get("Content-Type").unwrap_or("").to_owned();
    let headers = r.headers.iter().map(|(a, b)| (a.to_owned(), b.to_owned())).collect();
    Ok(Response { status: r.status, content_type: ctype, headers, body })
}

fn dechunk(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let Some(e) = b[i..].windows(2).position(|w| w == b"\r\n") else { break };
        let line = String::from_utf8_lossy(&b[i..i + e]);
        let size = usize::from_str_radix(line.split(';').next().unwrap_or("0").trim(), 16).unwrap_or(0);
        i += e + 2;
        if size == 0 || i + size > b.len() {
            break;
        }
        out.extend_from_slice(&b[i..i + size]);
        i += size + 2;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_e_codificacao() {
        let q = Request::new("get", "/api/days?camera=Frente%20Casa&day=2026-08-16&x");
        assert_eq!(q.method, "GET");
        assert_eq!(q.path, "/api/days");
        assert_eq!(q.param("CAMERA"), "Frente Casa");
        assert_eq!(q.param("nada"), "");
        assert!(q.has_param("x"));
        assert_eq!(url_decode("a+b%2Fc%zz"), "a b/c%zz");
        assert_eq!(url_encode("a b/ç"), "a%20b%2F%C3%A7");
        assert_eq!(query_value(&query_set("a=1&server=x", "server", "y z"), "server"), "y z");
        assert_eq!(query_remove("a=1&server=x&b=2", "server"), "a=1&b=2");
    }

    #[test]
    fn resposta_no_fio() {
        let r = Response::error(404, "nao achei").with_header("X-Vms-Cursor", "7");
        let s = String::from_utf8(r.serialize(false)).unwrap();
        assert!(s.starts_with("HTTP/1.1 404 Not Found\r\n"));
        assert!(s.contains("X-Vms-Cursor: 7\r\n"));
        assert!(s.ends_with("{\"error\":\"nao achei\"}"));
        let s = String::from_utf8(Response::empty(204).serialize(false)).unwrap();
        assert!(!s.contains("Content-Length"));
    }

    #[test]
    fn servidor_e_cliente_de_verdade() {
        let h: Arc<dyn Handler> = Arc::new(|q: &Request| {
            Response::json(&serde_json::json!({ "path": q.path, "camera": q.param("camera"), "body": q.body_text() }))
        });
        let mut srv = Server::start("127.0.0.1:0", h).unwrap();
        let url = format!("http://{}/api/x?camera=a%20b", srv.addr());
        let r = fetch("POST", &url, &[("Content-Type", "text/plain")], b"oi", Duration::from_secs(2)).unwrap();
        assert_eq!(r.status, 200);
        let j = r.json_value();
        assert_eq!(j["camera"], "a b");
        assert_eq!(j["body"], "oi");
        srv.stop();
    }

    #[test]
    fn chunked() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n";
        assert_eq!(parse_response(raw).unwrap().body, b"abcde");
    }
}
