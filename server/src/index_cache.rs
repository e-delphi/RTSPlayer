//! O que o servidor sabe sobre as gravações em disco, sem reabrir tudo a cada
//! pergunta.
//!
//! **Descrever um arquivo não monta índice**: para a timeline só interessam
//! começo, fim e tamanho, e isso sai do rodapé (fechado) ou das pontas do
//! `.vms.idx` (em gravação). O índice é outra pergunta (`index`), feita só por
//! quem vai tocar o arquivo, e fica em memória para os 8 mais usados.
//!
//! O resumo das gravações FECHADAS vai para a tabela `recording`: gravação
//! terminada é imutável, e a primeira consulta depois de subir não precisa
//! reabrir centenas de arquivos. A conferência é por tamanho + data de escrita.
//!
//! Nenhum handle fica aberto entre consultas (a retenção precisa apagar), e o
//! I/O acontece fora do lock.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use vms_core::log::SharedLogger;
use vms_core::media::{AudioCodec, VideoCodec};
use vms_core::vms::paths::{camera_dir, is_safe_vms_name};
use vms_core::vms::{IndexEntry, VmsReader};

use crate::db::Db;

/// Sem rodapé não há duração do último bloco: 2 s, o padrão de
/// `block.maxDurationMs`, só para o fim não cair no início dele.
pub const ASSUMED_LAST_BLOCK_MS: i64 = 2000;
pub const MAX_CACHED_INDEXES: usize = 8;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct FileInfo {
    pub path: PathBuf,
    pub name: String,
    /// A PASTA do arquivo (o prefixo do nome só para arquivo solto na raiz).
    pub camera: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    pub bytes: i64,
    pub blocks: usize,
    /// Tem rodapé: a gravação foi encerrada direito.
    pub closed: bool,
    /// Tem índice pronto (rodapé ou sidecar). false = descrever custou uma
    /// varredura, e tocar vai custar outra.
    pub indexed: bool,
    pub has_video: bool,
    pub video_codec: VideoCodec,
    pub width: u16,
    pub height: u16,
    pub has_audio: bool,
    pub audio_codec: AudioCodec,
    pub sample_rate: u32,
    pub channels: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeRange {
    pub start_ms: i64,
    pub end_ms: i64,
}

#[derive(Default)]
struct Cached {
    info: FileInfo,
    stamp_size: i64,
    stamp_mtime_ms: i64,
    index: Option<Arc<Vec<IndexEntry>>>,
    index_up_to: i64,
    index_size: i64,
    last_used: u64,
}

#[derive(Default)]
struct State {
    files: HashMap<String, Cached>,
    tick: u64,
    loaded: HashSet<String>,
    dirty: bool,
}

pub struct IndexCache {
    storage: PathBuf,
    db: Option<Arc<Db>>,
    log: SharedLogger,
    state: Mutex<State>,
}

fn key_of(p: &Path) -> String {
    p.to_string_lossy().to_lowercase()
}

/// (tamanho, data de escrita em unix ms) — o carimbo do arquivo.
pub fn stamp_of(p: &Path) -> Option<(i64, i64)> {
    let m = std::fs::metadata(p).ok()?;
    if !m.is_file() {
        return None;
    }
    let mt = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0);
    Some((m.len() as i64, mt))
}

impl IndexCache {
    pub fn new(storage: &Path, db: Option<Arc<Db>>, log: SharedLogger) -> Self {
        let storage = std::path::absolute(storage).unwrap_or_else(|_| storage.to_path_buf());
        Self { storage, db, log, state: Mutex::new(State::default()) }
    }

    pub fn storage_dir(&self) -> &Path {
        &self.storage
    }

