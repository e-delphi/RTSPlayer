//! vmsserver: grava as câmeras em .vms, publica todas em UMA porta RTSP
//! (`rtsp://<host>:8554/live/<câmera>`) e serve a API e a interface web na
//! mesma porta.
//!
//! Subida, na ordem que importa:
//!   1. banco (ao lado do executável) + esquema;
//!   2. importação única do `vmsserver.json` antigo, se nunca importou;
//!   3. configuração DO BANCO (é ela que vale);
//!   4. retenção e reparo das gravações que ficaram abertas — antes de gravar;
//!   5. ao vivo, índice, miniaturas, análise, API, supervisores, listener;
//!   6. laço: interações, sessões de comando PTZ e câmeras mudadas pela API.

#[macro_use]
pub mod db;
pub mod analytics;
pub mod api;
pub mod auth;
pub mod config;
pub mod ffmpeg;
pub mod index_cache;
pub mod interactions;
pub mod logger;
pub mod media;
pub mod repair;
pub mod retention;
pub mod rtsp;
pub mod thumbs;

use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use vms_core::camera_json::CameraEntry;
use vms_core::clock::{Clock, SystemClock};
use vms_core::live::{LiveHub, LiveSink};
use vms_core::log::{ConsoleLogger, SharedLogger};
use vms_core::recorder::{Recorder, RecorderConfig};
use vms_core::sink::{FanoutSink, SharedSink};
use vms_core::stop::StopToken;
use vms_core::supervisor::{DefaultFactory, Supervisor};

use config::{AppConfig, ServerConfig};
use db::Db;

static STOP: OnceLock<StopToken> = OnceLock::new();

#[cfg(windows)]
fn install_ctrl_handler() {
    #[link(name = "kernel32")]
    extern "system" {
        fn SetConsoleCtrlHandler(h: Option<unsafe extern "system" fn(u32) -> i32>, add: i32) -> i32;
    }
    unsafe extern "system" fn on_ctrl(_: u32) -> i32 {
        if let Some(s) = STOP.get() {
            s.stop();
        }
        1
    }
    // SAFETY: registra uma função estática que só sinaliza um token.
    unsafe {
        SetConsoleCtrlHandler(Some(on_ctrl), 1);
    }
}

#[cfg(not(windows))]
fn install_ctrl_handler() {}

/// Um supervisor por câmera habilitada: a sessão entrega a um leque com a
/// gravação e o anel do ao vivo (o áudio segue a regra da gravação).
fn montar_supervisor(app: &AppConfig, storage: &Path, cam: &CameraEntry, hub: Option<&LiveHub>, log: &SharedLogger, clock: &Arc<dyn Clock>) -> Option<Supervisor> {
    if !cam.enabled {
        log.info("composition", &format!("camera \"{}\" desabilitada, pulando", cam.name));
        return None;
    }
    let cfg = cam.to_session_config(&app.session_base(storage));
    let rec = Recorder::new(
        RecorderConfig {
            camera: cam.name.clone(),
            storage_dir: storage.to_path_buf(),
            filename_pattern: cam.filename_pattern.clone(),
            source_uri: cam.url().to_owned(),
            record_audio: cam.record_audio,
            block: app.block,
            wait_audio_ms: 1500,
            rotate_ms: app.rotate_ms,
        },
        clock.clone(),
        log.clone(),
    );
    let mut sinks: Vec<SharedSink> = vec![Arc::new(rec)];
    if let Some(h) = hub {
        sinks.push(Arc::new(LiveSink { stream: h.get_or_create(&cam.name), publish_audio: cam.record_audio }));
    }
    let factory = Arc::new(DefaultFactory { log: log.clone(), clock: clock.clone(), sink: Some(Arc::new(FanoutSink(sinks))) });
    log.info("composition", &format!("camera \"{}\": {}, gravando", cam.name, if cfg.is_dvrip() { "dvrip" } else { "rtsp" }));
    Some(Supervisor::start(cfg, log.clone(), clock.clone(), factory))
}

