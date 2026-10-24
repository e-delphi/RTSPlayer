//! A configuração do servidor: tabelas `setting`, `camera` e `camera_endpoint`,
//! e a importação ÚNICA do `vmsserver.json` antigo.
//!
//! Ordem na subida: abre o banco e garante o esquema; se nunca importou, despeja
//! o JSON nas tabelas (marcado em `db_meta.config_imported_at_ms`); daí em
//! diante vale o que está no banco. O JSON não é renomeado: fica de cópia.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::Value;
use vms_core::camera::{CameraConfig, CameraEndpoint};
use vms_core::camera_json::{self, CameraEntry, Reconnect};
use vms_core::live::LiveConfig;
use vms_core::log::SharedLogger;
use vms_core::media::Transport;
use vms_core::rtsp::KeepAliveMethod;
use vms_core::vms::BlockLimits;

use crate::db::{Db, DbResult};

pub const GIGABYTE: f64 = 1024.0 * 1024.0 * 1024.0;
pub const API_DEFAULT_MAX_BLOCKS: i64 = 32;

/// A parte comum (a mesma que o app lê do `cameras.json`).
#[derive(Debug, Clone)]
pub struct AppConfig {
    pub storage_dir: String,
    pub log_dir: String,
    pub transport_fallback_timeout_ms: u64,
    pub keep_alive: KeepAliveMethod,
    pub rotate_ms: i64,
    pub block: BlockLimits,
    pub cameras: Vec<CameraEntry>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            storage_dir: "recordings".into(),
            log_dir: "logs".into(),
            transport_fallback_timeout_ms: 5000,
            keep_alive: KeepAliveMethod::GetParameter,
            rotate_ms: 60 * 60_000,
            block: BlockLimits::default(),
            cameras: Vec::new(),
        }
    }
}

impl AppConfig {
    /// A base de sessão que todas as câmeras compartilham.
    pub fn session_base(&self, storage: &Path) -> CameraConfig {
        CameraConfig {
            storage_dir: storage.to_path_buf(),
            transport_fallback_timeout_ms: self.transport_fallback_timeout_ms,
            keep_alive: self.keep_alive,
            block: self.block.clone(),
            rotate_ms: self.rotate_ms,
            ..CameraConfig::default()
        }
    }

    pub fn camera(&self, name: &str) -> Option<&CameraEntry> {
        self.cameras.iter().find(|c| c.name.eq_ignore_ascii_case(name))
    }

    pub fn names(&self) -> Vec<String> {
        self.cameras.iter().map(|c| c.name.clone()).collect()
    }
}

/// Limpeza das gravações. Tudo zero = desligada.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RetentionPolicy {
    pub max_days: i64,
    pub max_total_bytes: u64,
    pub min_free_bytes: u64,
    pub interval_ms: u64,
    pub log_days: i64,
}

impl RetentionPolicy {
    pub fn enabled(&self) -> bool {
        self.max_days > 0 || self.max_total_bytes > 0 || self.min_free_bytes > 0
    }

