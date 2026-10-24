//! Cliente ONVIF do tamanho que a PTZ pede: SOAP montado à mão e lido por
//! marcação.
//!
//! ```text
//! GetSystemDateAndTime → o relógio da câmera (SEM credencial)
//! GetCapabilities      → onde ficam os serviços de mídia e de PTZ
//! GetProfiles          → o token do perfil, que a PTZ exige em todo comando
//! ContinuousMove/Stop  → o comando
//! ```
//!
//! A autenticação é WS-Security UsernameToken com digest, e a câmera RECUSA um
//! token cujo `created` esteja longe do relógio DELA. Por isso o relógio vem
//! antes de tudo, e cada token é carimbado na hora da câmera.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use base64::Engine;
use sha1::{Digest, Sha1};

use crate::http;
use crate::log::SharedLogger;

const NS_ENV: &str = "http://www.w3.org/2003/05/soap-envelope";
const NS_DEV: &str = "http://www.onvif.org/ver10/device/wsdl";
const NS_MEDIA: &str = "http://www.onvif.org/ver10/media/wsdl";
const NS_PTZ: &str = "http://www.onvif.org/ver20/ptz/wsdl";
const NS_SCH: &str = "http://www.onvif.org/ver10/schema";
const NS_WSSE: &str = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd";
const NS_WSU: &str = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd";
const TIPO_NONCE: &str = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary";
const TIPO_DIGEST: &str = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest";
const TEMPO_MS: u64 = 8000;
/// Por quanto tempo a câmera segue se movendo sem outra ordem: o mesmo teto
/// da tela, e o freio para a parada que se perder.
const DURACAO: &str = "PT8S";

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Move {
    pub pan: f64,
    pub tilt: f64,
    pub zoom: f64,
}

