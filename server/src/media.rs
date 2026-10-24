//! O pedaço de mídia de `/api/media`: **header do .vms + N blocos crus**, sem
//! rodapé — um .vms válido, que o leitor do app abre sem caso especial.
//!
//! O cliente não sabe que existem arquivos: pede um instante da câmera, e é
//! daqui que sai em qual .vms ele cai, por qual keyframe começar e por onde
//! continuar (o cursor). Uma resposta nunca atravessa arquivo; a seguinte
//! começa no próximo com `Discontinuity`.
//!
//! Com `stepMs` (varredura em 8x, 16x…) os blocos são REESCRITOS com só os
//! keyframes espaçados de `stepMs`, sem áudio: o desperdício está dentro do
//! bloco, nos quadros P.

use std::sync::Arc;

use vms_core::vms::format::{encode_block, index_block_at_time, index_keyframe_at_or_before, IDX_FLAG_KEYFRAME};
use vms_core::vms::paths::is_safe_vms_name;
use vms_core::vms::{Block, IndexEntry, VmsReader};

use crate::index_cache::{FileInfo, IndexCache};

/// Teto de bytes por resposta (um bloco pode ter 1 MB).
pub const MEDIA_MAX_FRAGMENT_BYTES: u64 = 4 * 1024 * 1024;
pub const MEDIA_DEFAULT_BLOCKS: usize = 4;
const ASSUMED_BLOCK_MS: i64 = 2000;

/// `<nextMs>-<bloco>-<tipo>-<arquivo>`; tipo 0 = mesmo arquivo, 1 = emenda
/// noutro, 2 = cauda de arquivo que ainda cresce.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MediaCursor {
    pub valid: bool,
    pub next_ms: i64,
    pub file: String,
    pub block: i64,
    pub new_file: bool,
    pub tail: bool,
}

impl MediaCursor {
    pub fn encode(&self) -> String {
        if !self.valid {
            return String::new();
        }
        let t = if self.tail { 2 } else if self.new_file { 1 } else { 0 };
        format!("{}-{}-{}-{}", self.next_ms, self.block, t, self.file)
    }

    pub fn decode(s: &str) -> Option<MediaCursor> {
        // nextMs pode ser negativo só em teoria; o Delphi exige o primeiro '-'
        // depois do primeiro caractere, o que aceita "-5-…" também.
        let p1 = s.get(1..)?.find('-')? + 1;
        let rest = &s[p1 + 1..];
        let p2 = rest.find('-')?;
        let rest2 = &rest[p2 + 1..];
        let p3 = rest2.find('-')?;
        if p2 == 0 || p3 == 0 {
            return None;
        }
        let next_ms = s[..p1].parse().ok()?;
        let block = rest[..p2].parse().ok()?;
        let flag: i32 = rest2[..p3].parse().ok()?;
        let file = rest2[p3 + 1..].to_owned();
        if file.is_empty() {
            return None;
        }
        Some(MediaCursor { valid: true, next_ms, file, block, new_file: flag == 1, tail: flag == 2 })
    }
}

#[derive(Debug, Clone, Default)]
pub struct MediaRequest {
    pub camera: String,
    /// Diagnóstico: fixa o arquivo.
    pub file: String,
    pub from_ms: Option<i64>,
    pub from_block: Option<i64>,
    pub cursor: MediaCursor,
    pub blocks: usize,
    pub step_ms: i64,
}

#[derive(Debug, Clone, Default)]
pub struct MediaFragment {
    pub ok: bool,
    pub status: u16,
    pub error: String,
    pub data: Vec<u8>,
    pub file: String,
    pub first_block: usize,
    pub block_count: usize,
    pub start_ms: i64,
    pub end_ms: i64,
    /// -1 = não há mais gravação depois disto.
    pub next_ms: i64,
    pub gap_ms: i64,
    pub discontinuity: bool,
    pub keyframe: bool,
    pub growing: bool,
    pub thinned: bool,
    /// Nada novo e a gravação não acabou: pergunte de novo com o mesmo cursor.
    pub empty: bool,
    pub cursor: String,
}