    pub fn describe(&self) -> String {
        if !self.enabled() {
            return "desligada".into();
        }
        let mut p = Vec::new();
        if self.max_days > 0 {
            p.push(format!("ate {} dia(s)", self.max_days));
        }
        if self.max_total_bytes > 0 {
            p.push(format!("ate {:.1} GB", self.max_total_bytes as f64 / GIGABYTE));
        }
        if self.min_free_bytes > 0 {
            p.push(format!("livre >= {:.1} GB", self.min_free_bytes as f64 / GIGABYTE));
        }
        format!("{} (a cada {} min)", p.join(", "), self.interval_ms / 60_000)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ApiConfig {
    pub enabled: bool,
    pub max_blocks_per_request: i64,
}

impl Default for ApiConfig {
    fn default() -> Self {
        Self { enabled: true, max_blocks_per_request: API_DEFAULT_MAX_BLOCKS }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AnalyticsConfig {
    pub enabled: bool,
    pub step_ms: i64,
    pub motion_threshold: f64,
    pub scene_change_threshold: f64,
    pub grid_scale: f64,
    pub cell_delta: i64,
    pub merge_gap_ms: i64,
    pub max_event_ms: i64,
    pub backfill_ms: i64,
    pub lag_ms: i64,
    pub model_path: String,
    pub onnx_dll: String,
    pub object_interval_ms: i64,
    pub object_idle_interval_ms: i64,
    pub object_threshold: f64,
    pub classes: Vec<String>,
}

impl Default for AnalyticsConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            step_ms: 2000,
            motion_threshold: 0.006,
            scene_change_threshold: 0.85,
            grid_scale: 1.0,
            cell_delta: 0,
            merge_gap_ms: 8000,
            max_event_ms: 300_000,
            backfill_ms: 6 * 3_600_000,
            lag_ms: 30_000,
            model_path: String::new(),
            onnx_dll: "onnxruntime.dll".into(),
            object_interval_ms: 5000,
            object_idle_interval_ms: 60_000,
            object_threshold: 0.35,
            classes: Vec::new(),
        }
    }
}

impl AnalyticsConfig {
    pub fn describe(&self) -> String {
        if !self.enabled {
            return "desligada".into();
        }
        format!(
            "passo {} ms, movimento {:.4}, troca de cena {:.2}, grade {:.2}, delta {}, objetos: {}",
            self.step_ms,
            self.motion_threshold,
            self.scene_change_threshold,
            self.grid_scale,
            self.cell_delta,
            if self.model_path.is_empty() { "sem modelo".to_owned() } else { self.model_path.clone() }
        )
    }
}

/// Tudo o que a subida precisa, lido do banco.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub app: AppConfig,
    pub rtsp_port: u16,
    pub bind_address: String,
    pub retention: RetentionPolicy,
    pub live: LiveConfig,
    pub api: ApiConfig,
    pub analytics: AnalyticsConfig,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            app: AppConfig::default(),
            rtsp_port: 8554,
            bind_address: String::new(),
            retention: RetentionPolicy { interval_ms: 5 * 60_000, log_days: 7, ..Default::default() },
            live: LiveConfig::default(),
            api: ApiConfig::default(),
            analytics: AnalyticsConfig::default(),
        }
    }
}

/// A pasta do executável: relativo resolve contra ela, não contra o cwd (o
/// servidor sobe como serviço, e aí o cwd é System32).
pub fn exe_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_else(|| PathBuf::from("."))
}

pub fn resolve_from_exe(p: &str) -> PathBuf {
    let pb = PathBuf::from(p);
    if pb.is_absolute() {
        pb
    } else {
        exe_dir().join(pb)
    }
}

// ------------------------------------------------------------ leitura do JSON

fn jint(o: &Value, k: &str, d: i64) -> i64 {
    o.get(k).and_then(Value::as_f64).map(|f| f as i64).unwrap_or(d)
}
fn jnum(o: &Value, k: &str, d: f64) -> f64 {
    o.get(k).and_then(Value::as_f64).unwrap_or(d)
}
fn jbool(o: &Value, k: &str, d: bool) -> bool {
    o.get(k).and_then(Value::as_bool).unwrap_or(d)
}
fn jstr(o: &Value, k: &str, d: &str) -> String {
    o.get(k).and_then(Value::as_str).map(str::to_owned).unwrap_or_else(|| d.to_owned())
}

