//! O cadastro de câmeras em JSON — o `cameras.json` do app e o `vmsserver.json`
//! antigo do servidor têm o MESMO formato, lido por uma função só (ler
//! diferente nos dois lados já fez o app carregar só o primeiro caminho).
//!
//! ```json
//! { "name": "Frente", "enabled": true,
//!   "endpoints": [ { "name": "Local", "url": "rtsp://…", "user": "…",
//!                    "password": "…", "transport": "tcp,udp", "tailscale": false } ],
//!   "recordAudio": true, "maxRetries": 0, "audioDelayMs": 200, "videoDelayMs": 200,
//!   "reconnect": { "initialDelayMs": 2000, "maxDelayMs": 30000,
//!                  "backoffMultiplier": 2.0, "noRtpTimeoutMs": 10000 },
//!   "ptz": "" }
//! ```
//!
//! O formato antigo (uma `url` solta) vira uma câmera de um caminho só.

use serde_json::{json, Map, Value};

use crate::camera::{CameraConfig, CameraEndpoint};
use crate::media::Transport;

#[derive(Debug, Clone, PartialEq)]
pub struct Reconnect {
    pub initial_ms: u64,
    pub max_ms: u64,
    pub multiplier: f64,
    pub no_rtp_timeout_ms: u64,
}

