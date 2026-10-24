//! O atendimento de `/api/ptz`, igual no app e no servidor: DVRIP pela sessão
//! viva quando há (o comando sai pela conexão já autenticada), senão ONVIF.
//!
//! A tela não sabe qual protocolo atende: manda pan/tilt/zoom em milésimos e
//! lê o `via` da resposta.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use crate::dvrip::protocol as dv;
use crate::http::{Request, Response};
use crate::log::SharedLogger;
use crate::onvif::{self, Move, OnvifClient};
use crate::ptz::PtzRegistry;

/// Onde está o ONVIF de cada câmera: (xaddr, usuário, senha). `None` = a
/// câmera não tem endereço de ONVIF cadastrado.
pub type OnvifResolver = Arc<dyn Fn(&str) -> Option<(String, String, String)> + Send + Sync>;

/// Um cliente ONVIF por câmera, guardado: a preparação custa três idas à
/// câmera, e um gesto de PTZ manda dois comandos.
pub struct OnvifCache {
    resolver: OnvifResolver,
    log: SharedLogger,
    clients: Mutex<HashMap<String, Arc<Mutex<OnvifClient>>>>,
}

impl OnvifCache {
    pub fn new(resolver: OnvifResolver, log: SharedLogger) -> Self {
        Self { resolver, log, clients: Mutex::new(HashMap::new()) }
    }

    pub fn client(&self, camera: &str) -> Option<Arc<Mutex<OnvifClient>>> {
        let k = camera.trim().to_lowercase();
        if let Some(c) = self.clients.lock().unwrap_or_else(|p| p.into_inner()).get(&k) {
            return Some(c.clone());
        }
        let (xaddr, user, pass) = (self.resolver)(camera)?;
        if xaddr.trim().is_empty() {
            return None;
        }
        let c = Arc::new(Mutex::new(OnvifClient::new(&xaddr, &user, &pass, Some(self.log.clone()), &format!("ptz.{camera}"), 0)));
        Some(self.clients.lock().unwrap_or_else(|p| p.into_inner()).entry(k).or_insert(c).clone())
    }

    /// Esquece tudo: o cadastro mudou.
    pub fn forget(&self) {
        self.clients.lock().unwrap_or_else(|p| p.into_inner()).clear();
    }
}

/// Antes do ONVIF, o dono pode abrir uma sessão DVRIP de comando e esperar por
/// ela (o servidor faz isso para câmera gravada por RTSP). Devolve a resposta
/// de erro quando ainda não deu.
pub type ControlOpener = Arc<dyn Fn(&str) -> Option<Response> + Send + Sync>;

pub struct PtzApi {
    onvif: Arc<OnvifCache>,
    ultimo: Mutex<HashMap<String, String>>,
    opener: Option<ControlOpener>,
}

/// pan/tilt/zoom chegam em milésimos: sem ponto nem vírgula para o cliente errar.
fn num(q: &Request, name: &str) -> f64 {
    q.param(name).trim().parse::<i64>().unwrap_or(0) as f64 / 1000.0
}

impl PtzApi {
    pub fn new(onvif: Arc<OnvifCache>, opener: Option<ControlOpener>) -> Self {
        Self { onvif, ultimo: Mutex::new(HashMap::new()), opener }
    }

    pub fn onvif_cache(&self) -> &Arc<OnvifCache> {
        &self.onvif
    }

    pub fn handle(&self, camera: &str, q: &Request) -> Response {
        let acao = q.param("acao").trim().to_lowercase();
        if PtzRegistry::achar(camera).is_none() {
            if let Some(open) = &self.opener {
                if let Some(r) = open(camera) {
                    return r;
                }
            }
        }
        match PtzRegistry::achar(camera) {
            Some(s) => self.dvrip(camera, &acao, q, &*s),
            None => self.via_onvif(camera, &acao, q),
        }
    }

    fn dvrip(&self, camera: &str, acao: &str, q: &Request, s: &dyn crate::ptz::PtzSession) -> Response {
        let canal = q.param("canal").trim().parse().unwrap_or(0);
        let key = camera.to_lowercase();
        let mut comando = String::new();
        let mut passo = 5;
        let ok = match acao {
            "mover" => {
                let (p, t, z) = (num(q, "pan"), num(q, "tilt"), num(q, "zoom"));
                comando = dv::comando_de(p, t, z).to_owned();
                passo = dv::passo_de(p, t, z);
                if comando.is_empty() {
                    return Response::error(400, "direcao vazia: informe pan, tilt ou zoom");
                }
                self.ultimo.lock().unwrap_or_else(|p| p.into_inner()).insert(key, comando.clone());
                s.mover_ptz(&comando, passo, canal, true)
            }
            "parar" => {
                // A parada repete o comando que estava andando; sem saber qual,
                // para pela esquerda, que as câmeras aceitam como "pare tudo".
                comando = self.ultimo.lock().unwrap_or_else(|p| p.into_inner()).get(&key).cloned().unwrap_or_else(|| dv::PTZ_ESQUERDA.into());
                s.mover_ptz(&comando, passo, canal, false)
            }
            "foco" | "iris" => {
                let dir = q.param("dir").trim().to_lowercase();
                comando = match (acao, dir.as_str()) {
                    ("foco", "perto") => dv::PTZ_FOCO_PERTO,
                    ("foco", "longe") => dv::PTZ_FOCO_LONGE,
                    ("iris", "abrir") => dv::PTZ_IRIS_ABRE,
                    ("iris", "fechar") => dv::PTZ_IRIS_FECHA,
                    _ => return Response::error(400, "informe dir"),
                }
                .to_owned();
                self.ultimo.lock().unwrap_or_else(|p| p.into_inner()).insert(key, comando.clone());
                s.mover_ptz(&comando, passo, canal, true)
            }
            "ronda" => {
                comando = if q.param("ligar").trim() == "0" { dv::PTZ_RONDA_FIM } else { dv::PTZ_RONDA_INI }.to_owned();
                s.mover_ptz(&comando, passo, canal, true)
            }
            "preset" => {
                let n: i32 = q.param("n").trim().parse().unwrap_or(-1);
                if n < 0 {
                    return Response::error(400, "informe n, o numero do preset");
                }
                comando = match q.param("op").trim().to_lowercase().as_str() {
                    "gravar" => dv::PTZ_PRESET_POR,
                    "apagar" => dv::PTZ_PRESET_LIMPA,
                    _ => dv::PTZ_PRESET_IR,
                }
                .to_owned();
                s.ir_para_preset(n, canal, &comando)
            }
            "config" => {
                comando = q.param("nome").trim().to_owned();
                if comando.is_empty() {
                    return Response::error(400, "informe nome, a secao da configuracao");
                }
                s.perguntar_config(&comando)
            }
            "testar" => true,
            _ => return Response::error(400, &format!("{acao} nao existe no DVRIP: use mover, parar, foco, iris, ronda, preset, config ou testar")),
        };
        let mut j = json!({ "camera": camera, "acao": acao, "via": "dvrip", "ok": ok });
        if !comando.is_empty() {
            j["comando"] = json!(comando);
        }
        if !ok {
            j["motivo"] = json!("nao consegui escrever na sessao");
        }
        Response::json(&j)
    }

