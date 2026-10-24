//! A configuração de uma sessão de câmera: o que o supervisor entrega à sessão
//! a cada tentativa.

use crate::media::Transport;
use crate::rtsp::KeepAliveMethod;
use crate::vms::BlockLimits;

/// Um jeito de chegar na MESMA câmera (LAN, servidor da casa, tailnet).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CameraEndpoint {
    /// Só para a tela: `Local`, `Online`, `Direto`.
    pub name: String,
    pub url: String,
    pub user: String,
    pub password: String,
    pub transports: Vec<Transport>,
    pub uses_tailscale: bool,
}

#[derive(Debug, Clone)]
pub struct CameraConfig {
    pub name: String,
    pub url: String,
    pub user: String,
    pub password: String,
    pub transports: Vec<Transport>,
    pub record_audio: bool,
    pub filename_pattern: String,
    pub storage_dir: std::path::PathBuf,
    pub no_rtp_timeout_ms: u64,
    pub transport_fallback_timeout_ms: u64,
    pub keep_alive: KeepAliveMethod,
    pub block: BlockLimits,
    /// De quanto em quanto a gravação roda de arquivo. 0 = nunca.
    pub rotate_ms: i64,
    pub connect_timeout_ms: u64,
    pub rtsp_timeout_ms: u64,
    /// A sessão RTSP grava sozinha (o DVRIP não: ver o sink de gravação).
    pub record_enabled: bool,
    /// 0 = reconecta pra sempre.
    pub max_reconnect_attempts: u32,
    pub uses_tailscale: bool,
    /// Caminhos alternativos em ordem de prioridade; o supervisor escolhe um
    /// antes de CADA tentativa e copia para os campos de cima.
    pub endpoints: Vec<CameraEndpoint>,
    pub reconnect_initial_ms: u64,
    pub reconnect_max_ms: u64,
    pub reconnect_multiplier: f64,
}

impl Default for CameraConfig {
    fn default() -> Self {
        Self {
            name: String::new(),
            url: String::new(),
            user: String::new(),
            password: String::new(),
            transports: vec![Transport::Tcp, Transport::Udp],
            record_audio: true,
            filename_pattern: String::new(),
            storage_dir: "recordings".into(),
            no_rtp_timeout_ms: 10_000,
            transport_fallback_timeout_ms: 5000,
            keep_alive: KeepAliveMethod::GetParameter,
            block: BlockLimits::default(),
            rotate_ms: 0,
            connect_timeout_ms: 5000,
            rtsp_timeout_ms: 10_000,
            record_enabled: false,
            max_reconnect_attempts: 0,
            uses_tailscale: false,
            endpoints: Vec::new(),
            reconnect_initial_ms: 2000,
            reconnect_max_ms: 30_000,
            reconnect_multiplier: 2.0,
        }
    }
}

impl CameraConfig {
    pub fn is_dvrip(&self) -> bool {
        self.url.trim().to_ascii_lowercase().starts_with("dvrip")
    }

    /// A config desta tentativa, com o caminho escolhido no lugar.
    pub fn with_endpoint(&self, e: &CameraEndpoint) -> Self {
        let mut c = self.clone();
        c.url = e.url.clone();
        c.user = e.user.clone();
        c.password = e.password.clone();
        if !e.transports.is_empty() {
            c.transports = e.transports.clone();
        }
        c.uses_tailscale = e.uses_tailscale;
        c
    }
}

/// O nome do arquivo de gravação: `{name}_{yyyy-MM-dd_HH-mm-ss}.vms` por padrão,
/// na hora local. `{yyyy}`, `{MM}`, `{dd}`, `{HH}`, `{mm}`, `{ss}` também valem.
pub fn format_filename(pattern: &str, name: &str, creation_utc_ms: i64) -> String {
    let p = if pattern.is_empty() { "{name}_{yyyy-MM-dd_HH-mm-ss}.vms" } else { pattern };
    let t = crate::clock::local_from_utc_ms(creation_utc_ms);
    let mut s = replace_ci(p, "{name}", name);
    s = s.replace("{yyyy-MM-dd_HH-mm-ss}", &t.file_stamp());
    s = s.replace("{yyyy}", &format!("{:04}", t.year));
    s = s.replace("{MM}", &format!("{:02}", t.month));
    s = s.replace("{dd}", &format!("{:02}", t.day));
    s = s.replace("{HH}", &format!("{:02}", t.hour));
    s = s.replace("{mm}", &format!("{:02}", t.minute));
    s = s.replace("{ss}", &format!("{:02}", t.second));
    s
}

fn replace_ci(s: &str, pat: &str, with: &str) -> String {
    let low = s.to_ascii_lowercase();
    let lp = pat.to_ascii_lowercase();
    let mut out = String::new();
    let mut i = 0;
    while let Some(p) = low[i..].find(&lp) {
        out.push_str(&s[i..i + p]);
        out.push_str(with);
        i += p + pat.len();
    }
    out.push_str(&s[i..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nome_do_arquivo() {
        crate::clock::force_local_offset_ms(0);
        let ms = crate::clock::days_from_civil(2026, 8, 16) * 86_400_000 + 18 * 3_600_000 + 37 * 60_000 + 57_000;
        assert_eq!(format_filename("", "frente", ms), "frente_2026-08-16_18-37-57.vms");
        assert_eq!(format_filename("{NAME}-{yyyy}{MM}{dd}.vms", "x", ms), "x-20260816.vms");
    }

    #[test]
    fn caminho_escolhido_substitui() {
        let c = CameraConfig { url: "rtsp://a".into(), ..Default::default() };
        let e = CameraEndpoint { url: "dvrip://b".into(), user: "u".into(), uses_tailscale: true, ..Default::default() };
        let t = c.with_endpoint(&e);
        assert!(t.is_dvrip());
        assert!(t.uses_tailscale);
        assert_eq!(t.transports, c.transports, "lista vazia mantém a da câmera");
    }
}
