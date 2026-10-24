//! Limpeza automática das gravações: sem ela o disco enche e o servidor para.
//!
//! Três limites opcionais (idade, tamanho somado, espaço livre), sempre
//! apagando o MAIS ANTIGO primeiro. Nunca apaga o que foi tocado nos últimos
//! 60 s (a gravação em curso), nem o que o sistema não deixa (em uso: fica para
//! a próxima). Com o `.vms` vai o sidecar; depois, miniaturas, eventos e
//! inventário de antes da gravação mais antiga que sobrou.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use vms_core::log::SharedLogger;
use vms_core::stop::StopToken;
use vms_core::vms::sidecar::delete_sidecar;

use crate::config::{RetentionPolicy, GIGABYTE};
use crate::db::Db;

const TAG: &str = "retencao";
pub const GRACE_MS: i64 = 60_000;
const MIN_INTERVAL_MS: u64 = 10_000;

#[derive(Debug, Default, Clone, PartialEq)]
pub struct RetentionResult {
    pub deleted: usize,
    pub freed_bytes: u64,
    pub kept_files: usize,
    pub kept_bytes: u64,
    pub locked: usize,
    pub short_on_space: bool,
    /// Escrita da gravação mais antiga que ficou (unix ms); 0 = nenhuma.
    pub oldest_kept_ms: i64,
}

struct RecFile {
    path: PathBuf,
    size: u64,
    written_ms: i64,
    deleted: bool,
    skip: bool,
}

/// Espaço livre no volume da pasta; 0 = não deu para saber.
pub fn free_space_of(dir: &Path) -> u64 {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        extern "system" {
            fn GetDiskFreeSpaceExW(dir: *const u16, avail: *mut u64, total: *mut u64, free: *mut u64) -> i32;
        }
        let abs = std::path::absolute(dir).unwrap_or_else(|_| dir.to_path_buf());
        let w: Vec<u16> = abs.as_os_str().encode_wide().chain([0]).collect();
        let (mut a, mut t, mut f) = (0u64, 0u64, 0u64);
        // SAFETY: ponteiros válidos para a duração da chamada.
        if unsafe { GetDiskFreeSpaceExW(w.as_ptr(), &mut a, &mut t, &mut f) } != 0 {
            return a;
        }
        0
    }
    #[cfg(not(windows))]
    {
        let _ = dir;
        0
    }
}

fn mtime_ms(m: &std::fs::Metadata) -> i64 {
    m.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn scan_folder(dir: &Path, out: &mut Vec<RecFile>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if !p.extension().map(|x| x.eq_ignore_ascii_case("vms")).unwrap_or(false) {
            continue;
        }
        let Ok(m) = e.metadata() else { continue };
        if m.is_file() {
            out.push(RecFile { path: p, size: m.len(), written_ms: mtime_ms(&m), deleted: false, skip: false });
        }
    }
}

/// Os .vms da raiz e de um nível abaixo, do mais antigo ao mais novo.
fn list_recordings(dir: &Path) -> Vec<RecFile> {
    let mut v = Vec::new();
    scan_folder(dir, &mut v);
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                scan_folder(&e.path(), &mut v);
            }
        }
    }
    v.sort_by_key(|f| f.written_ms);
    v
}