    fn via_onvif(&self, camera: &str, acao: &str, q: &Request) -> Response {
        let Some(cli) = self.onvif.client(camera) else {
            return Response::error(503, "camera sem sessao DVRIP viva e sem cadastro utilizavel para ONVIF");
        };
        let mut c = cli.lock().unwrap_or_else(|p| p.into_inner());
        let mut extra: Vec<(&str, Value)> = Vec::new();
        let ok = match acao {
            "parar" => c.parar(),
            "mover" => c.mover_continuo(Move::new(num(q, "pan"), num(q, "tilt"), num(q, "zoom"))),
            "ir" | "preset" => {
                let alvo = format!("{}{}", q.param("preset").trim(), q.param("n").trim());
                match q.param("op").trim().to_lowercase().as_str() {
                    "gravar" => match c.guardar_preset(&alvo, q.param("nome").trim()) {
                        Some(t) => {
                            if !t.is_empty() {
                                extra.push(("token", json!(t)));
                            }
                            true
                        }
                        None => false,
                    },
                    "apagar" => c.apagar_preset(&alvo),
                    _ => c.ir_para_preset(&alvo),
                }
            }
            "presets" => match c.ler_presets() {
                Some(l) => {
                    extra.push(("presets", Value::Array(l.iter().map(|p| json!({ "token": p.token, "nome": p.nome })).collect())));
                    true
                }
                None => {
                    extra.push(("presets", json!([])));
                    false
                }
            },
            "testar" => c.preparar(),
            _ => return Response::error(400, "acao invalida: use mover, parar, presets, preset, ir ou testar"),
        };
        let mut j = json!({ "camera": camera, "acao": acao, "via": "onvif", "ok": ok });
        if !ok {
            j["motivo"] = json!(c.motivo());
        }
        if acao == "testar" {
            j["ptz"] = json!(c.tem_ptz());
            j["servico"] = json!(c.ptz_url());
            j["perfil"] = json!(c.perfil());
        }
        for (k, v) in extra {
            j[k] = v;
        }
        Response::json(&j)
    }
}

/// `POST {url, user, password}` → em que porta a câmera atende ONVIF.
pub fn procurar(host: &str, user: &str, pass: &str, log: SharedLogger) -> Response {
    let achados = onvif::procurar(host, user, pass, Some(log), 1500);
    let melhor = achados.iter().find(|a| a.tem_ptz).map(|a| format!("{host}:{}", a.porta)).unwrap_or_default();
    Response::json(&json!({
        "host": host,
        "achados": achados.iter().map(|a| json!({ "porta": a.porta, "ptz": a.tem_ptz })).collect::<Vec<_>>(),
        "melhor": melhor,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ptz::tests::PtzFalsa;
    use crate::ptz::PtzSession;

    #[test]
    fn dvrip_pela_sessao_viva_e_parada_repete_o_comando() {
        let p = Arc::new(PtzFalsa::default());
        let s: Arc<dyn PtzSession> = p.clone();
        PtzRegistry::anunciar("ptzapi1", s.clone());
        let api = PtzApi::new(Arc::new(OnvifCache::new(Arc::new(|_| None), crate::log::null())), None);
        let r = api.handle("ptzapi1", &Request::new("GET", "/api/ptz?acao=mover&pan=-1000"));
        let j = r.json_value();
        assert_eq!(j["via"], "dvrip");
        assert_eq!(j["comando"], dv::PTZ_ESQUERDA);
        api.handle("ptzapi1", &Request::new("GET", "/api/ptz?acao=parar"));
        api.handle("ptzapi1", &Request::new("GET", "/api/ptz?acao=preset&n=3&op=gravar"));
        assert_eq!(api.handle("ptzapi1", &Request::new("GET", "/api/ptz?acao=mover")).status, 400);
        let c = p.comandos.lock().unwrap().clone();
        assert_eq!(c[0], "DirectionRight 8 true");
        assert_eq!(c[1], "DirectionRight 5 false");
        assert_eq!(c[2], "preset 3 SetPreset");
        PtzRegistry::apagar("ptzapi1", &s);
        let r = api.handle("ptzapi1", &Request::new("GET", "/api/ptz?acao=testar"));
        assert_eq!(r.status, 503, "sem sessao e sem ONVIF");
    }
}
