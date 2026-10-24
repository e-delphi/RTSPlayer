//! O que o app atende sozinho, e o que ele encaminha ao vmsserver.
//!
//! A página é a mesma do servidor; aqui ela roda dentro do WebView2 e fala com
//! este roteador pelo próprio origin (`https://rtsplayer.app/api/...`, servido
//! da memória pelo `WebResourceRequested`). Pedido com `server=<nome>` é de um
//! servidor cadastrado e segue para ele (com o Basic do cadastro e os
//! `X-Vms-*` de volta); sem `server`, é das câmeras do próprio app.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine;
use serde_json::{json, Value};
use vms_core::clock::Clock;
use vms_core::http::{Handler, Request, Response};
use vms_core::log::{MemoryLogger, SharedLogger};
use vms_core::ptz::FalaRegistry;
use vms_core::ptz::PtzRegistry;
use vms_core::ptz_api::{OnvifCache, PtzApi};
use vms_core::ptz_control::{is_dvrip_ptz, ControlSessions, ESPERA_PRONTA};

use crate::cameras::CameraStore;
use crate::live::{LiveViewer, Starter};
use crate::servers::Registro;
use crate::upstream::Upstream;

const LIVE_ESPERA_MS: u64 = 1500;

/// O que só a janela sabe fazer.
pub trait Window: Send + Sync {
    fn sair(&self);
    /// `pedido` "1"/"0" liga/desliga o sempre-à-frente; "" só pergunta.
    /// None = não dá para fixar aqui.
    fn frente(&self, pedido: &str) -> Option<bool>;
}

/// Sem janela (testes, ou antes de ela existir).
pub struct NoWindow;

impl Window for NoWindow {
    fn sair(&self) {}
    fn frente(&self, _: &str) -> Option<bool> {
        None
    }
}

pub struct AppDeps {
    pub dir: PathBuf,
    pub log: SharedLogger,
    pub memo: Arc<MemoryLogger>,
    pub clock: Arc<dyn Clock>,
    pub upstream: Arc<dyn Upstream>,
    pub starter: Starter,
    pub window: Arc<dyn Window>,
}

pub struct App {
    cameras: Arc<CameraStore>,
    servers: Registro,
    servers_path: PathBuf,
    servers_json: std::sync::Mutex<String>,
    live: LiveViewer,
    ptz: PtzApi,
    controles: ControlSessions,
    upstream: Arc<dyn Upstream>,
    window: Arc<dyn Window>,
    memo: Arc<MemoryLogger>,
    log: SharedLogger,
}

/// O ONVIF de uma câmera do app: o `ptz` do cadastro (não DVRIP) resolvido
/// contra a URL dela, com o usuário e a senha do primeiro caminho.
fn onvif_da_camera(store: &CameraStore, camera: &str) -> Option<(String, String, String)> {
    let c = store.find(camera)?;
    let ptz = c.ptz.trim();
    if ptz.is_empty() || ptz.to_ascii_lowercase().starts_with("dvrip://") {
        return None;
    }
    let e = c.first()?;
    Some((vms_core::onvif::endereco_onvif(ptz, &e.url), e.user.clone(), e.password.clone()))
}

fn basic(u: &str, p: &str) -> String {
    format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(format!("{u}:{p}")))
}

