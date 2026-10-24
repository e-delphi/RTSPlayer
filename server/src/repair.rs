//! Fecha, na subida, as gravações que ficaram abertas (queda de energia,
//! processo morto): monta o índice, corta a cauda incompleta, escreve índice e
//! rodapé e apaga o sidecar. O que sai é igual a uma gravação fechada direito.
//!
//! Roda ANTES dos supervisores (nada grava ainda). Só mexe em arquivo com
//! sidecar: sem ele seria uma varredura inteira na subida.

use std::fs::OpenOptions;
use std::io::{Seek, SeekFrom, Write};
use std::path::Path;

use vms_core::log::SharedLogger;
use vms_core::vms::format::{encode_footer, encode_index_chunk};
use vms_core::vms::paths::camera_dir;
use vms_core::vms::sidecar::{delete_sidecar, sidecar_path_of};
use vms_core::vms::{Footer, IndexEntry, VmsReader};

const TAG: &str = "repair";

/// (índice, onde a mídia completa termina, criação). None = já tem rodapé, não
/// tem bloco, ou não abriu.
fn read_pending_index(path: &Path, log: &SharedLogger) -> Option<(Vec<IndexEntry>, u64, i64)> {
    let mut r = VmsReader::open(path).ok()?;
    r.set_logger(log.clone());
    if !r.read_header() || r.read_footer().is_some() || r.ensure_index() == 0 {
        return None;
    }
    let end = r.scanned_up_to();
    (end > 0).then(|| (r.index().to_vec(), end as u64, r.header().creation_unix_ms))
}

fn append_index_and_footer(path: &Path, index: &[IndexEntry], media_end: u64, creation: i64, log: &SharedLogger) -> bool {
    let chunk = encode_index_chunk(index);
    if chunk.is_empty() {
        return false;
    }
    #[cfg(windows)]
    let f = {
        use std::os::windows::fs::OpenOptionsExt;
        // share_mode 0: exclusivo. Outro processo com o arquivo = não é hora.
        OpenOptions::new().read(true).write(true).share_mode(0).open(path)
    };
    #[cfg(not(windows))]
    let f = OpenOptions::new().read(true).write(true).open(path);
    let mut f = match f {
        Ok(f) => f,
        Err(_) => {
            log.debug(TAG, &format!("{} em uso; deixei como estava", path.display()));
            return false;
        }
    };
    let res = (|| -> std::io::Result<bool> {
        if f.metadata()?.len() < media_end {
            return Ok(false);
        }
        let last = index[index.len() - 1];
        let footer = encode_footer(&Footer {
            total_blocks: index.len() as u32,
            total_duration_ms: (last.start_unix_ms - creation).max(0),
            last_block_offset: last.offset as u64,
            index_offset: media_end,
            index_count: index.len() as u32,
        });
        // Trunca ANTES: o índice começa exatamente onde a mídia acaba.
        f.set_len(media_end)?;
        f.seek(SeekFrom::Start(media_end))?;
        f.write_all(&chunk)?;
        f.write_all(&footer)?;
        f.sync_all()?;
        Ok(true)
    })();
    match res {
        Ok(ok) => ok,
        Err(e) => {
            log.warn(TAG, &format!("falha ao fechar {}: {e}", path.display()));
            false
        }
    }
}

pub fn finalize_one(path: &Path, log: &SharedLogger) -> bool {
    if !sidecar_path_of(path).is_file() {
        return false;
    }
    let Some((index, end, creation)) = read_pending_index(path, log) else {
        // Já tem rodapé ou não tem bloco: o sidecar não serve mais.
        delete_sidecar(path);
        return false;
    };
    let before = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    if !append_index_and_footer(path, &index, end, creation, log) {
        return false;
    }
    delete_sidecar(path);
    let cauda = if before > end { format!(", {} bytes de cauda incompleta descartados", before - end) } else { String::new() };
    log.info(TAG, &format!("{} fechado: {} blocos indexados{cauda}", path.file_name().unwrap_or_default().to_string_lossy(), index.len()));
    true
}

/// Percorre as pastas das câmeras. Nunca falha: é manutenção.
pub fn finalize_orphan_recordings(storage: &Path, cameras: &[String], log: &SharedLogger) -> usize {
    let mut n = 0;
    for cam in cameras {
        let Ok(rd) = std::fs::read_dir(camera_dir(storage, cam)) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().map(|x| x.eq_ignore_ascii_case("vms")).unwrap_or(false) && finalize_one(&p, log) {
                n += 1;
            }
        }
    }
    if n > 0 {
        log.info(TAG, &format!("{n} gravacao(oes) que ficaram abertas foram fechadas"));
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    #[test]
    fn fecha_a_gravacao_que_ficou_aberta() {
        let d = TempDir::new("repair");
        let dir = ensure_camera_dir(d.path(), "cam").unwrap();
        let p = dir.join("cam_x.vms");
        // Muitos blocos para o sidecar ter um lote (16).
        write_vms(&p, 50_000, 40, 1000, false);
        // O handle ficou vivo de propósito no teste: libera reabrindo por cópia.
        let copia = dir.join("cam_y.vms");
        std::fs::copy(&p, &copia).unwrap();
        std::fs::copy(sidecar_path_of(&p), sidecar_path_of(&copia)).unwrap();
        // Cauda incompleta: lixo depois do último bloco.
        let mut f = OpenOptions::new().append(true).open(&copia).unwrap();
        f.write_all(b"BLK\x01meio bloco").unwrap();
        drop(f);

        let log = vms_core::log::null();
        assert!(finalize_one(&copia, &log));
        assert!(!sidecar_path_of(&copia).exists());
        let mut r = VmsReader::open(&copia).unwrap();
        assert!(r.read_header());
        let f = r.read_footer().expect("agora tem rodape");
        assert_eq!(f.total_blocks, 40);
        assert_eq!(r.ensure_index(), 40);
        assert!(r.index_from_footer());
        // Segunda passada: nada a fazer.
        assert!(!finalize_one(&copia, &log));
    }
}