/// Uma passada. `free` mede o espaço livre (injetável para o teste).
pub fn sweep(dir: &Path, p: &RetentionPolicy, now_ms: i64, free: &dyn Fn(&Path) -> u64, log: &SharedLogger) -> RetentionResult {
    let mut res = RetentionResult::default();
    if !p.enabled() {
        return res;
    }
    let mut files = list_recordings(dir);
    if files.is_empty() {
        return res;
    }
    let mut total: u64 = files.iter().map(|f| f.size).sum();
    let mut avail = free(dir);
    for f in files.iter_mut() {
        if f.written_ms > now_ms - GRACE_MS {
            f.skip = true;
        }
    }
    let drop = |f: &mut RecFile, why: &str, res: &mut RetentionResult, total: &mut u64, avail: &mut u64| {
        if f.deleted || f.skip {
            return;
        }
        if std::fs::remove_file(&f.path).is_err() {
            f.skip = true;
            res.locked += 1;
            log.debug(TAG, &format!("em uso, nao apaguei {}", f.path.display()));
            return;
        }
        delete_sidecar(&f.path);
        f.deleted = true;
        res.deleted += 1;
        res.freed_bytes += f.size;
        *total = total.saturating_sub(f.size);
        *avail += f.size;
        log.info(TAG, &format!("apagado {} ({:.1} MB, {why})", f.path.file_name().unwrap_or_default().to_string_lossy(), f.size as f64 / 1_048_576.0));
    };
    if p.max_days > 0 {
        let cutoff = now_ms - p.max_days * 86_400_000;
        let why = format!("mais de {} dia(s)", p.max_days);
        for f in files.iter_mut().filter(|f| f.written_ms < cutoff) {
            drop(f, &why, &mut res, &mut total, &mut avail);
        }
    }
    if p.max_total_bytes > 0 {
        for f in files.iter_mut() {
            if total <= p.max_total_bytes {
                break;
            }
            drop(f, "limite de tamanho", &mut res, &mut total, &mut avail);
        }
    }
    if p.min_free_bytes > 0 && avail > 0 {
        for f in files.iter_mut() {
            if avail >= p.min_free_bytes {
                break;
            }
            drop(f, "espaco livre", &mut res, &mut total, &mut avail);
        }
        res.short_on_space = avail < p.min_free_bytes;
        if res.short_on_space {
            log.warn(
                TAG,
                &format!("livre {:.1} GB, abaixo do minimo de {:.1} GB, e nao ha mais gravacao antiga para apagar", avail as f64 / GIGABYTE, p.min_free_bytes as f64 / GIGABYTE),
            );
        }
    }
    for f in files.iter().filter(|f| !f.deleted) {
        res.kept_files += 1;
        res.kept_bytes += f.size;
        if res.oldest_kept_ms == 0 {
            res.oldest_kept_ms = f.written_ms;
        }
    }
    res
}

/// O que descreve vídeo que não existe mais: eventos, miniaturas e linhas do
/// inventário anteriores à gravação mais antiga que sobrou.
pub fn prune_after(db: Option<&Db>, thumbs_dir: Option<&Path>, keep_from_ms: i64, log: &SharedLogger) {
    if keep_from_ms <= 0 {
        return;
    }
    if let Some(db) = db {
        let ev = db.exec("DELETE FROM event WHERE end_ms < ?", p![keep_from_ms]).unwrap_or(0);
        let th = db.exec("DELETE FROM thumb WHERE minute_ms < ?", p![keep_from_ms]).unwrap_or(0);
        if ev + th > 0 {
            log.debug(TAG, &format!("{ev} evento(s) e {th} miniatura(s) do banco apagados"));
        }
    }
    if let Some(d) = thumbs_dir {
        let n = crate::thumbs::prune_cache_older_than(d, keep_from_ms);
        if n > 0 {
            log.debug(TAG, &format!("{n} dia(s) de miniatura apagados"));
        }
    }
}

pub struct RetentionSweeper {
    pub dir: PathBuf,
    pub policy: RetentionPolicy,
    pub db: Option<Arc<Db>>,
    pub thumbs_dir: Option<PathBuf>,
    pub log: SharedLogger,
}

