//! Rede: TCP com prazo, o par UDP do RTP, e a escolha de caminho até a câmera.
//!
//! O que lê do socket depende de [`TimedRead`], e não do `TcpStream`: os
//! protocolos (RTSP, DVRIP) são testados contra um fluxo em memória.

use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::time::{Duration, Instant};

use crate::error::{Error, Result};
use crate::log::Logger;
use crate::stop::StopToken;

/// Leitura com prazo. `Ok(0)` = a outra ponta fechou; `Err(Timeout)` = nada
/// chegou no prazo, e o fluxo continua bom.
pub trait TimedRead {
    fn read_timeout(&mut self, buf: &mut [u8], timeout: Duration) -> Result<usize>;
}

/// Um fluxo de mão dupla: o que as sessões de câmera usam.
pub trait Conn: TimedRead + Send {
    fn send(&mut self, data: &[u8]) -> Result<()>;
    fn shutdown(&mut self);
}

pub struct TcpConn {
    s: TcpStream,
}

/// Resolve `host:port`, preferindo IPv4 (as câmeras são IPv4).
pub fn resolve(host: &str, port: u16) -> Result<SocketAddr> {
    let mut addrs: Vec<SocketAddr> = (host, port).to_socket_addrs().map_err(|e| Error::Io(format!("resolver {host}: {e}")))?.collect();
    addrs.sort_by_key(|a| !a.is_ipv4());
    addrs.into_iter().next().ok_or_else(|| Error::Io(format!("{host} nao resolve")))
}

impl TcpConn {
    pub fn connect(host: &str, port: u16, timeout_ms: u64) -> Result<Self> {
        let addr = resolve(host, port)?;
        let s = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms.max(1)))
            .map_err(|e| Error::Io(format!("conectar {host}:{port}: {e}")))?;
        let _ = s.set_nodelay(true);
        Ok(Self { s })
    }

    pub fn from_stream(s: TcpStream) -> Self {
        Self { s }
    }

    pub fn try_clone(&self) -> Result<Self> {
        Ok(Self { s: self.s.try_clone()? })
    }

    pub fn peer(&self) -> Option<SocketAddr> {
        self.s.peer_addr().ok()
    }

    pub fn local(&self) -> Option<SocketAddr> {
        self.s.local_addr().ok()
    }

    pub fn stream(&self) -> &TcpStream {
        &self.s
    }
}

impl TimedRead for TcpConn {
    fn read_timeout(&mut self, buf: &mut [u8], timeout: Duration) -> Result<usize> {
        self.s.set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        match self.s.read(buf) {
            Ok(n) => Ok(n),
            Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {
                Err(Error::Timeout("leitura".into()))
            }
            Err(e) => Err(Error::Io(format!("tcp: {e}"))),
        }
    }
}

impl Conn for TcpConn {
    fn send(&mut self, data: &[u8]) -> Result<()> {
        self.s.set_write_timeout(Some(Duration::from_secs(10)))?;
        self.s.write_all(data).map_err(|e| Error::Io(format!("tcp envio: {e}")))
    }
    fn shutdown(&mut self) {
        let _ = self.s.shutdown(std::net::Shutdown::Both);
    }
}

/// Fluxo em memória para teste: entrega o que foi programado e guarda o que
/// foi enviado.
#[derive(Default)]
pub struct MemConn {
    pub input: std::collections::VecDeque<u8>,
    pub output: Vec<u8>,
    /// Máximo de bytes por leitura (simula o TCP entregando aos pedaços).
    pub chunk: usize,
    pub closed: bool,
}

impl MemConn {
    pub fn new(input: &[u8]) -> Self {
        Self { input: input.iter().copied().collect(), output: Vec::new(), chunk: usize::MAX, closed: false }
    }
    pub fn push(&mut self, more: &[u8]) {
        self.input.extend(more.iter().copied());
    }
}

impl TimedRead for MemConn {
    fn read_timeout(&mut self, buf: &mut [u8], _t: Duration) -> Result<usize> {
        if self.input.is_empty() {
            return if self.closed { Ok(0) } else { Err(Error::Timeout("mem".into())) };
        }
        let n = buf.len().min(self.input.len()).min(self.chunk.max(1));
        for b in buf.iter_mut().take(n) {
            *b = self.input.pop_front().unwrap();
        }
        Ok(n)
    }
}

impl Conn for MemConn {
    fn send(&mut self, data: &[u8]) -> Result<()> {
        self.output.extend_from_slice(data);
        Ok(())
    }
    fn shutdown(&mut self) {
        self.closed = true;
    }
}

// ------------------------------------------------------------------ UDP

/// O par RTP/RTCP de uma trilha: duas portas vizinhas, a de RTP par.
pub struct UdpPair {
    pub rtp: UdpSocket,
    pub rtcp: UdpSocket,
}

