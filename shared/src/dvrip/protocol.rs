//! Protocolo Sofia / DVRIP (câmeras Xiongmai), porta 34567.
//!
//! Cada mensagem = cabeçalho de 20 bytes + payload (JSON nos comandos, binário
//! na mídia):
//!
//! ```text
//! 0     0xFF
//! 1     versão (0x01 nas que a câmera manda)
//! 2     reservado (0)
//! 3     flags — NÃO é reservado: 0x80 nas mensagens de áudio da câmera XM
//! 4-7   SessionID (LE)
//! 8-11  sequência (LE)
//! 12    total de pacotes, 13 pacote atual
//! 14-15 MsgID (LE)
//! 16-19 DataLen (LE), inclui o \n final dos JSON
//! ```

use std::time::{Duration, Instant};

use md5::{Digest, Md5};

use crate::error::{Error, Result};
use crate::net::{Conn, TimedRead};

pub const HEAD: u8 = 0xFF;
pub const LOGIN: u16 = 1000;
pub const LOGIN_RSP: u16 = 1001;
pub const KEEPALIVE: u16 = 1006;
pub const KEEPALIVE_RSP: u16 = 1007;
pub const SYSINFO: u16 = 1020;
pub const SYSINFO_RSP: u16 = 1021;
pub const CONFIG_GET: u16 = 1042;
pub const CONFIG_GET_RSP: u16 = 1043;
/// Claim no 1413, Start no 1410: mandar o Claim no 1410 faz a câmera recusar.
pub const OPMONITOR_CLAIM: u16 = 1413;
pub const OPMONITOR_CLAIM_RSP: u16 = 1414;
pub const OPMONITOR: u16 = 1410;
pub const OPMONITOR_RSP: u16 = 1411;
pub const OPMONITOR_DATA: u16 = 1412;
/// Aviso de evento que a câmera manda sozinha, com sessão própria.
pub const ALARM_INFO: u16 = 1504;
pub const PTZ: u16 = 1400;
pub const PTZ_RSP: u16 = 1401;
/// OPTalk: o mesmo desenho do OPMonitor (go2rtc, pkg/dvrip).
pub const OPTALK: u16 = 1430;
pub const OPTALK_RSP: u16 = 1431;
pub const OPTALK_DATA: u16 = 1432;
pub const OPTALK_CLAIM: u16 = 1434;
pub const OPTALK_CLAIM_RSP: u16 = 1435;
/// 320 bytes de G.711 = 40 ms a 8 kHz.
pub const OPTALK_QUADRO: usize = 320;

// O NOME é o da imagem (o que o usuário vê); o VALOR é como a câmera chama.
// No horizontal os dois são opostos — medido em duas câmeras.
pub const PTZ_CIMA: &str = "DirectionUp";
pub const PTZ_BAIXO: &str = "DirectionDown";
pub const PTZ_ESQUERDA: &str = "DirectionRight";
pub const PTZ_DIREITA: &str = "DirectionLeft";
pub const PTZ_CIMA_ESQ: &str = "DirectionRightUp";
pub const PTZ_CIMA_DIR: &str = "DirectionLeftUp";
pub const PTZ_BAIXO_ESQ: &str = "DirectionRightDown";
pub const PTZ_BAIXO_DIR: &str = "DirectionLeftDown";
pub const PTZ_ZOOM_MAIS: &str = "ZoomTile";
pub const PTZ_ZOOM_MENOS: &str = "ZoomWide";
pub const PTZ_PRESET_IR: &str = "GotoPreset";
pub const PTZ_PRESET_POR: &str = "SetPreset";
pub const PTZ_PRESET_LIMPA: &str = "ClearPreset";
pub const PTZ_FOCO_PERTO: &str = "FocusNear";
pub const PTZ_FOCO_LONGE: &str = "FocusFar";
pub const PTZ_IRIS_FECHA: &str = "IrisSmall";
pub const PTZ_IRIS_ABRE: &str = "IrisLarge";
pub const PTZ_RONDA_INI: &str = "StartTour";
pub const PTZ_RONDA_FIM: &str = "StopTour";

