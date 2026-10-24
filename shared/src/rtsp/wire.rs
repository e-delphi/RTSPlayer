//! Lê o fluxo TCP do RTSP, onde mensagens de texto e quadros interleaved
//! (`$` canal tamanho payload) chegam misturados.
//!
//! O quadro interleaved é ATÔMICO: só é consumido com cabeçalho e payload
//! inteiros no buffer. Faltando, o prazo estoura SEM consumir — a próxima
//! leitura reencontra o mesmo `$` e continua, sem perder o sincronismo.
//!
//! Serve aos dois lados: o cliente lê respostas, o servidor lê pedidos (e o
//! RTCP que o player manda de volta).

use std::time::{Duration, Instant};

use super::message::{find_header_end, parse_request_head, parse_response_head, Request, Response};
use crate::error::{Error, Result};
use crate::net::TimedRead;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireEvent {
    /// Uma mensagem de texto inteira: cabeçalho e corpo.
    Message { head: String, body: Vec<u8> },
    Interleaved { channel: u8, data: Vec<u8> },
}

/// Teto de uma mensagem de texto: cabeçalho que não acaba nisto é lixo.
const MAX_HEAD: usize = 64 * 1024;

pub struct WireReader {
    buf: Vec<u8>,
    start: usize,
    chunk: Vec<u8>,
}

impl Default for WireReader {
    fn default() -> Self {
        Self::new()
    }
}

impl WireReader {
    pub fn new() -> Self {
        Self { buf: Vec::with_capacity(64 * 1024), start: 0, chunk: vec![0u8; 64 * 1024] }
    }

    pub fn available(&self) -> usize {
        self.buf.len() - self.start
    }

    /// O que sobrou no buffer: quem troca de leitor (ex.: o servidor que
    /// descobre que é HTTP) não pode perder esses bytes.
    pub fn take_buffered(&mut self) -> Vec<u8> {
        let v = self.buf[self.start..].to_vec();
        self.buf.clear();
        self.start = 0;
        v
    }

    /// Bytes já lidos por outro (quem espiou a primeira linha para decidir
    /// entre HTTP e RTSP) entram antes do que vier do socket.
    pub fn push_initial(&mut self, b: &[u8]) {
        self.buf.extend_from_slice(b);
    }

    fn compact(&mut self) {
        if self.start > 0 {
            self.buf.drain(..self.start);
            self.start = 0;
        }
    }

    /// Uma leitura do socket. `Ok(false)` = a outra ponta fechou.
    fn read_once(&mut self, conn: &mut dyn TimedRead, timeout: Duration) -> Result<bool> {
        if self.start > 32 * 1024 {
            self.compact();
        }
        let n = conn.read_timeout(&mut self.chunk, timeout)?;
        if n == 0 {
            return Ok(false);
        }
        self.buf.extend_from_slice(&self.chunk[..n]);
        Ok(true)
    }

    fn ensure(&mut self, conn: &mut dyn TimedRead, n: usize, deadline: Instant) -> Result<()> {
        while self.available() < n {
            let now = Instant::now();
            if now >= deadline {
                return Err(Error::Timeout("fio".into()));
            }
            if !self.read_once(conn, deadline - now)? {
                return Err(Error::Io("conexao fechada".into()));
            }
        }
        Ok(())
    }

    fn advance(&mut self, n: usize) {
        self.start += n;
        if self.start >= self.buf.len() {
            self.buf.clear();
            self.start = 0;
        }
    }

