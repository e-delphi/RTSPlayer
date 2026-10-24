//! A API HTTP do servidor e a interface web, na mesma porta do RTSP.
//!
//! O porteiro vem antes de tudo (`gate`): o que não passa dali não toca em
//! gravação, banco ou configuração. As rotas estão separadas por assunto:
//! gravações (`recordings`), administração (`admin`), câmera ao vivo (`ptz`),
//! análise (`analysis`) e entrada (`auth`). O formato de cada resposta é o
//! mesmo do servidor Delphi: a interface web não mudou.

mod admin;
mod analysis;
mod auth_routes;
mod ptz;
mod recordings;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use vms_core::clock::Clock;
use vms_core::http::{Handler, Request, Response};
use vms_core::live::LiveHub;
use vms_core::log::SharedLogger;
use vms_core::ptz_api::{OnvifCache, PtzApi};

use crate::analytics::probe::MotionProbe;
use crate::analytics::EventSource;
use crate::auth::{Acesso, Autenticador, SESSAO_PADRAO_HORAS};
use crate::config::ApiConfig;
use crate::db::Db;
use crate::index_cache::IndexCache;
use crate::interactions::InteractionLog;
use crate::media::MediaBuilder;
use crate::thumbs::ThumbSource;

const AUTH_RELEITURA: Duration = Duration::from_secs(5);
pub const API_DEFAULT_GAP_MS: i64 = 5000;
pub const MS_PER_DAY: i64 = 86_400_000;

/// O que o roteador precisa, montado pela composição.
pub struct ApiDeps {
    pub config: ApiConfig,
    pub db: Option<Arc<Db>>,
    pub cache: Arc<IndexCache>,
    pub hub: Option<Arc<LiveHub>>,
    pub thumbs: Arc<dyn ThumbSource>,
    pub events: Option<Arc<dyn EventSource>>,
    pub probe: Option<Arc<MotionProbe>>,
    pub log: SharedLogger,
    pub clock: Arc<dyn Clock>,
}

type Hook = Box<dyn Fn() + Send + Sync>;

pub struct ApiRouter {
    d: ApiDeps,
    cameras: Mutex<Vec<String>>,
    pendentes: Mutex<Vec<String>>,
    auth: Autenticador,
    auth_lido: Mutex<Option<Instant>>,
    media: MediaBuilder,
    ptz: PtzApi,
    controles: ptz::Controles,
    interacoes: InteractionLog,
    on_analytics: Mutex<Option<Hook>>,
}

/// Rotas que respondem sem credencial: a tela de entrada e o que ela usa.
fn rota_aberta(path: &str) -> bool {
    ["/ui/login", "/ui/ui.css", "/api/auth/status", "/api/auth/login", "/favicon.svg", "/favicon.ico"].iter().any(|r| r.eq_ignore_ascii_case(path))
}

impl ApiRouter {
    pub fn new(d: ApiDeps, cameras: Vec<String>) -> Arc<ApiRouter> {
        let db = d.db.clone();
        let resolver_db = db.clone();
        let onvif = Arc::new(OnvifCache::new(Arc::new(move |camera: &str| ptz::onvif_de(resolver_db.as_deref(), camera)), d.log.clone()));
        Arc::new(ApiRouter {
            media: MediaBuilder::new(d.cache.clone(), d.config.max_blocks_per_request.max(1) as usize),
            ptz: PtzApi::new(onvif, None),
            controles: ptz::Controles::new(d.log.clone(), d.clock.clone()),
            interacoes: InteractionLog::new(db, d.clock.clone(), d.log.clone()),
            d,
            cameras: Mutex::new(cameras),
            pendentes: Mutex::new(Vec::new()),
            auth: Autenticador::new(),
            auth_lido: Mutex::new(None),
            on_analytics: Mutex::new(None),
        })
    }

    pub fn log(&self) -> &SharedLogger {
        &self.d.log
    }

    pub fn db(&self) -> Option<&Db> {
        self.d.db.as_deref()
    }

    /// Avisado quando um `analytics.*` muda em `/api/settings`.
    pub fn on_analytics_mudou(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.on_analytics.lock().unwrap_or_else(|p| p.into_inner()) = Some(Box::new(f));
    }

    pub fn cameras_agora(&self) -> Vec<String> {
        self.cameras.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }

    pub fn definir_cameras(&self, nomes: Vec<String>) {
        *self.cameras.lock().unwrap_or_else(|p| p.into_inner()) = nomes;
        self.ptz.onvif_cache().forget();
    }

    /// As câmeras cujo cadastro mudou pela API desde a última pergunta.
    pub fn tomar_cameras_pendentes(&self) -> Vec<String> {
        std::mem::take(&mut *self.pendentes.lock().unwrap_or_else(|p| p.into_inner()))
    }