/// O `vmsserver.json` antigo inteiro. Os padrões são os do Delphi: retenção
/// desligada sem o bloco, ao vivo e API ligados, análise desligada sem o bloco.
pub fn parse_server_json(root: &Value) -> ServerConfig {
    let mut c = ServerConfig::default();
    c.app.storage_dir = jstr(root, "storageDir", "recordings");
    c.app.log_dir = jstr(root, "logDir", "logs");
    c.app.transport_fallback_timeout_ms = jint(root, "transportFallbackTimeoutMs", 5000).max(0) as u64;
    c.app.keep_alive = if jstr(root, "keepAliveMethod", "get_parameter").eq_ignore_ascii_case("options") { KeepAliveMethod::Options } else { KeepAliveMethod::GetParameter };
    c.app.rotate_ms = jint(root, "rotateMinutes", 60).clamp(0, 1440) * 60_000;
    if let Some(b) = root.get("block") {
        c.app.block = BlockLimits {
            max_samples: jint(b, "maxSamples", 256).max(1) as usize,
            max_duration_ms: jint(b, "maxDurationMs", 2000).max(1),
            max_size_bytes: jint(b, "maxSizeBytes", 1_048_576).max(1) as usize,
        };
    }
    c.app.cameras = root.get("cameras").map(camera_json::parse_cameras).unwrap_or_default();
    c.rtsp_port = jint(root, "rtspPort", 8554).clamp(1, 65535) as u16;
    c.bind_address = jstr(root, "bindAddress", "").trim().to_owned();
    if let Some(r) = root.get("retention").filter(|v| v.is_object()) {
        c.retention.max_days = jint(r, "maxDays", 0);
        c.retention.max_total_bytes = (jnum(r, "maxTotalGB", 0.0).max(0.0) * GIGABYTE).round() as u64;
        c.retention.min_free_bytes = (jnum(r, "minFreeGB", 0.0).max(0.0) * GIGABYTE).round() as u64;
        c.retention.interval_ms = jint(r, "intervalMinutes", 5).max(1) as u64 * 60_000;
        c.retention.log_days = jint(r, "logDays", 7);
    }
    if let Some(l) = root.get("live").filter(|v| v.is_object()) {
        c.live.enabled = jbool(l, "enabled", true);
        c.live.buffer_ms = jint(l, "bufferMs", c.live.buffer_ms).max(500);
        let mb = jnum(l, "maxBufferMB", 0.0);
        if mb > 0.0 {
            c.live.max_bytes = (mb * 1024.0 * 1024.0).round() as usize;
        }
    }
    if let Some(a) = root.get("api").filter(|v| v.is_object()) {
        c.api.enabled = jbool(a, "enabled", true);
        c.api.max_blocks_per_request = jint(a, "maxBlocksPerRequest", API_DEFAULT_MAX_BLOCKS).max(1);
    }
    if let Some(a) = root.get("analytics").filter(|v| v.is_object()) {
        let x = &mut c.analytics;
        x.enabled = jbool(a, "enabled", true);
        x.step_ms = jint(a, "stepMs", 2000).max(500);
        x.motion_threshold = jnum(a, "motionThreshold", 0.006);
        x.scene_change_threshold = jnum(a, "sceneChangeThreshold", 0.85);
        x.object_interval_ms = jint(a, "objectIntervalMs", 5000);
        x.object_idle_interval_ms = jint(a, "objectIdleIntervalMs", 60_000);
        x.object_threshold = jnum(a, "objectThreshold", 0.35);
        x.merge_gap_ms = jint(a, "mergeGapMs", 8000);
        x.max_event_ms = jint(a, "maxEventMs", 300_000);
        x.backfill_ms = jint(a, "backfillHours", 6) * 3_600_000;
        x.lag_ms = jint(a, "lagMs", 30_000).max(5000);
        x.model_path = jstr(a, "modelPath", "").trim().to_owned();
        x.onnx_dll = jstr(a, "onnxDll", "onnxruntime.dll").trim().to_owned();
        if let Some(Value::Array(l)) = a.get("classes") {
            x.classes = l.iter().filter_map(Value::as_str).map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect();
        }
    }
    c
}

// ------------------------------------------------------------ importação