/// Põe UMA câmera no estado do banco: para a que roda, monta a nova se
/// habilitada. Serve para criar, alterar e desabilitar.
fn reconciliar(nome: &str, app: &AppConfig, storage: &Path, sups: &mut Vec<Supervisor>, hub: Option<&LiveHub>, rig: &analytics::AnalyticsRig, log: &SharedLogger, clock: &Arc<dyn Clock>) {
    // A que roda sai primeiro: duas sessões gravariam o mesmo vídeo.
    let mut i = 0;
    while i < sups.len() {
        if sups[i].camera().eq_ignore_ascii_case(nome) {
            log.info("main", &format!("camera {nome}: parando a captura atual"));
            sups.remove(i).stop();
        } else {
            i += 1;
        }
    }
    match app.camera(nome) {
        Some(cam) => match montar_supervisor(app, storage, cam, hub, log, clock) {
            Some(s) => {
                sups.push(s);
                log.info("main", &format!("camera {nome}: captura no ar"));
                rig.add_camera(&cam.name);
            }
            None => log.info("main", &format!("camera {nome}: desabilitada, sem captura")),
        },
        None => log.warn("main", &format!("camera {nome} mudou e sumiu do banco; sem captura")),
    }
}

fn importar_json_se_preciso(db: &Db, path: &Path, clock: &dyn Clock, log: &SharedLogger) {
    if config::config_imported(db) {
        return;
    }
    let Ok(text) = std::fs::read_to_string(path) else {
        log.info("db", &format!("sem {} para importar; o banco comeca com os padroes", path.display()));
        return;
    };
    match serde_json::from_str::<serde_json::Value>(text.trim_start_matches('\u{feff}')) {
        Ok(root) => {
            if let Err(e) = config::import_config(db, &config::parse_server_json(&root), clock.now_utc_ms(), log) {
                log.error("db", &format!("importacao de {} falhou: {e}", path.display()));
            }
        }
        Err(e) => log.error("db", &format!("{} nao e JSON valido: {e}", path.display())),
    }
}

fn storage_dir_of(cfg: &ServerConfig) -> PathBuf {
    config::resolve_from_exe(&cfg.app.storage_dir)
}

