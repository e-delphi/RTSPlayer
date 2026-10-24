//! Lê um `.vms`: de arquivo (inclusive o que ainda está sendo gravado) ou de
//! memória (o fragmento que a API entrega). O formato é um só.
//!
//! O índice vem, nesta ordem de preferência: do rodapé (arquivo fechado), do
//! sidecar mais a varredura da cauda (arquivo em gravação), ou da varredura
//! inteira. A varredura lê só cabeçalho + entradas de cada bloco.

use std::fs::{File, OpenOptions};
use std::io::{self, Cursor, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::format::{
    block_meta, decode_block, decode_footer, decode_header, decode_index_chunk, decode_preamble, index_block_at_time,
    index_keyframe_at_or_before, Block, BlockError, Footer, Header, IndexEntry, BLOCK_HEADER_SIZE, FOOTER_SIZE,
    FORMAT_VERSION, IDX_FLAG_KEYFRAME, INDEX_HEADER_SIZE, MAGIC_BLOCK, MAGIC_FOOTER, MAGIC_INDEX,
};
use super::sidecar;
use crate::log::SharedLogger;

pub trait Source: Read + Seek + Send {}
impl<T: Read + Seek + Send> Source for T {}

pub struct VmsReader {
    src: Box<dyn Source>,
    path: Option<PathBuf>,
    header: Header,
    header_read: bool,
    live_timeout: Option<Duration>,
    first_block_offset: u64,
    index: Vec<IndexEntry>,
    index_built: bool,
    index_from_footer: bool,
    scanned_up_to: i64,
    bad_blocks: u32,
    saw_closed_end: bool,
    last_bad_pos: u64,
    logger: Option<SharedLogger>,
}

fn open_shared(path: &Path) -> io::Result<File> {
    let mut o = OpenOptions::new();
    o.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Lê enquanto o gravador escreve (e sem impedir nada dele).
        o.share_mode(0x1 | 0x2 | 0x4);
    }
    o.open(path)
}

impl VmsReader {
    pub fn open(path: &Path) -> io::Result<Self> {
        let f = open_shared(path)?;
        Ok(Self::with_source(Box::new(f), Some(path.to_path_buf())))
    }

    /// Fragmento em memória.
    pub fn from_bytes(data: Vec<u8>) -> Self {
        Self::with_source(Box::new(Cursor::new(data)), None)
    }

    fn with_source(src: Box<dyn Source>, path: Option<PathBuf>) -> Self {
        Self {
            src,
            path,
            header: Header::default(),
            header_read: false,
            live_timeout: None,
            first_block_offset: 0,
            index: Vec::new(),
            index_built: false,
            index_from_footer: false,
            scanned_up_to: 0,
            bad_blocks: 0,
            saw_closed_end: false,
            last_bad_pos: 0,
            logger: None,
        }
    }

    pub fn set_logger(&mut self, l: SharedLogger) {
        self.logger = Some(l);
    }

    fn warn(&self, msg: &str) {
        if let Some(l) = &self.logger {
            l.warn("vms.reader", msg);
        }
    }

    fn size(&mut self) -> u64 {
        let pos = self.src.stream_position().unwrap_or(0);
        let end = self.src.seek(SeekFrom::End(0)).unwrap_or(0);
        let _ = self.src.seek(SeekFrom::Start(pos));
        end
    }

    fn pos(&mut self) -> u64 {
        self.src.stream_position().unwrap_or(0)
    }

    fn set_pos(&mut self, p: u64) {
        let _ = self.src.seek(SeekFrom::Start(p));
    }

    /// Lê exatamente `n` bytes em `at`, sem mexer na posição de leitura.
    fn read_at(&mut self, at: u64, n: usize) -> Option<Vec<u8>> {
        let saved = self.pos();
        self.set_pos(at);
        let mut v = vec![0u8; n];
        let ok = self.src.read_exact(&mut v).is_ok();
        self.set_pos(saved);
        ok.then_some(v)
    }