/// Já importou? Exceção: há câmeras e nenhum caminho até elas — o que uma
/// build antiga deixou ao importar ignorando o formato de `url` solta. Aí vale
/// importar de novo (é seguro: ON CONFLICT atualiza).
pub fn config_imported(db: &Db) -> bool {
    if db.query_i64("SELECT COUNT(*) FROM db_meta WHERE key = 'config_imported_at_ms'", p![], 0) == 0 {
        return false;
    }
    let cams = db.query_i64("SELECT COUNT(*) FROM camera", p![], 0);
    let eps = db.query_i64("SELECT COUNT(*) FROM camera_endpoint", p![], 0);
    !(cams > 0 && eps == 0)
}

pub fn set_setting(db: &Db, key: &str, value: &str, now_ms: i64) -> DbResult<()> {
    db.exec(
        "INSERT INTO setting (key, value, updated_at_ms) VALUES (?, ?, ?) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_ms = excluded.updated_at_ms",
        p![key, value, now_ms],
    )?;
    Ok(())
}

/// Número com ponto, sempre: o banco não pode depender da máquina.
fn num_text(v: f64) -> String {
    let s = format!("{v}");
    s
}

/// Grava uma câmera inteira (a linha e os caminhos, apagados e regravados).
pub fn save_camera(db: &Db, c: &CameraEntry, now_ms: i64) -> DbResult<()> {
    db.exec(
        "INSERT INTO camera (name, enabled, record_audio, filename_pattern, audio_delay_ms, video_delay_ms, \
           max_reconnect_attempts, reconnect_initial_ms, reconnect_max_ms, reconnect_multiplier, no_rtp_timeout_ms, \
           created_at_ms, updated_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) \
         ON CONFLICT(name) DO UPDATE SET enabled = excluded.enabled, record_audio = excluded.record_audio, \
           filename_pattern = excluded.filename_pattern, audio_delay_ms = excluded.audio_delay_ms, \
           video_delay_ms = excluded.video_delay_ms, max_reconnect_attempts = excluded.max_reconnect_attempts, \
           reconnect_initial_ms = excluded.reconnect_initial_ms, reconnect_max_ms = excluded.reconnect_max_ms, \
           reconnect_multiplier = excluded.reconnect_multiplier, no_rtp_timeout_ms = excluded.no_rtp_timeout_ms, \
           updated_at_ms = excluded.updated_at_ms",
        p![
            c.name.clone(),
            c.enabled as i64,
            c.record_audio as i64,
            c.filename_pattern.clone(),
            c.audio_delay_ms,
            c.video_delay_ms,
            c.max_retries as i64,
            c.reconnect.initial_ms as i64,
            c.reconnect.max_ms as i64,
            c.reconnect.multiplier,
            c.reconnect.no_rtp_timeout_ms as i64,
            now_ms,
            now_ms
        ],
    )?;
    db.exec("DELETE FROM camera_endpoint WHERE camera_id = (SELECT id FROM camera WHERE name = ?)", p![c.name.clone()])?;
    for (i, e) in c.endpoints.iter().enumerate() {
        db.exec(
            "INSERT INTO camera_endpoint (camera_id, ord, label, url, user_name, password, transports, uses_tailscale) \
             VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?, ?, ?)",
            p![c.name.clone(), i as i64, e.name.clone(), e.url.clone(), e.user.clone(), e.password.clone(), Transport::list_to_string(&e.transports), e.uses_tailscale as i64],
        )?;
    }
    if !c.ptz.trim().is_empty() {
        set_setting(db, &format!("ptz.{}.xaddr", c.name.to_lowercase()), c.ptz.trim(), now_ms)?;
    }
    Ok(())
}