impl Default for Reconnect {
    fn default() -> Self {
        Self { initial_ms: 2000, max_ms: 30_000, multiplier: 2.0, no_rtp_timeout_ms: 10_000 }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CameraEntry {
    pub name: String,
    pub enabled: bool,
    pub endpoints: Vec<CameraEndpoint>,
    pub record_audio: bool,
    pub filename_pattern: String,
    pub reconnect: Reconnect,
    pub max_retries: u32,
    pub audio_delay_ms: i64,
    pub video_delay_ms: i64,
    /// Onde falar ONVIF (`ip`, `ip:porta`, URL) ou `dvrip://…` para PTZ.
    pub ptz: String,
    /// O que mais veio no objeto e não é desta struct: volta igual na
    /// gravação, para a tela poder guardar campos que só ela conhece.
    pub extra: Map<String, Value>,
}

impl Default for CameraEntry {
    fn default() -> Self {
        Self {
            name: String::new(),
            enabled: true,
            endpoints: Vec::new(),
            record_audio: true,
            filename_pattern: "{name}_{yyyy-MM-dd_HH-mm-ss}.vms".into(),
            reconnect: Reconnect::default(),
            max_retries: 0,
            audio_delay_ms: 200,
            video_delay_ms: 200,
            ptz: String::new(),
            extra: Map::new(),
        }
    }
}

impl CameraEntry {
    /// O primeiro caminho: é o que a lista mostra e o padrão.
    pub fn first(&self) -> Option<&CameraEndpoint> {
        self.endpoints.first()
    }

    pub fn url(&self) -> &str {
        self.first().map(|e| e.url.as_str()).unwrap_or("")
    }

    /// A config de sessão desta câmera (os campos de topo espelham o
    /// primeiro caminho; o supervisor escolhe o caminho a cada tentativa).
    pub fn to_session_config(&self, base: &CameraConfig) -> CameraConfig {
        let mut c = base.clone();
        c.name = self.name.clone();
        c.endpoints = if self.endpoints.len() > 1 { self.endpoints.clone() } else { Vec::new() };
        if let Some(e) = self.first() {
            c = c.with_endpoint(e);
            c.endpoints = if self.endpoints.len() > 1 { self.endpoints.clone() } else { Vec::new() };
        }
        c.record_audio = self.record_audio;
        c.filename_pattern = self.filename_pattern.clone();
        c.max_reconnect_attempts = self.max_retries;
        c.reconnect_initial_ms = self.reconnect.initial_ms;
        c.reconnect_max_ms = self.reconnect.max_ms;
        c.reconnect_multiplier = self.reconnect.multiplier;
        c.no_rtp_timeout_ms = self.reconnect.no_rtp_timeout_ms;
        c
    }
}

fn s(o: &Map<String, Value>, k: &str, d: &str) -> String {
    match o.get(k) {
        Some(Value::String(v)) => v.clone(),
        Some(Value::Null) | None => d.to_owned(),
        Some(v) => v.to_string(),
    }
}

fn b(o: &Map<String, Value>, k: &str, d: bool) -> bool {
    o.get(k).and_then(Value::as_bool).unwrap_or(d)
}

fn i(o: &Map<String, Value>, k: &str, d: i64) -> i64 {
    o.get(k).and_then(|v| v.as_f64()).map(|f| f as i64).unwrap_or(d)
}

fn f(o: &Map<String, Value>, k: &str, d: f64) -> f64 {
    o.get(k).and_then(Value::as_f64).unwrap_or(d)
}

fn transports(v: Option<&Value>) -> Vec<Transport> {
    match v {
        Some(Value::String(t)) => Transport::parse_list(t),
        _ => vec![Transport::Tcp, Transport::Udp],
    }
}

pub fn parse_endpoint(o: &Map<String, Value>, index: usize) -> CameraEndpoint {
    let mut name = s(o, "name", "");
    if name.is_empty() {
        name = s(o, "label", "");
    }
    if name.is_empty() {
        name = format!("conexão {}", index + 1);
    }
    CameraEndpoint {
        name,
        url: s(o, "url", "").trim().to_owned(),
        user: s(o, "user", ""),
        password: s(o, "password", ""),
        transports: transports(o.get("transport")),
        uses_tailscale: b(o, "tailscale", false),
    }
}

const KNOWN: &[&str] = &["name", "enabled", "endpoints", "url", "user", "password", "transport", "tailscale", "recordAudio", "filenamePattern", "reconnect", "maxRetries", "audioDelayMs", "videoDelayMs", "ptz"];

pub fn parse_camera(v: &Value) -> Option<CameraEntry> {
    let o = v.as_object()?;
    let mut c = CameraEntry { name: s(o, "name", "").trim().to_owned(), enabled: b(o, "enabled", true), ..Default::default() };
    if let Some(Value::Array(arr)) = o.get("endpoints") {
        c.endpoints = arr.iter().filter_map(Value::as_object).enumerate().map(|(i, e)| parse_endpoint(e, i)).filter(|e| !e.url.is_empty()).collect();
    }
    if c.endpoints.is_empty() {
        let url = s(o, "url", "").trim().to_owned();
        if !url.is_empty() {
            // Mesmo nome que o caminho ganharia relido da lista `endpoints`.
            let mut e = parse_endpoint(o, 0);
            if s(o, "name", "").is_empty() || !o.contains_key("endpoints") {
                e.name = "conexão 1".into();
            }
            e.url = url;
            c.endpoints.push(e);
        }
    }
    c.record_audio = b(o, "recordAudio", true);
    c.filename_pattern = s(o, "filenamePattern", "{name}_{yyyy-MM-dd_HH-mm-ss}.vms");
    if let Some(Value::Object(r)) = o.get("reconnect") {
        c.reconnect = Reconnect {
            initial_ms: i(r, "initialDelayMs", 2000).max(0) as u64,
            max_ms: i(r, "maxDelayMs", 30_000).max(0) as u64,
            multiplier: f(r, "backoffMultiplier", 2.0),
            no_rtp_timeout_ms: i(r, "noRtpTimeoutMs", 10_000).max(0) as u64,
        };
    }
    c.max_retries = i(o, "maxRetries", 0).max(0) as u32;
    c.audio_delay_ms = i(o, "audioDelayMs", 200);
    c.video_delay_ms = i(o, "videoDelayMs", 200);
    c.ptz = s(o, "ptz", "");
    for (k, v) in o {
        if !KNOWN.contains(&k.as_str()) {
            c.extra.insert(k.clone(), v.clone());
        }
    }
    Some(c)
}

pub fn endpoint_to_json(e: &CameraEndpoint) -> Value {
    json!({
        "name": e.name,
        "url": e.url,
        "user": e.user,
        "password": e.password,
        "transport": Transport::list_to_string(&e.transports),
        "tailscale": e.uses_tailscale,
    })
}

pub fn camera_to_json(c: &CameraEntry) -> Value {
    let mut o = Map::new();
    for (k, v) in &c.extra {
        o.insert(k.clone(), v.clone());
    }
    o.insert("name".into(), json!(c.name));
    o.insert("enabled".into(), json!(c.enabled));
    o.insert("endpoints".into(), Value::Array(c.endpoints.iter().map(endpoint_to_json).collect()));
    // Espelho do primeiro caminho: quem lê o formato antigo continua lendo.
    if let Some(e) = c.first() {
        o.insert("url".into(), json!(e.url));
        o.insert("user".into(), json!(e.user));
        o.insert("password".into(), json!(e.password));
        o.insert("transport".into(), json!(Transport::list_to_string(&e.transports)));
        o.insert("tailscale".into(), json!(e.uses_tailscale));
    }
    o.insert("recordAudio".into(), json!(c.record_audio));
    o.insert("filenamePattern".into(), json!(c.filename_pattern));
    o.insert(
        "reconnect".into(),
        json!({ "initialDelayMs": c.reconnect.initial_ms, "maxDelayMs": c.reconnect.max_ms, "backoffMultiplier": c.reconnect.multiplier, "noRtpTimeoutMs": c.reconnect.no_rtp_timeout_ms }),
    );
    o.insert("maxRetries".into(), json!(c.max_retries));
    o.insert("audioDelayMs".into(), json!(c.audio_delay_ms));
    o.insert("videoDelayMs".into(), json!(c.video_delay_ms));
    o.insert("ptz".into(), json!(c.ptz));
    Value::Object(o)
}

/// O cadastro SEM as senhas (o que sai para a tela): no lugar de cada senha
/// vai `temSenha`. Senha que não sai não vaza por cache, histórico ou captura.
pub fn camera_to_json_sem_senha(c: &CameraEntry) -> Value {
    let mut v = camera_to_json(c);
    let tira = |o: &mut Map<String, Value>| {
        let tem = o.get("password").and_then(Value::as_str).is_some_and(|p| !p.is_empty());
        o.remove("password");
        o.insert("temSenha".into(), json!(tem));
    };
    if let Some(o) = v.as_object_mut() {
        if let Some(Value::Array(eps)) = o.get_mut("endpoints") {
            for e in eps.iter_mut().filter_map(Value::as_object_mut) {
                tira(e);
            }
        }
        if o.contains_key("password") {
            tira(o);
        }
    }
    v
}

/// A lista, com ou sem senhas, indentada (o arquivo é lido por gente).
pub fn cameras_to_json(cams: &[CameraEntry], com_senha: bool) -> String {
    let arr: Vec<Value> = cams.iter().map(|c| if com_senha { camera_to_json(c) } else { camera_to_json_sem_senha(c) }).collect();
    serde_json::to_string_pretty(&arr).unwrap_or_else(|_| "[]".into())
}

/// Repõe, no cadastro que volta da tela, as senhas que nunca foram até lá:
/// senha vazia = "mantenha a que estava". A câmera se acha pelo nome; não
/// achando e com as listas do mesmo tamanho, vale a posição (renomeou no
/// lugar). Os caminhos casam por posição.
pub fn mesclar_senhas(novas: &mut [CameraEntry], atuais: &[CameraEntry]) {
    let mesmo_tamanho = novas.len() == atuais.len();
    for (i, n) in novas.iter_mut().enumerate() {
        let j = atuais.iter().position(|a| a.name.eq_ignore_ascii_case(&n.name)).or(if mesmo_tamanho { Some(i) } else { None });
        let Some(a) = j.and_then(|j| atuais.get(j)) else { continue };
        for (k, e) in n.endpoints.iter_mut().enumerate() {
            if e.password.is_empty() {
                if let Some(old) = a.endpoints.get(k) {
                    e.password = old.password.clone();
                }
            }
        }
    }
}

/// Uma lista (`[...]`) ou um objeto com `cameras: [...]`.
pub fn parse_cameras(v: &Value) -> Vec<CameraEntry> {
    let arr = match v {
        Value::Array(a) => a,
        Value::Object(o) => match o.get("cameras") {
            Some(Value::Array(a)) => a,
            _ => return parse_camera(v).into_iter().collect(),
        },
        _ => return Vec::new(),
    };
    arr.iter().filter_map(parse_camera).filter(|c| !c.name.is_empty()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formato_antigo_vira_um_caminho() {
        let v: Value = serde_json::from_str(r#"{"name":"Portaria","url":"rtsp://h/x","user":"a","transport":"udp","maxRetries":3,"cor":"azul"}"#).unwrap();
        let c = parse_camera(&v).unwrap();
        assert_eq!(c.endpoints.len(), 1);
        assert_eq!(c.endpoints[0].transports, vec![Transport::Udp]);
        assert_eq!(c.max_retries, 3);
        assert_eq!(c.extra["cor"], "azul");
        let back = camera_to_json(&c);
        assert_eq!(back["url"], "rtsp://h/x");
        assert_eq!(back["cor"], "azul");
        assert_eq!(parse_camera(&back).unwrap().endpoints, c.endpoints);
    }

    #[test]
    fn sem_senha_e_mescla() {
        let v: Value = serde_json::from_str(r#"[{"name":"A","endpoints":[{"url":"rtsp://a","password":"s1"},{"url":"rtsp://b"}]},{"name":"B","url":"rtsp://c","password":"s2"}]"#).unwrap();
        let atuais = parse_cameras(&v);
        let tela: Value = serde_json::from_str(&cameras_to_json(&atuais, false)).unwrap();
        assert_eq!(tela[0]["endpoints"][0]["temSenha"], true);
        assert_eq!(tela[0]["endpoints"][1]["temSenha"], false);
        assert!(tela[0]["endpoints"][0].get("password").is_none());
        assert!(tela[1].get("password").is_none());
        assert_eq!(tela[1]["temSenha"], true);
        // Volta da tela sem senhas; "B" renomeado no lugar.
        let mut novas = parse_cameras(&tela);
        novas[1].name = "B2".into();
        mesclar_senhas(&mut novas, &atuais);
        assert_eq!(novas[0].endpoints[0].password, "s1");
        assert_eq!(novas[1].endpoints[0].password, "s2");
        assert!(cameras_to_json(&novas, true).contains("\"s2\""));
    }

    #[test]
    fn varios_caminhos_e_lista() {
        let v: Value = serde_json::from_str(
            r#"[{"name":"Frente","endpoints":[{"name":"Local","url":"rtsp://a"},{"url":""},{"url":"rtsp://b","tailscale":true}]},{"url":"rtsp://sem-nome"}]"#,
        )
        .unwrap();
        let l = parse_cameras(&v);
        assert_eq!(l.len(), 1, "sem nome fica de fora");
        assert_eq!(l[0].endpoints.len(), 2, "caminho sem url fica de fora");
        assert!(l[0].endpoints[1].uses_tailscale);
        assert_eq!(l[0].endpoints[1].name, "conexão 3");
        let cfg = l[0].to_session_config(&CameraConfig::default());
        assert_eq!(cfg.url, "rtsp://a");
        assert_eq!(cfg.endpoints.len(), 2);
    }
}
