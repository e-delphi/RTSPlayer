//! O layout do `.vms`, byte a byte. Desenho completo em
//! `delphi/docs/anatomia-vms.html`; tudo little-endian.
//!
//! ```text
//! header  'VMS1' ver(2) headerSize(4) creation(8) uriLen(2) uri
//!         vPresent(1) vCodec(1) vTimescale(4) w(2) h(2) vExtraLen(4) vExtra
//!         aPresent(1) aCodec(1) sampleRate(4) ch(1) bits(1) aTimescale(4)
//!         aExtraLen(4) aExtra crc(4)
//! bloco   'BLK\x01' size(4) seq(4) startMs(8) samples(4) indexSize(4)
//!         samples × (track(1) flags(1) pts(8) off(4) len(4))
//!         [ 'BANC' videoAnchor(8) audioAnchor(8) ]   ← dentro do indexSize
//!         payload crc(4)
//! índice  'VIDX' size(4) count(4) count × (off(8) startMs(8) flags(1)) crc(4)
//! rodapé  'VEOF' blocks(4) durationMs(8) lastBlockOff(8) indexOff(8)
//!         indexCount(4) crc(4)
//! ```
//!
//! Existe UM layout. Versão diferente é recusada em vez de adivinhada.
//!
//! Estas funções são puras (bytes ↔ estrutura): quem lê arquivo, quem monta
//! fragmento da API e quem serve o ao vivo da memória usam as mesmas, então não
//! há dois serializadores para divergir.

use crate::bytes::{PutLe, Reader};
use crate::crc32;
use crate::media::{AudioCodec, AudioTrackInfo, VideoCodec, VideoTrackInfo};

pub const MAGIC_FILE: [u8; 4] = *b"VMS1";
pub const MAGIC_BLOCK: [u8; 4] = [b'B', b'L', b'K', 0x01];
pub const MAGIC_FOOTER: [u8; 4] = *b"VEOF";
pub const MAGIC_INDEX: [u8; 4] = *b"VIDX";
pub const MAGIC_ANCHOR: [u8; 4] = *b"BANC";