pub fn import_config(db: &Db, c: &ServerConfig, now_ms: i64, log: &SharedLogger) -> DbResult<()> {
    let a = &c.app;
    let mut kv: Vec<(&str, String)> = vec![
        ("rtspPort", c.rtsp_port.to_string()),
        ("bindAddress", c.bind_address.clone()),
        ("storageDir", a.storage_dir.clone()),
        ("logDir", a.log_dir.clone()),
        ("transportFallbackTimeoutMs", a.transport_fallback_timeout_ms.to_string()),
        ("keepAliveMethod", if a.keep_alive == KeepAliveMethod::Options { "options" } else { "get_parameter" }.into()),
        ("rotateMinutes", (a.rotate_ms / 60_000).to_string()),
        ("block.maxSamples", a.block.max_samples.to_string()),
        ("block.maxDurationMs", a.block.max_duration_ms.to_string()),
        ("block.maxSizeBytes", a.block.max_size_bytes.to_string()),
        ("retention.maxDays", c.retention.max_days.to_string()),
        ("retention.maxTotalGB", num_text(c.retention.max_total_bytes as f64 / GIGABYTE)),
        ("retention.minFreeGB", num_text(c.retention.min_free_bytes as f64 / GIGABYTE)),
        ("retention.intervalMinutes", (c.retention.interval_ms / 60_000).to_string()),
        ("retention.logDays", c.retention.log_days.to_string()),
        ("live.enabled", (c.live.enabled as i32).to_string()),
        ("live.bufferMs", c.live.buffer_ms.to_string()),
        ("live.maxBufferMB", num_text(c.live.max_bytes as f64 / (1024.0 * 1024.0))),
        ("api.enabled", (c.api.enabled as i32).to_string()),
        ("api.maxBlocksPerRequest", c.api.max_blocks_per_request.to_string()),
    ];
    let x = &c.analytics;
    kv.extend([
        ("analytics.enabled", (x.enabled as i32).to_string()),
        ("analytics.stepMs", x.step_ms.to_string()),
        ("analytics.motionThreshold", num_text(x.motion_threshold)),
        ("analytics.sceneChangeThreshold", num_text(x.scene_change_threshold)),
        ("analytics.gridScale", num_text(x.grid_scale)),
        ("analytics.cellDelta", x.cell_delta.to_string()),
        ("analytics.mergeGapMs", x.merge_gap_ms.to_string()),
        ("analytics.maxEventMs", x.max_event_ms.to_string()),
        ("analytics.backfillHours", (x.backfill_ms / 3_600_000).to_string()),
        ("analytics.lagMs", x.lag_ms.to_string()),
        ("analytics.modelPath", x.model_path.clone()),
        ("analytics.onnxDll", x.onnx_dll.clone()),
        ("analytics.objectIntervalMs", x.object_interval_ms.to_string()),
        ("analytics.objectIdleIntervalMs", x.object_idle_interval_ms.to_string()),
        ("analytics.objectThreshold", num_text(x.object_threshold)),
        ("analytics.classes", x.classes.join(",")),
    ]);
    for (k, v) in kv {
        set_setting(db, k, &v, now_ms)?;
    }
    for cam in a.cameras.iter().filter(|c| !c.name.trim().is_empty()) {
        save_camera(db, cam, now_ms)?;
    }
    db.exec("INSERT OR REPLACE INTO db_meta (key, value) VALUES (?, ?)", p!["config_imported_at_ms", now_ms.to_string()])?;
    log.info("db", &format!("config importada do json: {} camera(s)", a.cameras.len()));
    Ok(())
}

/// Garante a LINHA de cada câmera (não a configuração dela): sem a linha, os
/// eventos e o inventário caem na chave estrangeira e não gravam.
pub fn ensure_cameras(db: &Db, cams: &[CameraEntry], now_ms: i64) {
    for c in cams.iter().filter(|c| !c.name.trim().is_empty()) {
        let _ = db.exec(
            "INSERT OR IGNORE INTO camera (name, enabled, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?)",
            p![c.name.clone(), c.enabled as i64, now_ms, now_ms],
        );
    }
}

// ------------------------------------------------------------ leitura do banco

/// Os ajustes como estão no banco, com os conversores do Delphi.
pub struct Settings(pub HashMap<String, String>);

