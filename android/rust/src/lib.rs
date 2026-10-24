//! RTSPlayer para Android.
//!
//! O app é o MESMO do Windows (`rtsplayer::app::App`: cadastro, servidores,
//! ao vivo de uma câmera por vez, PTZ, fala, encaminhamento ao vmsserver).
//! Muda só quem o hospeda: aqui é um servidor HTTP em `127.0.0.1` (porta
//! livre), que o WebView da Activity abre — como o app Delphi fazia no
//! Android. O `shouldInterceptRequest` do WebView não entrega o corpo dos
//! POSTs, e a fala e o cadastro dependem dele.
//!
//! A ponte com o Java é pequena (`app.rtsplayer.Native`): `start` devolve a
//! porta, `wantsExit` diz se a página pediu para sair, `stop` encerra.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jint, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use rtsplayer::app::{App, AppDeps, SharedApp, Window};
use rtsplayer::upstream::{Upstream, MAX_ENCAMINHADO};
use vms_core::clock::{Clock, SystemClock};
use vms_core::http::{Handler, Response, Server};
use vms_core::log::{Level, Logger, MemoryLogger, SharedLogger, TeeLogger};

/// O encaminhamento ao vmsserver pelo `ureq` (http e https, com rustls).
pub struct UreqHttp;

impl Upstream for UreqHttp {
    fn send(&self, method: &str, url: &str, headers: &[(String, String)], body: &[u8]) -> Result<Response, String> {
        let mut r = ureq::request(method, url).timeout(Duration::from_secs(30));
        for (k, v) in headers {
            r = r.set(k, v);
        }
        let resp = match if method == "POST" { r.send_bytes(body) } else { r.call() } {
            Ok(r) => r,
            // 4xx/5xx também é resposta: a página precisa ver o erro do servidor.
            Err(ureq::Error::Status(_, r)) => r,
            Err(e) => return Err(e.to_string()),
        };
        let status = resp.status();
        let ctype = resp.header("Content-Type").unwrap_or("").to_owned();
        let hdrs: Vec<(String, String)> = resp.headers_names().into_iter().filter_map(|n| resp.header(&n).map(|v| (n.clone(), v.to_owned()))).collect();
        let mut out = Vec::new();
        use std::io::Read;
        resp.into_reader().take(MAX_ENCAMINHADO as u64 + 1).read_to_end(&mut out).map_err(|e| e.to_string())?;
        if out.len() > MAX_ENCAMINHADO {
            return Err("resposta grande demais".into());
        }
        let mut r = Response::new(status, &ctype, out);
        r.headers = hdrs.into_iter().filter(|(k, _)| !k.eq_ignore_ascii_case("Content-Type") && !k.eq_ignore_ascii_case("Content-Length")).collect();
        Ok(r)
    }
}

/// O "sair" da página: a Activity pergunta (`wantsExit`) e fecha.
#[derive(Default)]
pub struct AndroidWindow {
    exit: AtomicBool,
}

impl Window for AndroidWindow {
    fn sair(&self) {
        self.exit.store(true, Ordering::SeqCst);
    }
    /// "Sempre à frente" não existe no celular.
    fn frente(&self, _: &str) -> Option<bool> {
        None
    }
}

/// O log vai também para o logcat (`adb logcat -s RTSPlayer`).
struct Logcat;

#[cfg(target_os = "android")]
#[link(name = "log")]
extern "C" {
    fn __android_log_write(prio: i32, tag: *const std::ffi::c_char, text: *const std::ffi::c_char) -> i32;
}

impl Logger for Logcat {
    #[allow(unused_variables)]
    fn log(&self, level: Level, tag: &str, msg: &str) {
        #[cfg(target_os = "android")]
        {
            let prio = match level {
                Level::Debug => 3,
                Level::Info => 4,
                Level::Warn => 5,
                Level::Error => 6,
            };
            let t = std::ffi::CString::new("RTSPlayer").unwrap_or_default();
            let m = std::ffi::CString::new(format!("{tag}: {msg}").replace('\0', " ")).unwrap_or_default();
            // SAFETY: duas strings C válidas durante a chamada.
            unsafe {
                __android_log_write(prio, t.as_ptr(), m.as_ptr());
            }
        }
    }
}

pub struct Running {
    pub app: Arc<App>,
    pub server: Server,
    pub window: Arc<AndroidWindow>,
}

/// Sobe o app com o cadastro em `dir` e o servidor em `bind`.
pub fn start(dir: &Path, bind: &str) -> Result<Running, String> {
    let memo = Arc::new(MemoryLogger::new(2000));
    let log: SharedLogger = Arc::new(TeeLogger(vec![memo.clone(), Arc::new(Logcat)]));
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let window = Arc::new(AndroidWindow::default());
    log.info("main", &format!("cadastro em {}", dir.display()));
    let app = App::new(AppDeps {
        dir: dir.to_path_buf(),
        log: log.clone(),
        memo,
        clock: clock.clone(),
        upstream: Arc::new(UreqHttp),
        starter: rtsplayer::live::default_starter(log.clone(), clock),
        window: window.clone(),
    });
    let handler: Arc<dyn Handler> = Arc::new(SharedApp(app.clone()));
    let server = Server::start(bind, handler).map_err(|e| e.to_string())?;
    log.info("main", &format!("interface em http://{}/", server.addr()));
    Ok(Running { app, server, window })
}

fn running() -> &'static Mutex<Option<Running>> {
    static R: OnceLock<Mutex<Option<Running>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(None))
}