    fn st(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn folder_of(&self, camera: &str) -> String {
        camera_dir(&self.storage, camera).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
    }

    /// O resumo, sem montar índice. Duas leituras curtas no caso normal.
    fn read_info(&self, path: &Path) -> Option<FileInfo> {
        let mut r = match VmsReader::open(path) {
            Ok(r) => r,
            Err(e) => {
                self.log.debug("api.cache", &format!("nao abriu {}: {e}", path.display()));
                return None;
            }
        };
        if !r.read_header() {
            return None;
        }
        let mut info = FileInfo::default();
        let footer = r.read_footer();
        info.closed = footer.is_some();
        let first = r.first_block_start_ms();
        let (count, mut first_ms, mut last_ms);
        first_ms = first.unwrap_or(0);
        last_ms = first_ms;
        let mut have = first.is_some();
        if let (Some(f), true) = (&footer, have) {
            count = f.total_blocks as usize;
            last_ms = (r.header().creation_unix_ms + f.total_duration_ms).max(first_ms);
            info.indexed = true;
        } else if let Some((n, a, b)) = have.then(|| r.sidecar_summary()).flatten() {
            count = n;
            first_ms = a;
            last_ms = b;
            info.indexed = true;
        } else {
            count = r.ensure_index();
            if count > 0 {
                have = true;
                first_ms = r.index()[0].start_unix_ms;
                last_ms = r.index()[count - 1].start_unix_ms;
            }
        }
        let name = path.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        if !have || count == 0 {
            self.log.debug("api.cache", &format!("{name} fora da lista: {}", if have { "contagem de blocos zero" } else { "nenhum bloco legivel" }));
            return None;
        }
        let parent = path.parent().unwrap_or(Path::new(""));
        info.camera = if key_of(parent).trim_end_matches(['\\', '/']) == key_of(&self.storage).trim_end_matches(['\\', '/']) {
            name.find('_').filter(|&p| p > 0).map(|p| name[..p].to_owned()).unwrap_or_default()
        } else {
            parent.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
        };
        info.path = path.to_path_buf();
        info.name = name;
        info.blocks = count;
        info.start_ms = first_ms;
        info.end_ms = (last_ms + ASSUMED_LAST_BLOCK_MS).max(first_ms);
        info.duration_ms = info.end_ms - info.start_ms;
        let h = r.header();
        info.has_video = h.video_present;
        info.video_codec = h.video.codec;
        info.width = h.video.width;
        info.height = h.video.height;
        info.has_audio = h.audio_present;
        info.audio_codec = h.audio.codec;
        info.sample_rate = h.audio.sample_rate;
        info.channels = h.audio.channels;
        info.bytes = std::fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);
        Some(info)
    }

    /// Traz do banco o resumo das gravações fechadas desta câmera, uma vez.
    fn load_disk_cache(&self, camera: &str) {
        if !self.st().loaded.insert(camera.to_lowercase()) {
            return;
        }
        let Some(db) = &self.db else { return };
        let dir = camera_dir(&self.storage, camera);
        let folder = self.folder_of(camera);
        let rows = db.query(
            "SELECT r.name, r.start_ms, r.end_ms, r.bytes, r.blocks, r.has_video, r.video_codec, r.width, r.height, \
               r.has_audio, r.audio_codec, r.sample_rate, r.channels, r.stamp_size, r.stamp_mtime_ms \
             FROM recording r JOIN camera c ON c.id = r.camera_id WHERE c.name = ? AND r.closed = 1",
            p![camera],
            |r| {
                let name: String = r.get(0)?;
                Ok((
                    FileInfo {
                        path: dir.join(&name),
                        camera: folder.clone(),
                        start_ms: r.get(1)?,
                        end_ms: r.get(2)?,
                        bytes: r.get(3)?,
                        blocks: r.get::<_, i64>(4)? as usize,
                        closed: true,
                        indexed: true,
                        has_video: r.get::<_, i64>(5)? != 0,
                        video_codec: VideoCodec::from_u8(r.get::<_, i64>(6)? as u8),
                        width: r.get::<_, i64>(7)? as u16,
                        height: r.get::<_, i64>(8)? as u16,
                        has_audio: r.get::<_, i64>(9)? != 0,
                        audio_codec: AudioCodec::from_u8(r.get::<_, i64>(10)? as u8),
                        sample_rate: r.get::<_, i64>(11)? as u32,
                        channels: r.get::<_, i64>(12)? as u8,
                        name,
                        duration_ms: 0,
                    },
                    r.get::<_, i64>(13)?,
                    r.get::<_, i64>(14)?,
                ))
            },
        );
        let rows = match rows {
            Ok(r) => r,
            Err(e) => {
                self.log.debug("api.cache", &format!("inventario nao pode ser lido do banco: {e}"));
                return;
            }
        };
        let mut st = self.st();
        for (mut info, size, mt) in rows {
            if !is_safe_vms_name(&info.name) || info.start_ms <= 0 || info.end_ms <= info.start_ms {
                continue;
            }
            info.duration_ms = info.end_ms - info.start_ms;
            let e = st.files.entry(key_of(&info.path)).or_default();
            e.info = info;
            e.stamp_size = size;
            e.stamp_mtime_ms = mt;
        }
    }

