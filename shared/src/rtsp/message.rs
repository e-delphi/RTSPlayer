//! Pedido e resposta RTSP: linha inicial, cabeçalhos e corpo. O formato é o
//! mesmo do HTTP/1.1, e o servidor HTTP usa estes mesmos tipos.

/// Cabeçalhos em ordem, comparados sem caixa.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Headers(Vec<(String, String)>);

impl Headers {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn add(&mut self, name: &str, value: &str) {
        self.0.push((name.to_owned(), value.to_owned()));
    }
    /// Troca o valor do primeiro com esse nome, ou acrescenta.
    pub fn set(&mut self, name: &str, value: &str) {
        match self.0.iter_mut().find(|(n, _)| n.eq_ignore_ascii_case(name)) {
            Some(h) => h.1 = value.to_owned(),
            None => self.add(name, value),
        }
    }
    pub fn get(&self, name: &str) -> Option<&str> {
        self.0.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
    pub fn has(&self, name: &str) -> bool {
        self.get(name).is_some()
    }
    pub fn remove(&mut self, name: &str) {
        self.0.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
    }
    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.0.iter().map(|(n, v)| (n.as_str(), v.as_str()))
    }
    pub fn len(&self) -> usize {
        self.0.len()
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn content_length(&self) -> usize {
        self.get("Content-Length").and_then(|v| v.trim().parse().ok()).unwrap_or(0)
    }
    fn write_to(&self, out: &mut String, body_len: usize) {
        for (n, v) in &self.0 {
            out.push_str(n);
            out.push_str(": ");
            out.push_str(v);
            out.push_str("\r\n");
        }
        if body_len > 0 && !self.has("Content-Length") {
            out.push_str(&format!("Content-Length: {body_len}\r\n"));
        }
        out.push_str("\r\n");
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    pub uri: String,
    pub version: String,
    pub headers: Headers,
    pub body: Vec<u8>,
}

impl Request {
    pub fn new(method: &str, uri: &str) -> Self {
        Self { method: method.into(), uri: uri.into(), version: "RTSP/1.0".into(), ..Default::default() }
    }

    pub fn serialize(&self) -> Vec<u8> {
        let mut s = format!("{} {} {}\r\n", self.method, self.uri, if self.version.is_empty() { "RTSP/1.0" } else { &self.version });
        self.headers.write_to(&mut s, self.body.len());
        let mut b = s.into_bytes();
        b.extend_from_slice(&self.body);
        b
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Response {
    pub version: String,
    pub status: u16,
    pub reason: String,
    pub headers: Headers,
    pub body: Vec<u8>,
}

impl Response {
    pub fn new(status: u16) -> Self {
        Self { version: "RTSP/1.0".into(), status, reason: status_text(status).into(), ..Default::default() }
    }

    pub fn serialize(&self) -> Vec<u8> {
        let ver = if self.version.is_empty() { "RTSP/1.0" } else { &self.version };
        let mut s = format!("{ver} {} {}\r\n", self.status, self.reason);
        self.headers.write_to(&mut s, self.body.len());
        let mut b = s.into_bytes();
        b.extend_from_slice(&self.body);
        b
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split('\n').map(|l| l.trim_end_matches('\r'))
}

fn parse_header_lines<'a>(it: impl Iterator<Item = &'a str>) -> Headers {
    let mut h = Headers::new();
    for line in it {
        if line.trim().is_empty() {
            continue;
        }
        let Some(p) = line.find(':') else { continue };
        if p < 1 {
            continue;
        }
        h.add(line[..p].trim(), line[p + 1..].trim());
    }
    h
}

/// A parte de cabeçalhos (até a linha em branco) de uma resposta.
pub fn parse_response_head(text: &str) -> Option<Response> {
    let mut it = lines(text);
    let status_line = it.next()?;
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next()?.to_owned();
    let status: u16 = parts.next()?.trim().parse().ok()?;
    let reason = parts.next().unwrap_or("").trim().to_owned();
    Some(Response { version, status, reason, headers: parse_header_lines(it), body: Vec::new() })
}

/// A parte de cabeçalhos de um pedido.
pub fn parse_request_head(text: &str) -> Option<Request> {
    let mut it = lines(text);
    let start = it.next()?;
    let mut parts = start.splitn(3, ' ');
    let method = parts.next()?.to_owned();
    let uri = parts.next()?.to_owned();
    let version = parts.next()?.trim().to_owned();
    if method.is_empty() || uri.is_empty() {
        return None;
    }
    Some(Request { method, uri, version, headers: parse_header_lines(it), body: Vec::new() })
}

/// Onde acaba o cabeçalho (`\r\n\r\n`), contando o terminador.
pub fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

pub fn status_text(code: u16) -> &'static str {
    match code {
        200 => "OK",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        454 => "Session Not Found",
        455 => "Method Not Valid in This State",
        456 => "Header Field Not Valid for Resource",
        461 => "Unsupported Transport",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pedido_serializado() {
        let mut r = Request::new("DESCRIBE", "rtsp://h/x");
        r.headers.add("CSeq", "2");
        r.headers.add("Accept", "application/sdp");
        assert_eq!(String::from_utf8(r.serialize()).unwrap(), "DESCRIBE rtsp://h/x RTSP/1.0\r\nCSeq: 2\r\nAccept: application/sdp\r\n\r\n");
        r.body = b"abc".to_vec();
        assert!(String::from_utf8(r.serialize()).unwrap().contains("Content-Length: 3\r\n\r\nabc"));
    }

    #[test]
    fn resposta_lida() {
        let r = parse_response_head("RTSP/1.0 401 Unauthorized\r\nCSeq: 1\r\nWWW-Authenticate: Digest realm=\"x\"\r\ncontent-length: 10\r\n\r\n").unwrap();
        assert_eq!(r.status, 401);
        assert_eq!(r.reason, "Unauthorized");
        assert_eq!(r.headers.get("www-authenticate"), Some("Digest realm=\"x\""));
        assert_eq!(r.headers.content_length(), 10);
        assert_eq!(parse_response_head("RTSP/1.0 200\r\n\r\n").unwrap().status, 200);
        assert!(parse_response_head("lixo").is_none());
    }

    #[test]
    fn pedido_lido_e_fim_de_cabecalho() {
        let q = parse_request_head("GET /api/days?camera=x HTTP/1.1\r\nHost: a\r\n\r\n").unwrap();
        assert_eq!((q.method.as_str(), q.uri.as_str(), q.version.as_str()), ("GET", "/api/days?camera=x", "HTTP/1.1"));
        assert_eq!(find_header_end(b"A\r\n\r\nbody"), Some(5));
        assert_eq!(find_header_end(b"A\r\n\r"), None);
    }

    #[test]
    fn headers_set_e_remove() {
        let mut h = Headers::new();
        h.add("A", "1");
        h.set("a", "2");
        assert_eq!(h.get("A"), Some("2"));
        assert_eq!(h.len(), 1);
        h.remove("A");
        assert!(h.is_empty());
    }
}