impl Settings {
    pub fn load(db: &Db) -> Settings {
        let rows = db.query("SELECT key, value FROM setting", p![], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))).unwrap_or_default();
        Settings(rows.into_iter().collect())
    }

    pub fn str(&self, k: &str, d: &str) -> String {
        self.0.get(k).cloned().unwrap_or_else(|| d.to_owned())
    }

    pub fn int(&self, k: &str, d: i64) -> i64 {
        self.0.get(k).and_then(|v| v.trim().parse().ok()).unwrap_or(d)
    }

    pub fn num(&self, k: &str, d: f64) -> f64 {
        self.0.get(k).and_then(|v| v.trim().replace(',', ".").parse().ok()).unwrap_or(d)
    }

    pub fn bool(&self, k: &str, d: bool) -> bool {
        match self.0.get(k).map(|v| v.trim().to_lowercase()) {
            None => d,
            Some(s) if s.is_empty() => d,
            Some(s) => s != "0" && s != "false" && s != "no",
        }
    }
}

pub fn load_cameras(db: &Db, log: &SharedLogger) -> Vec<CameraEntry> {
    let mut cams = db
        .query(
            "SELECT name, enabled, record_audio, filename_pattern, audio_delay_ms, video_delay_ms, max_reconnect_attempts, \
               reconnect_initial_ms, reconnect_max_ms, reconnect_multiplier, no_rtp_timeout_ms FROM camera ORDER BY id",
            p![],
            |r| {
                let pattern: String = r.get(3)?;
                Ok(CameraEntry {
                    name: r.get(0)?,
                    enabled: r.get::<_, i64>(1)? != 0,
                    record_audio: r.get::<_, i64>(2)? != 0,
                    filename_pattern: if pattern.is_empty() { CameraEntry::default().filename_pattern } else { pattern },
                    audio_delay_ms: r.get(4)?,
                    video_delay_ms: r.get(5)?,
                    max_retries: r.get::<_, i64>(6)?.max(0) as u32,
                    reconnect: Reconnect {
                        initial_ms: r.get::<_, i64>(7)?.max(0) as u64,
                        max_ms: r.get::<_, i64>(8)?.max(0) as u64,
                        multiplier: r.get(9)?,
                        no_rtp_timeout_ms: r.get::<_, i64>(10)?.max(0) as u64,
                    },
                    ..Default::default()
                })
            },
        )
        .unwrap_or_default();
    let settings = Settings::load(db);
    for c in &mut cams {
        c.endpoints = db
            .query(
                "SELECT e.label, e.url, e.user_name, e.password, e.transports, e.uses_tailscale FROM camera_endpoint e \
                 JOIN camera c ON c.id = e.camera_id WHERE c.name = ? ORDER BY e.ord",
                p![c.name.clone()],
                |r| {
                    let t: String = r.get(4)?;
                    let mut tr = Transport::parse_list(&t);
                    if tr.is_empty() {
                        tr = vec![Transport::Tcp, Transport::Udp];
                    }
                    Ok(CameraEndpoint { name: r.get(0)?, url: r.get(1)?, user: r.get(2)?, password: r.get(3)?, transports: tr, uses_tailscale: r.get::<_, i64>(5)? != 0 })
                },
            )
            .unwrap_or_default();
        if c.endpoints.is_empty() {
            log.warn("config", &format!("camera \"{}\" nao tem nenhum endpoint no banco; ela nao vai conectar", c.name));
        }
        c.ptz = settings.str(&format!("ptz.{}.xaddr", c.name.to_lowercase()), "");
    }
    cams
}