pub const FORMAT_VERSION: u16 = 1;
pub const FOOTER_SIZE: usize = 40;
pub const INDEX_ENTRY_SIZE: usize = 17;
pub const INDEX_HEADER_SIZE: usize = 12;
pub const ANCHOR_SIZE: usize = 20;
pub const BLOCK_HEADER_SIZE: usize = 28;
pub const SAMPLE_ENTRY_SIZE: usize = 18;
pub const IDX_FLAG_KEYFRAME: u8 = 0x01;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Header {
    pub version: u16,
    pub header_size: u32,
    pub creation_unix_ms: i64,
    pub source_uri: String,
    pub video_present: bool,
    pub video: VideoTrackInfo,
    pub audio_present: bool,
    pub audio: AudioTrackInfo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SampleEntry {
    pub track_id: u8,
    pub flags: u8,
    pub pts: i64,
    pub payload_offset: u32,
    pub payload_size: u32,
}

impl SampleEntry {
    pub fn is_video_keyframe(&self) -> bool {
        self.track_id == 0 && self.flags & IDX_FLAG_KEYFRAME != 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Block {
    pub seq: u32,
    pub start_unix_ms: i64,
    pub samples: Vec<SampleEntry>,
    pub payload: Vec<u8>,
    /// Parede do primeiro sample de cada trilha no bloco; 0 = a trilha não
    /// aparece. É o que relaciona os PTS das duas trilhas.
    pub video_anchor_ms: i64,
    pub audio_anchor_ms: i64,
}

impl Block {
    pub fn has_keyframe(&self) -> bool {
        samples_have_keyframe(&self.samples)
    }
    /// Os bytes de um sample, se o offset/tamanho couberem no payload.
    pub fn sample_data(&self, e: &SampleEntry) -> Option<&[u8]> {
        let a = e.payload_offset as usize;
        let b = a.checked_add(e.payload_size as usize)?;
        self.payload.get(a..b)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Footer {
    pub total_blocks: u32,
    pub total_duration_ms: i64,
    pub last_block_offset: u64,
    /// 0 = fechou sem conseguir escrever o índice.
    pub index_offset: u64,
    pub index_count: u32,
}

/// Uma entrada por bloco, na ordem do arquivo.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct IndexEntry {
    pub offset: i64,
    pub start_unix_ms: i64,
    pub flags: u8,
}

impl IndexEntry {
    pub fn has_keyframe(&self) -> bool {
        self.flags & IDX_FLAG_KEYFRAME != 0
    }
}

/// Um bloco serve de ponto de entrada quando traz keyframe de vídeo. O gravador
/// fecha bloco por tempo/tamanho e não por keyframe, então isto se descobre
/// olhando os samples.
pub fn samples_have_keyframe(samples: &[SampleEntry]) -> bool {
    samples.iter().any(|s| s.is_video_keyframe())
}

/// Bloco que contém o instante, ou o anterior mais próximo; `None` se o instante
/// é anterior ao primeiro bloco. Busca binária: o índice está em ordem de tempo
/// porque está em ordem de arquivo, e o gravador só acrescenta.
pub fn index_block_at_time(index: &[IndexEntry], wall_ms: i64) -> Option<usize> {
    if index.is_empty() || wall_ms < index[0].start_unix_ms {
        return None;
    }
    // Último com start <= wall_ms.
    let n = index.partition_point(|e| e.start_unix_ms <= wall_ms);
    Some(n.saturating_sub(1))
}

/// Andando para trás a partir de `from`, o primeiro bloco com keyframe.
pub fn index_keyframe_at_or_before(index: &[IndexEntry], from: usize) -> Option<usize> {
    if from >= index.len() {
        return None;
    }
    (0..=from).rev().find(|&i| index[i].has_keyframe())
}

// ------------------------------------------------------------------ header

pub fn encode_header(h: &Header) -> Vec<u8> {
    let mut uri = h.source_uri.as_bytes().to_vec();
    uri.truncate(65535);
    let size = 4 + 2 + 4 + 8 + 2 + uri.len()
        + 1 + 1 + 4 + 2 + 2 + 4 + h.video.extradata.len()
        + 1 + 1 + 4 + 1 + 1 + 4 + 4 + h.audio.extradata.len()
        + 4;
    let mut b = Vec::with_capacity(size);
    b.put_bytes(&MAGIC_FILE);
    b.put_u16_le(FORMAT_VERSION);
    b.put_u32_le(size as u32);
    b.put_i64_le(h.creation_unix_ms);
    b.put_u16_le(uri.len() as u16);
    b.put_bytes(&uri);
    b.put_u8(h.video_present as u8);
    b.put_u8(h.video.codec as u8);
    b.put_u32_le(h.video.timescale);
    b.put_u16_le(h.video.width);
    b.put_u16_le(h.video.height);
    b.put_u32_le(h.video.extradata.len() as u32);
    b.put_bytes(&h.video.extradata);
    b.put_u8(h.audio_present as u8);
    b.put_u8(h.audio.codec as u8);
    b.put_u32_le(h.audio.sample_rate);
    b.put_u8(h.audio.channels);
    b.put_u8(h.audio.bits_per_sample);
    b.put_u32_le(h.audio.timescale);
    b.put_u32_le(h.audio.extradata.len() as u32);
    b.put_bytes(&h.audio.extradata);
    let crc = crc32::compute(&b);
    b.put_u32_le(crc);
    debug_assert_eq!(b.len(), size);
    b
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeaderError {
    /// Não começa com `VMS1`, ou acabou no meio.
    NotVms,
    /// Formato de outra versão.
    Version(u16),
    Truncated,
}

/// Só o preâmbulo: (versão, tamanho do header). Quem lê arquivo precisa dele
/// para saber quanto mais ler.
pub fn decode_preamble(b: &[u8]) -> Result<(u16, u32), HeaderError> {
    if b.len() < 10 || b[0..4] != MAGIC_FILE {
        return Err(HeaderError::NotVms);
    }
    let mut r = Reader::at(b, 4);
    let ver = r.u16_le().ok_or(HeaderError::Truncated)?;
    let size = r.u32_le().ok_or(HeaderError::Truncated)?;
    Ok((ver, size))
}

/// O header inteiro, a partir dos seus `header_size` bytes.
pub fn decode_header(b: &[u8]) -> Result<Header, HeaderError> {
    let (version, header_size) = decode_preamble(b)?;
    if version != FORMAT_VERSION {
        return Err(HeaderError::Version(version));
    }
    if (header_size as usize) < 10 || b.len() < header_size as usize {
        return Err(HeaderError::Truncated);
    }
    let mut r = Reader::at(&b[..header_size as usize], 10);
    let t = || HeaderError::Truncated;
    let creation_unix_ms = r.i64_le().ok_or_else(t)?;
    let uri_len = r.u16_le().ok_or_else(t)? as usize;
    let source_uri = String::from_utf8_lossy(r.bytes(uri_len).ok_or_else(t)?).into_owned();
    let video_present = r.u8().ok_or_else(t)? != 0;
    let vcodec = VideoCodec::from_u8(r.u8().ok_or_else(t)?);
    let vts = r.u32_le().ok_or_else(t)?;
    let w = r.u16_le().ok_or_else(t)?;
    let h = r.u16_le().ok_or_else(t)?;
    let vlen = r.u32_le().ok_or_else(t)? as usize;
    let vextra = r.bytes(vlen).ok_or_else(t)?.to_vec();
    let audio_present = r.u8().ok_or_else(t)? != 0;
    let acodec = AudioCodec::from_u8(r.u8().ok_or_else(t)?);
    let rate = r.u32_le().ok_or_else(t)?;
    let ch = r.u8().ok_or_else(t)?;
    let bits = r.u8().ok_or_else(t)?;
    let ats = r.u32_le().ok_or_else(t)?;
    let alen = r.u32_le().ok_or_else(t)? as usize;
    let aextra = r.bytes(alen).ok_or_else(t)?.to_vec();
    Ok(Header {
        version,
        header_size,
        creation_unix_ms,
        source_uri,
        video_present,
        video: VideoTrackInfo { codec: vcodec, timescale: vts, width: w, height: h, extradata: vextra },
        audio_present,
        audio: AudioTrackInfo {
            codec: acodec,
            timescale: ats,
            sample_rate: rate,
            channels: ch,
            bits_per_sample: bits,
            extradata: aextra,
        },
    })
}

// ------------------------------------------------------------------ bloco

pub fn encode_block(blk: &Block) -> Vec<u8> {
    // A âncora entra DENTRO da área de índice, depois das entradas: leitor que
    // não a conhece acha o payload por `indexSize` e a ignora.
    let has_anchor = blk.video_anchor_ms > 0 || blk.audio_anchor_ms > 0;
    let mut index_size = blk.samples.len() * SAMPLE_ENTRY_SIZE;
    if has_anchor {
        index_size += ANCHOR_SIZE;
    }
    let total = BLOCK_HEADER_SIZE + index_size + blk.payload.len() + 4;
    let mut b = Vec::with_capacity(total);
    b.put_bytes(&MAGIC_BLOCK);
    b.put_u32_le(total as u32);
    b.put_u32_le(blk.seq);
    b.put_i64_le(blk.start_unix_ms);
    b.put_u32_le(blk.samples.len() as u32);
    b.put_u32_le(index_size as u32);
    for s in &blk.samples {
        b.put_u8(s.track_id);
        b.put_u8(s.flags);
        b.put_i64_le(s.pts);
        b.put_u32_le(s.payload_offset);
        b.put_u32_le(s.payload_size);
    }
    if has_anchor {
        b.put_bytes(&MAGIC_ANCHOR);
        b.put_i64_le(blk.video_anchor_ms);
        b.put_i64_le(blk.audio_anchor_ms);
    }
    b.put_bytes(&blk.payload);
    let crc = crc32::compute(&b);
    b.put_u32_le(crc);
    b
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockError {
    /// Não é bloco aqui (outro magic, ou tamanho impossível).
    NotBlock,
    /// O bloco não está inteiro no buffer (ainda sendo escrito).
    Incomplete,
    /// Inteiro, mas o CRC não bate: bloco corrompido.
    BadCrc,
}

/// O tamanho declarado no cabeçalho de um bloco que começa em `b[0]`.
pub fn block_size_at(b: &[u8]) -> Result<usize, BlockError> {
    if b.len() < 8 {
        return Err(BlockError::Incomplete);
    }
    if b[0..4] != MAGIC_BLOCK {
        return Err(BlockError::NotBlock);
    }
    let size = u32::from_le_bytes([b[4], b[5], b[6], b[7]]) as usize;
    if size < BLOCK_HEADER_SIZE {
        return Err(BlockError::NotBlock);
    }
    Ok(size)
}

/// Um bloco completo (os `size` bytes dele), com o CRC conferido.
pub fn decode_block(b: &[u8]) -> Result<Block, BlockError> {
    let size = block_size_at(b)?;
    if b.len() < size {
        return Err(BlockError::Incomplete);
    }
    let b = &b[..size];
    let stored = u32::from_le_bytes([b[size - 4], b[size - 3], b[size - 2], b[size - 1]]);
    if crc32::compute(&b[..size - 4]) != stored {
        return Err(BlockError::BadCrc);
    }
    let mut r = Reader::at(b, 8);
    let nb = || BlockError::NotBlock;
    let seq = r.u32_le().ok_or_else(nb)?;
    let start_unix_ms = r.i64_le().ok_or_else(nb)?;
    let count = r.u32_le().ok_or_else(nb)? as usize;
    let index_size = r.u32_le().ok_or_else(nb)? as usize;
    if index_size > size - BLOCK_HEADER_SIZE || count.saturating_mul(SAMPLE_ENTRY_SIZE) > index_size {
        return Err(BlockError::NotBlock);
    }
    let mut samples = Vec::with_capacity(count);
    for _ in 0..count {
        samples.push(SampleEntry {
            track_id: r.u8().ok_or_else(nb)?,
            flags: r.u8().ok_or_else(nb)?,
            pts: r.i64_le().ok_or_else(nb)?,
            payload_offset: r.u32_le().ok_or_else(nb)?,
            payload_size: r.u32_le().ok_or_else(nb)?,
        });
    }
    let (mut va, mut aa) = (0, 0);
    let anchor_at = 28 + count * SAMPLE_ENTRY_SIZE;
    if index_size >= count * SAMPLE_ENTRY_SIZE + ANCHOR_SIZE && b[anchor_at..anchor_at + 4] == MAGIC_ANCHOR {
        let mut ar = Reader::at(b, anchor_at + 4);
        va = ar.i64_le().ok_or_else(nb)?;
        aa = ar.i64_le().ok_or_else(nb)?;
    }
    let payload_start = BLOCK_HEADER_SIZE + index_size;
    let payload = b[payload_start..size - 4].to_vec();
    Ok(Block { seq, start_unix_ms, samples, payload, video_anchor_ms: va, audio_anchor_ms: aa })
}

/// Só o que o índice precisa de um bloco: (tamanho, início, tem keyframe). Lê
/// o cabeçalho e as entradas, sem payload e sem CRC — é a varredura barata.
pub fn block_meta(head_and_index: &[u8]) -> Result<(usize, i64, bool), BlockError> {
    let size = block_size_at(head_and_index)?;
    if head_and_index.len() < BLOCK_HEADER_SIZE {
        return Err(BlockError::Incomplete);
    }
    let start = i64::from_le_bytes(head_and_index[12..20].try_into().unwrap());
    let count = u32::from_le_bytes(head_and_index[20..24].try_into().unwrap()) as usize;
    let index_size = u32::from_le_bytes(head_and_index[24..28].try_into().unwrap()) as usize;
    if index_size > size {
        return Err(BlockError::NotBlock);
    }
    let mut key = false;
    for i in 0..count {
        let base = BLOCK_HEADER_SIZE + i * SAMPLE_ENTRY_SIZE;
        if base + 1 >= BLOCK_HEADER_SIZE + index_size || base + 1 >= head_and_index.len() {
            break;
        }
        if head_and_index[base] == 0 && head_and_index[base + 1] & IDX_FLAG_KEYFRAME != 0 {
            key = true;
            break;
        }
    }
    Ok((size, start, key))
}

// ------------------------------------------------------------------ índice e rodapé

pub fn encode_index_chunk(index: &[IndexEntry]) -> Vec<u8> {
    if index.is_empty() {
        return Vec::new();
    }
    let total = INDEX_HEADER_SIZE + index.len() * INDEX_ENTRY_SIZE + 4;
    let mut b = Vec::with_capacity(total);
    b.put_bytes(&MAGIC_INDEX);
    b.put_u32_le(total as u32);
    b.put_u32_le(index.len() as u32);
    for e in index {
        b.put_i64_le(e.offset);
        b.put_i64_le(e.start_unix_ms);
        b.put_u8(e.flags);
    }
    let crc = crc32::compute(&b);
    b.put_u32_le(crc);
    b
}

/// O chunk VIDX inteiro (a partir do magic). `None` se qualquer conferência
/// falhar: índice que não bate cai na varredura, que é lenta mas não mente.
pub fn decode_index_chunk(b: &[u8], expected_count: u32) -> Option<Vec<IndexEntry>> {
    if b.len() < INDEX_HEADER_SIZE || b[0..4] != MAGIC_INDEX {
        return None;
    }
    let size = u32::from_le_bytes(b[4..8].try_into().ok()?) as usize;
    let count = u32::from_le_bytes(b[8..12].try_into().ok()?);
    if count != expected_count || count == 0 {
        return None;
    }
    if size != INDEX_HEADER_SIZE + count as usize * INDEX_ENTRY_SIZE + 4 || b.len() < size {
        return None;
    }
    let stored = u32::from_le_bytes(b[size - 4..size].try_into().ok()?);
    if crc32::compute(&b[..size - 4]) != stored {
        return None;
    }
    let mut r = Reader::at(b, INDEX_HEADER_SIZE);
    let mut v = Vec::with_capacity(count as usize);
    for _ in 0..count {
        v.push(IndexEntry { offset: r.i64_le()?, start_unix_ms: r.i64_le()?, flags: r.u8()? });
    }
    Some(v)
}

pub fn encode_footer(f: &Footer) -> Vec<u8> {
    let mut b = Vec::with_capacity(FOOTER_SIZE);
    b.put_bytes(&MAGIC_FOOTER);
    b.put_u32_le(f.total_blocks);
    b.put_i64_le(f.total_duration_ms);
    b.put_u64_le(f.last_block_offset);
    b.put_u64_le(f.index_offset);
    // Sem índice, a contagem acompanha: o rodapé não promete entradas que não
    // existem.
    b.put_u32_le(if f.index_offset == 0 { 0 } else { f.index_count });
    let crc = crc32::compute(&b);
    b.put_u32_le(crc);
    b
}

/// Os últimos 40 bytes do arquivo. Arquivo em gravação não tem rodapé: ali cai
/// o meio de um bloco, e é o CRC que impede confundir os dois.
pub fn decode_footer(b: &[u8]) -> Option<Footer> {
    if b.len() != FOOTER_SIZE || b[0..4] != MAGIC_FOOTER {
        return None;
    }
    let stored = u32::from_le_bytes(b[36..40].try_into().ok()?);
    if crc32::compute(&b[..36]) != stored {
        return None;
    }
    let mut r = Reader::at(b, 4);
    Some(Footer {
        total_blocks: r.u32_le()?,
        total_duration_ms: r.i64_le()?,
        last_block_offset: r.u64_le()?,
        index_offset: r.u64_le()?,
        index_count: r.u32_le()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn header_exemplo() -> Header {
        Header {
            version: FORMAT_VERSION,
            header_size: 0,
            creation_unix_ms: 1_786_846_215_000,
            source_uri: "rtsp://cam/onvif1".into(),
            video_present: true,
            video: VideoTrackInfo { codec: VideoCodec::H265, timescale: 90000, width: 1920, height: 1080, extradata: vec![0, 0, 0, 1, 0x40] },
            audio_present: true,
            audio: AudioTrackInfo { codec: AudioCodec::G711A, timescale: 8000, sample_rate: 8000, channels: 1, bits_per_sample: 8, extradata: vec![] },
        }
    }

    #[test]
    fn header_ida_e_volta() {
        let h = header_exemplo();
        let b = encode_header(&h);
        let d = decode_header(&b).unwrap();
        assert_eq!(d.header_size as usize, b.len());
        assert_eq!(d.creation_unix_ms, h.creation_unix_ms);
        assert_eq!(d.source_uri, h.source_uri);
        assert_eq!(d.video, h.video);
        assert_eq!(d.audio, h.audio);
        // O CRC fecha o header e cobre tudo antes dele.
        let n = b.len();
        assert_eq!(crc32::compute(&b[..n - 4]), u32::from_le_bytes(b[n - 4..].try_into().unwrap()));
    }

    #[test]
    fn header_de_outra_versao_e_recusado() {
        let mut b = encode_header(&header_exemplo());
        b[4] = 2;
        assert_eq!(decode_header(&b), Err(HeaderError::Version(2)));
        assert_eq!(decode_header(b"nada"), Err(HeaderError::NotVms));
    }

    fn bloco_exemplo(ancora: bool) -> Block {
        let payload = b"KEYFRAMEaudio".to_vec();
        Block {
            seq: 3,
            start_unix_ms: 1000,
            samples: vec![
                SampleEntry { track_id: 0, flags: 1, pts: 90000, payload_offset: 0, payload_size: 8 },
                SampleEntry { track_id: 1, flags: 0, pts: 8000, payload_offset: 8, payload_size: 5 },
            ],
            payload,
            video_anchor_ms: if ancora { 1000 } else { 0 },
            audio_anchor_ms: if ancora { 1010 } else { 0 },
        }
    }

    #[test]
    fn bloco_ida_e_volta_com_e_sem_ancora() {
        for ancora in [false, true] {
            let blk = bloco_exemplo(ancora);
            let b = encode_block(&blk);
            assert_eq!(block_size_at(&b).unwrap(), b.len());
            let d = decode_block(&b).unwrap();
            assert_eq!(d, blk);
            assert_eq!(d.sample_data(&d.samples[1]), Some(&b"audio"[..]));
            let (size, start, key) = block_meta(&b).unwrap();
            assert_eq!((size, start, key), (b.len(), 1000, true));
        }
    }

    #[test]
    fn bloco_corrompido_ou_cortado() {
        let mut b = encode_block(&bloco_exemplo(true));
        assert_eq!(decode_block(&b[..b.len() - 1]), Err(BlockError::Incomplete));
        let meio = b.len() / 2;
        b[meio] ^= 0xFF;
        assert_eq!(decode_block(&b), Err(BlockError::BadCrc));
        assert_eq!(decode_block(b"VEOFxxxxxxxx"), Err(BlockError::NotBlock));
    }

    #[test]
    fn indice_e_rodape() {
        let idx = vec![
            IndexEntry { offset: 100, start_unix_ms: 1000, flags: 1 },
            IndexEntry { offset: 300, start_unix_ms: 3000, flags: 0 },
        ];
        let c = encode_index_chunk(&idx);
        assert_eq!(decode_index_chunk(&c, 2), Some(idx.clone()));
        assert_eq!(decode_index_chunk(&c, 3), None);
        let f = Footer { total_blocks: 2, total_duration_ms: 2000, last_block_offset: 300, index_offset: 500, index_count: 2 };
        let fb = encode_footer(&f);
        assert_eq!(fb.len(), FOOTER_SIZE);
        assert_eq!(decode_footer(&fb), Some(f));
        let sem = encode_footer(&Footer { index_offset: 0, index_count: 9, ..f });
        assert_eq!(decode_footer(&sem).unwrap().index_count, 0);
    }

    #[test]
    fn busca_no_indice() {
        let idx: Vec<IndexEntry> = [(0, 1000, 1), (1, 2000, 0), (2, 3000, 1), (3, 4000, 0)]
            .iter()
            .map(|&(o, t, f)| IndexEntry { offset: o, start_unix_ms: t, flags: f })
            .collect();
        assert_eq!(index_block_at_time(&idx, 999), None);
        assert_eq!(index_block_at_time(&idx, 1000), Some(0));
        assert_eq!(index_block_at_time(&idx, 2500), Some(1));
        assert_eq!(index_block_at_time(&idx, 99999), Some(3));
        assert_eq!(index_keyframe_at_or_before(&idx, 3), Some(2));
        assert_eq!(index_keyframe_at_or_before(&idx, 1), Some(0));
        assert_eq!(index_keyframe_at_or_before(&idx, 9), None);
    }
}