impl MediaFragment {
    fn fail(status: u16, msg: &str) -> Self {
        Self { status, error: msg.into(), next_ms: -1, ..Default::default() }
    }

    /// Os `X-Vms-*` da resposta.
    pub fn headers(&self) -> Vec<(String, String)> {
        let b = |v: bool| if v { "1" } else { "0" }.to_owned();
        if self.empty {
            return vec![("X-Vms-Cursor".into(), self.cursor.clone()), ("X-Vms-Growing".into(), b(self.growing))];
        }
        vec![
            ("X-Vms-Cursor".into(), self.cursor.clone()),
            ("X-Vms-Block-Count".into(), self.block_count.to_string()),
            ("X-Vms-Start-Ms".into(), self.start_ms.to_string()),
            ("X-Vms-End-Ms".into(), self.end_ms.to_string()),
            ("X-Vms-Next-Ms".into(), self.next_ms.to_string()),
            ("X-Vms-Gap-Ms".into(), self.gap_ms.to_string()),
            ("X-Vms-Discontinuity".into(), b(self.discontinuity)),
            ("X-Vms-Keyframe".into(), b(self.keyframe)),
            ("X-Vms-Growing".into(), b(self.growing)),
            ("X-Vms-Thinned".into(), b(self.thinned)),
        ]
    }
}

/// Reescreve um bloco com só os keyframes espaçados de `step_ms`. A âncora do
/// bloco novo é o instante do primeiro quadro escolhido, e `last_ms` leva o
/// espaçamento através dos blocos.
pub fn thin_block(src: &Block, timescale: u32, step_ms: i64, last_ms: &mut i64) -> Option<Block> {
    let ts = if timescale == 0 { 90_000 } else { timescale } as i64;
    let anchor = if src.video_anchor_ms != 0 { src.video_anchor_ms } else { src.start_unix_ms };
    let mut first_pts = None;
    let mut keep = Vec::new();
    let mut first_kept = 0;
    for (i, s) in src.samples.iter().enumerate() {
        if s.track_id != 0 {
            continue;
        }
        let fp = *first_pts.get_or_insert(s.pts);
        if s.flags & IDX_FLAG_KEYFRAME == 0 {
            continue;
        }
        let wall = anchor + (s.pts - fp) * 1000 / ts;
        if *last_ms > 0 && wall - *last_ms < step_ms {
            continue;
        }
        if keep.is_empty() {
            first_kept = wall;
        }
        keep.push(i);
        *last_ms = wall;
    }
    if keep.is_empty() {
        return None;
    }
    let mut dst = Block { seq: src.seq, start_unix_ms: first_kept, video_anchor_ms: first_kept, audio_anchor_ms: 0, ..Default::default() };
    for i in keep {
        let mut e = src.samples[i];
        let a = e.payload_offset as usize;
        let data = src.payload.get(a..a + e.payload_size as usize).unwrap_or(&[]);
        e.payload_offset = dst.payload.len() as u32;
        e.payload_size = data.len() as u32;
        dst.payload.extend_from_slice(data);
        dst.samples.push(e);
    }
    Some(dst)
}

pub struct MediaBuilder {
    cache: Arc<IndexCache>,
    max_blocks: usize,
}

impl MediaBuilder {
    pub fn new(cache: Arc<IndexCache>, max_blocks: usize) -> Self {
        Self { cache, max_blocks: if max_blocks == 0 { 32 } else { max_blocks } }
    }

    /// O arquivo que contém o instante; não havendo, o primeiro depois dele;
    /// depois de tudo, o último.
    fn resolve_by_time(&self, camera: &str, from: i64) -> Option<FileInfo> {
        let files = self.cache.list_files(camera);
        files
            .iter()
            .find(|f| from >= f.start_ms && from < f.end_ms)
            .or_else(|| files.iter().find(|f| f.start_ms >= from))
            .or(files.last())
            .cloned()
    }

    fn open_by_name(&self, camera: &str, name: &str) -> Option<FileInfo> {
        if !is_safe_vms_name(name) {
            return None;
        }
        self.cache.info(&self.cache.path_of(camera, name))
    }