    /// O próximo evento, esperando até `timeout`.
    pub fn read_next(&mut self, conn: &mut dyn TimedRead, timeout: Duration) -> Result<WireEvent> {
        let deadline = Instant::now() + timeout;
        self.ensure(conn, 1, deadline)?;
        if self.buf[self.start] == b'$' {
            self.ensure(conn, 4, deadline)?;
            let ch = self.buf[self.start + 1];
            let len = u16::from_be_bytes([self.buf[self.start + 2], self.buf[self.start + 3]]) as usize;
            self.ensure(conn, 4 + len, deadline)?;
            let data = self.buf[self.start + 4..self.start + 4 + len].to_vec();
            self.advance(4 + len);
            return Ok(WireEvent::Interleaved { channel: ch, data });
        }
        let head_len = loop {
            if let Some(n) = find_header_end(&self.buf[self.start..]) {
                break n;
            }
            if self.available() > MAX_HEAD {
                return Err(Error::Protocol("cabecalho sem fim".into()));
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(Error::Timeout("cabecalho".into()));
            }
            if !self.read_once(conn, deadline - now)? {
                return Err(Error::Io("conexao fechada lendo cabecalho".into()));
            }
        };
        let head = String::from_utf8_lossy(&self.buf[self.start..self.start + head_len]).into_owned();
        let clen = content_length_of(&head);
        self.ensure(conn, head_len + clen, deadline)?;
        let body = self.buf[self.start + head_len..self.start + head_len + clen].to_vec();
        self.advance(head_len + clen);
        Ok(WireEvent::Message { head, body })
    }

    /// A próxima RESPOSTA, pulando quadros interleaved no caminho.
    pub fn read_response(&mut self, conn: &mut dyn TimedRead, timeout: Duration) -> Result<Response> {
        let deadline = Instant::now() + timeout;
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err(Error::Timeout("resposta RTSP".into()));
            }
            match self.read_next(conn, deadline - now)? {
                WireEvent::Message { head, body } => {
                    let mut r = parse_response_head(&head).ok_or_else(|| Error::Protocol("resposta RTSP invalida".into()))?;
                    r.body = body;
                    return Ok(r);
                }
                WireEvent::Interleaved { .. } => continue,
            }
        }
    }
}

fn content_length_of(head: &str) -> usize {
    for line in head.split('\n') {
        if let Some(p) = line.find(':') {
            if line[..p].trim().eq_ignore_ascii_case("content-length") {
                return line[p + 1..].trim().parse().unwrap_or(0);
            }
        }
    }
    0
}

/// Um evento de texto lido como pedido (lado do servidor).
pub fn as_request(head: &str, body: Vec<u8>) -> Option<Request> {
    let mut r = parse_request_head(head)?;
    r.body = body;
    Some(r)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::MemConn;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn resposta_com_corpo_e_quadros_no_meio() {
        let mut input = vec![b'$', 0, 0, 3, 9, 9, 9];
        input.extend_from_slice(b"RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 4\r\n\r\nv=0\n");
        input.extend_from_slice(&[b'$', 2, 0, 1, 7]);
        let mut c = MemConn::new(&input);
        c.chunk = 3; // chega aos pedaços
        let mut w = WireReader::new();
        assert_eq!(w.read_next(&mut c, ms(100)).unwrap(), WireEvent::Interleaved { channel: 0, data: vec![9, 9, 9] });
        let r = w.read_response(&mut c, ms(100)).unwrap();
        assert_eq!(r.status, 200);
        assert_eq!(r.body, b"v=0\n");
        assert_eq!(w.read_next(&mut c, ms(100)).unwrap(), WireEvent::Interleaved { channel: 2, data: vec![7] });
    }

    #[test]
    fn quadro_incompleto_nao_e_consumido() {
        let mut c = MemConn::new(&[b'$', 0, 0, 4, 1, 2]);
        let mut w = WireReader::new();
        assert!(w.read_next(&mut c, ms(10)).unwrap_err().is_timeout());
        c.push(&[3, 4]);
        assert_eq!(w.read_next(&mut c, ms(10)).unwrap(), WireEvent::Interleaved { channel: 0, data: vec![1, 2, 3, 4] });
    }

    #[test]
    fn fechada_e_pedido() {
        let mut c = MemConn::new(b"OPTIONS rtsp://h/ RTSP/1.0\r\nCSeq: 5\r\n\r\n");
        c.closed = true;
        let mut w = WireReader::new();
        let WireEvent::Message { head, body } = w.read_next(&mut c, ms(10)).unwrap() else { panic!() };
        let q = as_request(&head, body).unwrap();
        assert_eq!(q.method, "OPTIONS");
        assert_eq!(q.headers.get("cseq"), Some("5"));
        assert!(matches!(w.read_next(&mut c, ms(10)), Err(Error::Io(_))));
    }
}