/// Teto de UMA mensagem: um quadro. O I-frame H.265 medido dá ~116 KB.
pub const MAX_PAYLOAD: u32 = 4 * 1024 * 1024;
/// Prazo TOTAL para juntar o payload de uma mensagem.
const MAX_PAYLOAD_MS: u64 = 5000;
/// Prazo para engolir o resto de um payload que não completou.
const DRENO_MS: u64 = 10_000;
const MAX_RESYNC_SCAN: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Header {
    pub session_id: u32,
    pub sequence: u32,
    pub msg_id: u16,
    pub data_len: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MsgKind {
    Unknown,
    Control,
    Media,
}

/// Para que serve a mensagem, pelo MsgID — olhar o primeiro byte do payload
/// erra em frame de mídia que começa com `{`.
pub fn classify(msg_id: u16) -> MsgKind {
    match msg_id {
        OPMONITOR_DATA | OPTALK_DATA => MsgKind::Media,
        LOGIN | LOGIN_RSP | KEEPALIVE | KEEPALIVE_RSP | SYSINFO | SYSINFO_RSP | CONFIG_GET | CONFIG_GET_RSP
        | OPMONITOR_CLAIM | OPMONITOR_CLAIM_RSP | OPMONITOR_RSP | PTZ | PTZ_RSP | OPTALK_CLAIM | OPTALK_CLAIM_RSP
        | OPTALK_RSP | ALARM_INFO => MsgKind::Control,
        // 1410 fica de fora de propósito: é onde mandamos o Start, e não se sabe
        // se a câmera responde nele ou manda mídia por ele.
        _ => MsgKind::Unknown,
    }
}

/// Hash "Sofia" da senha: MD5 → 8 caracteres.
pub fn sofia_hash(password: &str) -> String {
    const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    let d = Md5::digest(password.as_bytes());
    (0..8).map(|i| ALPHABET[((d[2 * i] as u32 + d[2 * i + 1] as u32) % 62) as usize] as char).collect()
}

pub fn encode(session_id: u32, sequence: u32, msg_id: u16, payload: &[u8]) -> Vec<u8> {
    let mut b = vec![0u8; 20 + payload.len()];
    b[0] = HEAD;
    b[4..8].copy_from_slice(&session_id.to_le_bytes());
    b[8..12].copy_from_slice(&sequence.to_le_bytes());
    b[14..16].copy_from_slice(&msg_id.to_le_bytes());
    b[16..20].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    b[20..].copy_from_slice(payload);
    b
}

/// JSON + `\n`, como a câmera espera.
pub fn encode_cmd(session_id: u32, sequence: u32, msg_id: u16, json: &str) -> Vec<u8> {
    let mut p = json.as_bytes().to_vec();
    p.push(b'\n');
    encode(session_id, sequence, msg_id, &p)
}

pub fn decode_header(h: &[u8]) -> Header {
    Header {
        session_id: u32::from_le_bytes(h[4..8].try_into().unwrap()),
        sequence: u32::from_le_bytes(h[8..12].try_into().unwrap()),
        msg_id: u16::from_le_bytes([h[14], h[15]]),
        data_len: u32::from_le_bytes(h[16..20].try_into().unwrap()),
    }
}

/// Por que um candidato a cabeçalho foi recusado; `None` = aceito. Quem filtra
/// header falso é o SessionID — 32 bits que vídeo comprimido não imita —, ou um
/// MsgID conhecido (a câmera manda AlarmInfo com sessão própria).
pub fn header_reject(h: &[u8], expected_session: u32) -> Option<String> {
    if h.len() < 20 {
        return Some("curto".into());
    }
    if h[0] != HEAD {
        return Some("sem 0xFF".into());
    }
    if h[2] != 0 {
        return Some(format!("reservado={:02x}", h[2]));
    }
    let hd = decode_header(h);
    if expected_session != 0 && hd.session_id != expected_session && hd.session_id != 0 && classify(hd.msg_id) == MsgKind::Unknown {
        return Some(format!("sessao={:x} (esperada {:x})", hd.session_id, expected_session));
    }
    if hd.data_len > MAX_PAYLOAD {
        return Some(format!("DataLen={}", hd.data_len));
    }
    None
}

pub fn bytes_to_hex(b: &[u8], max: usize) -> String {
    b.iter().take(max).map(|x| format!("{x:02x} ")).collect()
}

/// O lado de leitura de uma conexão DVRIP, com buffer próprio.
pub struct DvripReader {
    conn: Box<dyn TimedRead + Send>,
    buf: Vec<u8>,
    pos: usize,
    chunk: Vec<u8>,
}

impl DvripReader {
    pub fn new(conn: Box<dyn TimedRead + Send>) -> Self {
        Self { conn, buf: Vec::new(), pos: 0, chunk: vec![0u8; 64 * 1024] }
    }

    fn avail(&self) -> usize {
        self.buf.len() - self.pos
    }

    fn fill(&mut self, idle: Duration) -> Result<()> {
        if self.pos > 0 && self.pos == self.buf.len() {
            self.buf.clear();
            self.pos = 0;
        } else if self.pos > 256 * 1024 {
            self.buf.drain(..self.pos);
            self.pos = 0;
        }
        let n = self.conn.read_timeout(&mut self.chunk, idle)?;
        if n == 0 {
            return Err(Error::Io("conexao DVRIP fechada".into()));
        }
        self.buf.extend_from_slice(&self.chunk[..n]);
        Ok(())
    }

    /// Exatamente `n` bytes. `idle` vale por leitura; `total` (se houver) limita
    /// a soma — um DataLen falso e enorme não prende a thread por minutos
    /// enquanto o vídeo continua chegando.
    fn read_exact(&mut self, n: usize, idle: Duration, total: Option<Duration>) -> Result<Vec<u8>> {
        let deadline = total.map(|t| Instant::now() + t);
        while self.avail() < n {
            if deadline.is_some_and(|d| Instant::now() > d) {
                return Err(Error::Timeout("payload DVRIP".into()));
            }
            self.fill(idle)?;
        }
        let v = self.buf[self.pos..self.pos + n].to_vec();
        self.pos += n;
        Ok(v)
    }

    fn take_up_to(&mut self, n: usize) -> usize {
        let k = n.min(self.avail());
        self.pos += k;
        k
    }

    /// Joga fora `n` bytes, para o fluxo voltar ao começo da próxima mensagem.
    fn discard(&mut self, mut n: usize, idle: Duration) -> bool {
        let deadline = Instant::now() + Duration::from_millis(DRENO_MS);
        n -= self.take_up_to(n);
        while n > 0 {
            if Instant::now() > deadline || self.fill(idle).is_err() {
                return false;
            }
            n -= self.take_up_to(n);
        }
        true
    }

    fn read_payload(&mut self, hd: &Header, idle: Duration) -> Result<Vec<u8>> {
        let n = hd.data_len as usize;
        if n == 0 {
            return Ok(Vec::new());
        }
        match self.read_exact(n, idle, Some(Duration::from_millis(MAX_PAYLOAD_MS))) {
            Ok(v) => Ok(v),
            Err(e @ Error::Io(_)) => Err(e),
            Err(_) => {
                // O resto do payload TEM que sair do socket; senão a próxima
                // leitura começa no meio dele. O que já está no buffer é dele.
                let restante = n.saturating_sub(self.take_up_to(n));
                let ok = self.discard(restante, idle);
                Err(Error::Protocol(format!(
                    "payload incompleto ({n} bytes) MsgID={}; {}",
                    hd.msg_id,
                    if ok { "resto descartado" } else { "fluxo desenquadrado" }
                )))
            }
        }
    }

    /// Uma mensagem inteira. Erro de enquadramento vira `Error::Protocol`.
    pub fn recv(&mut self, idle: Duration) -> Result<(Header, Vec<u8>)> {
        let h = self.read_exact(20, idle, None)?;
        if h[0] != HEAD {
            return Err(Error::Protocol(format!("fora de sincronia: esperava 0xff, veio 0x{:02x} [{}]", h[0], bytes_to_hex(&h, 20))));
        }
        let hd = decode_header(&h);
        if hd.data_len > MAX_PAYLOAD {
            return Err(Error::Protocol(format!("DataLen invalido ({}) MsgID={} [{}]", hd.data_len, hd.msg_id, bytes_to_hex(&h, 20))));
        }
        let p = self.read_payload(&hd, idle)?;
        Ok((hd, p))
    }

    /// Igual, mas fora de sincronia procura o próximo cabeçalho plausível em
    /// vez de desistir. Devolve também quantos bytes pulou e o motivo da
    /// recusa do primeiro candidato.
    pub fn recv_resync(&mut self, idle: Duration, expected_session: u32) -> Result<(Header, Vec<u8>, usize, Option<String>)> {
        let mut win = self.read_exact(20, idle, None)?;
        let reject = header_reject(&win, expected_session).map(|r| format!("{r} [{}]", bytes_to_hex(&win, 20)));
        let mut skipped = 0;
        while header_reject(&win, expected_session).is_some() {
            if skipped >= MAX_RESYNC_SCAN {
                return Err(Error::Protocol(format!("sem sincronia apos {skipped} bytes [{}]", bytes_to_hex(&win, 20))));
            }
            let b = self.read_exact(1, idle, None)?;
            win.remove(0);
            win.push(b[0]);
            skipped += 1;
        }
        let hd = decode_header(&win);
        let p = self.read_payload(&hd, idle)?;
        Ok((hd, p, skipped, reject))
    }
}

/// O lado de escrita: SessionID e sequência ficam aqui, e a escrita é uma por
/// vez (o comando de PTZ vem da thread do HTTP; o keepalive, da sessão).
pub struct DvripWriter {
    conn: std::sync::Mutex<Option<Box<dyn Conn>>>,
    seq: std::sync::atomic::AtomicU32,
    session: std::sync::atomic::AtomicU32,
}

impl DvripWriter {
    pub fn new(conn: Box<dyn Conn>) -> Self {
        Self { conn: std::sync::Mutex::new(Some(conn)), seq: Default::default(), session: Default::default() }
    }

    pub fn set_session(&self, id: u32) {
        self.session.store(id, std::sync::atomic::Ordering::SeqCst);
    }

    pub fn session(&self) -> u32 {
        self.session.load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn send_bin(&self, msg_id: u16, payload: &[u8]) -> Result<()> {
        let mut g = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let c = g.as_mut().ok_or_else(|| Error::Io("conexao DVRIP fechada".into()))?;
        let seq = self.seq.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
        c.send(&encode(self.session(), seq, msg_id, payload))
    }

    pub fn send_cmd(&self, msg_id: u16, json: &str) -> Result<()> {
        let mut p = json.as_bytes().to_vec();
        p.push(b'\n');
        self.send_bin(msg_id, &p)
    }

    /// O login vai com sessão e sequência zero.
    pub fn send_raw(&self, bytes: &[u8]) -> Result<()> {
        let mut g = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        g.as_mut().ok_or_else(|| Error::Io("conexao DVRIP fechada".into()))?.send(bytes)
    }

    pub fn close(&self) {
        if let Some(mut c) = self.conn.lock().unwrap_or_else(|p| p.into_inner()).take() {
            c.shutdown();
        }
    }

    pub fn is_open(&self) -> bool {
        self.conn.lock().unwrap_or_else(|p| p.into_inner()).is_some()
    }
}

// ------------------------------------------------------------------ JSON da câmera
//
// A câmera manda JSON com `\n\0` no fim e, em algumas, campos fora do padrão.
// Estas leituras por texto são as mesmas do Delphi, e não quebram com isso.

/// Valor de `"chave":"valor"` ou `"chave":123`.
pub fn json_get_str(json: &str, key: &str) -> String {
    let pat = format!("\"{key}\"");
    let Some(p) = json.find(&pat) else { return String::new() };
    let rest = &json[p + pat.len()..];
    let Some(c) = rest.find(':') else { return String::new() };
    let v = rest[c + 1..].trim_start_matches(' ');
    if let Some(q) = v.strip_prefix('"') {
        q.split('"').next().unwrap_or("").to_owned()
    } else {
        v.split([',', '}']).next().unwrap_or("").trim().to_owned()
    }
}

pub fn json_get_int(json: &str, key: &str, default: i64) -> i64 {
    json_get_str(json, key).parse().unwrap_or(default)
}

/// O objeto `{ ... }` que segue `"Section"`, respeitando chaves aninhadas.
pub fn extract_section(json: &str, section: &str) -> String {
    let pat = format!("\"{section}\"");
    let Some(p) = json.find(&pat) else { return String::new() };
    let Some(open) = json[p..].find('{').map(|o| p + o) else { return String::new() };
    let mut depth = 0;
    for (i, ch) in json[open..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return json[open..open + i + 1].to_owned();
                }
            }
            _ => {}
        }
    }
    json[open..].to_owned()
}