    /// Grava no banco o resumo das gravações fechadas (assíncrono).
    fn save_disk_cache(&self, camera: &str) {
        let Some(db) = &self.db else { return };
        let folder = self.folder_of(camera);
        let copies: Vec<(FileInfo, i64, i64)> = self
            .st()
            .files
            .values()
            .filter(|c| c.info.closed && c.info.camera.eq_ignore_ascii_case(&folder) && c.stamp_size > 0)
            .map(|c| (c.info.clone(), c.stamp_size, c.stamp_mtime_ms))
            .collect();
        for (i, size, mt) in copies {
            if !i.path.is_file() {
                continue;
            }
            db.post(
                "INSERT INTO recording (camera_id, name, start_ms, end_ms, duration_ms, bytes, blocks, closed, indexed, \
                   has_video, video_codec, width, height, has_audio, audio_codec, sample_rate, channels, stamp_size, stamp_mtime_ms) \
                 VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?, ?, 1, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(camera_id, name) DO UPDATE SET start_ms = excluded.start_ms, end_ms = excluded.end_ms, \
                   duration_ms = excluded.duration_ms, bytes = excluded.bytes, blocks = excluded.blocks, closed = 1, indexed = 1, \
                   has_video = excluded.has_video, video_codec = excluded.video_codec, width = excluded.width, height = excluded.height, \
                   has_audio = excluded.has_audio, audio_codec = excluded.audio_codec, sample_rate = excluded.sample_rate, \
                   channels = excluded.channels, stamp_size = excluded.stamp_size, stamp_mtime_ms = excluded.stamp_mtime_ms",
                p![
                    camera,
                    i.name.clone(),
                    i.start_ms,
                    i.end_ms,
                    i.duration_ms,
                    i.bytes,
                    i.blocks,
                    i.has_video,
                    i.video_codec as u8,
                    i.width,
                    i.height,
                    i.has_audio,
                    i.audio_codec as u8,
                    i.sample_rate,
                    i.channels,
                    size,
                    mt
                ],
            );
        }
    }

    /// Tira do inventário as gravações cujo arquivo já não existe.
    pub fn forget_missing(&self, camera: &str) -> usize {
        let Some(db) = &self.db else { return 0 };
        let names = db.query("SELECT r.name FROM recording r JOIN camera c ON c.id = r.camera_id WHERE c.name = ?", p![camera], |r| r.get::<_, String>(0)).unwrap_or_default();
        let dir = camera_dir(&self.storage, camera);
        let mut n = 0;
        for name in names {
            if !dir.join(&name).is_file() {
                db.post("DELETE FROM recording WHERE name = ? AND camera_id = (SELECT id FROM camera WHERE name = ?)", p![name, camera]);
                n += 1;
            }
        }
        n
    }

    /// Resumo de um arquivo, do cache ou do disco. None = não é .vms legível.
    pub fn info(&self, path: &Path) -> Option<FileInfo> {
        match stamp_of(path) {
            Some((size, mt)) => self.info_stamped(path, size, mt),
            None => {
                self.forget(path);
                None
            }
        }
    }

