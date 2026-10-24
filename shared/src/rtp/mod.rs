//! RTP: o pacote e o roteamento por canal interleaved ou payload type.

pub mod packet;

pub use packet::RtpPacket;

use crate::media::TrackKind;

/// Para onde vai cada pacote. Em TCP manda o canal interleaved; em UDP cada
/// trilha tem a sua porta, e o payload type desempata.
#[derive(Debug, Clone, Default)]
pub struct Demux {
    routes: Vec<Route>,
}

#[derive(Debug, Clone, Copy)]
struct Route {
    kind: TrackKind,
    payload_type: u8,
    channel: Option<u8>,
}

impl Demux {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, kind: TrackKind, payload_type: u8, channel: Option<u8>) {
        self.routes.push(Route { kind, payload_type, channel });
    }

    /// Quadro interleaved → (trilha, pacote). Canal ímpar é RTCP: fora.
    pub fn route_interleaved(&self, channel: u8, data: &[u8]) -> Option<(TrackKind, RtpPacket)> {
        if channel & 1 == 1 {
            return None;
        }
        let r = self.routes.iter().find(|r| r.channel == Some(channel))?;
        Some((r.kind, RtpPacket::parse(data)?))
    }

    /// Datagrama da porta de uma trilha → (trilha, pacote).
    pub fn route_udp(&self, port_kind: TrackKind, data: &[u8]) -> Option<(TrackKind, RtpPacket)> {
        let p = RtpPacket::parse(data)?;
        if let Some(r) = self.routes.iter().find(|r| r.payload_type == p.payload_type) {
            return Some((r.kind, p));
        }
        let r = self.routes.iter().find(|r| r.kind == port_kind)?;
        Some((r.kind, p))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pkt(pt: u8) -> Vec<u8> {
        RtpPacket { payload_type: pt, payload: vec![1], ..Default::default() }.serialize()
    }

    #[test]
    fn roteia_por_canal_e_por_tipo() {
        let mut d = Demux::new();
        d.register(TrackKind::Video, 96, Some(0));
        d.register(TrackKind::Audio, 8, Some(2));
        assert_eq!(d.route_interleaved(0, &pkt(96)).unwrap().0, TrackKind::Video);
        assert_eq!(d.route_interleaved(2, &pkt(8)).unwrap().0, TrackKind::Audio);
        assert!(d.route_interleaved(1, &pkt(96)).is_none(), "RTCP");
        assert!(d.route_interleaved(4, &pkt(96)).is_none());
        assert_eq!(d.route_udp(TrackKind::Video, &pkt(8)).unwrap().0, TrackKind::Audio);
        assert_eq!(d.route_udp(TrackKind::Video, &pkt(33)).unwrap().0, TrackKind::Video);
    }
}
