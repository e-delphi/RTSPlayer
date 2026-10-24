//! O cabeçalho `Transport` do SETUP: o que se pede e o que o servidor aceitou.

use crate::media::Transport;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportSpec {
    pub kind: Transport,
    pub interleaved_rtp: u8,
    pub interleaved_rtcp: u8,
    pub client_rtp_port: u16,
    pub client_rtcp_port: u16,
    pub server_rtp_port: u16,
    pub server_rtcp_port: u16,
    pub ssrc: u32,
    pub source: String,
    pub declared: String,
}

impl TransportSpec {
    pub fn tcp(rtp: u8) -> Self {
        Self { kind: Transport::Tcp, interleaved_rtp: rtp, interleaved_rtcp: rtp + 1, ..Self::empty() }
    }

    pub fn udp(rtp: u16, rtcp: u16) -> Self {
        Self { kind: Transport::Udp, client_rtp_port: rtp, client_rtcp_port: rtcp, ..Self::empty() }
    }

    fn empty() -> Self {
        Self {
            kind: Transport::Tcp,
            interleaved_rtp: 0,
            interleaved_rtcp: 1,
            client_rtp_port: 0,
            client_rtcp_port: 0,
            server_rtp_port: 0,
            server_rtcp_port: 0,
            ssrc: 0,
            source: String::new(),
            declared: String::new(),
        }
    }

    pub fn header(&self) -> String {
        match self.kind {
            Transport::Tcp => format!("RTP/AVP/TCP;unicast;interleaved={}-{}", self.interleaved_rtp, self.interleaved_rtcp),
            Transport::Udp => format!("RTP/AVP;unicast;client_port={}-{}", self.client_rtp_port, self.client_rtcp_port),
        }
    }

    /// Lê o que veio, por cima do que foi pedido. `false` se nem o perfil veio.
    pub fn apply_response(&mut self, header: &str) -> bool {
        self.declared = header.trim().to_owned();
        let mut ok = false;
        for tok in header.split(';').map(str::trim) {
            if tok.eq_ignore_ascii_case("RTP/AVP/TCP") {
                self.kind = Transport::Tcp;
                ok = true;
            } else if tok.eq_ignore_ascii_case("RTP/AVP") || tok.eq_ignore_ascii_case("RTP/AVP/UDP") {
                self.kind = Transport::Udp;
                ok = true;
            } else if let Some(v) = param(tok, "interleaved") {
                let (a, b) = port_pair(v);
                self.interleaved_rtp = a as u8;
                self.interleaved_rtcp = b as u8;
                self.kind = Transport::Tcp;
            } else if let Some(v) = param(tok, "client_port") {
                (self.client_rtp_port, self.client_rtcp_port) = port_pair(v);
            } else if let Some(v) = param(tok, "server_port") {
                (self.server_rtp_port, self.server_rtcp_port) = port_pair(v);
            } else if let Some(v) = param(tok, "ssrc") {
                self.ssrc = u32::from_str_radix(v.trim(), 16).unwrap_or(0);
            } else if let Some(v) = param(tok, "source") {
                self.source = v.to_owned();
            }
        }
        ok
    }
}

fn param<'a>(tok: &'a str, name: &str) -> Option<&'a str> {
    let p = tok.find('=')?;
    tok[..p].trim().eq_ignore_ascii_case(name).then(|| &tok[p + 1..])
}

fn port_pair(s: &str) -> (u16, u16) {
    let mut it = s.split('-');
    let a: u16 = it.next().and_then(|x| x.trim().parse().ok()).unwrap_or(0);
    let b: u16 = it.next().and_then(|x| x.trim().parse().ok()).unwrap_or(0);
    (a, if b == 0 { a.wrapping_add(1) } else { b })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pede_e_le() {
        assert_eq!(TransportSpec::tcp(2).header(), "RTP/AVP/TCP;unicast;interleaved=2-3");
        assert_eq!(TransportSpec::udp(5000, 5001).header(), "RTP/AVP;unicast;client_port=5000-5001");
        let mut t = TransportSpec::udp(5000, 5001);
        assert!(t.apply_response("RTP/AVP;unicast;client_port=5000-5001;server_port=6970-6971;ssrc=1A2B3C4D;source=10.0.0.5"));
        assert_eq!((t.server_rtp_port, t.server_rtcp_port), (6970, 6971));
        assert_eq!(t.ssrc, 0x1A2B3C4D);
        assert_eq!(t.source, "10.0.0.5");
        let mut t = TransportSpec::tcp(0);
        assert!(t.apply_response("RTP/AVP/TCP;unicast;interleaved=4-5"));
        assert_eq!((t.interleaved_rtp, t.interleaved_rtcp), (4, 5));
        assert!(!TransportSpec::tcp(0).apply_response("lixo"));
    }
}
