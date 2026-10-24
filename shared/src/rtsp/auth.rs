//! Autenticação Basic e Digest (RFC 2617), do lado de quem pede.

use base64::Engine;
use md5::{Digest, Md5};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Scheme {
    #[default]
    None,
    Basic,
    Digest,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Challenge {
    pub scheme: Scheme,
    pub realm: String,
    pub nonce: String,
    pub opaque: String,
    pub qop: String,
    pub algorithm: String,
}

pub fn md5_hex(s: &str) -> String {
    let d = Md5::digest(s.as_bytes());
    d.iter().map(|b| format!("{b:02x}")).collect()
}

/// `WWW-Authenticate: Digest realm="x", nonce="y", qop="auth"`
pub fn parse_authenticate(header: &str) -> Option<Challenge> {
    let s = header.trim();
    let (scheme, rest) = match s.find(' ') {
        Some(i) => (&s[..i], &s[i..]),
        None => (s, ""),
    };
    let scheme = if scheme.eq_ignore_ascii_case("basic") {
        Scheme::Basic
    } else if scheme.eq_ignore_ascii_case("digest") {
        Scheme::Digest
    } else {
        return None;
    };
    let mut c = Challenge { scheme, ..Default::default() };
    for (k, v) in parse_params(rest) {
        match k.to_ascii_lowercase().as_str() {
            "realm" => c.realm = v,
            "nonce" => c.nonce = v,
            "opaque" => c.opaque = v,
            "qop" => c.qop = v,
            "algorithm" => c.algorithm = v,
            _ => {}
        }
    }
    Some(c)
}

/// `a="x, y", b=z` → [(a, "x, y"), (b, z)]. Também serve para o lado do
/// servidor ler o `Authorization`.
pub fn parse_params(s: &str) -> Vec<(String, String)> {
    let b: Vec<char> = s.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while i < b.len() {
        while i < b.len() && matches!(b[i], ',' | ' ' | '\t') {
            i += 1;
        }
        if i >= b.len() {
            break;
        }
        let ks = i;
        while i < b.len() && b[i] != '=' && b[i] != ',' {
            i += 1;
        }
        let key: String = b[ks..i].iter().collect::<String>().trim().to_owned();
        let mut val = String::new();
        if i < b.len() && b[i] == '=' {
            i += 1;
            if i < b.len() && b[i] == '"' {
                i += 1;
                let vs = i;
                while i < b.len() && b[i] != '"' {
                    i += 1;
                }
                val = b[vs..i].iter().collect();
                if i < b.len() {
                    i += 1;
                }
            } else {
                let vs = i;
                while i < b.len() && b[i] != ',' && b[i] != ' ' {
                    i += 1;
                }
                val = b[vs..i].iter().collect();
            }
        }
        if !key.is_empty() {
            out.push((key, val));
        }
    }
    out
}

/// Monta o `Authorization` de cada pedido depois de receber o desafio.
#[derive(Debug, Clone, Default)]
pub struct AuthHandler {
    user: String,
    password: String,
    challenge: Challenge,
    nonce_count: u32,
    /// Para teste: cnonce fixo.
    pub fixed_cnonce: Option<String>,
}

impl AuthHandler {
    pub fn new(user: &str, password: &str) -> Self {
        Self { user: user.into(), password: password.into(), ..Default::default() }
    }

    pub fn consume_challenge(&mut self, www_authenticate: &str) {
        self.challenge = parse_authenticate(www_authenticate).unwrap_or_default();
        self.nonce_count = 0;
    }

    pub fn has_challenge(&self) -> bool {
        self.challenge.scheme != Scheme::None
    }

    pub fn challenge(&self) -> &Challenge {
        &self.challenge
    }

    pub fn authorization(&mut self, method: &str, uri: &str) -> String {
        match self.challenge.scheme {
            Scheme::Basic => {
                let tok = base64::engine::general_purpose::STANDARD.encode(format!("{}:{}", self.user, self.password));
                format!("Basic {tok}")
            }
            Scheme::Digest => self.digest(method, uri),
            Scheme::None => String::new(),
        }
    }

    fn cnonce(&self) -> String {
        if let Some(c) = &self.fixed_cnonce {
            return c.clone();
        }
        let seed = crate::clock::unix_ms() as u64 ^ (self as *const _ as u64).rotate_left(17) ^ self.nonce_count as u64;
        format!("{:016x}", seed.wrapping_mul(0x9E37_79B9_7F4A_7C15))
    }

    fn digest(&mut self, method: &str, uri: &str) -> String {
        let c = &self.challenge;
        let ha1 = md5_hex(&format!("{}:{}:{}", self.user, c.realm, self.password));
        let ha2 = md5_hex(&format!("{method}:{uri}"));
        let mut out;
        if !c.qop.is_empty() {
            self.nonce_count += 1;
            let nc = format!("{:08x}", self.nonce_count);
            let cnonce = self.cnonce();
            let c = &self.challenge;
            let qop = c.qop.split(',').next().map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).unwrap_or_else(|| "auth".into());
            let resp = md5_hex(&format!("{ha1}:{}:{nc}:{cnonce}:{qop}:{ha2}", c.nonce));
            let alg = if c.algorithm.is_empty() { "MD5" } else { &c.algorithm };
            out = format!(
                "Digest username=\"{}\", realm=\"{}\", nonce=\"{}\", uri=\"{uri}\", algorithm={alg}, qop={qop}, nc={nc}, cnonce=\"{cnonce}\", response=\"{resp}\"",
                self.user, c.realm, c.nonce
            );
        } else {
            let resp = md5_hex(&format!("{ha1}:{}:{ha2}", c.nonce));
            out = format!(
                "Digest username=\"{}\", realm=\"{}\", nonce=\"{}\", uri=\"{uri}\", response=\"{resp}\"",
                self.user, c.realm, c.nonce
            );
        }
        if !self.challenge.opaque.is_empty() {
            out.push_str(&format!(", opaque=\"{}\"", self.challenge.opaque));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_o_desafio() {
        let c = parse_authenticate(r#"Digest realm="IP Camera", nonce="abc123", qop="auth,auth-int", opaque=xyz"#).unwrap();
        assert_eq!(c.scheme, Scheme::Digest);
        assert_eq!(c.realm, "IP Camera");
        assert_eq!(c.nonce, "abc123");
        assert_eq!(c.qop, "auth,auth-int");
        assert_eq!(c.opaque, "xyz");
        assert!(parse_authenticate("Bearer x").is_none());
    }

    #[test]
    fn digest_da_rfc_2617() {
        // O exemplo da própria RFC (seção 3.5).
        let mut a = AuthHandler::new("Mufasa", "Circle Of Life");
        a.consume_challenge(r#"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#);
        a.fixed_cnonce = Some("0a4f113b".into());
        let h = a.authorization("GET", "/dir/index.html");
        assert!(h.contains("response=\"6629fae49393a05397450978507c4ef1\""), "{h}");
        assert!(h.contains("nc=00000001"));
        assert!(h.ends_with("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""));
    }

    #[test]
    fn basic() {
        let mut a = AuthHandler::new("admin", "1234");
        assert!(!a.has_challenge());
        a.consume_challenge("Basic realm=\"x\"");
        assert_eq!(a.authorization("DESCRIBE", "rtsp://h/"), "Basic YWRtaW46MTIzNA==");
    }
}