fn run() -> Result<(), String> {
    let stop = STOP.get_or_init(StopToken::new).clone();
    install_ctrl_handler();
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let boot: SharedLogger = Arc::new(ConsoleLogger);
    let args: Vec<String> = std::env::args().collect();
    let json_path = config::resolve_config_path(args.get(1).map(String::as_str));

    // 1–3. O banco antes do logger: é dele que sai a configuração.
    let db_path = config::default_db_path();
    let db = Db::open(&db_path).map_err(|e| format!("nao abri o banco {}: {e}", db_path.display()))?;
    boot.info("db", &db::ensure_schema(&db, clock.now_utc_ms()).map_err(|e| e.to_string())?);
    importar_json_se_preciso(&db, &json_path, &*clock, &boot);
    let mut cfg = config::load(&db, &boot);
    config::ensure_cameras(&db, &cfg.app.cameras, clock.now_utc_ms());
    let log: SharedLogger = Arc::new(logger::DbLogger::new(db.clone(), clock.clone(), Some(boot.clone())));

    let storage = storage_dir_of(&cfg);
    std::fs::create_dir_all(&storage).map_err(|e| format!("nao criei {}: {e}", storage.display()))?;
    log.info("main", &format!("Config: {}", json_path.display()));
    log.info("main", &format!("Gravacoes: {}", storage.display()));
    log.info("main", &format!("Espaco livre: {:.1} GB | retencao: {}", retention::free_space_of(&storage) as f64 / config::GIGABYTE, cfg.retention.describe()));
    log.info("main", &format!("Ao vivo: {}", cfg.live.describe()));
    log.info("main", &format!("Analise de imagem: {}", cfg.analytics.describe()));
    log.info("main", &format!("Banco: {}", db::describe(&db)));
    log.info("main", &vms_core::ui::describe());

    // 4. Antes de gravar: abrir espaço e fechar o que ficou aberto.
    let thumbs_dir = thumbs::default_cache_dir();
    let sweeper = retention::RetentionSweeper { dir: storage.clone(), policy: cfg.retention.clone(), db: Some(db.clone()), thumbs_dir: Some(thumbs_dir), log: log.clone() };
    if cfg.retention.enabled() {
        sweeper.run_once();
    }
    repair::finalize_orphan_recordings(&storage, &cfg.app.names(), &log);

    // 5. As peças.
    let hub = cfg.live.enabled.then(|| Arc::new(LiveHub::new(cfg.live.clone(), log.clone(), clock.clone())));
    let cache = Arc::new(index_cache::IndexCache::new(&storage, Some(db.clone()), log.clone()));
    let rig = Arc::new(if cfg.api.enabled {
        analytics::AnalyticsRig::build(&cfg.analytics, Some(db.clone()), &cfg.app.names(), cache.clone(), clock.clone(), log.clone())
    } else {
        analytics::AnalyticsRig::empty()
    });
    let api = cfg.api.enabled.then(|| {
        let r = api::ApiRouter::new(
            api::ApiDeps {
                config: cfg.api.clone(),
                db: Some(db.clone()),
                cache: cache.clone(),
                hub: hub.clone(),
                thumbs: thumbs::build_thumb_source(cache.clone(), Some(db.clone()), clock.clone(), log.clone()),
                events: rig.events.clone(),
                probe: rig.probe.clone(),
                log: log.clone(),
                clock: clock.clone(),
            },
            cfg.app.names(),
        );
        // A sintonia vale na hora: relê do banco e passa às threads.
        let (db2, rig2, log2) = (db.clone(), rig.clone(), log.clone());
        r.on_analytics_mudou(move || {
            let nova = config::load_analytics(&config::Settings::load(&db2));
            log2.info("main", &format!("analise reconfigurada: {}", nova.describe()));
            rig2.ajustar(&nova);
        });
        r
    });

    let mut sups: Vec<Supervisor> = cfg.app.cameras.iter().filter_map(|c| montar_supervisor(&cfg.app, &storage, c, hub.as_deref(), &log, &clock)).collect();
    let retention_thread = cfg.retention.enabled().then(|| sweeper.spawn(stop.clone()));

    let bind = format!("{}:{}", if cfg.bind_address.is_empty() { "0.0.0.0" } else { &cfg.bind_address }, cfg.rtsp_port);
    let shared = Arc::new(rtsp::Shared { storage: storage.clone(), hub: hub.clone(), log: log.clone(), clock: clock.clone() });
    let handler = api.clone().map(|a| Arc::new(api::SharedRouter(a)) as Arc<dyn vms_core::http::Handler>);
    let mut listener = rtsp::Listener::start(&bind, shared, handler).map_err(|e| format!("nao abri a porta {bind}: {e}"))?;
    for c in cfg.app.cameras.iter().filter(|c| c.enabled) {
        log.info("main", &format!("  rtsp://<host>:{}/live/{}", cfg.rtsp_port, c.name));
    }
    if api.is_some() {
        log.info("main", &format!("  http://<host>:{}/  (interface)", cfg.rtsp_port));
    }
    log.info("main", "No ar. Ctrl+C para parar.");

    // 6. O laço.
    while !stop.wait_ms(500) {
        let Some(api) = &api else { continue };
        api.manter();
        let pend = api.tomar_cameras_pendentes();
        if pend.is_empty() {
            continue;
        }
        cfg = config::load(&db, &boot);
        api.definir_cameras(cfg.app.names());
        for n in pend {
            reconciliar(&n, &cfg.app, &storage, &mut sups, hub.as_deref(), &rig, &log, &clock);
        }
    }

    log.info("main", "Parando...");
    listener.stop();
    for s in &sups {
        s.signal_stop();
    }
    for s in sups {
        s.stop();
    }
    if let Some(t) = retention_thread {
        let _ = t.join();
    }
    rig.stop();
    if let Some(a) = &api {
        a.encerrar();
    }
    if db.pending() > 0 {
        log.info("main", &format!("Banco: {} escrita(s) na fila ao fechar", db.pending()));
    }
    log.info("main", "Parado.");
    db.close();
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("FATAL: {e}");
        std::process::exit(1);
    }
}