pub fn load(db: &Db, log: &SharedLogger) -> ServerConfig {
    let s = Settings::load(db);
    let mut c = ServerConfig::default();
    c.rtsp_port = s.int("rtspPort", 8554).clamp(1, 65535) as u16;
    c.bind_address = s.str("bindAddress", "").trim().to_owned();
    let a = &mut c.app;
    a.storage_dir = s.str("storageDir", "recordings");
    a.log_dir = s.str("logDir", "logs");
    a.transport_fallback_timeout_ms = s.int("transportFallbackTimeoutMs", 5000).max(0) as u64;
    a.keep_alive = if s.str("keepAliveMethod", "get_parameter").eq_ignore_ascii_case("options") { KeepAliveMethod::Options } else { KeepAliveMethod::GetParameter };
    a.rotate_ms = s.int("rotateMinutes", 60).clamp(0, 1440) * 60_000;
    a.block = BlockLimits {
        max_samples: s.int("block.maxSamples", 256).max(1) as usize,
        max_duration_ms: s.int("block.maxDurationMs", 2000).max(1),
        max_size_bytes: s.int("block.maxSizeBytes", 1_048_576).max(1) as usize,
    };
    let r = &mut c.retention;
    r.max_days = s.int("retention.maxDays", 0);
    r.max_total_bytes = (s.num("retention.maxTotalGB", 0.0).max(0.0) * GIGABYTE).round() as u64;
    r.min_free_bytes = (s.num("retention.minFreeGB", 0.0).max(0.0) * GIGABYTE).round() as u64;
    r.interval_ms = s.int("retention.intervalMinutes", 5).max(1) as u64 * 60_000;
    r.log_days = s.int("retention.logDays", 7);
    let def = LiveConfig::default();
    c.live.enabled = s.bool("live.enabled", true);
    c.live.buffer_ms = s.int("live.bufferMs", def.buffer_ms).max(500);
    let mb = s.num("live.maxBufferMB", 0.0);
    c.live.max_bytes = if mb > 0.0 { (mb * 1024.0 * 1024.0).round() as usize } else { def.max_bytes };
    c.api.enabled = s.bool("api.enabled", true);
    c.api.max_blocks_per_request = s.int("api.maxBlocksPerRequest", API_DEFAULT_MAX_BLOCKS).max(1);
    c.analytics = load_analytics(&s);
    c.app.cameras = load_cameras(db, log);
    c
}

pub fn load_analytics(s: &Settings) -> AnalyticsConfig {
    let mut x = AnalyticsConfig {
        enabled: s.bool("analytics.enabled", false),
        step_ms: s.int("analytics.stepMs", 2000).max(500),
        motion_threshold: s.num("analytics.motionThreshold", 0.006),
        scene_change_threshold: s.num("analytics.sceneChangeThreshold", 0.85),
        grid_scale: s.num("analytics.gridScale", 1.0),
        cell_delta: s.int("analytics.cellDelta", 0),
        merge_gap_ms: s.int("analytics.mergeGapMs", 8000),
        max_event_ms: s.int("analytics.maxEventMs", 300_000),
        backfill_ms: s.int("analytics.backfillHours", 6) * 3_600_000,
        lag_ms: s.int("analytics.lagMs", 30_000).max(5000),
        model_path: s.str("analytics.modelPath", "").trim().to_owned(),
        onnx_dll: s.str("analytics.onnxDll", "onnxruntime.dll").trim().to_owned(),
        object_interval_ms: s.int("analytics.objectIntervalMs", 5000),
        object_idle_interval_ms: s.int("analytics.objectIdleIntervalMs", 60_000),
        object_threshold: s.num("analytics.objectThreshold", 0.35),
        classes: s.str("analytics.classes", "").split(',').map(|c| c.trim().to_lowercase()).filter(|c| !c.is_empty()).collect(),
    };
    if x.grid_scale <= 0.0 || x.grid_scale > 1.0 {
        x.grid_scale = 1.0;
    }
    if !(0..=255).contains(&x.cell_delta) {
        x.cell_delta = 0;
    }
    if !x.model_path.is_empty() {
        x.model_path = resolve_from_exe(&x.model_path).to_string_lossy().into_owned();
    }
    x
}

/// O arquivo de bootstrap: o argumento, senão `<exe>.json` ao lado do
/// executável, senão no cwd.
pub fn resolve_config_path(arg: Option<&str>) -> PathBuf {
    if let Some(a) = arg {
        if Path::new(a).is_file() {
            return PathBuf::from(a);
        }
    }
    let name = std::env::current_exe()
        .ok()
        .and_then(|p| p.file_stem().map(|s| format!("{}.json", s.to_string_lossy())))
        .unwrap_or_else(|| "vmsserver.json".into());
    let beside = exe_dir().join(&name);
    if beside.is_file() {
        return beside;
    }
    std::env::current_dir().map(|d| d.join(&name)).unwrap_or(beside)
}

