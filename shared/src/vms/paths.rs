//! Onde cada gravação mora: `<storageDir>/<câmera>/<arquivo>.vms`.
//!
//! Uma pasta por câmera. O nome do arquivo continua trazendo o nome da câmera
//! (`{nome}_{data}.vms`): é o que identifica a gravação fora do disco. Quem
//! descobre a câmera de um arquivo deve preferir a PASTA ao prefixo do nome.

use std::path::{Path, PathBuf};

/// Pasta segura a partir do nome da câmera: fora de `[A-Za-z0-9._-]` vira `_`
/// — o mesmo alfabeto que a API aceita, para nada de fora sair da pasta.
pub fn camera_folder_name(camera: &str) -> String {
    let mut s: String = camera
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '_' })
        .collect();
    // O Windows não guarda pasta terminada em ponto ou espaço.
    while s.ends_with(['.', ' ']) {
        s.pop();
    }
    if s.is_empty() {
        "camera".into()
    } else {
        s
    }
}

/// `<storageDir>/<pasta da câmera>`, sem criar nada. Vazio vira `recordings`.
pub fn camera_dir(storage_dir: &Path, camera: &str) -> PathBuf {
    let base = if storage_dir.as_os_str().is_empty() { Path::new("recordings") } else { storage_dir };
    let base = std::path::absolute(base).unwrap_or_else(|_| base.to_path_buf());
    base.join(camera_folder_name(camera))
}

pub fn ensure_camera_dir(storage_dir: &Path, camera: &str) -> std::io::Result<PathBuf> {
    let d = camera_dir(storage_dir, camera);
    std::fs::create_dir_all(&d)?;
    Ok(d)
}

/// Caminho livre para uma gravação nova. O nome tem resolução de segundo; duas
/// trocas no mesmo segundo dariam o mesmo nome, e abrir por cima apagaria a
/// gravação que acabou de fechar.
pub fn unique_recording_path(path: &Path) -> PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let dir = path.parent().unwrap_or(Path::new(""));
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|s| format!(".{}", s.to_string_lossy())).unwrap_or_default();
    for i in 2..=999 {
        let p = dir.join(format!("{stem}-{i}{ext}"));
        if !p.exists() {
            return p;
        }
    }
    dir.join(format!("{stem}-{}{ext}", crate::clock::unix_ms() % 1_000_000))
}

/// Nome de arquivo que a API aceita: só o alfabeto seguro e terminando em
/// `.vms`. É o que impede `../` de sair da pasta de gravações.
pub fn is_safe_vms_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        && !name.starts_with('.')
        && name.to_ascii_lowercase().ends_with(".vms")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nome_de_pasta_seguro() {
        assert_eq!(camera_folder_name("frente"), "frente");
        assert_eq!(camera_folder_name("Ísis da sala"), "_sis_da_sala");
        assert_eq!(camera_folder_name("../x"), ".._x");
        assert_eq!(camera_folder_name("a. "), "a._");
        assert_eq!(camera_folder_name("a.."), "a");
        assert_eq!(camera_folder_name(""), "camera");
    }

    #[test]
    fn nome_unico_nao_sobrescreve() {
        let d = crate::testutil::TempDir::new("paths");
        let p = d.path().join("cam_x.vms");
        assert_eq!(unique_recording_path(&p), p);
        std::fs::write(&p, b"1").unwrap();
        assert_eq!(unique_recording_path(&p), d.path().join("cam_x-2.vms"));
    }

    #[test]
    fn nome_de_arquivo_da_api() {
        assert!(is_safe_vms_name("isis_2026-08-16_18-38-21.vms"));
        assert!(!is_safe_vms_name("../x.vms"));
        assert!(!is_safe_vms_name("a.vms.idx"));
        assert!(!is_safe_vms_name("a b.vms"));
    }
}