    fn info_stamped(&self, path: &Path, size: i64, mt: i64) -> Option<FileInfo> {
        let k = key_of(path);
        if let Some(c) = self.st().files.get(&k) {
            if c.stamp_size == size && c.stamp_mtime_ms == mt {
                return Some(c.info.clone());
            }
        }
        let fresh = self.read_info(path)?;
        let mut st = self.st();
        if fresh.closed {
            st.dirty = true;
        }
        let e = st.files.entry(k).or_default();
        e.info = fresh.clone();
        e.stamp_size = size;
        e.stamp_mtime_ms = mt;
        Some(fresh)
    }

    /// O índice de blocos de um arquivo — a pergunta cara. O arquivo que ainda
    /// cresce continua de onde parou.
    pub fn index(&self, path: &Path) -> Option<Arc<Vec<IndexEntry>>> {
        self.info(path)?;
        let (size, _) = stamp_of(path)?;
        if size <= 0 {
            return None;
        }
        let k = key_of(path);
        let mut prev: Option<(Arc<Vec<IndexEntry>>, i64)> = None;
        {
            let mut st = self.st();
            st.tick += 1;
            let tick = st.tick;
            if let Some(c) = st.files.get_mut(&k) {
                if let Some(ix) = &c.index {
                    c.last_used = tick;
                    if c.index_size == size {
                        return Some(ix.clone());
                    }
                    if size > c.index_size && c.index_up_to > 0 {
                        prev = Some((ix.clone(), c.index_up_to));
                    }
                }
            }
        }
        let mut r = VmsReader::open(path).ok()?;
        if !r.read_header() {
            return None;
        }
        if let Some((ix, up)) = &prev {
            r.seed_index(ix, *up);
        }
        r.ensure_index();
        r.extend_index();
        if r.index_count() == 0 {
            return None;
        }
        let ix = Arc::new(r.index().to_vec());
        let up = r.scanned_up_to();
        drop(r);
        let mut st = self.st();
        st.tick += 1;
        let tick = st.tick;
        if let Some(c) = st.files.get_mut(&k) {
            c.index = Some(ix.clone());
            c.index_up_to = up;
            c.index_size = size;
            c.last_used = tick;
            trim_indexes(&mut st);
        }
        Some(ix)
    }

    pub fn forget(&self, path: &Path) {
        self.st().files.remove(&key_of(path));
    }

    /// Caminho de um arquivo pelo nome. Sem câmera, ela sai do prefixo do nome;
    /// arquivo antigo, da raiz, continua achável.
    pub fn path_of(&self, camera: &str, name: &str) -> PathBuf {
        let mut cam = camera.to_owned();
        if cam.is_empty() {
            if let Some(p) = name.find('_').filter(|&p| p > 0) {
                cam = name[..p].to_owned();
            }
        }
        if cam.is_empty() {
            return self.storage.join(name);
        }
        let p = camera_dir(&self.storage, &cam).join(name);
        let root = self.storage.join(name);
        if !p.is_file() && root.is_file() {
            return root;
        }
        p
    }

    /// Todos os .vms de uma câmera, em ordem de tempo.
    pub fn list_files(&self, camera: &str) -> Vec<FileInfo> {
        if camera.is_empty() {
            return Vec::new();
        }
        let dir = camera_dir(&self.storage, camera);
        let Ok(rd) = std::fs::read_dir(&dir) else { return Vec::new() };
        self.load_disk_cache(camera);
        let mut out = Vec::new();
        for e in rd.flatten() {
            let p = e.path();
            let is_vms = p.extension().map(|x| x.eq_ignore_ascii_case("vms")).unwrap_or(false);
            if !is_vms {
                continue;
            }
            let Ok(m) = e.metadata() else { continue };
            if !m.is_file() {
                continue;
            }
            let mt = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0);
            if let Some(i) = self.info_stamped(&p, m.len() as i64, mt) {
                out.push(i);
            }
        }
        let dirty = std::mem::take(&mut self.st().dirty);
        if dirty {
            self.save_disk_cache(camera);
        }
        out.sort_by_key(|i| i.start_ms);
        out
    }
}