    pub fn header(&self) -> &Header {
        &self.header
    }
    pub fn index(&self) -> &[IndexEntry] {
        &self.index
    }
    pub fn index_count(&self) -> usize {
        self.index.len()
    }
    pub fn scanned_up_to(&self) -> i64 {
        self.scanned_up_to
    }
    pub fn index_from_footer(&self) -> bool {
        self.index_from_footer
    }
    /// A leitura sequencial esbarrou no índice/rodapé: este arquivo ACABOU.
    pub fn at_closed_end(&self) -> bool {
        self.saw_closed_end
    }
    pub fn bad_blocks(&self) -> u32 {
        self.bad_blocks
    }
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }
    pub fn first_block_offset(&self) -> u64 {
        self.first_block_offset
    }

    pub fn read_header(&mut self) -> bool {
        self.set_pos(0);
        let mut pre = [0u8; 10];
        if self.src.read_exact(&mut pre).is_err() {
            return false;
        }
        let Ok((ver, size)) = decode_preamble(&pre) else { return false };
        if ver != FORMAT_VERSION {
            self.warn(&format!("arquivo em formato v{ver}; este build lê v{FORMAT_VERSION}"));
            return false;
        }
        if size < 10 {
            return false;
        }
        let mut buf = pre.to_vec();
        buf.resize(size as usize, 0);
        if self.src.read_exact(&mut buf[10..]).is_err() {
            return false;
        }
        let Ok(h) = decode_header(&buf) else { return false };
        self.header = h;
        self.header_read = true;
        self.saw_closed_end = false;
        self.first_block_offset = size as u64;
        self.index.clear();
        self.index_built = false;
        self.index_from_footer = false;
        self.scanned_up_to = 0;
        true
    }

    pub fn enable_live_mode(&mut self, timeout_ms: u64) {
        self.live_timeout = Some(Duration::from_millis(timeout_ms));
    }
    pub fn disable_live_mode(&mut self) {
        self.live_timeout = None;
    }
    pub fn is_live_mode(&self) -> bool {
        self.live_timeout.is_some()
    }

    fn wait_for_bytes(&mut self, need: u64) -> bool {
        let pos = self.pos();
        if self.size().saturating_sub(pos) >= need {
            return true;
        }
        let Some(t) = self.live_timeout else { return false };
        let deadline = Instant::now() + t;
        while Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
            if self.size().saturating_sub(pos) >= need {
                return true;
            }
        }
        false
    }

    pub fn at_eof(&mut self) -> bool {
        let p = self.pos();
        p >= self.size()
    }

    /// O próximo bloco, em sequência. `None` no fim (provisório, se o arquivo
    /// cresce), no rodapé, ou num bloco corrompido — que é PULADO: um bloco
    /// quebrado no meio do dia não pode impedir de assistir ao resto.
    pub fn read_next_block(&mut self) -> Option<Block> {
        if !self.header_read {
            return None;
        }
        let pos = self.pos();
        if self.live_timeout.is_some() && !self.wait_for_bytes(8) {
            return None;
        }
        let mut head = [0u8; 8];
        if self.src.read_exact(&mut head).is_err() {
            self.set_pos(pos);
            return None;
        }
        if head[0..4] == MAGIC_FOOTER || head[0..4] == MAGIC_INDEX {
            self.saw_closed_end = true;
            let end = self.size();
            self.set_pos(end);
            return None;
        }
        if head[0..4] != MAGIC_BLOCK {
            self.set_pos(pos);
            return None;
        }
        let size = u32::from_le_bytes(head[4..8].try_into().unwrap()) as usize;
        if size < BLOCK_HEADER_SIZE {
            self.set_pos(pos);
            return None;
        }
        if self.live_timeout.is_some() && !self.wait_for_bytes((size - 8) as u64) {
            self.set_pos(pos);
            return None;
        }
        let mut buf = head.to_vec();
        buf.resize(size, 0);
        if self.src.read_exact(&mut buf[8..]).is_err() {
            self.set_pos(pos);
            return None;
        }
        match decode_block(&buf) {
            Ok(b) => {
                self.last_bad_pos = 0;
                Some(b)
            }
            Err(BlockError::BadCrc) => {
                self.bad_blocks += 1;
                // Ao vivo, a primeira falha num offset é "ainda não pronto":
                // volta e tenta de novo no mesmo lugar.
                if self.live_timeout.is_some() && self.last_bad_pos != pos {
                    self.last_bad_pos = pos;
                    self.set_pos(pos);
                    return None;
                }
                self.warn(&format!("bloco em {pos} com crc invalido ({size} bytes); pulando"));
                self.set_pos(pos + size as u64);
                None
            }
            Err(_) => {
                self.set_pos(pos);
                None
            }
        }
    }

    /// Lê cabeçalho + índice de samples de um bloco. `None` quando não há bloco
    /// completo ali.
    fn block_meta_at(&mut self, offset: u64) -> Option<(usize, i64, bool)> {
        let total = self.size();
        if offset + BLOCK_HEADER_SIZE as u64 > total {
            return None;
        }
        let head = self.read_at(offset, BLOCK_HEADER_SIZE)?;
        if head[0..4] != MAGIC_BLOCK {
            return None;
        }
        let size = u32::from_le_bytes(head[4..8].try_into().unwrap()) as usize;
        let index_size = u32::from_le_bytes(head[24..28].try_into().unwrap()) as usize;
        // Bloco cortado é bloco ainda sendo escrito: fora do índice.
        if size < BLOCK_HEADER_SIZE || offset + size as u64 > total || index_size > size {
            return None;
        }
        let with_index = self.read_at(offset, BLOCK_HEADER_SIZE + index_size)?;
        block_meta(&with_index).ok()
    }

    fn scan_blocks_from(&mut self, from: i64) -> usize {
        if from <= 0 {
            return 0;
        }
        let mut off = from as u64;
        let mut n = 0;
        while let Some((size, start, key)) = self.block_meta_at(off) {
            self.index.push(IndexEntry { offset: off as i64, start_unix_ms: start, flags: if key { IDX_FLAG_KEYFRAME } else { 0 } });
            n += 1;
            off += size as u64;
        }
        self.scanned_up_to = off as i64;
        n
    }

    pub fn read_footer(&mut self) -> Option<Footer> {
        let total = self.size();
        if total < FOOTER_SIZE as u64 {
            return None;
        }
        let b = self.read_at(total - FOOTER_SIZE as u64, FOOTER_SIZE)?;
        decode_footer(&b)
    }

    fn load_index_from_footer(&mut self) -> bool {
        let Some(f) = self.read_footer() else { return false };
        if f.index_offset == 0 || f.index_count == 0 {
            return false;
        }
        let total = self.size();
        if f.index_offset + INDEX_HEADER_SIZE as u64 > total {
            return false;
        }
        let Some(head) = self.read_at(f.index_offset, INDEX_HEADER_SIZE) else { return false };
        if head[0..4] != MAGIC_INDEX {
            return false;
        }
        let chunk = u32::from_le_bytes(head[4..8].try_into().unwrap()) as u64;
        if f.index_offset + chunk > total || chunk > total {
            return false;
        }
        let Some(all) = self.read_at(f.index_offset, chunk as usize) else { return false };
        let Some(idx) = decode_index_chunk(&all, f.index_count) else { return false };
        self.index = idx;
        self.scanned_up_to = f.index_offset as i64;
        true
    }

    fn load_index_from_sidecar(&mut self) -> bool {
        let Some(path) = self.path.clone() else { return false };
        let Some((mut idx, valid)) = sidecar::read_sidecar(&path, self.header.creation_unix_ms) else { return false };
        if idx.is_empty() || valid <= self.first_block_offset as i64 {
            return false;
        }
        let total = self.size() as i64;
        if valid <= total {
            self.index = idx;
            self.scanned_up_to = valid;
            return true;
        }
        // O sidecar está À FRENTE da mídia (queda levou a cauda do .vms e não a
        // do índice): aproveita o prefixo que ainda tem arquivo por baixo. A
        // última entrada que cabia pode ser de um bloco cortado; sai também, e
        // a varredura recomeça nela.
        let mut cut = idx.iter().take_while(|e| e.offset < total).count();
        cut = cut.saturating_sub(1);
        if cut == 0 {
            return false;
        }
        self.scanned_up_to = idx[cut].offset;
        idx.truncate(cut);
        self.index = idx;
        self.warn(&format!(
            "{}: indice adiante da midia (queda de energia?); aproveitando {cut} blocos",
            path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
        ));
        true
    }

    /// Garante o índice. Devolve quantos blocos tem.
    pub fn ensure_index(&mut self) -> usize {
        if self.index_built {
            return self.index.len();
        }
        let saved = self.pos();
        self.index.clear();
        self.index_from_footer = self.load_index_from_footer();
        if !self.index_from_footer {
            if self.load_index_from_sidecar() {
                let from = self.scanned_up_to;
                self.scan_blocks_from(from);
            } else {
                self.index.clear();
                let first = self.first_block_offset as i64;
                self.scan_blocks_from(first);
            }
        }
        self.index_built = true;
        self.set_pos(saved);
        self.index.len()
    }

    pub fn build_index(&mut self) -> usize {
        self.index_built = false;
        self.ensure_index()
    }

    /// Arquivo em gravação: retoma de onde parou. Devolve quantos entraram.
    pub fn extend_index(&mut self) -> usize {
        if !self.index_built {
            return self.ensure_index();
        }
        if self.index_from_footer || self.scanned_up_to <= 0 {
            return 0;
        }
        let saved = self.pos();
        let from = self.scanned_up_to;
        let n = self.scan_blocks_from(from);
        self.set_pos(saved);
        n
    }

    /// Índice montado noutra leitura (o cache do servidor), para continuar dali
    /// sem segurar o arquivo aberto entre consultas.
    pub fn seed_index(&mut self, index: &[IndexEntry], scanned_up_to: i64) {
        if index.is_empty() || scanned_up_to <= 0 {
            return;
        }
        self.index = index.to_vec();
        self.scanned_up_to = scanned_up_to;
        self.index_built = true;
        self.index_from_footer = false;
    }

    /// Início do primeiro bloco: o começo real da faixa deste arquivo.
    pub fn first_block_start_ms(&mut self) -> Option<i64> {
        if !self.header_read {
            return None;
        }
        let off = self.first_block_offset;
        self.block_meta_at(off).map(|(_, start, _)| start)
    }

    /// (blocos, primeiro início, último início) do que o sidecar registrou.
    pub fn sidecar_summary(&self) -> Option<(usize, i64, i64)> {
        let path = self.path.as_ref()?;
        if !self.header_read {
            return None;
        }
        sidecar::sidecar_summary(path, self.header.creation_unix_ms)
    }

    pub fn find_block_at_time(&mut self, wall_ms: i64) -> Option<usize> {
        self.ensure_index();
        index_block_at_time(&self.index, wall_ms)
    }

    pub fn find_keyframe_block_at_or_before(&self, block: usize) -> Option<usize> {
        index_keyframe_at_or_before(&self.index, block)
    }

    /// Os bytes crus do header, para prefixar um fragmento da API.
    pub fn read_header_bytes(&mut self) -> Option<Vec<u8>> {
        if !self.header_read || self.header.header_size == 0 {
            return None;
        }
        let n = self.header.header_size as usize;
        if n as u64 > self.size() {
            return None;
        }
        let saved = self.pos();
        let r = self.read_at(0, n);
        self.set_pos(saved);
        r
    }

    /// Onde um bloco começa e quanto ocupa.
    pub fn block_range(&mut self, block: usize) -> Option<(u64, usize)> {
        self.ensure_index();
        let off = self.index.get(block)?.offset as u64;
        self.block_meta_at(off).map(|(size, _, _)| (off, size))
    }

    pub fn read_raw(&mut self, offset: u64, size: usize) -> Option<Vec<u8>> {
        if size == 0 || offset + size as u64 > self.size() {
            return None;
        }
        self.read_at(offset, size)
    }

    pub fn seek_to_block(&mut self, block: usize) -> bool {
        match self.index.get(block) {
            Some(e) => {
                let o = e.offset as u64;
                self.set_pos(o);
                true
            }
            None => false,
        }
    }

    /// Antes do primeiro bloco, começa do começo.
    pub fn seek_to_time(&mut self, wall_ms: i64) -> bool {
        let i = match self.find_block_at_time(wall_ms) {
            Some(i) => i,
            None if self.index.is_empty() => return false,
            None => 0,
        };
        self.seek_to_block(i)
    }

    pub fn seek_to_start(&mut self) -> bool {
        if self.first_block_offset == 0 {
            return false;
        }
        let o = self.first_block_offset;
        self.set_pos(o);
        true
    }

    /// O ponto de entrada mais recente: o que o ao vivo de arquivo precisa.
    pub fn seek_to_last_keyframe(&mut self) -> bool {
        self.ensure_index();
        match self.index.iter().rposition(|e| e.has_keyframe()) {
            Some(i) => self.seek_to_block(i),
            None => false,
        }
    }

    pub fn last_keyframe_ms(&mut self) -> i64 {
        self.ensure_index();
        self.index.iter().rev().find(|e| e.has_keyframe()).map(|e| e.start_unix_ms).unwrap_or(0)
    }

    pub fn current_block_offset(&mut self) -> u64 {
        self.pos()
    }
}