pub fn looks_like_json(p: &[u8]) -> bool {
    p.iter().find(|b| !matches!(b, b' ' | b'\t' | b'\n' | b'\r')).is_some_and(|&b| b == b'{')
}

pub fn session_hex(id: u32) -> String {
    format!("0x{id:08X}")
}

pub fn login_json(user: &str, password: &str) -> String {
    format!(
        "{{ \"CommunicateKey\" : \"\", \"EncryptType\" : \"MD5\", \"LoginType\" : \"DVRIP-Web\", \"PassWord\" : \"{}\", \"UserName\" : \"{user}\" }}",
        sofia_hash(password)
    )
}

pub fn monitor_json(action: &str, combin: &str, stream: &str, session: u32) -> String {
    format!(
        "{{ \"Name\" : \"OPMonitor\", \"OPMonitor\" : {{ \"Action\" : \"{action}\", \"Parameter\" : {{ \"Channel\" : 0, \"CombinMode\" : \"{combin}\", \"StreamType\" : \"{stream}\", \"TransMode\" : \"TCP\" }} }}, \"SessionID\" : \"0x{session:X}\" }}"
    )
}

pub fn keepalive_json(session: u32) -> String {
    format!("{{ \"Name\" : \"KeepAlive\", \"SessionID\" : \"0x{session:X}\" }}")
}