impl RetentionSweeper {
    pub fn run_once(&self) -> RetentionResult {
        let now = vms_core::clock::unix_ms();
        let r = sweep(&self.dir, &self.policy, now, &free_space_of, &self.log);
        if r.deleted > 0 {
            prune_after(self.db.as_deref(), self.thumbs_dir.as_deref(), r.oldest_kept_ms, &self.log);
        }
        if let Some(db) = &self.db {
            if self.policy.log_days > 0 {
                let n = crate::logger::prune_log(db, now - self.policy.log_days * 86_400_000);
                if n > 0 {
                    self.log.info(TAG, &format!("{n} linha(s) de log com mais de {} dia(s) apagadas", self.policy.log_days));
                }
            }
        }
        if r.deleted > 0 || r.locked > 0 {
            let extra = if r.locked > 0 { format!(" ({} em uso, ficam para depois)", r.locked) } else { String::new() };
            self.log.info(
                TAG,
                &format!(
                    "{} apagado(s), {:.2} GB liberados; ficaram {} arquivo(s) somando {:.2} GB{extra}",
                    r.deleted,
                    r.freed_bytes as f64 / GIGABYTE,
                    r.kept_files,
                    r.kept_bytes as f64 / GIGABYTE
                ),
            );
        }
        r
    }

    /// A thread: uma passada a cada intervalo até o `stop`.
    pub fn spawn(self, stop: StopToken) -> std::thread::JoinHandle<()> {
        std::thread::Builder::new()
            .name("retencao".into())
            .spawn(move || {
                let iv = self.policy.interval_ms.max(MIN_INTERVAL_MS);
                loop {
                    self.run_once();
                    if stop.wait_ms(iv) {
                        break;
                    }
                }
            })
            .expect("thread de retencao")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::testutil::TempDir;

    fn arquivo(dir: &Path, nome: &str, bytes: usize, idade_ms: i64, now: i64) {
        let p = dir.join(nome);
        std::fs::write(&p, vec![0u8; bytes]).unwrap();
        let t = SystemTime::UNIX_EPOCH + std::time::Duration::from_millis((now - idade_ms) as u64);
        std::fs::File::options().write(true).open(&p).unwrap().set_modified(t).unwrap();
    }

    #[test]
    fn apaga_o_mais_antigo_e_poupa_o_em_curso() {
        let d = TempDir::new("ret");
        let cam = d.path().join("cam");
        std::fs::create_dir_all(&cam).unwrap();
        let now = vms_core::clock::unix_ms();
        arquivo(&cam, "a.vms", 1000, 3 * 86_400_000, now);
        arquivo(&cam, "b.vms", 1000, 2 * 3_600_000, now);
        arquivo(&cam, "c.vms", 1000, 1_000, now); // em curso
        arquivo(&cam, "c.vms.idx", 10, 1000 * 86_400_000, now); // não é .vms
        std::fs::write(cam.join("a.vms.idx"), b"x").unwrap();
        let log = vms_core::log::null();

        let pol = RetentionPolicy { max_days: 2, interval_ms: 60_000, ..Default::default() };
        let r = sweep(d.path(), &pol, now, &|_| 0, &log);
        assert_eq!(r.deleted, 1);
        assert!(!cam.join("a.vms").exists() && !cam.join("a.vms.idx").exists());
        assert!(cam.join("c.vms.idx").exists());

        let pol = RetentionPolicy { max_total_bytes: 500, ..Default::default() };
        let r = sweep(d.path(), &pol, now, &|_| 0, &log);
        assert_eq!(r.deleted, 1, "b sai; c esta em curso");
        assert_eq!(r.kept_files, 1);
        assert!(cam.join("c.vms").exists());

        assert_eq!(sweep(d.path(), &RetentionPolicy::default(), now, &|_| 0, &log), RetentionResult::default());
    }

    #[test]
    fn espaco_livre() {
        let d = TempDir::new("ret2");
        let now = vms_core::clock::unix_ms();
        arquivo(d.path(), "x.vms", 300, 10 * 3_600_000, now);
        arquivo(d.path(), "y.vms", 300, 9 * 3_600_000, now);
        let pol = RetentionPolicy { min_free_bytes: 1000, ..Default::default() };
        let r = sweep(d.path(), &pol, now, &|_| 500, &vms_core::log::null());
        assert_eq!(r.deleted, 2);
        assert!(!r.short_on_space, "500 + 600 liberados passa de 1000");
    }
}
