//! O cadastro de câmeras do app: `cameras.json` em Documentos (o MESMO
//! arquivo e formato do app Delphi, que continua valendo), lido e gravado pelo
//! `vms-core::camera_json`.
//!
//! As câmeras do app reconectam rápido (1 s, teto de 6 s): quem está olhando
//! quer a imagem de volta, e uma tentativa a mais custa pouco.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use vms_core::camera_json::{self, CameraEntry, Reconnect};
use vms_core::log::SharedLogger;

pub fn app_reconnect() -> Reconnect {
    Reconnect { initial_ms: 1000, max_ms: 6000, multiplier: 2.0, no_rtp_timeout_ms: 10_000 }
}

/// A pasta Documentos do usuário (onde o app Delphi guardava os dois JSON).
pub fn documents_dir() -> PathBuf {
    #[cfg(windows)]
    {
        use windows::Win32::UI::Shell::{FOLDERID_Documents, SHGetKnownFolderPath, KF_FLAG_DEFAULT};
        // SAFETY: a string devolvida é liberada com CoTaskMemFree.
        unsafe {
            if let Ok(p) = SHGetKnownFolderPath(&FOLDERID_Documents, KF_FLAG_DEFAULT, None) {
                let s = p.to_string().unwrap_or_default();
                windows::Win32::System::Com::CoTaskMemFree(Some(p.0 as *const _));
                if !s.is_empty() {
                    return PathBuf::from(s);
                }
            }
        }
    }
    std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join("Documents")).unwrap_or_else(|| PathBuf::from("."))
}

pub struct CameraStore {
    path: PathBuf,
    cams: Mutex<Vec<CameraEntry>>,
    log: SharedLogger,
}

impl CameraStore {
    pub fn open(path: &Path, log: SharedLogger) -> Self {
        let s = Self { path: path.to_path_buf(), cams: Mutex::new(Vec::new()), log };
        s.reload();
        s
    }

    pub fn reload(&self) {
        let cams = match std::fs::read_to_string(&self.path) {
            Ok(t) => match serde_json::from_str::<serde_json::Value>(t.trim_start_matches('\u{feff}')) {
                Ok(v) => camera_json::parse_cameras(&v),
                Err(e) => {
                    self.log.error("cfg", &format!("cameras.json ilegivel: {e}"));
                    Vec::new()
                }
            },
            // Começa vazio: o arquivo nasce ao cadastrar a primeira câmera.
            Err(_) => Vec::new(),
        };
        *self.lock() = cams.into_iter().map(with_app_reconnect).collect();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<CameraEntry>> {
        self.cams.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn all(&self) -> Vec<CameraEntry> {
        self.lock().clone()
    }

    pub fn enabled_names(&self) -> Vec<String> {
        self.lock().iter().filter(|c| c.enabled).map(|c| c.name.clone()).collect()
    }

    pub fn find(&self, name: &str) -> Option<CameraEntry> {
        self.lock().iter().find(|c| c.name.trim().eq_ignore_ascii_case(name.trim())).cloned()
    }

    /// O que vai para a tela: sem senhas.
    pub fn json_sem_senha(&self) -> String {
        camera_json::cameras_to_json(&self.lock(), false)
    }

    /// O cadastro que volta da tela: senhas mescladas, gravado em disco.
    pub fn gravar(&self, json: &str) -> Result<(), String> {
        let v: serde_json::Value = serde_json::from_str(json).map_err(|_| "json invalido".to_owned())?;
        if !v.is_array() {
            return Err("json invalido".into());
        }
        let mut novas: Vec<CameraEntry> = camera_json::parse_cameras(&v).into_iter().map(with_app_reconnect).collect();
        let mut g = self.lock();
        camera_json::mesclar_senhas(&mut novas, &g);
        if let Some(d) = self.path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        std::fs::write(&self.path, camera_json::cameras_to_json(&novas, true)).map_err(|e| e.to_string())?;
        *g = novas;
        Ok(())
    }
}

fn with_app_reconnect(mut c: CameraEntry) -> CameraEntry {
    c.reconnect = app_reconnect();
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grava_sem_perder_a_senha() {
        let d = vms_core::testutil::TempDir::new("camstore");
        let p = d.path().join("cameras.json");
        std::fs::write(&p, r#"[{"name":"Frente","url":"rtsp://a","password":"s"},{"name":"Off","url":"rtsp://b","enabled":false}]"#).unwrap();
        let s = CameraStore::open(&p, vms_core::log::null());
        assert_eq!(s.enabled_names(), vec!["Frente".to_string()]);
        assert_eq!(s.find(" frente ").unwrap().reconnect.max_ms, 6000);
        let tela = s.json_sem_senha();
        assert!(!tela.contains("\"s\""));
        s.gravar(&tela).unwrap();
        let s2 = CameraStore::open(&p, vms_core::log::null());
        assert_eq!(s2.find("Frente").unwrap().endpoints[0].password, "s");
        assert!(s.gravar("{}").is_err());
    }
}