fn trim_indexes(st: &mut State) {
    let mut held: Vec<(u64, String)> = st.files.iter().filter(|(_, c)| c.index.is_some()).map(|(k, c)| (c.last_used, k.clone())).collect();
    if held.len() <= MAX_CACHED_INDEXES {
        return;
    }
    held.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, k) in held.into_iter().skip(MAX_CACHED_INDEXES) {
        if let Some(c) = st.files.get_mut(&k) {
            c.index = None;
            c.index_up_to = 0;
            c.index_size = 0;
        }
    }
}

/// Junta o que se encosta: arquivos separados por até `gap_ms` viram uma faixa.
pub fn merge_ranges(files: &[FileInfo], gap_ms: i64) -> Vec<TimeRange> {
    let mut out: Vec<TimeRange> = Vec::new();
    for f in files.iter().filter(|f| f.end_ms > f.start_ms) {
        if let Some(last) = out.last_mut() {
            if f.start_ms - last.end_ms <= gap_ms {
                last.end_ms = last.end_ms.max(f.end_ms);
                continue;
            }
        }
        out.push(TimeRange { start_ms: f.start_ms, end_ms: f.end_ms });
    }
    out
}

/// Recorta para dentro de [from, to), descartando o que ficar vazio.
pub fn clip_ranges(r: &[TimeRange], from: i64, to: i64) -> Vec<TimeRange> {
    r.iter()
        .filter_map(|x| {
            let (s, e) = (x.start_ms.max(from), x.end_ms.min(to));
            (e > s).then_some(TimeRange { start_ms: s, end_ms: e })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    #[test]
    fn faixas() {
        let f = |s, e| FileInfo { start_ms: s, end_ms: e, ..Default::default() };
        let m = merge_ranges(&[f(0, 10), f(12, 20), f(100, 90), f(40, 50)], 5);
        assert_eq!(m, vec![TimeRange { start_ms: 0, end_ms: 20 }, TimeRange { start_ms: 40, end_ms: 50 }]);
        assert_eq!(clip_ranges(&m, 5, 45), vec![TimeRange { start_ms: 5, end_ms: 20 }, TimeRange { start_ms: 40, end_ms: 45 }]);
    }

    #[test]
    fn lista_descreve_e_persiste_as_fechadas() {
        let d = TempDir::new("idxcache");
        let dir = ensure_camera_dir(d.path(), "frente").unwrap();
        write_vms(&dir.join("frente_a.vms"), 1_000_000, 10, 1000, true);
        write_vms(&dir.join("frente_b.vms"), 2_000_000, 5, 1000, false);
        std::fs::write(dir.join("lixo.vms"), b"nada").unwrap();
        let db = Db::memory("idxcache");
        crate::db::ensure_schema(&db, 1).unwrap();
        crate::config::ensure_cameras(&db, &[vms_core::camera_json::CameraEntry { name: "frente".into(), ..Default::default() }], 1);

        let c = IndexCache::new(d.path(), Some(db.clone()), vms_core::log::null());
        let l = c.list_files("frente");
        assert_eq!(l.len(), 2, "o ilegivel fica de fora");
        assert!(l[0].closed && l[0].indexed);
        assert_eq!(l[0].start_ms, 1_000_000);
        assert_eq!(l[0].blocks, 10);
        assert!(!l[1].closed);
        assert_eq!(l[1].end_ms, 2_000_000 + 4000 + ASSUMED_LAST_BLOCK_MS);
        assert_eq!(l[1].camera, "frente");
        db.flush();
        assert_eq!(db.query_i64("SELECT COUNT(*) FROM recording", p![], 0), 1, "so a fechada");

        // Outro cache (outra subida) acha o resumo pronto no banco.
        let c2 = IndexCache::new(d.path(), Some(db.clone()), vms_core::log::null());
        c2.load_disk_cache("frente");
        assert!(c2.st().files.contains_key(&key_of(&l[0].path)));

        let ix = c.index(&l[0].path).unwrap();
        assert_eq!(ix.len(), 10);
        assert!(Arc::ptr_eq(&ix, &c.index(&l[0].path).unwrap()), "do cache");
        assert_eq!(c.path_of("", "frente_a.vms"), l[0].path);

        std::fs::remove_file(&l[0].path).unwrap();
        assert_eq!(c.forget_missing("frente"), 1);
        db.close();
    }
}