    fn anotar_pendente(&self, nome: &str) {
        self.pendentes.lock().unwrap_or_else(|p| p.into_inner()).push(nome.to_owned());
    }

    /// O nome como está no cadastro (a comparação ignora maiúsculas).
    pub fn known_camera(&self, name: &str) -> Option<String> {
        let n = name.trim();
        if n.is_empty() {
            return None;
        }
        self.cameras.lock().unwrap_or_else(|p| p.into_inner()).iter().find(|c| c.eq_ignore_ascii_case(n)).cloned()
    }

    pub fn is_live(&self, camera: &str) -> bool {
        self.d.hub.as_ref().and_then(|h| h.find(camera)).map(|s| s.is_publishing(10_000)).unwrap_or(false)
    }

    /// O que o laço principal chama a cada meio segundo.
    pub fn manter(&self) {
        self.interacoes.varrer();
        self.controles.manter(self, false);
    }

    pub fn encerrar(&self) {
        self.controles.fechar_todos();
        self.interacoes.fechar_todas();
    }

    pub fn recarregar_auth(&self) {
        *self.auth_lido.lock().unwrap_or_else(|p| p.into_inner()) = Some(Instant::now());
        let Some(db) = self.db() else {
            // Sem banco não se sabe se há senha: o lado seguro é "só o próprio
            // computador entra".
            self.auth.configurar(true, "admin", "", SESSAO_PADRAO_HORAS);
            return;
        };
        let s = crate::config::Settings::load(db);
        self.auth.configurar(s.str("auth.enabled", "1").trim() != "0", &s.str("auth.user", "admin"), &s.str("auth.hash", ""), s.int("auth.sessionHours", SESSAO_PADRAO_HORAS as i64).max(1) as u64);
    }

    fn gate(&self, req: &Request) -> Option<Response> {
        let velho = self.auth_lido.lock().unwrap_or_else(|p| p.into_inner()).map(|t| t.elapsed() > AUTH_RELEITURA).unwrap_or(true);
        if velho {
            self.recarregar_auth();
        }
        if rota_aberta(&req.path) {
            return None;
        }
        let mut a = self.auth.avaliar(req.header("Authorization").unwrap_or(""), req.header("Cookie").unwrap_or(""));
        if a == Acesso::SemSenhaDefinida && req.is_loopback() {
            a = Acesso::Liberado;
        }
        match a {
            Acesso::Liberado => None,
            Acesso::SemSenhaDefinida => Some(Response::error(
                503,
                "este servidor ainda nao tem senha definida; abra-o no proprio computador (http://localhost:8554) e defina uma em /ui/login",
            )),
            _ if req.path == "/" || req.path.to_ascii_lowercase().starts_with("/ui/") => Some(Response::text(302, "text/plain; charset=utf-8", "entre primeiro").with_header("Location", "/ui/login")),
            // Sem WWW-Authenticate: o navegador abriria o diálogo dele.
            _ => Some(Response::error(401, "nao autenticado")),
        }
    }

    fn ui(&self, path: &str) -> Option<Response> {
        let name = match path.to_ascii_lowercase().as_str() {
            "/" | "/ui/" | "/ui/app" => "app-ui.html",
            "/ui/login" => "login-ui.html",
            "/ui/motion" => "motion-ui.html",
            "/ui/events" => "events-ui.html",
            "/ui/player" => "player-ui.html",
            "/ui/cameras" => "cameras-ui.html",
            "/ui/ui.css" => "ui.css",
            "/ui/vmsreader.js" => "vmsreader.js",
            "/ui/player.js" => "player.js",
            "/favicon.svg" | "/favicon.ico" => {
                let r = vms_core::ui::response("favicon.svg");
                return Some(if r.status == 200 { Response { headers: vec![("Cache-Control".into(), "public, max-age=86400".into())], ..r } } else { r });
            }
            _ => return None,
        };
        Some(vms_core::ui::response(name))
    }