impl Move {
    pub fn new(pan: f64, tilt: f64, zoom: f64) -> Self {
        Self { pan: pan.clamp(-1.0, 1.0), tilt: tilt.clamp(-1.0, 1.0), zoom: zoom.clamp(-1.0, 1.0) }
    }
    pub fn parado(&self) -> bool {
        self.pan.abs() < 0.001 && self.tilt.abs() < 0.001 && self.zoom.abs() < 0.001
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preset {
    pub token: String,
    pub nome: String,
}

/// O palpite a partir da URL de mídia: mesmo host, HTTP, caminho da norma.
pub fn endereco_padrao(url_midia: &str) -> String {
    let h = host_da_url(url_midia);
    if h.is_empty() {
        String::new()
    } else {
        format!("http://{h}/onvif/device_service")
    }
}

/// Só o host, sem esquema, credencial, porta ou caminho.
pub fn host_da_url(url: &str) -> String {
    let mut s = url.trim();
    if let Some(p) = s.find("://") {
        s = &s[p + 3..];
    }
    if let Some(p) = s.find('@') {
        s = &s[p + 1..];
    }
    let s = s.split('/').next().unwrap_or("");
    s.split(':').next().unwrap_or("").to_owned()
}

/// O endereço do serviço a partir do que o cadastro escreveu: host, host:porta
/// ou URL inteira. Vazio = o palpite padrão.
pub fn endereco_onvif(escrito: &str, url_midia: &str) -> String {
    let s = escrito.trim();
    if s.is_empty() {
        return endereco_padrao(url_midia);
    }
    let mut s = if s.contains("://") { s.to_owned() } else { format!("http://{s}") };
    let after = s.find("://").map(|p| p + 3).unwrap_or(0);
    if !s[after..].contains('/') {
        s.push_str("/onvif/device_service");
    }
    s
}

/// O endereço anunciado, mas no host por onde a câmera foi ALCANÇADA (câmera
/// atrás de encaminhamento de porta anuncia o IP da rede dela). A porta
/// anunciada fica.
pub fn mesmo_host_que(anunciado: &str, base: &str) -> String {
    let a = anunciado.trim();
    let hb = host_da_url(base);
    if a.is_empty() || hb.is_empty() {
        return anunciado.to_owned();
    }
    let Some(p) = a.find("://") else { return anunciado.to_owned() };
    let resto = &a[p + 3..];
    let (aut, path) = match resto.find('/') {
        Some(i) => (&resto[..i], &resto[i..]),
        None => (resto, ""),
    };
    let aut = match aut.find(':') {
        Some(c) => format!("{hb}{}", &aut[c..]),
        None => hb,
    };
    format!("http://{aut}{path}")
}

fn achar_abertura(xml: &str, nome: &str, de: usize) -> Option<(usize, usize)> {
    let b = xml.as_bytes();
    let mut i = de;
    loop {
        i += xml[i..].find('<')? + 1;
        if i >= b.len() || matches!(b[i], b'/' | b'?' | b'!') {
            continue;
        }
        let mut p = i;
        while p < b.len() && !matches!(b[p], b'>' | b' ' | b'/' | b'\t' | b'\n' | b'\r') {
            p += 1;
        }
        let n = &xml[i..p];
        let local = n.rsplit(':').next().unwrap_or(n);
        if local.eq_ignore_ascii_case(nome) {
            return Some((i - 1, p));
        }
        i = p;
    }
}

fn achar_fechamento(xml: &str, nome: &str, de: usize) -> Option<usize> {
    let b = xml.as_bytes();
    let mut i = de;
    loop {
        i += xml[i..].find("</")?;
        let mut p = i + 2;
        while p < b.len() && !matches!(b[p], b'>' | b' ' | b'\t' | b'\n' | b'\r') {
            p += 1;
        }
        let n = &xml[i + 2..p];
        if n.rsplit(':').next().unwrap_or(n).eq_ignore_ascii_case(nome) {
            return Some(i);
        }
        i = p;
    }
}

/// O conteúdo do primeiro elemento com este nome LOCAL (sem prefixo).
pub fn valor_da_tag(xml: &str, nome: &str) -> String {
    let mut de = 0;
    while let Some((_, apos)) = achar_abertura(xml, nome, de) {
        let Some(ini) = xml[apos..].find('>').map(|x| apos + x) else { return String::new() };
        if ini > 0 && xml.as_bytes()[ini - 1] == b'/' {
            de = ini;
            continue;
        }
        let Some(fim) = xml[ini..].find("</").map(|x| ini + x) else { return String::new() };
        return xml[ini + 1..fim].trim().to_owned();
    }
    String::new()
}

/// O mesmo, dentro do primeiro elemento `dentro` (o XAddr do PTZ e o da Mídia
/// têm o mesmo nome local).
pub fn valor_dentro_de(xml: &str, dentro: &str, nome: &str) -> String {
    let Some((abre, apos)) = achar_abertura(xml, dentro, 0) else { return String::new() };
    let fecha = achar_fechamento(xml, dentro, apos).unwrap_or(xml.len());
    valor_da_tag(&xml[abre..fecha], nome)
}

/// base64(sha1(nonce CRU + created + senha)).
pub fn digest_de_senha(nonce: &[u8], created: &str, senha: &str) -> String {
    let mut h = Sha1::new();
    h.update(nonce);
    h.update(created.as_bytes());
    h.update(senha.as_bytes());
    base64::engine::general_purpose::STANDARD.encode(h.finalize())
}

fn escapar(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn nonce16() -> [u8; 16] {
    static N: AtomicU64 = AtomicU64::new(0x9E37_79B9_7F4A_7C15);
    let mut out = [0u8; 16];
    let mut x = N.fetch_add(0x632B_E59B_D9B4_E019, Ordering::SeqCst) ^ (crate::clock::unix_ms() as u64).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    for c in out.chunks_mut(8) {
        x ^= x >> 31;
        x = x.wrapping_mul(0x94D0_49BB_1331_11EB);
        x ^= x >> 29;
        c.copy_from_slice(&x.to_le_bytes());
    }
    out
}

/// `2026-08-16T18:37:57.123Z` de um instante UTC.
pub fn iso_utc(ms: i64) -> String {
    let t = crate::clock::datetime_from_ms(ms);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z", t.year, t.month, t.day, t.hour, t.minute, t.second, t.millis)
}

/// O transporte SOAP: porta para o teste responder sem câmera.
pub trait SoapPost: Send + Sync {
    /// (status, corpo). `Err` = não houve resposta HTTP.
    fn post(&self, url: &str, body: &str, timeout_ms: u64) -> Result<(u16, String), String>;
}

pub struct HttpSoap;

impl SoapPost for HttpSoap {
    fn post(&self, url: &str, body: &str, timeout_ms: u64) -> Result<(u16, String), String> {
        let r = http::fetch("POST", url, &[("Content-Type", "application/soap+xml; charset=utf-8")], body.as_bytes(), Duration::from_millis(timeout_ms))
            .map_err(|e| e.to_string())?;
        Ok((r.status, r.body_text()))
    }
}

pub struct OnvifClient {
    xaddr: String,
    user: String,
    pass: String,
    log: Option<SharedLogger>,
    tag: String,
    tempo_ms: u64,
    soap: Box<dyn SoapPost>,
    preparado: bool,
    ptz_url: String,
    media_url: String,
    perfil: String,
    delta_ms: i64,
    motivo: String,
    respondeu: bool,
    sem_stop: bool,
    sem_presets: bool,
}

impl OnvifClient {
    pub fn new(xaddr: &str, user: &str, pass: &str, log: Option<SharedLogger>, tag: &str, tempo_ms: u64) -> Self {
        Self::with_transport(xaddr, user, pass, log, tag, tempo_ms, Box::new(HttpSoap))
    }

    pub fn with_transport(xaddr: &str, user: &str, pass: &str, log: Option<SharedLogger>, tag: &str, tempo_ms: u64, soap: Box<dyn SoapPost>) -> Self {
        Self {
            xaddr: xaddr.trim().into(),
            user: user.into(),
            pass: pass.into(),
            log,
            tag: tag.into(),
            tempo_ms: if tempo_ms > 0 { tempo_ms } else { TEMPO_MS },
            soap,
            preparado: false,
            ptz_url: String::new(),
            media_url: String::new(),
            perfil: String::new(),
            delta_ms: 0,
            motivo: String::new(),
            respondeu: false,
            sem_stop: false,
            sem_presets: false,
        }
    }

    pub fn motivo(&self) -> &str {
        &self.motivo
    }
    pub fn tem_ptz(&self) -> bool {
        self.preparado
    }
    pub fn responde_onvif(&self) -> bool {
        self.respondeu
    }
    pub fn ptz_url(&self) -> &str {
        &self.ptz_url
    }
    pub fn perfil(&self) -> &str {
        &self.perfil
    }

    fn header(&self) -> String {
        if self.user.is_empty() {
            return String::new();
        }
        let nonce = nonce16();
        let created = iso_utc(crate::clock::unix_ms() + self.delta_ms);
        format!(
            "<s:Header><wsse:Security s:mustUnderstand=\"1\" xmlns:wsse=\"{NS_WSSE}\" xmlns:wsu=\"{NS_WSU}\"><wsse:UsernameToken><wsse:Username>{}</wsse:Username><wsse:Password Type=\"{TIPO_DIGEST}\">{}</wsse:Password><wsse:Nonce EncodingType=\"{TIPO_NONCE}\">{}</wsse:Nonce><wsu:Created>{created}</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>",
            escapar(&self.user),
            digest_de_senha(&nonce, &created, &self.pass),
            base64::engine::general_purpose::STANDARD.encode(nonce)
        )
    }

    fn post(&mut self, url: &str, body: &str) -> Option<String> {
        match self.soap.post(url, body, self.tempo_ms) {
            Err(e) => {
                self.motivo = format!("nao consegui falar com {url}: {e}");
                None
            }
            Ok((200, r)) => Some(r),
            Ok((st, r)) => {
                // O texto do Fault diz mais que o código.
                self.motivo = format!("{url} respondeu {st}: {}", valor_da_tag(&r, "Text"));
                None
            }
        }
    }

    fn chamar(&mut self, url: &str, acao: &str, interno: &str) -> Option<String> {
        let body = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope xmlns:s=\"{NS_ENV}\">{}<s:Body>{interno}</s:Body></s:Envelope>", self.header());
        let url = url.to_owned();
        let r = self.post(&url, &body);
        if r.is_none() {
            if let Some(l) = &self.log {
                l.warn(&self.tag, &format!("{acao}: {}", self.motivo));
            }
        }
        r
    }

    fn acertar_relogio(&mut self) {
        self.delta_ms = 0;
        let body = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope xmlns:s=\"{NS_ENV}\"><s:Body><GetSystemDateAndTime xmlns=\"{NS_DEV}\"/></s:Body></s:Envelope>");
        let x = self.xaddr.clone();
        let Some(r) = self.post(&x, &body) else { return };
        let d = valor_dentro_de(&r, "UTCDateTime", "Date");
        let t = valor_dentro_de(&r, "UTCDateTime", "Time");
        let n = |s: &str, k: &str| valor_da_tag(s, k).parse::<i64>().unwrap_or(0);
        let (y, mo, dd) = (n(&d, "Year"), n(&d, "Month"), n(&d, "Day"));
        if y < 2000 || !(1..=12).contains(&mo) || !(1..=31).contains(&dd) {
            if let Some(l) = &self.log {
                l.info(&self.tag, "camera nao informou a hora; usando a daqui");
            }
            return;
        }
        let cam = crate::clock::days_from_civil(y as i32, mo as u32, dd as u32) * 86_400_000 + n(&t, "Hour") * 3_600_000 + n(&t, "Minute") * 60_000 + n(&t, "Second") * 1000;
        self.delta_ms = cam - crate::clock::unix_ms();
        if self.delta_ms.abs() > 2000 {
            if let Some(l) = &self.log {
                l.info(&self.tag, &format!("relogio da camera {} s de diferenca; os tokens vao pela hora dela", self.delta_ms / 1000));
            }
        }
    }

    fn ler_capacidades(&mut self) -> bool {
        let x = self.xaddr.clone();
        let r = self.chamar(&x, "GetCapabilities", &format!("<GetCapabilities xmlns=\"{NS_DEV}\"><Category>All</Category></GetCapabilities>"));
        self.respondeu = r.is_some();
        let Some(r) = r else { return false };
        self.ptz_url = mesmo_host_que(&valor_dentro_de(&r, "PTZ", "XAddr"), &self.xaddr);
        self.media_url = mesmo_host_que(&valor_dentro_de(&r, "Media", "XAddr"), &self.xaddr);
        if self.media_url.is_empty() {
            self.motivo = "a camera nao anunciou o servico de midia".into();
            return false;
        }
        if self.ptz_url.is_empty() {
            // Câmera fixa, e não erro de comunicação.
            self.motivo = "esta camera nao tem PTZ".into();
            return false;
        }
        true
    }

    fn ler_perfil(&mut self) -> bool {
        let m = self.media_url.clone();
        let Some(r) = self.chamar(&m, "GetProfiles", &format!("<GetProfiles xmlns=\"{NS_MEDIA}\"/>")) else { return false };
        // O token vem como ATRIBUTO do Profiles.
        let Some(i) = r.find("token=\"").map(|i| i + 7) else {
            self.motivo = "nenhum perfil de midia na resposta".into();
            return false;
        };
        self.perfil = r[i..].split('"').next().unwrap_or("").to_owned();
        if self.perfil.is_empty() {
            self.motivo = "perfil de midia sem token".into();
        }
        !self.perfil.is_empty()
    }

    /// As três chamadas de preparação, uma vez.
    pub fn preparar(&mut self) -> bool {
        if self.preparado {
            return true;
        }
        self.motivo.clear();
        if self.xaddr.is_empty() {
            self.motivo = "sem endereco do servico ONVIF".into();
            return false;
        }
        // O relógio é um ACERTO, não um requisito: câmera que não responde a
        // hora ainda pode mover.
        self.acertar_relogio();
        self.preparado = self.ler_capacidades() && self.ler_perfil();
        self.preparado
    }

    pub fn mover_continuo(&mut self, m: Move) -> bool {
        if !self.preparar() {
            return false;
        }
        if m.parado() {
            return self.parar();
        }
        let p = self.ptz_url.clone();
        // Ponto decimal, sempre.
        let body = format!(
            "<ContinuousMove xmlns=\"{NS_PTZ}\"><ProfileToken>{}</ProfileToken><Velocity><PanTilt x=\"{:.3}\" y=\"{:.3}\" xmlns=\"{NS_SCH}\"/><Zoom x=\"{:.3}\" xmlns=\"{NS_SCH}\"/></Velocity><Timeout>{DURACAO}</Timeout></ContinuousMove>",
            escapar(&self.perfil),
            m.pan,
            m.tilt,
            m.zoom
        );
        self.chamar(&p, "ContinuousMove", &body).is_some()
    }

    pub fn parar(&mut self) -> bool {
        if !self.preparar() {
            return false;
        }
        let p = self.ptz_url.clone();
        let perfil = escapar(&self.perfil);
        if !self.sem_stop {
            if self.chamar(&p, "Stop", &format!("<Stop xmlns=\"{NS_PTZ}\"><ProfileToken>{perfil}</ProfileToken><PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>")).is_some() {
                return true;
            }
            // Falhou uma vez, não se pergunta mais: a espera sairia na frente
            // do movimento zero que de fato para a câmera.
            self.sem_stop = true;
            if let Some(l) = &self.log {
                l.info(&self.tag, "Stop nao respondeu; daqui em diante paro com velocidade zero direto");
            }
        }
        self.chamar(
            &p,
            "ContinuousMove",
            &format!("<ContinuousMove xmlns=\"{NS_PTZ}\"><ProfileToken>{perfil}</ProfileToken><Velocity><PanTilt x=\"0.000\" y=\"0.000\" xmlns=\"{NS_SCH}\"/><Zoom x=\"0.000\" xmlns=\"{NS_SCH}\"/></Velocity></ContinuousMove>"),
        )
        .is_some()
    }

    pub fn ler_presets(&mut self) -> Option<Vec<Preset>> {
        if !self.preparar() || self.sem_presets {
            return None;
        }
        let p = self.ptz_url.clone();
        let Some(r) = self.chamar(&p, "GetPresets", &format!("<GetPresets xmlns=\"{NS_PTZ}\"><ProfileToken>{}</ProfileToken></GetPresets>", escapar(&self.perfil))) else {
            self.sem_presets = true;
            return None;
        };
        let mut out = Vec::new();
        let mut i = 0;
        while let Some(k) = r[i..].find("token=\"") {
            let ini = i + k + 7;
            let Some(fim) = r[ini..].find('"').map(|f| ini + f) else { break };
            let token = r[ini..fim].to_owned();
            let bloco: String = r[fim..].chars().take(400).collect();
            let nome = valor_da_tag(&bloco, "Name");
            out.push(Preset { nome: if nome.is_empty() { token.clone() } else { nome }, token });
            i = fim;
        }
        Some(out)
    }

    pub fn ir_para_preset(&mut self, token: &str) -> bool {
        if !self.preparar() {
            return false;
        }
        let p = self.ptz_url.clone();
        let body = format!("<GotoPreset xmlns=\"{NS_PTZ}\"><ProfileToken>{}</ProfileToken><PresetToken>{}</PresetToken></GotoPreset>", escapar(&self.perfil), escapar(token));
        self.chamar(&p, "GotoPreset", &body).is_some()
    }

    /// Guarda a posição de agora. Token vazio cria; devolve o token usado.
    pub fn guardar_preset(&mut self, token: &str, nome: &str) -> Option<String> {
        if !self.preparar() {
            return None;
        }
        let mut body = format!("<SetPreset xmlns=\"{NS_PTZ}\"><ProfileToken>{}</ProfileToken>", escapar(&self.perfil));
        if !nome.trim().is_empty() {
            body.push_str(&format!("<PresetName>{}</PresetName>", escapar(nome)));
        }
        if !token.trim().is_empty() {
            body.push_str(&format!("<PresetToken>{}</PresetToken>", escapar(token)));
        }
        body.push_str("</SetPreset>");
        let p = self.ptz_url.clone();
        let r = self.chamar(&p, "SetPreset", &body)?;
        let t = valor_da_tag(&r, "PresetToken");
        Some(if t.is_empty() { token.trim().to_owned() } else { t })
    }

    pub fn apagar_preset(&mut self, token: &str) -> bool {
        if !self.preparar() {
            return false;
        }
        if token.trim().is_empty() {
            self.motivo = "sem o token da posicao a apagar".into();
            return false;
        }
        let p = self.ptz_url.clone();
        let body = format!("<RemovePreset xmlns=\"{NS_PTZ}\"><ProfileToken>{}</ProfileToken><PresetToken>{}</PresetToken></RemovePreset>", escapar(&self.perfil), escapar(token));
        self.chamar(&p, "RemovePreset", &body).is_some()
    }
}

pub fn portas_comuns() -> &'static [u16] {
    &[80, 8000, 8080, 5000, 8899, 2020, 88, 8090, 8081, 10080]
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Achado {
    pub porta: u16,
    pub tem_ptz: bool,
    pub servico: String,
}

/// Procura o serviço nas portas comuns; para na primeira COM PTZ.
pub fn procurar(host: &str, user: &str, pass: &str, log: Option<SharedLogger>, tempo_ms: u64) -> Vec<Achado> {
    let mut out = Vec::new();
    if host.trim().is_empty() {
        return out;
    }
    for &p in portas_comuns() {
        let mut c = OnvifClient::new(&format!("http://{host}:{p}/onvif/device_service"), user, pass, None, "onvif.procura", tempo_ms);
        let tem = c.preparar();
        if !c.responde_onvif() {
            continue;
        }
        if let Some(l) = &log {
            l.info("onvif.procura", &format!("{host}:{p} responde ONVIF{}", if tem { " e tem PTZ" } else { " sem PTZ" }));
        }
        out.push(Achado { porta: p, tem_ptz: tem, servico: c.ptz_url().to_owned() });
        if tem {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn enderecos() {
        assert_eq!(endereco_padrao("rtsp://admin:x@192.168.1.5:554/onvif1"), "http://192.168.1.5/onvif/device_service");
        assert_eq!(endereco_onvif("192.168.1.5:5000", ""), "http://192.168.1.5:5000/onvif/device_service");
        assert_eq!(endereco_onvif("http://h:80/x", ""), "http://h:80/x");
        assert_eq!(endereco_onvif("", "dvrip://10.0.0.1:34567"), "http://10.0.0.1/onvif/device_service");
        assert_eq!(mesmo_host_que("http://192.168.0.6:5000/onvif/ptz", "http://192.168.100.2:5000/onvif/device_service"), "http://192.168.100.2:5000/onvif/ptz");
    }

    #[test]
    fn xml_por_nome_local() {
        let x = "<tds:Capabilities><tt:Media><tt:XAddr>http://m</tt:XAddr></tt:Media><tt:PTZ><tt:XAddr>http://p</tt:XAddr></tt:PTZ><Profile/></tds:Capabilities>";
        assert_eq!(valor_dentro_de(x, "PTZ", "XAddr"), "http://p");
        assert_eq!(valor_dentro_de(x, "Media", "XAddr"), "http://m");
        assert_eq!(valor_da_tag(x, "XAddr"), "http://m");
        assert_eq!(valor_da_tag("<a:Profiles><a:Profile>x</a:Profile></a:Profiles>", "Profile"), "x");
    }

    #[test]
    fn digest_do_usernametoken() {
        // Exemplo do ONVIF Application Programmer's Guide.
        let nonce = base64::engine::general_purpose::STANDARD.decode("LKqI6G/AikKCQrN0zqZFlg==").unwrap();
        assert_eq!(digest_de_senha(&nonce, "2010-09-16T07:50:45Z", "userpassword"), "tuOSpGlFlIXsozq4HFNeeGeFLEI=");
    }

    struct Roteiro(Arc<Mutex<Vec<String>>>);
    impl SoapPost for Roteiro {
        fn post(&self, url: &str, body: &str, _: u64) -> Result<(u16, String), String> {
            self.0.lock().unwrap().push(format!("{url} {body}"));
            if body.contains("GetSystemDateAndTime") {
                return Ok((200, "<x><tt:UTCDateTime><tt:Time><tt:Hour>1</tt:Hour></tt:Time><tt:Date><tt:Year>2026</tt:Year><tt:Month>1</tt:Month><tt:Day>2</tt:Day></tt:Date></tt:UTCDateTime></x>".into()));
            }
            if body.contains("GetCapabilities") {
                return Ok((200, "<tt:Media><tt:XAddr>http://192.168.0.9/media</tt:XAddr></tt:Media><tt:PTZ><tt:XAddr>http://192.168.0.9:5000/ptz</tt:XAddr></tt:PTZ>".into()));
            }
            if body.contains("GetProfiles") {
                return Ok((200, "<trt:Profiles token=\"P1\" fixed=\"true\"></trt:Profiles>".into()));
            }
            if body.contains("<Stop") {
                return Err("fechou sem resposta".into());
            }
            if body.contains("GetPresets") {
                return Ok((200, "<tptz:Preset token=\"1\"><tt:Name>Portao</tt:Name></tptz:Preset><tptz:Preset token=\"2\"></tptz:Preset>".into()));
            }
            Ok((200, "<ok/>".into()))
        }
    }

    #[test]
    fn prepara_move_e_para_sem_stop() {
        let log = Arc::new(Mutex::new(Vec::new()));
        let mut c = OnvifClient::with_transport("http://10.1.1.1:5000/onvif/device_service", "admin", "x", None, "t", 100, Box::new(Roteiro(log.clone())));
        assert!(c.mover_continuo(Move::new(0.5, 0.0, 0.0)));
        assert_eq!(c.perfil(), "P1");
        assert_eq!(c.ptz_url(), "http://10.1.1.1:5000/ptz");
        assert!(c.parar(), "sem Stop, para com velocidade zero");
        assert!(c.parar());
        let l = log.lock().unwrap();
        assert!(l.iter().any(|x| x.contains("PanTilt x=\"0.500\" y=\"0.000\"")));
        assert_eq!(l.iter().filter(|x| x.contains("<Stop")).count(), 1, "Stop só é tentado uma vez");
        assert!(l.iter().any(|x| x.contains("<wsse:Username>admin</wsse:Username>")));
        drop(l);
        let p = c.ler_presets().unwrap();
        assert_eq!(p, vec![Preset { token: "1".into(), nome: "Portao".into() }, Preset { token: "2".into(), nome: "2".into() }]);
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00.000Z");
    }
}