impl UdpPair {
    /// Acha um par livre (RTP par, RTCP = RTP+1).
    pub fn bind(host: &str) -> Result<Self> {
        let ip: IpAddr = host.parse().unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
        for _ in 0..50 {
            let probe = UdpSocket::bind((ip, 0))?;
            let p = probe.local_addr()?.port();
            drop(probe);
            let base = if p % 2 == 0 { p } else { p.wrapping_add(1) };
            if base == 0 || base == u16::MAX {
                continue;
            }
            if let (Ok(a), Ok(b)) = (UdpSocket::bind((ip, base)), UdpSocket::bind((ip, base + 1))) {
                let _ = a.set_read_timeout(Some(Duration::from_millis(100)));
                let _ = b.set_read_timeout(Some(Duration::from_millis(1)));
                return Ok(Self { rtp: a, rtcp: b });
            }
        }
        Err(Error::Io("nao achei par de portas UDP livre".into()))
    }

    pub fn rtp_port(&self) -> u16 {
        self.rtp.local_addr().map(|a| a.port()).unwrap_or(0)
    }
    pub fn rtcp_port(&self) -> u16 {
        self.rtcp.local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// Um pacote RTP, esperando até `ms` (0 = só o que já está na fila).
    pub fn recv_rtp(&self, buf: &mut [u8], ms: u64) -> Option<usize> {
        recv_with(&self.rtp, buf, ms)
    }
    pub fn recv_rtcp(&self, buf: &mut [u8], ms: u64) -> Option<usize> {
        recv_with(&self.rtcp, buf, ms)
    }
}

fn recv_with(s: &UdpSocket, buf: &mut [u8], ms: u64) -> Option<usize> {
    if ms == 0 {
        let _ = s.set_nonblocking(true);
        let r = s.recv(buf).ok();
        let _ = s.set_nonblocking(false);
        return r;
    }
    let _ = s.set_read_timeout(Some(Duration::from_millis(ms)));
    s.recv(buf).ok()
}

// ------------------------------------------------------------------ caminhos

/// Curto: são até N caminhos em série antes de conectar.
pub const PROBE_TIMEOUT_MS: u64 = 700;

/// Host e porta de uma URL `rtsp://`, `dvrip://` ou `http://`, com a porta
/// padrão do esquema.
pub fn host_port_of_url(url: &str) -> Option<(String, u16)> {
    let s = url.trim();
    let p = s.find("://")?;
    if p < 1 {
        return None;
    }
    let scheme = s[..p].to_ascii_lowercase();
    let rest = &s[p + 3..];
    let mut authority = rest.split('/').next().unwrap_or("");
    if let Some(at) = authority.rfind('@') {
        authority = &authority[at + 1..];
    }
    if authority.is_empty() || authority.contains(']') {
        return None;
    }
    let (host, port) = match authority.rfind(':') {
        Some(c) => (&authority[..c], authority[c + 1..].parse::<u16>().unwrap_or(0)),
        None => (authority, 0),
    };
    let port = if port != 0 {
        port
    } else {
        match scheme.as_str() {
            "dvrip" => 34567,
            "http" => 80,
            "https" => 443,
            _ => 554,
        }
    };
    (!host.is_empty()).then(|| (host.to_owned(), port))
}

/// Alcança? Um TCP connect, sem nada por cima.
pub fn host_reachable(host: &str, port: u16, timeout_ms: u64) -> bool {
    if host.is_empty() || port == 0 {
        return false;
    }
    let Ok(addr) = resolve(host, port) else { return false };
    TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms.max(1))).is_ok()
}

pub fn url_reachable(url: &str, timeout_ms: u64) -> bool {
    host_port_of_url(url).is_some_and(|(h, p)| host_reachable(&h, p, timeout_ms))
}

/// Primeiro caminho que responde, na ordem. `None` se nenhum.
pub fn select_endpoint(urls: &[(&str, &str)], log: &dyn Logger, tag: &str, timeout_ms: u64) -> Option<usize> {
    for (i, (name, url)) in urls.iter().enumerate() {
        if url.trim().is_empty() {
            continue;
        }
        let Some((h, p)) = host_port_of_url(url) else { continue };
        if host_reachable(&h, p, timeout_ms) {
            log.info(tag, &format!("conexao por \"{name}\" ({h}:{p} responde)"));
            return Some(i);
        }
        log.debug(tag, &format!("\"{name}\" ({h}:{p}) nao respondeu em {timeout_ms} ms"));
    }
    None
}

// ------------------------------------------------------------------ tailnet

pub const TAILNET_WAIT_MS: u64 = 30_000;
pub const TAILNET_PROBE_MS: u64 = 1500;

