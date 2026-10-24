//! Os servidores cadastrados no app (`servers.json`) e por onde falar com cada
//! um: várias rotas (a LAN, a tailnet), a primeira que responde vale por 30 s.
//!
//! O JSON é da tela; aqui só se lê `name`, `routes[{url, tailscale}]` (ou um
//! `url` solto), `user` e `password`. Acrescentar campo não mexe aqui.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use vms_core::log::SharedLogger;
use vms_core::net;

pub const VALIDADE: Duration = Duration::from_secs(30);
pub const SONDA_MS: u64 = 1200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rota {
    pub url: String,
    pub tailscale: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Servidor {
    pub nome: String,
    pub rotas: Vec<Rota>,
    pub usuario: String,
    pub senha: String,
}

/// Quem diz se uma rota responde (o teste troca).
pub type Sonda = Box<dyn Fn(&str, u16, u64) -> bool + Send + Sync>;

pub struct Registro {
    servidores: Mutex<Vec<Servidor>>,
    escolha: Mutex<HashMap<String, (String, Instant)>>,
    sonda: Sonda,
    log: SharedLogger,
}

/// `http(s)://host[:porta]/...` → (host, porta)
pub fn host_e_porta(url: &str) -> Option<(String, u16)> {
    let s = url.trim();
    let (seguro, rest) = if let Some(r) = s.strip_prefix("https://") {
        (true, r)
    } else {
        (false, s.strip_prefix("http://").unwrap_or(s))
    };
    let aut = rest.split('/').next().unwrap_or("");
    if aut.is_empty() {
        return None;
    }
    match aut.rsplit_once(':').and_then(|(h, p)| p.parse::<u16>().ok().filter(|&p| p > 0).map(|p| (h, p))) {
        Some((h, p)) => Some((h.to_owned(), p)),
        None => Some((aut.to_owned(), if seguro { 443 } else { 80 })),
    }
}

pub fn parse(json: &str) -> Vec<Servidor> {
    // O app Delphi gravava com BOM.
    let Ok(v) = serde_json::from_str::<Value>(json.trim_start_matches('\u{feff}')) else { return Vec::new() };
    let Some(arr) = v.get("servers").and_then(Value::as_array) else { return Vec::new() };
    let s = |o: &Value, k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    let rota = |o: &Value| {
        let url = s(o, "url").trim().trim_end_matches('/').to_owned();
        (!url.is_empty()).then(|| Rota { url, tailscale: o.get("tailscale").and_then(Value::as_bool).unwrap_or(false) })
    };
    arr.iter()
        .filter(|i| i.is_object())
        .filter_map(|i| {
            let mut rotas: Vec<Rota> = i.get("routes").and_then(Value::as_array).map(|r| r.iter().filter_map(rota).collect()).unwrap_or_default();
            if rotas.is_empty() {
                rotas.extend(rota(i));
            }
            (!rotas.is_empty()).then(|| Servidor { nome: s(i, "name"), rotas, usuario: s(i, "user"), senha: s(i, "password") })
        })
        .collect()
}

impl Registro {
    pub fn new(log: SharedLogger) -> Self {
        Self::with_sonda(log, Box::new(net::tailnet_reachable))
    }

    pub fn with_sonda(log: SharedLogger, sonda: Sonda) -> Self {
        Self { servidores: Mutex::new(Vec::new()), escolha: Mutex::new(HashMap::new()), sonda, log }
    }

    pub fn carregar(&self, json: &str) {
        let l = parse(json);
        *self.servidores.lock().unwrap_or_else(|p| p.into_inner()) = l;
        self.escolha.lock().unwrap_or_else(|p| p.into_inner()).clear();
        self.log.info("servidores", &format!("cadastro lido: {}", self.diagnostico()));
    }

    fn achar(&self, nome: &str) -> Option<Servidor> {
        self.servidores.lock().unwrap_or_else(|p| p.into_inner()).iter().find(|s| s.nome.eq_ignore_ascii_case(nome)).cloned()
    }

    pub fn invalidar(&self, nome: &str) {
        self.escolha.lock().unwrap_or_else(|p| p.into_inner()).remove(&nome.to_lowercase());
    }

    pub fn credencial(&self, nome: &str) -> Option<(String, String)> {
        self.achar(nome).filter(|s| !s.usuario.trim().is_empty()).map(|s| (s.usuario, s.senha))
    }

    pub fn diagnostico(&self) -> String {
        let l = self.servidores.lock().unwrap_or_else(|p| p.into_inner());
        if l.is_empty() {
            return "nenhum servidor no cadastro em memoria".into();
        }
        let nomes: Vec<String> = l.iter().map(|s| format!("{} ({} rota{})", s.nome, s.rotas.len(), if s.rotas.len() == 1 { "" } else { "s" })).collect();
        format!("{} no cadastro: {}", l.len(), nomes.join(", "))
    }

    /// A primeira rota que não é de tailnet e responde; senão a da tailnet
    /// (garantindo o túnel); senão a primeira.
    fn escolher(&self, s: &Servidor) -> String {
        if s.rotas.len() == 1 {
            return s.rotas[0].url.clone();
        }
        for r in s.rotas.iter().filter(|r| !r.tailscale) {
            if let Some((h, p)) = host_e_porta(&r.url) {
                if (self.sonda)(&h, p, SONDA_MS) {
                    self.log.debug("servidores", &format!("{}: {} respondeu", s.nome, r.url));
                    return r.url.clone();
                }
            }
        }
        if let Some(t) = s.rotas.iter().find(|r| r.tailscale) {
            if let Some((h, p)) = host_e_porta(&t.url) {
                self.log.info("servidores", &format!("{}: so a rota de tailnet resta; garantindo o tunel ate {h}:{p}", s.nome));
                net::ensure_tailnet_up(&h, p, &*self.log, None, net::TAILNET_WAIT_MS);
            }
            return t.url.clone();
        }
        s.rotas[0].url.clone()
    }

    /// A URL base de um servidor ('' = não cadastrado).
    pub fn url_de(&self, nome: &str) -> String {
        if nome.trim().is_empty() {
            return String::new();
        }
        let k = nome.to_lowercase();
        if let Some((u, t)) = self.escolha.lock().unwrap_or_else(|p| p.into_inner()).get(&k) {
            if t.elapsed() < VALIDADE {
                return u.clone();
            }
        }
        let Some(s) = self.achar(nome) else {
            self.log.warn("servidores", &format!("pediram \"{nome}\"; {}", self.diagnostico()));
            return String::new();
        };
        let u = self.escolher(&s);
        if !u.is_empty() {
            self.escolha.lock().unwrap_or_else(|p| p.into_inner()).insert(k, (u.clone(), Instant::now()));
        }
        u
    }

    /// Testa todas as rotas (a tela de diagnóstico).
    pub fn sondar_todas(&self, nome: &str) -> Value {
        let Some(s) = self.achar(nome) else { return json!({ "server": nome, "routes": [], "error": "servidor nao cadastrado" }) };
        let rotas: Vec<Value> = s
            .rotas
            .iter()
            .map(|r| {
                let t = Instant::now();
                let mut o = json!({ "url": r.url, "tailscale": r.tailscale });
                let ok = match host_e_porta(&r.url) {
                    Some((h, p)) => (self.sonda)(&h, p, SONDA_MS),
                    None => {
                        o["error"] = json!("endereco invalido");
                        false
                    }
                };
                o["ok"] = json!(ok);
                o["ms"] = json!(t.elapsed().as_millis() as u64);
                o
            })
            .collect();
        let cached = self.escolha.lock().unwrap_or_else(|p| p.into_inner()).get(&nome.to_lowercase()).filter(|(_, t)| t.elapsed() < VALIDADE).map(|(u, _)| u.clone());
        let chosen = cached.unwrap_or_else(|| rotas.iter().find(|r| r["ok"] == true).and_then(|r| r["url"].as_str()).unwrap_or("").to_owned());
        json!({ "server": nome, "routes": rotas, "chosen": chosen })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const J: &str = r#"{"servers":[
        {"name":"Casa","user":"admin","password":"x","routes":[{"url":"http://192.168.0.5:8554/"},{"url":"https://casa.ts.net","tailscale":true}]},
        {"name":"Velho","url":"http://10.0.0.1:8554"},
        {"name":"Vazio","routes":[]}]}"#;

    #[test]
    fn le_o_arquivo_com_bom() {
        let l = parse(&format!("\u{feff}{J}"));
        assert!(!l.is_empty());
        assert_eq!(l, parse(J));
    }

    #[test]
    fn rotas_cache_e_credencial() {
        let r = Registro::with_sonda(vms_core::log::null(), Box::new(|h, _, _| h == "192.168.0.5"));
        r.carregar(J);
        assert!(r.diagnostico().starts_with("2 no cadastro"), "o vazio fica de fora");
        assert_eq!(r.url_de("casa"), "http://192.168.0.5:8554");
        assert_eq!(r.url_de("VELHO"), "http://10.0.0.1:8554");
        assert_eq!(r.url_de("nada"), "");
        assert_eq!(r.credencial("Casa"), Some(("admin".into(), "x".into())));
        assert_eq!(r.credencial("Velho"), None);
        let s = r.sondar_todas("Casa");
        assert_eq!(s["routes"][0]["ok"], true);
        assert_eq!(s["chosen"], "http://192.168.0.5:8554");
        assert_eq!(host_e_porta("https://casa.ts.net"), Some(("casa.ts.net".into(), 443)));
        assert_eq!(host_e_porta("http://h:81/x"), Some(("h".into(), 81)));
    }
}