impl App {
    pub fn new(d: AppDeps) -> Arc<App> {
        let cameras = Arc::new(CameraStore::open(&d.dir.join("cameras.json"), d.log.clone()));
        let servers_path = d.dir.join("servers.json");
        let servers_json = std::fs::read_to_string(&servers_path).map(|t| t.trim_start_matches('\u{feff}').to_owned()).unwrap_or_else(|_| r#"{"servers":[]}"#.into());
        d.log.info("cfg", &format!("servers.json em {} ({}, {} bytes)", servers_path.display(), if servers_path.is_file() { "existe" } else { "NAO existe" }, servers_json.len()));
        let servers = Registro::new(d.log.clone());
        servers.carregar(&servers_json);
        let store = cameras.clone();
        let onvif = Arc::new(OnvifCache::new(Arc::new(move |c: &str| onvif_da_camera(&store, c)), d.log.clone()));
        Arc::new(App {
            cameras,
            servers,
            servers_path,
            servers_json: std::sync::Mutex::new(servers_json),
            live: LiveViewer::new(d.starter, d.log.clone(), d.clock.clone()),
            ptz: PtzApi::new(onvif, None),
            controles: ControlSessions::new(d.log.clone(), d.clock.clone()),
            upstream: d.upstream,
            window: d.window,
            memo: d.memo,
            log: d.log,
        })
    }

    pub fn servers(&self) -> &Registro {
        &self.servers
    }

    /// Fecha o ao vivo e as sessões de comando (sair).
    pub fn encerrar(&self) {
        self.live.parar();
        self.controles.close_all();
    }

    /// Câmera com vídeo por RTSP e PTZ por DVRIP (`ptz` = `dvrip://…`): sem
    /// sessão viva no registro, abre a de comando e espera um pouco por ela —
    /// o mesmo que o servidor faz.
    fn garantir_controle(&self, camera: &str) {
        if PtzRegistry::achar(camera).is_some() {
            return;
        }
        let Some(c) = self.cameras.find(camera) else { return };
        if !is_dvrip_ptz(&c.ptz) {
            return;
        }
        let (user, password) = c.first().map(|e| (e.user.clone(), e.password.clone())).unwrap_or_default();
        self.controles.ensure(vms_core::camera::CameraConfig { name: c.name.clone(), url: c.ptz.trim().to_owned(), user, password, connect_timeout_ms: 8000, rtsp_timeout_ms: 8000, ..Default::default() });
        ControlSessions::wait_ready(&c.name, ESPERA_PRONTA);
    }

    fn cameras_local(&self) -> Response {
        Response::json(&json!({ "cameras": self.cameras.enabled_names().iter().map(|n| json!({ "name": n })).collect::<Vec<_>>() }))
    }

    fn app_cameras(&self, req: &Request) -> Response {
        if req.method == "POST" {
            if req.body.iter().all(u8::is_ascii_whitespace) {
                return Response::error(400, "corpo vazio");
            }
            return match self.cameras.gravar(&req.body_text()) {
                Ok(()) => {
                    self.ptz.onvif_cache().forget();
                    Response::json(&json!({ "ok": true }))
                }
                Err(e) => Response::error(400, &e),
            };
        }
        Response::new(200, "application/json; charset=utf-8", self.cameras.json_sem_senha().into_bytes())
    }

    fn app_servers(&self, req: &Request) -> Response {
        if req.method != "POST" {
            let j = self.servers_json.lock().unwrap_or_else(|p| p.into_inner()).clone();
            return Response::new(200, "application/json; charset=utf-8", j.into_bytes());
        }
        let body = req.body_text();
        if body.trim().is_empty() {
            return Response::error(400, "corpo vazio");
        }
        if !serde_json::from_str::<Value>(&body).is_ok_and(|v| v.is_object()) {
            return Response::error(400, "json invalido");
        }
        if let Err(e) = std::fs::write(&self.servers_path, &body) {
            return Response::error(400, &e.to_string());
        }
        self.servers.carregar(&body);
        *self.servers_json.lock().unwrap_or_else(|p| p.into_inner()) = body;
        Response::json(&json!({ "ok": true }))
    }

    fn live(&self, req: &Request) -> Response {
        let cam = req.param("camera");
        if cam.trim().is_empty() {
            return Response::error(400, "informe camera");
        }
        let Some(c) = self.cameras.find(&cam).filter(|c| c.enabled) else {
            return Response::new(204, "application/x-vms", Vec::new()).with_header("X-Vms-Live", "0");
        };
        let f = self.live.fragment(&c, req.param("cursor").trim(), LIVE_ESPERA_MS);
        let mut r = Response::new(f.status, "application/x-vms", f.body);
        r.headers.extend(f.headers);
        r
    }

    fn procurar_ptz(&self, req: &Request) -> Response {
        let Some(o) = serde_json::from_slice::<Value>(&req.body).ok().filter(Value::is_object) else { return Response::error(400, "mande {url, user, password}") };
        let s = |k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        let host = vms_core::onvif::host_da_url(&s("url"));
        if host.is_empty() {
            return Response::error(400, "a url nao tem host");
        }
        let (mut user, mut pass) = (s("user"), s("password"));
        // A tela não tem a senha (só `temSenha`): vale a do cadastro.
        if pass.is_empty() {
            if let Some(c) = self.cameras.find(s("camera").trim()) {
                if let Some(e) = c.first() {
                    pass = e.password.clone();
                    if user.trim().is_empty() {
                        user = e.user.clone();
                    }
                }
            }
        }
        vms_core::ptz_api::procurar(&host, &user, &pass, self.log.clone())
    }

    fn ptz_local(&self, req: &Request) -> Response {
        let cam = req.param("camera").trim().to_owned();
        if cam.is_empty() {
            return Response::error(400, "informe camera");
        }
        self.garantir_controle(&cam);
        self.ptz.handle(&cam, req)
    }

    fn fala_local(&self, req: &Request) -> Response {
        let cam = req.param("camera").trim().to_owned();
        if cam.is_empty() {
            return Response::error(400, "informe camera");
        }
        self.garantir_controle(&cam);
        let (st, j) = FalaRegistry::atender(&cam, &req.param("acao").trim().to_lowercase(), &req.body);
        Response::new(st, "application/json; charset=utf-8", j.into_bytes())
    }

    fn frente(&self, req: &Request) -> Response {
        let pedido = if req.method == "POST" { req.param("ligar").trim().to_owned() } else { String::new() };
        let r = self.window.frente(&pedido);
        Response::json(&json!({ "disponivel": r.is_some(), "ligado": r.unwrap_or(false) }))
    }

    fn log_route(&self, req: &Request) -> Response {
        let desde = req.param_i64("desde", -1).max(0) as u64;
        let (linhas, prox) = self.memo.read_since(desde);
        Response::json(&json!({ "proxima": prox, "linhas": linhas }))
    }

    /// Para o servidor do `server=`, com o Basic do cadastro; volta o status,
    /// o tipo e os `X-Vms-*`.
    fn encaminhar(&self, req: &Request) -> Response {
        let nome = req.param("server").trim().to_owned();
        let base = self.servers.url_de(&nome);
        if base.is_empty() {
            let mut e = if nome.is_empty() { "a requisicao nao disse a qual servidor se refere".to_owned() } else { format!("nao achei o servidor \"{nome}\"") };
            e = format!("{e}; {}", self.servers.diagnostico());
            self.log.warn("local", &format!("{}: {e}", req.path));
            return Response::error(503, &e);
        }
        let url = format!("{}{}", base.trim_end_matches('/'), req.uri());
        let mut hs: Vec<(String, String)> = Vec::new();
        if let Some((u, p)) = self.servers.credencial(&nome) {
            hs.push(("Authorization".into(), basic(&u, &p)));
        }
        if let Some(ct) = req.header("Content-Type") {
            hs.push(("Content-Type".into(), ct.to_owned()));
        }
        let body: &[u8] = if req.method == "POST" { &req.body } else { &[] };
        match self.upstream.send(if req.method == "POST" { "POST" } else { "GET" }, &url, &hs, body) {
            Ok(r) => {
                let mut out = Response::new(r.status, &r.content_type, r.body);
                out.headers = r.headers.into_iter().filter(|(k, _)| k.len() > 6 && k[..6].eq_ignore_ascii_case("X-Vms-")).collect();
                out
            }
            Err(e) => {
                self.servers.invalidar(&nome);
                Response::error(502, &e)
            }
        }
    }

    fn route(&self, req: &Request) -> Response {
        let path = req.path.to_ascii_lowercase();
        let local = req.param("server").trim().is_empty();
        let ui = match path.as_str() {
            "/" | "/ui/app" => Some("app-ui.html"),
            "/ui/events" => Some("events-ui.html"),
            "/ui/motion" => Some("motion-ui.html"),
            "/ui/player" => Some("player-ui.html"),
            "/ui/cameras" => Some("cameras-ui.html"),
            "/ui/login" => Some("login-ui.html"),
            "/ui/ui.css" => Some("ui.css"),
            "/ui/vmsreader.js" => Some("vmsreader.js"),
            "/ui/player.js" => Some("player.js"),
            _ => None,
        };
        if let Some(n) = ui {
            return vms_core::ui::response(n);
        }
        match path.as_str() {
            "/favicon.svg" | "/favicon.ico" => vms_core::ui::response("favicon.svg").with_header("Cache-Control", "public, max-age=86400"),
            "/api/cameras" if local => self.cameras_local(),
            "/api/app/route" => {
                let n = req.param("server").trim().to_owned();
                if n.is_empty() {
                    Response::error(400, "informe o servidor")
                } else {
                    Response::json(&self.servers.sondar_todas(&n))
                }
            }
            "/api/app/sair" => {
                self.window.sair();
                Response::empty(204)
            }
            "/api/app/frente" => self.frente(req),
            "/api/app/log" => self.log_route(req),
            "/api/ptz/procurar" => self.procurar_ptz(req),
            "/api/ptz" if local => self.ptz_local(req),
            // O microfone nativo era do Android; no Windows a página usa o
            // getUserMedia do próprio WebView.
            "/api/app/fala" if req.param("acao").trim().eq_ignore_ascii_case("testar") => Response::json(&json!({ "nativo": false })),
            "/api/app/fala" => Response::error(503, "sem microfone nativo aqui"),
            "/api/fala" if local => self.fala_local(req),
            "/api/decode" | "/api/frame" => Response::error(503, "sem decodificacao nativa aqui"),
            "/api/app/servers" => self.app_servers(req),
            "/api/live" if local => self.live(req),
            "/api/app/cameras" => self.app_cameras(req),
            p if p.starts_with("/api/") => self.encaminhar(req),
            _ => Response::error(404, "nao existe aqui"),
        }
    }
}

impl Handler for App {
    fn handle(&self, req: &Request) -> Response {
        // O log que a página lê não se registra: cada leitura viraria a linha
        // que a próxima leitura traz.
        if !req.path.eq_ignore_ascii_case("/api/app/log") {
            self.log.debug("local", &format!("{} {}", req.method, req.uri()));
        }
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.route(req))).unwrap_or_else(|_| Response::error(500, "falha interna"));
        if r.header("Cache-Control").is_none() {
            r.with_header("Cache-Control", "no-store")
        } else {
            r
        }
    }
}