fn in_cgnat(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    o[0] == 100 && (64..=127).contains(&o[1])
}

/// 100.64.0.0/10 (o que o Tailscale distribui) ou `*.ts.net`.
pub fn looks_like_tailnet_host(host: &str) -> bool {
    let h = host.trim().to_ascii_lowercase();
    if h.ends_with(".ts.net") {
        return true;
    }
    h.parse::<Ipv4Addr>().is_ok_and(in_cgnat)
}

/// O nome resolve para DENTRO da faixa da tailnet? Operadora que responde
/// NXDOMAIN com página própria devolve IP público para `x.ts.net` — e um
/// connect nele "alcança" a operadora, não a tailnet.
pub fn resolves_into_tailnet(host: &str) -> bool {
    if let Ok(ip) = host.parse::<Ipv4Addr>() {
        return in_cgnat(ip);
    }
    (host, 0u16).to_socket_addrs().is_ok_and(|mut it| it.any(|a| matches!(a.ip(), IpAddr::V4(v4) if in_cgnat(v4))))
}

/// Há rota ATÉ A TAILNET para este host?
pub fn tailnet_reachable(host: &str, port: u16, timeout_ms: u64) -> bool {
    if looks_like_tailnet_host(host) && !resolves_into_tailnet(host) {
        return false;
    }
    host_reachable(host, port, timeout_ms)
}

/// Espera a rota até a câmera da tailnet. No Windows o Tailscale é serviço do
/// sistema: não há app a abrir, então isto é só a espera. `false` no fim do
/// prazo — quem chamou tenta conectar assim mesmo (o erro de conexão diz mais).
pub fn ensure_tailnet_up(host: &str, port: u16, log: &dyn Logger, stop: Option<&StopToken>, timeout_ms: u64) -> bool {
    if tailnet_reachable(host, port, TAILNET_PROBE_MS) {
        return true;
    }
    log.info("tailscale", &format!("{host}:{port} sem rota; aguardando a VPN ate {} s", timeout_ms / 1000));
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    while Instant::now() < deadline {
        if let Some(s) = stop {
            if s.wait_ms(1000) {
                return false;
            }
        } else {
            std::thread::sleep(Duration::from_millis(1000));
        }
        if tailnet_reachable(host, port, TAILNET_PROBE_MS) {
            log.info("tailscale", &format!("{host}:{port} alcancavel"));
            return true;
        }
    }
    log.warn("tailscale", &format!("{host}:{port} continua sem rota depois de {} s", timeout_ms / 1000));
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_e_porta_da_url() {
        assert_eq!(host_port_of_url("rtsp://admin:x@192.168.1.9:555/onvif1"), Some(("192.168.1.9".into(), 555)));
        assert_eq!(host_port_of_url("rtsp://cam/x"), Some(("cam".into(), 554)));
        assert_eq!(host_port_of_url("dvrip://10.0.0.2"), Some(("10.0.0.2".into(), 34567)));
        assert_eq!(host_port_of_url("http://h:8080/onvif"), Some(("h".into(), 8080)));
        assert_eq!(host_port_of_url("lixo"), None);
        assert_eq!(host_port_of_url("rtsp://[::1]:554/"), None);
    }

    #[test]
    fn faixa_da_tailnet() {
        assert!(looks_like_tailnet_host("100.102.246.119"));
        assert!(looks_like_tailnet_host("casa.tail1234.ts.net"));
        assert!(!looks_like_tailnet_host("100.128.0.1"));
        assert!(!looks_like_tailnet_host("192.168.0.1"));
        assert!(resolves_into_tailnet("100.64.0.1"));
    }

    #[test]
    fn porta_fechada_nao_alcanca_e_aberta_alcanca() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        assert!(host_reachable("127.0.0.1", port, 500));
        drop(l);
        assert!(!host_reachable("", 1, 10));
        let log = crate::log::NullLogger;
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let ok = format!("rtsp://127.0.0.1:{}/", l.local_addr().unwrap().port());
        let urls = [("morto", "rtsp://127.0.0.1:1/"), ("vivo", ok.as_str())];
        assert_eq!(select_endpoint(&urls, &log, "t", 300), Some(1));
    }

    #[test]
    fn par_udp_e_vizinho_e_par() {
        let u = UdpPair::bind("127.0.0.1").unwrap();
        assert_eq!(u.rtp_port() % 2, 0);
        assert_eq!(u.rtcp_port(), u.rtp_port() + 1);
        let s = UdpSocket::bind("127.0.0.1:0").unwrap();
        s.send_to(b"oi", ("127.0.0.1", u.rtp_port())).unwrap();
        let mut b = [0u8; 10];
        assert_eq!(u.recv_rtp(&mut b, 500), Some(2));
        assert_eq!(u.recv_rtp(&mut b, 0), None);
    }
}
