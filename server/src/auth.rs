//! Quem pode falar com o servidor.
//!
//! Guarda-se `pbkdf2$<iterações>$<sal hex>$<hash hex>` (PBKDF2-HMAC-SHA256,
//! um bloco de 32 bytes) — o mesmo registro que o servidor Delphi gravava, então
//! a senha definida antes continua valendo.
//!
//! O navegador entra uma vez e recebe o cookie `vmsauth` (token de 256 bits,
//! só em memória); o app manda Basic em toda requisição. Como o PBKDF2 custa
//! 50 mil rodadas, o Basic já conferido fica lembrado (pelo SHA-256 da
//! credencial) até a senha mudar — o app manda dezenas de pedidos por segundo.
//!
//! Não protege o RTSP: a porteira está no caminho do HTTP.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

pub const ITERACOES: u32 = 50_000;
pub const SESSAO_PADRAO_HORAS: u64 = 720;
pub const COOKIE_SESSAO: &str = "vmsauth";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Acesso {
    Liberado,
    SemCredencial,
    CredencialInvalida,
    SemSenhaDefinida,
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// Tempo constante: o `==` de string sai no primeiro byte diferente.
pub fn igual_em_tempo_constante(a: &[u8], b: &[u8]) -> bool {
    let mut d = (a.len() ^ b.len()) as u8 | ((a.len() ^ b.len()) >> 8) as u8;
    for (i, x) in a.iter().enumerate() {
        d |= x ^ b.get(i).copied().unwrap_or(0);
    }
    d == 0 && a.len() == b.len()
}

pub fn pbkdf2_sha256(senha: &str, sal: &[u8], iter: u32) -> [u8; 32] {
    let mac = || <Hmac<Sha256>>::new_from_slice(senha.as_bytes()).expect("hmac aceita qualquer chave");
    let mut m = mac();
    m.update(sal);
    m.update(&[0, 0, 0, 1]);
    let mut u: [u8; 32] = m.finalize().into_bytes().into();
    let mut bloco = u;
    for _ in 1..iter {
        let mut m = mac();
        m.update(&u);
        u = m.finalize().into_bytes().into();
        for (b, x) in bloco.iter_mut().zip(u.iter()) {
            *b ^= x;
        }
    }
    bloco
}

/// Bytes imprevisíveis do gerador do sistema.
pub fn bytes_aleatorios(n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    getrandom::getrandom(&mut b).expect("gerador do sistema");
    b
}

pub fn gerar_hash_de_senha(senha: &str) -> String {
    let sal = bytes_aleatorios(16);
    format!("pbkdf2${ITERACOES}${}${}", hex(&sal), hex(&pbkdf2_sha256(senha, &sal, ITERACOES)))
}

/// false também para registro ilegível: o que não dá para conferir não passa.
pub fn senha_confere(senha: &str, registro: &str) -> bool {
    let p: Vec<&str> = registro.trim().split('$').collect();
    if p.len() != 4 || !p[0].eq_ignore_ascii_case("pbkdf2") {
        return false;
    }
    let Ok(iter) = p[1].parse::<u32>() else { return false };
    if iter == 0 || iter > 5_000_000 {
        return false;
    }
    let Some(sal) = unhex(p[2]).filter(|s| !s.is_empty()) else { return false };
    igual_em_tempo_constante(hex(&pbkdf2_sha256(senha, &sal, iter)).as_bytes(), p[3].to_lowercase().as_bytes())
}

pub fn cookie_de(cabecalho: &str, nome: &str) -> String {
    for item in cabecalho.split(';') {
        let item = item.trim();
        if let Some(p) = item.find('=') {
            if p >= 1 && item[..p].eq_ignore_ascii_case(nome) {
                return item[p + 1..].to_owned();
            }
        }
    }
    String::new()
}

pub fn ler_basic(authorization: &str) -> Option<(String, String)> {
    let s = authorization.trim();
    if s.len() < 6 || !s[..6].eq_ignore_ascii_case("basic ") {
        return None;
    }
    let raw = base64::engine::general_purpose::STANDARD.decode(s[6..].trim()).ok()?;
    let claro = String::from_utf8_lossy(&raw).into_owned();
    let p = claro.find(':')?;
    Some((claro[..p].to_owned(), claro[p + 1..].to_owned()))
}

struct Estado {
    ligado: bool,
    usuario: String,
    hash: String,
    horas: u64,
    sessoes: HashMap<String, Instant>,
    basic_ok: HashSet<[u8; 32]>,
}

pub struct Autenticador {
    st: Mutex<Estado>,
}

impl Default for Autenticador {
    fn default() -> Self {
        Self::new()
    }
}

impl Autenticador {
    pub fn new() -> Self {
        Self {
            st: Mutex::new(Estado {
                ligado: true,
                usuario: "admin".into(),
                hash: String::new(),
                horas: SESSAO_PADRAO_HORAS,
                sessoes: HashMap::new(),
                basic_ok: HashSet::new(),
            }),
        }
    }

    fn st(&self) -> std::sync::MutexGuard<'_, Estado> {
        self.st.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Trocar senha (ou usuário) derruba as sessões: é o que se faz para
    /// expulsar alguém.
    pub fn configurar(&self, ligado: bool, usuario: &str, hash: &str, horas: u64) {
        let mut s = self.st();
        let usuario = if usuario.trim().is_empty() { "admin" } else { usuario.trim() };
        let mudou = s.hash != hash.trim() || !s.usuario.eq_ignore_ascii_case(usuario);
        s.ligado = ligado;
        s.usuario = usuario.to_owned();
        s.hash = hash.trim().to_owned();
        if horas > 0 {
            s.horas = horas;
        }
        if mudou {
            s.sessoes.clear();
            s.basic_ok.clear();
        }
    }

    pub fn ligado(&self) -> bool {
        self.st().ligado
    }

    pub fn usuario(&self) -> String {
        self.st().usuario.clone()
    }

    pub fn sem_senha(&self) -> bool {
        self.st().hash.is_empty()
    }

    /// Não diz qual dos dois errou; o PBKDF2 roda mesmo com usuário errado.
    pub fn confere(&self, usuario: &str, senha: &str) -> bool {
        let (u, h) = {
            let s = self.st();
            (s.usuario.clone(), s.hash.clone())
        };
        if h.is_empty() {
            return false;
        }
        senha_confere(senha, &h) & igual_em_tempo_constante(usuario.to_lowercase().as_bytes(), u.to_lowercase().as_bytes())
    }

    pub fn abrir_sessao(&self) -> String {
        let token = hex(&bytes_aleatorios(32));
        let mut s = self.st();
        let agora = Instant::now();
        s.sessoes.retain(|_, ate| *ate > agora);
        let ate = agora + Duration::from_secs(s.horas * 3600);
        s.sessoes.insert(token.clone(), ate);
        token
    }

    pub fn sessao_valida(&self, token: &str) -> bool {
        if token.trim().is_empty() {
            return false;
        }
        let mut s = self.st();
        match s.sessoes.get(token) {
            Some(ate) if *ate > Instant::now() => true,
            Some(_) => {
                s.sessoes.remove(token);
                false
            }
            None => false,
        }
    }

    pub fn fechar_sessao(&self, token: &str) {
        self.st().sessoes.remove(token);
    }

    pub fn horas(&self) -> u64 {
        self.st().horas
    }

    fn basic_confere(&self, authorization: &str) -> bool {
        let chave: [u8; 32] = Sha256::digest(authorization.trim().as_bytes()).into();
        if self.st().basic_ok.contains(&chave) {
            return true;
        }
        let ok = ler_basic(authorization).map(|(u, p)| self.confere(&u, &p)).unwrap_or(false);
        if ok {
            let mut s = self.st();
            if s.basic_ok.len() > 64 {
                s.basic_ok.clear();
            }
            s.basic_ok.insert(chave);
        }
        ok
    }

    pub fn avaliar(&self, authorization: &str, cookie: &str) -> Acesso {
        if !self.ligado() {
            return Acesso::Liberado;
        }
        if self.sem_senha() {
            return Acesso::SemSenhaDefinida;
        }
        // Cookie primeiro: é o caminho do navegador, e o mais barato.
        let token = cookie_de(cookie, COOKIE_SESSAO);
        if !token.is_empty() {
            return if self.sessao_valida(&token) { Acesso::Liberado } else { Acesso::CredencialInvalida };
        }
        if !authorization.trim().is_empty() {
            return if self.basic_confere(authorization) { Acesso::Liberado } else { Acesso::CredencialInvalida };
        }
        Acesso::SemCredencial
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pbkdf2_vetor_conhecido() {
        // RFC 7914 §11: PBKDF2-HMAC-SHA256("passwd", "salt", 1), 32 bytes.
        assert_eq!(hex(&pbkdf2_sha256("passwd", b"salt", 1)), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc");
        // RFC 7914 §11, 80000 rodadas.
        assert_eq!(hex(&pbkdf2_sha256("Password", b"NaCl", 80000)), "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56");
    }

    #[test]
    fn registro_confere_e_recusa() {
        let h = gerar_hash_de_senha("segredo123");
        assert!(h.starts_with("pbkdf2$50000$"));
        assert!(senha_confere("segredo123", &h));
        assert!(!senha_confere("segredo124", &h));
        assert!(!senha_confere("x", "lixo"));
        assert!(!senha_confere("x", "pbkdf2$0$aa$bb"));
    }

    #[test]
    fn avaliacao_por_cookie_e_basic() {
        let a = Autenticador::new();
        assert_eq!(a.avaliar("", ""), Acesso::SemSenhaDefinida);
        a.configurar(true, "Admin", &gerar_hash_de_senha("12345678"), 1);
        assert_eq!(a.avaliar("", ""), Acesso::SemCredencial);
        let basic = format!("Basic {}", base64::engine::general_purpose::STANDARD.encode("admin:12345678"));
        assert_eq!(a.avaliar(&basic, ""), Acesso::Liberado);
        assert_eq!(a.avaliar(&basic, ""), Acesso::Liberado, "do cache");
        assert_eq!(a.avaliar("Basic YWRtaW46eA==", ""), Acesso::CredencialInvalida);
        let t = a.abrir_sessao();
        assert_eq!(a.avaliar("", &format!("x=1; vmsauth={t}")), Acesso::Liberado);
        a.fechar_sessao(&t);
        assert_eq!(a.avaliar("", &format!("vmsauth={t}")), Acesso::CredencialInvalida);
        // Senha nova derruba o Basic lembrado.
        a.configurar(true, "admin", &gerar_hash_de_senha("outra-senha"), 1);
        assert_eq!(a.avaliar(&basic, ""), Acesso::CredencialInvalida);
        a.configurar(false, "admin", "", 1);
        assert_eq!(a.avaliar("", ""), Acesso::Liberado);
    }

    #[test]
    fn cabecalhos() {
        assert_eq!(cookie_de("a=1; VMSAUTH=xyz; b=2", "vmsauth"), "xyz");
        assert_eq!(cookie_de("a=1", "vmsauth"), "");
        assert_eq!(ler_basic("Basic dTpwOmE="), Some(("u".into(), "p:a".into())));
        assert_eq!(ler_basic("Bearer x"), None);
        assert!(igual_em_tempo_constante(b"abc", b"abc"));
        assert!(!igual_em_tempo_constante(b"abc", b"abd"));
        assert!(!igual_em_tempo_constante(b"abc", b"ab"));
    }
}