/// `int Native.start(String dataDir)`: a porta, ou -1.
#[no_mangle]
pub extern "system" fn Java_app_rtsplayer_Native_start(mut env: JNIEnv, _: JClass, dir: JString) -> jint {
    let dir: String = match env.get_string(&dir) {
        Ok(s) => s.into(),
        Err(_) => return -1,
    };
    let mut g = running().lock().unwrap_or_else(|p| p.into_inner());
    // A Activity recriada (girar a tela) reaproveita o que já está no ar.
    if let Some(r) = g.as_ref() {
        r.window.exit.store(false, Ordering::SeqCst);
        return r.server.addr().port() as jint;
    }
    match start(Path::new(&dir), "127.0.0.1:0") {
        Ok(r) => {
            let port = r.server.addr().port() as jint;
            *g = Some(r);
            port
        }
        Err(_) => -1,
    }
}

/// `boolean Native.wantsExit()`: a página pediu `/api/app/sair`.
#[no_mangle]
pub extern "system" fn Java_app_rtsplayer_Native_wantsExit(_: JNIEnv, _: JClass) -> jboolean {
    let g = running().lock().unwrap_or_else(|p| p.into_inner());
    if g.as_ref().is_some_and(|r| r.window.exit.load(Ordering::SeqCst)) {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

/// `void Native.stop()`: derruba o ao vivo e o servidor.
#[no_mangle]
pub extern "system" fn Java_app_rtsplayer_Native_stop(_: JNIEnv, _: JClass) {
    let r = running().lock().unwrap_or_else(|p| p.into_inner()).take();
    if let Some(mut r) = r {
        r.app.encerrar();
        r.server.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sobe_atende_e_pede_para_sair() {
        let d = vms_core::testutil::TempDir::new("android");
        let mut r = start(d.path(), "127.0.0.1:0").unwrap();
        let base = format!("http://{}", r.server.addr());
        let get = |p: &str| vms_core::http::fetch("GET", &format!("{base}{p}"), &[], &[], Duration::from_secs(5)).unwrap();
        assert_eq!(get("/").status, 200);
        assert!(get("/api/cameras").json_value()["cameras"].as_array().is_some_and(|a| a.is_empty()));
        assert_eq!(get("/api/app/frente").json_value()["disponivel"], false);
        assert!(!r.window.exit.load(Ordering::SeqCst));
        assert_eq!(get("/api/app/sair").status, 204);
        assert!(r.window.exit.load(Ordering::SeqCst));
        r.server.stop();
    }

    #[test]
    fn encaminha_pelo_ureq() {
        let srv = Server::start("127.0.0.1:0", Arc::new(|q: &vms_core::http::Request| Response::new(404, "application/json", b"{}".to_vec()).with_header("X-Vms-Cursor", q.method.as_str()))).unwrap();
        let r = UreqHttp.send("POST", &format!("http://{}/api/x", srv.addr()), &[("Content-Type".into(), "application/json".into())], b"{}").unwrap();
        assert_eq!(r.status, 404, "erro do servidor volta como resposta");
        assert_eq!(r.header("X-Vms-Cursor"), Some("POST"));
        assert!(UreqHttp.send("GET", "http://127.0.0.1:1/", &[], &[]).is_err());
    }
}

/// O app de verdade (fora da suíte padrão): câmeras reais e um vmsserver.
///   set VMS_TEST_DATA=pasta com cameras.json e servers.json ("Teste")
///   cargo test -p rtsplayer-android -- --ignored cameras_reais --nocapture
#[cfg(test)]
mod reais {
    use super::*;

    #[test]
    #[ignore]
    fn cameras_reais() {
        let dir = std::path::PathBuf::from(std::env::var("VMS_TEST_DATA").expect("VMS_TEST_DATA"));
        let mut r = start(&dir, "127.0.0.1:0").unwrap();
        let base = format!("http://{}", r.server.addr());
        let get = |p: &str| vms_core::http::fetch("GET", &format!("{base}{p}"), &[], &[], Duration::from_secs(20)).unwrap();
        let cams = get("/api/cameras").json_value();
        eprintln!("cameras do app: {cams}");
        for c in cams["cameras"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            // O 1º pedido conecta a câmera; os seguintes trazem o vídeo.
            let (mut cur, mut bytes, mut keyframe) = (String::new(), 0usize, false);
            let t = std::time::Instant::now();
            while t.elapsed() < Duration::from_secs(15) && bytes < 50_000 {
                let f = get(&format!("/api/live?camera={name}&cursor={cur}"));
                if let Some(c) = f.header("X-Vms-Cursor") {
                    cur = c.to_owned();
                }
                if f.status == 200 {
                    bytes += f.body.len();
                    keyframe |= f.header("X-Vms-Keyframe") == Some("1");
                }
            }
            eprintln!("ao vivo direto {name}: {bytes} bytes em {:?}, keyframe={keyframe}", t.elapsed());
            assert!(bytes > 0, "{name} sem video");
            let p = get(&format!("/api/ptz?camera={name}&acao=testar"));
            eprintln!("ptz {name}: {} {}", p.status, p.body_text());
        }
        // Pelo servidor cadastrado.
        let d = get("/api/days?server=Teste&camera=frente");
        eprintln!("servidor days: {} {}", d.status, &d.body_text()[..d.body_text().len().min(200)]);
        assert_eq!(d.status, 200);
        let m = get("/api/media?server=Teste&camera=isis&fromMs=1788044100000&blocks=2");
        eprintln!("servidor media: {} {} bytes cursor={:?}", m.status, m.body.len(), m.header("X-Vms-Cursor"));
        assert_eq!(m.status, 200);
        assert!(m.header("X-Vms-Cursor").is_some());
        r.app.encerrar();
        r.server.stop();
    }
}