/// O roteador atrás de um `Arc`.
pub struct SharedApp(pub Arc<App>);

impl Handler for SharedApp {
    fn handle(&self, req: &Request) -> Response {
        self.0.handle(req)
    }
}

pub fn data_dir_or(dir: Option<&Path>) -> PathBuf {
    dir.map(Path::to_path_buf).unwrap_or_else(crate::cameras::documents_dir)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use vms_core::clock::SystemClock;
    use vms_core::ptz::fakes::PtzFalsa;
    use vms_core::ptz::{PtzRegistry, PtzSession};

    struct Janela(Mutex<bool>, Mutex<u32>);
    impl Window for Janela {
        fn sair(&self) {
            *self.1.lock().unwrap() += 1;
        }
        fn frente(&self, p: &str) -> Option<bool> {
            let mut g = self.0.lock().unwrap();
            if !p.is_empty() {
                *g = p == "1";
            }
            Some(*g)
        }
    }

    fn app(d: &Path, up: Arc<dyn Upstream>) -> (Arc<App>, Arc<Janela>) {
        let j = Arc::new(Janela(Mutex::new(false), Mutex::new(0)));
        let memo = Arc::new(MemoryLogger::new(100));
        let a = App::new(AppDeps {
            dir: d.to_path_buf(),
            log: memo.clone(),
            memo,
            clock: Arc::new(SystemClock),
            upstream: up,
            starter: Box::new(|_, _| None),
            window: j.clone(),
        });
        (a, j)
    }

    #[test]
    fn rotas_locais() {
        let d = vms_core::testutil::TempDir::new("app-local");
        std::fs::write(d.path().join("cameras.json"), r#"[{"name":"appcam1","url":"rtsp://a","password":"s"}]"#).unwrap();
        let (a, j) = app(d.path(), Arc::new(crate::upstream::PlainHttp));
        assert_eq!(a.handle(&Request::new("GET", "/api/cameras")).json_value()["cameras"][0]["name"], "appcam1");
        assert_eq!(a.handle(&Request::new("GET", "/")).status, 200);
        let c = a.handle(&Request::new("GET", "/api/app/cameras")).body_text();
        assert!(c.contains("temSenha") && !c.contains("\"s\""));
        assert_eq!(a.handle(&Request::new("POST", "/api/app/frente?ligar=1")).json_value()["ligado"], true);
        assert_eq!(a.handle(&Request::new("GET", "/api/app/frente")).json_value()["ligado"], true);
        assert_eq!(a.handle(&Request::new("GET", "/api/app/sair")).status, 204);
        assert_eq!(*j.1.lock().unwrap(), 1);
        assert!(a.handle(&Request::new("GET", "/api/app/log")).json_value()["linhas"].as_array().is_some_and(|l| !l.is_empty()));
        assert_eq!(a.handle(&Request::new("GET", "/api/app/fala?acao=testar")).json_value()["nativo"], false);
        assert_eq!(a.handle(&Request::new("GET", "/api/live?camera=outra")).header("X-Vms-Live"), Some("0"));
        assert_eq!(a.handle(&Request::new("POST", "/api/app/servers").with_body(b"[1]".to_vec())).status, 400);
        assert_eq!(a.handle(&Request::new("POST", "/api/app/servers").with_body(br#"{"servers":[]}"#.to_vec())).status, 200);
        assert!(d.path().join("servers.json").is_file());
        // PTZ pela sessão viva da câmera do app.
        let s: Arc<dyn PtzSession> = Arc::new(PtzFalsa::default());
        PtzRegistry::anunciar("appcam1", s.clone());
        assert_eq!(a.handle(&Request::new("GET", "/api/ptz?camera=appcam1&acao=testar")).json_value()["via"], "dvrip");
        PtzRegistry::apagar("appcam1", &s);
        assert_eq!(a.handle(&Request::new("GET", "/api/ptz?camera=appcam1&acao=testar")).status, 503, "sem ptz no cadastro");
        assert_eq!(a.handle(&Request::new("GET", "/api/nada")).status, 503, "sem server: nao ha para onde mandar");
        assert_eq!(a.handle(&Request::new("GET", "/x")).status, 404);
    }

    #[test]
    fn encaminha_com_basic_e_cabecalhos_vms() {
        let seen = Arc::new(Mutex::new(String::new()));
        let s2 = seen.clone();
        let srv = vms_core::http::Server::start(
            "127.0.0.1:0",
            Arc::new(move |r: &Request| {
                *s2.lock().unwrap() = format!("{} {} {}", r.method, r.uri(), r.header("Authorization").unwrap_or(""));
                Response::new(200, "application/x-vms", vec![1, 2, 3]).with_header("X-Vms-Cursor", "c1").with_header("Set-Cookie", "x")
            }),
        )
        .unwrap();
        let d = vms_core::testutil::TempDir::new("app-fwd");
        std::fs::write(d.path().join("servers.json"), format!(r#"{{"servers":[{{"name":"Casa","url":"http://{}","user":"u","password":"p"}}]}}"#, srv.addr())).unwrap();
        let (a, _) = app(d.path(), Arc::new(crate::upstream::PlainHttp));
        let r = a.handle(&Request::new("GET", "/api/media?server=Casa&camera=x"));
        assert_eq!(r.status, 200);
        assert_eq!(r.body, vec![1, 2, 3]);
        assert_eq!(r.header("X-Vms-Cursor"), Some("c1"));
        assert!(r.header("Set-Cookie").is_none(), "so X-Vms-* volta");
        assert_eq!(*seen.lock().unwrap(), format!("GET /api/media?server=Casa&camera=x {}", basic("u", "p")));
        let r = a.handle(&Request::new("GET", "/api/cameras?server=Nada"));
        assert_eq!(r.status, 503);
    }
}