    /// O PRÓXIMO DA LISTA, e não "o primeiro depois do fim" (o fim é estimado).
    fn next_file_after(&self, camera: &str, current: &str, current_end: i64) -> Option<FileInfo> {
        if camera.is_empty() {
            return None;
        }
        let files = self.cache.list_files(camera);
        if let Some(i) = files.iter().position(|f| f.name.eq_ignore_ascii_case(current)) {
            return files.get(i + 1).cloned();
        }
        files.into_iter().find(|f| f.start_ms >= current_end)
    }

    pub fn fetch(&self, req: &MediaRequest) -> MediaFragment {
        let mut used_hint = false;
        // 1. Que arquivo.
        let info = if !req.file.is_empty() {
            match self.open_by_name(&req.camera, &req.file) {
                Some(i) => i,
                None => return MediaFragment::fail(404, "arquivo nao encontrado"),
            }
        } else if req.cursor.valid {
            match self.open_by_name(&req.camera, &req.cursor.file) {
                Some(i) => {
                    used_hint = true;
                    i
                }
                None => match self.resolve_by_time(&req.camera, req.cursor.next_ms) {
                    Some(i) => i,
                    None => return MediaFragment::fail(404, "nao ha gravacao a partir daqui"),
                },
            }
        } else if let Some(f) = req.from_ms {
            match self.resolve_by_time(&req.camera, f) {
                Some(i) => i,
                None => return MediaFragment::fail(404, "nao ha gravacao para esta camera"),
            }
        } else {
            return MediaFragment::fail(400, "informe fromMs ou cursor");
        };

        let Some(index) = self.cache.index(&info.path) else { return MediaFragment::fail(404, "arquivo sem indice legivel") };
        if index.is_empty() {
            return MediaFragment::fail(404, "arquivo sem blocos");
        }
        let last_ix = index.len() - 1;
        let camera_of_file = if req.camera.is_empty() && req.file.is_empty() { info.camera.clone() } else { req.camera.clone() };

        // 2. Que bloco.
        let first: usize = if used_hint && req.cursor.tail {
            // Aqui o BLOCO é a verdade: pela busca por tempo o ao vivo repetiria
            // o último bloco para sempre.
            if req.cursor.block > last_ix as i64 {
                // O que prova que este acabou é a EXISTÊNCIA do seguinte (o
                // rodapé falta quando a câmera derruba a conexão).
                if let Some(next) = self.next_file_after(&camera_of_file, &info.name, index[last_ix].start_unix_ms + ASSUMED_BLOCK_MS) {
                    let mut nr = req.clone();
                    nr.cursor = MediaCursor { valid: true, next_ms: next.start_ms, file: next.name.clone(), block: 0, new_file: true, tail: false };
                    let p = self.fetch(&nr);
                    if p.ok {
                        return p;
                    }
                }
                return MediaFragment { ok: true, status: 204, empty: true, next_ms: -1, growing: !info.closed, cursor: req.cursor.encode(), ..Default::default() };
            }
            req.cursor.block.max(0) as usize
        } else if used_hint {
            let b = req.cursor.block;
            if b < 0 || b > last_ix as i64 || index[b as usize].start_unix_ms != req.cursor.next_ms {
                index_block_at_time(&index, req.cursor.next_ms).unwrap_or(0)
            } else {
                b as usize
            }
        } else if let Some(b) = req.from_block {
            if b < 0 || b > last_ix as i64 {
                return MediaFragment::fail(416, "bloco fora do arquivo");
            }
            b as usize
        } else {
            let from = req.from_ms.unwrap_or(req.cursor.next_ms);
            let f = index_block_at_time(&index, from).unwrap_or(0);
            // Recua até o keyframe: começar no meio do GOP é tela preta.
            index_keyframe_at_or_before(&index, f).unwrap_or(f)
        };

        // 3. Quantos blocos.
        let wanted = if req.blocks == 0 { MEDIA_DEFAULT_BLOCKS } else { req.blocks }.min(self.max_blocks);
        let Ok(mut r) = VmsReader::open(&info.path) else { return MediaFragment::fail(404, "arquivo sumiu") };
        if !r.read_header() {
            return MediaFragment::fail(500, "header ilegivel");
        }
        let Some(header_bytes) = r.read_header_bytes() else { return MediaFragment::fail(500, "nao consegui ler o header") };
        let (mut last, mut span, mut count) = (first, 0u64, 0usize);
        let (mut last_off, mut last_size) = (0u64, 0usize);
        for i in first..=last_ix {
            let Some((off, size)) = r.block_range(i) else { break };
            if count > 0 && req.step_ms <= 0 && span + size as u64 > MEDIA_MAX_FRAGMENT_BYTES {
                break;
            }
            span += size as u64;
            last_off = off;
            last_size = size;
            last = i;
            count += 1;
            if count >= wanted {
                break;
            }
        }
        if count == 0 {
            return MediaFragment::fail(416, "nada para ler a partir deste bloco");
        }
        let mut thinned = false;
        let body = if req.step_ms > 0 {
            thinned = true;
            let mut body = Vec::new();
            let mut last_kept = 0;
            let ts = r.header().video.timescale;
            for i in first..=last {
                if !index[i].has_keyframe() {
                    continue;
                }
                if !r.seek_to_block(i) {
                    break;
                }
                let Some(b) = r.read_next_block() else { continue };
                if let Some(t) = thin_block(&b, ts, req.step_ms, &mut last_kept) {
                    body.extend_from_slice(&encode_block(&t));
                }
            }
            body
        } else {
            let start = index[first].offset as u64;
            match r.read_raw(start, (last_off + last_size as u64 - start) as usize) {
                Some(b) => b,
                None => return MediaFragment::fail(500, "falha ao ler os blocos"),
            }
        };
        drop(r);

        let mut f = MediaFragment {
            ok: true,
            status: 200,
            file: info.name.clone(),
            first_block: first,
            block_count: count,
            start_ms: index[first].start_unix_ms,
            end_ms: if last < last_ix { index[last + 1].start_unix_ms } else { index[last].start_unix_ms + ASSUMED_BLOCK_MS },
            keyframe: index[first].has_keyframe(),
            growing: !info.closed,
            thinned,
            discontinuity: !req.cursor.valid || req.cursor.new_file || !req.cursor.file.eq_ignore_ascii_case(&info.name),
            next_ms: -1,
            ..Default::default()
        };
        f.data = header_bytes;
        f.data.extend_from_slice(&body);

        // 4. Por onde continuar.
        let mut c = MediaCursor::default();
        if last < last_ix {
            f.next_ms = index[last + 1].start_unix_ms;
            c = MediaCursor { valid: true, next_ms: f.next_ms, file: info.name.clone(), block: last as i64 + 1, ..Default::default() };
        } else if !info.closed {
            c = MediaCursor { valid: true, next_ms: f.end_ms, file: info.name.clone(), block: last as i64 + 1, tail: true, ..Default::default() };
        } else if let Some(next) = self.next_file_after(&camera_of_file, &info.name, f.end_ms) {
            f.next_ms = next.start_ms;
            f.gap_ms = (next.start_ms - f.end_ms).max(0);
            c = MediaCursor { valid: true, next_ms: next.start_ms, file: next.name, block: 0, new_file: true, tail: false };
        }
        f.cursor = c.encode();
        f
    }
}