pub fn config_get_json(name: &str, session: u32) -> String {
    format!("{{ \"Name\" : \"{name}\", \"SessionID\" : \"{}\" }}", session_hex(session))
}

/// Só A-law: o formato que a câmera devolve no áudio dela.
pub fn talk_json(action: &str, session: u32) -> String {
    format!(
        "{{ \"Name\" : \"OPTalk\", \"OPTalk\" : {{ \"Action\" : \"{action}\", \"AudioFormat\" : {{ \"BitRate\" : 128, \"EncodeType\" : \"G711_ALAW\", \"SampleBit\" : 8, \"SampleRate\" : 8 }} }}, \"SessionID\" : \"{}\" }}",
        session_hex(session)
    )
}

/// Um frame de fala: o sub-header que a câmera usa no áudio dela.
pub fn talk_frame(alaw: &[u8]) -> Vec<u8> {
    let n = alaw.len() as u16;
    let mut v = vec![0x00, 0x00, 0x01, 0xFA, 0x0E, 0x02];
    v.extend_from_slice(&n.to_le_bytes());
    v.extend_from_slice(alaw);
    v
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PtzForma {
    /// Pattern "SetBegin" com POINT: a da captura do iCSee.
    Passo,
    /// Pattern "Start" sem POINT: a que a referência usa para preset.
    Start,
}

/// O JSON do OPPTZControl, no texto EXATO da captura (o DataLen bateu: 328 no
/// comando e 325 na parada, com o `\n`).
pub fn op_ptz_json(comando: &str, passo: i32, canal: i32, preset: i32, session_hex: &str, forma: PtzForma) -> String {
    let passo = passo.clamp(1, 8);
    let (ponto, padrao) = match forma {
        PtzForma::Passo => ("\"POINT\" : { \"bottom\" : 0, \"left\" : 0, \"right\" : 0, \"top\" : 0 }, ", "SetBegin"),
        PtzForma::Start => ("", "Start"),
    };
    format!(
        "{{ \"Name\" : \"OPPTZControl\", \"OPPTZControl\" : {{ \"Command\" : \"{comando}\", \"Parameter\" : {{ \"AUX\" : {{ \"Number\" : 0, \"Status\" : \"On\" }}, \"Channel\" : {canal}, \"MenuOpts\" : \"Enter\", {ponto}\"Pattern\" : \"{padrao}\", \"Preset\" : {preset}, \"Step\" : {passo}, \"Tour\" : 0 }} }}, \"SessionID\" : \"{session_hex}\" }}"
    )
}

/// Andar e parar são a MESMA mensagem: Preset 65535 anda, -1 para.
pub fn ptz_json(comando: &str, passo: i32, canal: i32, iniciar: bool, session_hex: &str) -> String {
    op_ptz_json(comando, passo, canal, if iniciar { 65535 } else { -1 }, session_hex, PtzForma::Passo)
}

pub fn preset_json(preset: i32, canal: i32, session_hex: &str, comando: &str) -> String {
    op_ptz_json(comando, 5, canal, preset.max(0), session_hex, PtzForma::Start)
}

/// pan/tilt/zoom contínuos (o vocabulário da ONVIF) → uma das direções do
/// DVRIP. Vazio = direção inválida.
pub fn comando_de(pan: f64, tilt: f64, zoom: f64) -> &'static str {
    const MORTO: f64 = 0.15;
    if zoom.abs() > MORTO {
        return if zoom > 0.0 { PTZ_ZOOM_MAIS } else { PTZ_ZOOM_MENOS };
    }
    match (tilt > MORTO, tilt < -MORTO, pan < -MORTO, pan > MORTO) {
        (true, _, true, _) => PTZ_CIMA_ESQ,
        (true, _, _, true) => PTZ_CIMA_DIR,
        (_, true, true, _) => PTZ_BAIXO_ESQ,
        (_, true, _, true) => PTZ_BAIXO_DIR,
        (true, ..) => PTZ_CIMA,
        (_, true, ..) => PTZ_BAIXO,
        (_, _, true, _) => PTZ_ESQUERDA,
        (_, _, _, true) => PTZ_DIREITA,
        _ => "",
    }
}