    fn route(&self, req: &Request) -> Response {
        if !self.d.config.enabled {
            return Response::error(404, "api desligada");
        }
        if let Some(r) = self.gate(req) {
            return r;
        }
        let path = req.path.to_ascii_lowercase();
        let m = req.method.as_str();
        match path.as_str() {
            "/api/auth/status" => return self.auth_status(req),
            "/api/auth/login" => return self.login(req),
            "/api/auth/logout" => return self.logout(req),
            "/api/auth/password" => return self.definir_senha(req),
            _ => {}
        }
        if let Some(r) = self.ui(&path) {
            return r;
        }
        match path.as_str() {
            "/api/sql" if m == "GET" || m == "POST" => return self.sql(req),
            "/api/sql" => return Response::error(405, "use GET ou POST"),
            "/api/settings" if m == "POST" => return self.settings_post(req),
            "/api/settings" if m == "GET" || m == "HEAD" => return self.settings_get(),
            "/api/settings" => return Response::error(405, "use GET ou POST"),
            "/api/config/ptz/procurar" if m == "POST" => return self.procurar_ptz(req),
            "/api/config/ptz/procurar" => return Response::error(405, "use POST"),
            "/api/fala" if m == "GET" || m == "POST" => return self.fala(req),
            "/api/fala" => return Response::error(405, "use GET ou POST"),
            "/api/config/cameras" if m == "POST" => return self.config_cameras_post(req),
            "/api/config/cameras" if m == "GET" || m == "HEAD" => return self.config_cameras_get(),
            "/api/config/cameras" => return Response::error(405, "use GET ou POST"),
            _ => {}
        }
        if m != "GET" && m != "HEAD" {
            return Response::error(405, "so GET e HEAD");
        }
        match path.as_str() {
            "/api/cameras" => self.cameras_list(),
            "/api/days" => self.days(req),
            "/api/segments" => self.segments(req),
            "/api/media" => self.media_route(req),
            "/api/live" => self.live(req),
            "/api/ptz" => self.ptz_route(req),
            "/api/interacoes" => self.interacoes_route(req),
            "/api/recordings" => self.recordings(req),
            "/api/index" => self.index_route(req),
            "/api/thumb" => self.thumb(req),
            "/api/events" => self.events_route(req),
            "/api/motion/probe" => self.motion_probe(req),
            _ => Response::error(404, &format!("rota desconhecida: {}", req.path)),
        }
    }
}

impl Handler for ApiRouter {
    fn handle(&self, req: &Request) -> Response {
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.route(req))).unwrap_or_else(|_| {
            self.d.log.error("api", &format!("{} {}: falha interna", req.method, req.uri()));
            Response::error(500, "falha interna")
        });
        // Nada de cache por padrão: gravação em curso muda a cada segundo.
        if r.header("Cache-Control").is_none() {
            r.with_header("Cache-Control", "no-store")
        } else {
            r
        }
    }
}

/// O roteador atrás de um `Arc` serve de `Handler` para o listener.
pub struct SharedRouter(pub Arc<ApiRouter>);

impl Handler for SharedRouter {
    fn handle(&self, req: &Request) -> Response {
        self.0.handle(req)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use vms_core::clock::SystemClock;

    pub fn router(tag: &str, storage: &std::path::Path, cameras: &[&str]) -> (Arc<ApiRouter>, Arc<Db>) {
        let db = Db::memory(tag);
        crate::db::ensure_schema(&db, 1).unwrap();
        let cams: Vec<vms_core::camera_json::CameraEntry> = cameras.iter().map(|n| vms_core::camera_json::CameraEntry { name: (*n).into(), ..Default::default() }).collect();
        crate::config::ensure_cameras(&db, &cams, 1);
        let log = vms_core::log::null();
        let d = ApiDeps {
            config: ApiConfig::default(),
            db: Some(db.clone()),
            cache: Arc::new(IndexCache::new(storage, Some(db.clone()), log.clone())),
            hub: Some(Arc::new(LiveHub::new(Default::default(), log.clone(), Arc::new(SystemClock)))),
            thumbs: Arc::new(crate::thumbs::NullThumbSource),
            events: None,
            probe: None,
            log,
            clock: Arc::new(SystemClock),
        };
        (ApiRouter::new(d, cameras.iter().map(|s| s.to_string()).collect()), db)
    }

    pub fn local(method: &str, uri: &str) -> Request {
        let mut r = Request::new(method, uri);
        r.peer = Some("127.0.0.1:5000".parse().unwrap());
        r
    }

    #[test]
    fn porteiro_e_paginas() {
        let d = vms_core::testutil::TempDir::new("api-gate");
        let (r, _db) = router("api-gate", d.path(), &["cam"]);
        // Sem senha: só o próprio computador entra.
        assert_eq!(r.handle(&local("GET", "/api/cameras")).status, 200);
        let mut fora = Request::new("GET", "/api/cameras");
        fora.peer = Some("10.0.0.9:5000".parse().unwrap());
        assert_eq!(r.handle(&fora).status, 503);
        // A tela de entrada abre para qualquer um.
        let mut l = Request::new("GET", "/ui/login");
        l.peer = fora.peer;
        assert_eq!(r.handle(&l).status, 200);
        let p = r.handle(&local("GET", "/"));
        assert_eq!(p.status, 200);
        assert_eq!(p.header("Cache-Control"), Some("no-store"));
        assert_eq!(r.handle(&local("GET", "/favicon.ico")).header("Cache-Control"), Some("public, max-age=86400"));
        assert_eq!(r.handle(&local("POST", "/api/cameras")).status, 405);
        assert_eq!(r.handle(&local("GET", "/api/nada")).status, 404);
    }
}