/// O `.vms` mais recente da pasta da câmera (por data de escrita).
pub fn find_most_recent_vms_for_camera(recordings_dir: &Path, camera: &str) -> Option<PathBuf> {
    let dir = super::paths::camera_dir(recordings_dir, camera);
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for e in std::fs::read_dir(dir).ok()?.flatten() {
        let p = e.path();
        // Sem conferir a extensão, um `.vms.idx` recém-escrito seria "a gravação
        // mais recente".
        if !p.extension().is_some_and(|x| x.eq_ignore_ascii_case("vms")) {
            continue;
        }
        let Ok(t) = e.metadata().and_then(|m| m.modified()) else { continue };
        if best.as_ref().is_none_or(|(bt, _)| t > *bt) {
            best = Some((t, p));
        }
    }
    best.map(|(_, p)| p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;
    use crate::vms::format::{encode_block, encode_header, SampleEntry};
    use crate::vms::writer::{FileRecordingWriter, RecordingWriter};

    fn bloco(seq: u32, ms: i64, key: bool) -> Block {
        Block {
            seq,
            start_unix_ms: ms,
            samples: vec![SampleEntry { track_id: 0, flags: key as u8, pts: seq as i64 * 3600, payload_offset: 0, payload_size: 3 }],
            payload: vec![seq as u8; 3],
            video_anchor_ms: ms,
            audio_anchor_ms: 0,
        }
    }

    fn grava(p: &Path, n: u32, fechar: bool) {
        let mut w = FileRecordingWriter::create(p).unwrap();
        w.write_header(&Header { creation_unix_ms: 777, source_uri: "rtsp://x".into(), ..Default::default() }).unwrap();
        for i in 0..n {
            w.write_block(&bloco(i, 10_000 + i as i64 * 2000, i % 4 == 0)).unwrap();
        }
        if fechar {
            w.close(true);
        } else {
            std::mem::forget(w); // simula queda: sem close e sem drop
        }
    }

    #[test]
    fn arquivo_fechado_usa_o_indice_do_rodape() {
        let d = TempDir::new("reader1");
        let p = d.path().join("a.vms");
        grava(&p, 10, true);
        let mut r = VmsReader::open(&p).unwrap();
        assert!(r.read_header());
        assert_eq!(r.header().source_uri, "rtsp://x");
        assert_eq!(r.ensure_index(), 10);
        assert!(r.index_from_footer());
        assert_eq!(r.find_block_at_time(15_000), Some(2));
        assert_eq!(r.find_keyframe_block_at_or_before(7), Some(4));
        assert_eq!(r.last_keyframe_ms(), 10_000 + 8 * 2000);
        // Leitura sequencial termina no índice e marca o fim fechado.
        r.seek_to_start();
        let mut n = 0;
        while let Some(b) = r.read_next_block() {
            assert_eq!(b.seq, n);
            n += 1;
        }
        assert_eq!(n, 10);
        assert!(r.at_closed_end());
    }

    #[test]
    fn arquivo_aberto_usa_sidecar_e_varre_a_cauda() {
        let d = TempDir::new("reader2");
        let p = d.path().join("b.vms");
        grava(&p, 20, false); // 16 no sidecar, 4 na cauda
        let mut r = VmsReader::open(&p).unwrap();
        assert!(r.read_header());
        assert_eq!(r.ensure_index(), 20);
        assert!(!r.index_from_footer());
        assert_eq!(r.sidecar_summary().unwrap().0, 16);
        assert_eq!(r.first_block_start_ms(), Some(10_000));
    }

    #[test]
    fn sem_sidecar_varre_tudo_e_estende() {
        let d = TempDir::new("reader3");
        let p = d.path().join("c.vms");
        let mut data = encode_header(&Header { creation_unix_ms: 1, ..Default::default() });
        for i in 0..3 {
            data.extend(encode_block(&bloco(i, 100 + i as i64, true)));
        }
        std::fs::write(&p, &data).unwrap();
        let mut r = VmsReader::open(&p).unwrap();
        r.read_header();
        assert_eq!(r.ensure_index(), 3);
        // O arquivo cresce: dois blocos novos e um pela metade.
        let mut more = encode_block(&bloco(3, 200, false));
        more.extend(encode_block(&bloco(4, 300, false)));
        let meio = encode_block(&bloco(5, 400, true));
        more.extend(&meio[..meio.len() / 2]);
        data.extend(&more);
        std::fs::write(&p, &data).unwrap();
        assert_eq!(r.extend_index(), 2);
        assert_eq!(r.index_count(), 5);
    }

    #[test]
    fn bloco_corrompido_e_pulado() {
        let mut data = encode_header(&Header::default());
        let a = encode_block(&bloco(0, 1, true));
        let mut b = encode_block(&bloco(1, 2, false));
        let c = encode_block(&bloco(2, 3, false));
        let meio = b.len() - 6;
        b[meio] ^= 0x55;
        data.extend(&a);
        data.extend(&b);
        data.extend(&c);
        let mut r = VmsReader::from_bytes(data);
        assert!(r.read_header());
        assert_eq!(r.read_next_block().unwrap().seq, 0);
        assert!(r.read_next_block().is_none(), "o corrompido devolve nada...");
        assert_eq!(r.bad_blocks(), 1);
        assert_eq!(r.read_next_block().unwrap().seq, 2, "...e a leitura segue depois dele");
    }

    #[test]
    fn mais_recente_da_pasta() {
        let d = TempDir::new("reader4");
        let cam = crate::vms::paths::camera_dir(d.path(), "frente");
        std::fs::create_dir_all(&cam).unwrap();
        std::fs::write(cam.join("frente_1.vms"), b"x").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(cam.join("frente_2.vms"), b"y").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(cam.join("frente_2.vms.idx"), b"z").unwrap();
        let p = find_most_recent_vms_for_camera(d.path(), "frente").unwrap();
        assert!(p.ends_with("frente_2.vms"));
    }
}