/// O banco mora num lugar fixo, ao lado do executável: o caminho dele não pode
/// morar na configuração que está dentro dele.
pub fn default_db_path() -> PathBuf {
    exe_dir().join("vmsserver.db")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::ensure_schema;

    const JSON: &str = r#"{
      "storageDir": "D:\\rec", "rtspPort": 9554, "rotateMinutes": 30,
      "block": { "maxSamples": 128 },
      "retention": { "maxDays": 10, "minFreeGB": 2.5 },
      "live": { "bufferMs": 100 },
      "analytics": { "stepMs": 100, "classes": ["Person", " car "] },
      "cameras": [
        { "name": "Frente", "url": "rtsp://a/1", "user": "u", "password": "p", "ptz": "10.0.0.5:8899" },
        { "name": "Fundo", "enabled": false, "endpoints": [ { "name": "LAN", "url": "dvrip://b" }, { "url": "rtsp://c", "transport": "udp" } ] }
      ] }"#;

    #[test]
    fn json_antigo_importado_e_relido_do_banco() {
        let root: Value = serde_json::from_str(JSON).unwrap();
        let j = parse_server_json(&root);
        assert_eq!(j.live.buffer_ms, 500, "piso do buffer");
        assert_eq!(j.analytics.step_ms, 500);
        assert!(j.analytics.enabled, "bloco presente liga");
        assert_eq!(j.analytics.classes, vec!["person", "car"]);
        assert!(j.retention.enabled());

        let db = Db::memory("cfg");
        ensure_schema(&db, 1).unwrap();
        assert!(!config_imported(&db));
        let log = vms_core::log::null();
        import_config(&db, &j, 5, &log).unwrap();
        assert!(config_imported(&db));

        let c = load(&db, &log);
        assert_eq!(c.rtsp_port, 9554);
        assert_eq!(c.app.storage_dir, "D:\\rec");
        assert_eq!(c.app.rotate_ms, 30 * 60_000);
        assert_eq!(c.app.block.max_samples, 128);
        assert_eq!(c.retention.max_days, 10);
        assert_eq!(c.retention.min_free_bytes, (2.5 * GIGABYTE) as u64);
        assert_eq!(c.analytics.classes, vec!["person", "car"]);
        assert_eq!(c.app.cameras.len(), 2);
        let f = c.app.camera("frente").unwrap();
        assert_eq!(f.url(), "rtsp://a/1");
        assert_eq!(f.endpoints[0].password, "p");
        assert_eq!(f.ptz, "10.0.0.5:8899");
        let fundo = c.app.camera("Fundo").unwrap();
        assert!(!fundo.enabled);
        assert_eq!(fundo.endpoints.len(), 2);
        assert_eq!(fundo.endpoints[1].transports, vec![Transport::Udp]);

        // Reimportação quando sobrou câmera sem caminho.
        db.exec("DELETE FROM camera_endpoint", p![]).unwrap();
        assert!(!config_imported(&db));
        db.close();
    }

    #[test]
    fn padroes_do_banco_novo() {
        let db = Db::memory("cfg2");
        ensure_schema(&db, 1).unwrap();
        let c = load(&db, &vms_core::log::null());
        assert_eq!(c.rtsp_port, 8554);
        assert!(c.live.enabled && c.api.enabled && !c.analytics.enabled);
        assert_eq!(c.live.buffer_ms, 4000);
        assert_eq!(c.api.max_blocks_per_request, 32);
        assert_eq!(c.retention.min_free_bytes, (20.0 * GIGABYTE) as u64);
        ensure_cameras(&db, &[CameraEntry { name: "X".into(), ..Default::default() }], 1);
        assert_eq!(load(&db, &vms_core::log::null()).app.cameras.len(), 1);
        db.close();
    }
}