/// Os blocos de um índice como JSON da rota `/api/index`.
pub fn index_json(index: &[IndexEntry]) -> serde_json::Value {
    serde_json::Value::Array(index.iter().enumerate().map(|(i, e)| serde_json::json!({ "block": i, "offset": e.offset, "startMs": e.start_unix_ms, "keyframe": e.has_keyframe() })).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;
    use vms_core::vms::SampleEntry;

    #[test]
    fn cursor_ida_e_volta() {
        let c = MediaCursor { valid: true, next_ms: 1234, file: "a_b-c.vms".into(), block: 7, new_file: false, tail: true };
        assert_eq!(c.encode(), "1234-7-2-a_b-c.vms");
        assert_eq!(MediaCursor::decode(&c.encode()).unwrap(), c);
        assert!(MediaCursor::decode("12-3-0-").is_none());
        assert!(MediaCursor::decode("x").is_none());
        assert!(MediaCursor::decode("").is_none());
    }

    #[test]
    fn varredura_so_keyframes_espacados() {
        let mut b = Block { start_unix_ms: 1000, video_anchor_ms: 1000, ..Default::default() };
        for i in 0..10u32 {
            b.samples.push(SampleEntry { track_id: 0, flags: (i % 2 == 0) as u8, pts: i as i64 * 9000, payload_offset: i, payload_size: 1 });
            b.payload.push(i as u8);
        }
        b.samples.push(SampleEntry { track_id: 1, flags: 1, pts: 0, payload_offset: 0, payload_size: 1 });
        let mut last = 0;
        let t = thin_block(&b, 90_000, 350, &mut last).unwrap();
        // keyframes em 1000,1200,1400,1600,1800 → passo 350: 1000, 1400, 1800
        assert_eq!(t.samples.len(), 3);
        assert_eq!(t.payload, vec![0, 4, 8]);
        assert_eq!(t.start_unix_ms, 1000);
        assert_eq!(last, 1800);
    }

    #[test]
    fn percorre_arquivos_e_segue_a_cauda() {
        let d = TempDir::new("media");
        let dir = ensure_camera_dir(d.path(), "cam").unwrap();
        write_vms(&dir.join("cam_1.vms"), 100_000, 6, 1000, true);
        write_vms(&dir.join("cam_2.vms"), 110_000, 3, 1000, false);
        let cache = Arc::new(IndexCache::new(d.path(), None, vms_core::log::null()));
        let m = MediaBuilder::new(cache, 32);

        // Pedido no meio de um GOP recua ao keyframe (blocos 0 e 4 são chave).
        let f = m.fetch(&MediaRequest { camera: "cam".into(), from_ms: Some(102_500), blocks: 2, ..Default::default() });
        assert!(f.ok, "{}", f.error);
        assert_eq!(f.first_block, 0);
        assert_eq!(f.block_count, 2);
        assert!(f.discontinuity);
        let mut rd = VmsReader::from_bytes(f.data.clone());
        assert!(rd.read_header());
        assert_eq!(rd.ensure_index(), 2, "o corpo e um .vms valido");

        let mut cur = MediaCursor::decode(&f.cursor).unwrap();
        assert_eq!(cur.block, 2);
        // Até o fim do primeiro arquivo: o cursor emenda no segundo.
        let f = m.fetch(&MediaRequest { camera: "cam".into(), cursor: cur.clone(), blocks: 10, ..Default::default() });
        assert!(!f.discontinuity);
        assert_eq!(f.block_count, 4);
        cur = MediaCursor::decode(&f.cursor).unwrap();
        assert!(cur.new_file);
        assert_eq!(cur.file, "cam_2.vms");
        assert_eq!(f.gap_ms, 110_000 - (105_000 + 2000));

        let f = m.fetch(&MediaRequest { camera: "cam".into(), cursor: cur, blocks: 10, ..Default::default() });
        assert!(f.discontinuity && f.growing);
        let cur = MediaCursor::decode(&f.cursor).unwrap();
        assert!(cur.tail, "arquivo aberto: cursor de cauda");
        let f = m.fetch(&MediaRequest { camera: "cam".into(), cursor: cur.clone(), ..Default::default() });
        assert_eq!(f.status, 204);
        assert!(f.empty);
        assert_eq!(f.cursor, cur.encode(), "o mesmo cursor para tentar de novo");

        assert_eq!(m.fetch(&MediaRequest { camera: "cam".into(), ..Default::default() }).status, 400);
        assert_eq!(m.fetch(&MediaRequest { camera: "cam".into(), file: "../x.vms".into(), ..Default::default() }).status, 404);
        let f = m.fetch(&MediaRequest { camera: "cam".into(), from_ms: Some(100_000), step_ms: 3000, blocks: 6, ..Default::default() });
        assert!(f.thinned);
    }
}