/// O passo de 1 a 8 a partir da velocidade normalizada.
pub fn passo_de(pan: f64, tilt: f64, zoom: f64) -> i32 {
    let v = pan.abs().max(tilt.abs()).max(zoom.abs());
    ((v * 8.0).round() as i32).max(1)
}

/// Login: lê até achar a resposta com SessionID (algumas câmeras mandam um
/// "LoginEncryptionType" antes). Devolve (sessão, alive interval, última resposta).
pub fn login(reader: &mut DvripReader, writer: &DvripWriter, user: &str, password: &str, timeout: Duration) -> Result<(u32, i64, String)> {
    writer.send_raw(&encode_cmd(0, 0, LOGIN, &login_json(user, password)))?;
    let mut last = String::new();
    for _ in 0..4 {
        let (_, p) = reader.recv(timeout)?;
        last = String::from_utf8_lossy(&p).into_owned();
        let sid = json_get_str(&last, "SessionID");
        if sid.is_empty() {
            continue;
        }
        if json_get_int(&last, "Ret", 0) != 100 {
            return Err(Error::Auth(format!("login DVRIP recusado: {}", last.trim_end_matches(['\n', '\0']))));
        }
        let id = match sid.strip_prefix("0x").or_else(|| sid.strip_prefix("0X")) {
            Some(h) => u32::from_str_radix(h, 16).unwrap_or(0),
            None => sid.parse().unwrap_or(0),
        };
        let alive = json_get_int(&last, "AliveInterval", 30);
        writer.set_session(id);
        return Ok((id, if alive <= 0 { 30 } else { alive }, last));
    }
    Err(Error::Auth(format!("login DVRIP sem SessionID: {last}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::MemConn;

    #[test]
    fn hash_sofia_conhecido() {
        // Senha vazia: o valor que toda XM de fábrica aceita.
        assert_eq!(sofia_hash(""), "tlJwpbo6");
        assert_eq!(sofia_hash("x").len(), 8);
    }

    #[test]
    fn json_do_ptz_tem_o_tamanho_da_captura() {
        let sh = session_hex(0x1A);
        assert_eq!(sh, "0x0000001A");
        // O mesmo texto do Delphi, byte a byte (o que foi conferido contra a
        // captura do iCSee): andar e parar diferem só em "65535" x "-1".
        let anda = ptz_json(PTZ_DIREITA, 5, 0, true, &sh);
        assert_eq!(anda.len() + 1, 334);
        assert_eq!(anda.len() - ptz_json(PTZ_DIREITA, 5, 0, false, &sh).len(), 3);
        assert!(anda.starts_with("{ \"Name\" : \"OPPTZControl\", \"OPPTZControl\" : { \"Command\" : \"DirectionLeft\", \"Parameter\" : { \"AUX\""));
        assert!(anda.ends_with("\"Pattern\" : \"SetBegin\", \"Preset\" : 65535, \"Step\" : 5, \"Tour\" : 0 } }, \"SessionID\" : \"0x0000001A\" }"));
        assert!(preset_json(3, 0, &sh, PTZ_PRESET_IR).contains("\"Pattern\" : \"Start\", \"Preset\" : 3,"));
        assert!(!preset_json(3, 0, &sh, PTZ_PRESET_IR).contains("POINT"));
    }

    #[test]
    fn direcoes() {
        assert_eq!(comando_de(1.0, 0.0, 0.0), PTZ_DIREITA);
        assert_eq!(comando_de(-1.0, 1.0, 0.0), PTZ_CIMA_ESQ);
        assert_eq!(comando_de(0.1, 0.1, 0.0), "");
        assert_eq!(comando_de(0.0, 0.0, -0.5), PTZ_ZOOM_MENOS);
        assert_eq!(passo_de(0.35, 0.0, 0.0), 3);
        assert_eq!(passo_de(0.0, 0.0, 0.0), 1);
    }

    #[test]
    fn leitura_de_json_por_texto() {
        let j = "{ \"Name\" : \"\", \"Ret\" : 100, \"SessionID\" : \"0x0000000B\", \"AliveInterval\" : 21 }\n\0";
        assert_eq!(json_get_str(j, "SessionID"), "0x0000000B");
        assert_eq!(json_get_int(j, "Ret", 0), 100);
        assert_eq!(json_get_int(j, "Nada", 7), 7);
        let s = extract_section("{\"A\":{\"MainFormat\":{\"V\":{\"x\":1}},\"B\":2}}", "MainFormat");
        assert_eq!(s, "{\"V\":{\"x\":1}}");
        assert!(looks_like_json(b"  {\"a\":1}"));
        assert!(!looks_like_json(&[0, 0, 1, 0xFC]));
    }

    #[test]
    fn login_e_mensagens() {
        let resp = "{ \"Ret\" : 100, \"SessionID\" : \"0x00000ABC\", \"AliveInterval\" : 20 }\n";
        let mut input = encode_cmd(0, 0, LOGIN_RSP, "{ \"Name\" : \"LoginEncryptionType\" }");
        input.extend(encode_cmd(0xABC, 0, LOGIN_RSP, resp.trim_end()));
        let mut r = DvripReader::new(Box::new(MemConn::new(&input)));
        let w = DvripWriter::new(Box::new(MemConn::default()));
        let (id, alive, _) = login(&mut r, &w, "admin", "", Duration::from_millis(50)).unwrap();
        assert_eq!((id, alive), (0xABC, 20));
        assert_eq!(w.session(), 0xABC);
    }

    #[test]
    fn ressincroniza_depois_de_lixo() {
        let mut input = vec![0xFF, 0x13, 0x55, 0x00, 0x77];
        input.extend(encode(0x42, 1, OPMONITOR_DATA, &[1, 2, 3]));
        let mut r = DvripReader::new(Box::new(MemConn::new(&input)));
        let (h, p, skipped, reject) = r.recv_resync(Duration::from_millis(50), 0x42).unwrap();
        assert_eq!(h.msg_id, OPMONITOR_DATA);
        assert_eq!(p, vec![1, 2, 3]);
        assert_eq!(skipped, 5);
        assert!(reject.unwrap().starts_with("reservado=55"));
        // Sessão diferente com MsgID conhecido passa (AlarmInfo).
        let mut r = DvripReader::new(Box::new(MemConn::new(&encode(0x99, 1, ALARM_INFO, b"{}"))));
        assert_eq!(r.recv_resync(Duration::from_millis(50), 0x42).unwrap().2, 0);
        // Byte 3 (flags) com 0x80 não pode ser recusado: é o áudio da XM.
        let mut a = encode(0x42, 1, OPMONITOR_DATA, &[9]);
        a[3] = 0x80;
        assert!(header_reject(&a, 0x42).is_none());
    }

    #[test]
    fn frame_de_fala() {
        let f = talk_frame(&[0xD5; 320]);
        assert_eq!(&f[..8], &[0, 0, 1, 0xFA, 0x0E, 0x02, 0x40, 0x01]);
        assert_eq!(f.len(), 328);
        assert!(talk_json("Claim", 0xA).contains("\"SessionID\" : \"0x0000000A\""));
    }
}
