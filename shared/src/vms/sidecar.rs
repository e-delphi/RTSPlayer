//! O índice do arquivo que ainda está sendo gravado: `<gravação>.vms.idx`.
//!
//! O VIDX só é escrito quando a gravação fecha; até lá achar um instante custa
//! varrer o arquivo — e o arquivo em gravação é justamente o de hoje. Fechou
//! direito, o sidecar é apagado; fechou torto (queda de energia), ele fica e é
//! o que evita a varredura para sempre.
//!
//! ```text
//! cabeçalho  'VIDS' ver(2) reservado(2) creation(8) crc(4)
//! lote       'IDXB' count(4) validUpTo(8) count × (off(8) start(8) flags(1)) crc(4)
//! ```
//!
//! Só append. O CRC de cada lote cobre cabeçalho e entradas: lote cortado no
//! meio é descartado, e vale tudo que veio antes. `validUpTo` é o ponto de
//! append do gravador quando o lote foi escrito — de onde retomar a varredura.

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use super::format::{IndexEntry, INDEX_ENTRY_SIZE};
use crate::bytes::{PutLe, Reader};
use crate::crc32;

pub const MAGIC_SIDECAR: [u8; 4] = *b"VIDS";
pub const MAGIC_BATCH: [u8; 4] = *b"IDXB";
pub const HEADER_SIZE: usize = 20;
pub const BATCH_HEADER_SIZE: usize = 16;
pub const VERSION: u16 = 1;
/// De quantos em quantos blocos sai um lote (~32 s com blocos de 2 s).
pub const BATCH_BLOCKS: usize = 16;
const MAX_BATCH: u32 = 1_000_000;

pub fn sidecar_path_of(vms: &Path) -> PathBuf {
    let mut s = vms.as_os_str().to_owned();
    s.push(".idx");
    PathBuf::from(s)
}

/// Some com o sidecar de uma gravação (retenção). Sidecar órfão não estraga
/// nada, então falha aqui é ignorada.
pub fn delete_sidecar(vms: &Path) {
    let _ = std::fs::remove_file(sidecar_path_of(vms));
}

/// Escreve o sidecar enquanto a gravação corre. Qualquer falha desliga o
/// sidecar e a gravação segue sem ele: mídia é o que não pode parar.
pub struct SidecarWriter {
    path: PathBuf,
    file: Option<File>,
    written: usize,
}

impl SidecarWriter {
    pub fn create(vms: &Path, creation_unix_ms: i64) -> Self {
        let path = sidecar_path_of(vms);
        let file = (|| {
            let mut f = OpenOptions::new().create(true).write(true).truncate(true).open(&path).ok()?;
            let mut b = Vec::with_capacity(HEADER_SIZE);
            b.put_bytes(&MAGIC_SIDECAR);
            b.put_u16_le(VERSION);
            b.put_u16_le(0);
            b.put_i64_le(creation_unix_ms);
            let crc = crc32::compute(&b);
            b.put_u32_le(crc);
            f.write_all(&b).ok()?;
            Some(f)
        })();
        Self { path, file, written: 0 }
    }

    pub fn ok(&self) -> bool {
        self.file.is_some()
    }

    pub fn written(&self) -> usize {
        self.written
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Grava num lote as entradas de `index[written..]`.
    pub fn write_batch(&mut self, index: &[IndexEntry], valid_up_to: i64) -> bool {
        let Some(f) = self.file.as_mut() else { return false };
        if index.len() <= self.written {
            return false;
        }
        let novas = &index[self.written..];
        let mut b = Vec::with_capacity(BATCH_HEADER_SIZE + novas.len() * INDEX_ENTRY_SIZE + 4);
        b.put_bytes(&MAGIC_BATCH);
        b.put_u32_le(novas.len() as u32);
        b.put_i64_le(valid_up_to);
        for e in novas {
            b.put_i64_le(e.offset);
            b.put_i64_le(e.start_unix_ms);
            b.put_u8(e.flags);
        }
        let crc = crc32::compute(&b);
        b.put_u32_le(crc);
        // Uma escrita só: lote pela metade no disco é lote que o CRC reprova.
        if f.write_all(&b).is_err() {
            self.file = None;
            return false;
        }
        self.written = index.len();
        true
    }

    /// Fecha. `delete` = a gravação fechou direito e o VIDX ficou no `.vms`.
    pub fn close(mut self, delete: bool) {
        self.file = None;
        if delete {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// O sidecar de `vms`: as entradas dos lotes íntegros e o offset de onde
/// retomar a varredura. `creation_unix_ms` (do header do `.vms`) tem de bater —
/// sidecar de outra gravação é pior que sidecar nenhum.
pub fn read_sidecar(vms: &Path, creation_unix_ms: i64) -> Option<(Vec<IndexEntry>, i64)> {
    let mut data = Vec::new();
    File::open(sidecar_path_of(vms)).ok()?.read_to_end(&mut data).ok()?;
    parse_sidecar(&data, creation_unix_ms)
}

/// O mesmo, sobre os bytes já lidos.
pub fn parse_sidecar(data: &[u8], creation_unix_ms: i64) -> Option<(Vec<IndexEntry>, i64)> {
    if data.len() < HEADER_SIZE || data[0..4] != MAGIC_SIDECAR {
        return None;
    }
    let stored = u32::from_le_bytes(data[16..20].try_into().ok()?);
    if crc32::compute(&data[..16]) != stored {
        return None;
    }
    let mut r = Reader::at(data, 4);
    if r.u16_le()? != VERSION {
        return None;
    }
    r.u16_le()?;
    if r.i64_le()? != creation_unix_ms {
        return None;
    }
    let mut pos = HEADER_SIZE;
    let mut index = Vec::new();
    let mut valid_up_to = 0i64;
    while pos + BATCH_HEADER_SIZE <= data.len() {
        let head = &data[pos..pos + BATCH_HEADER_SIZE];
        if head[0..4] != MAGIC_BATCH {
            break;
        }
        let count = u32::from_le_bytes(head[4..8].try_into().ok()?);
        if count == 0 || count > MAX_BATCH {
            break;
        }
        let need = count as usize * INDEX_ENTRY_SIZE + 4;
        let body_at = pos + BATCH_HEADER_SIZE;
        if body_at + need > data.len() {
            break; // lote cortado: o que a gravação em curso deixa no fim
        }
        let body = &data[body_at..body_at + need];
        let stored = u32::from_le_bytes(body[need - 4..].try_into().ok()?);
        if crc32::update(crc32::compute(head), &body[..need - 4]) != stored {
            break;
        }
        let mut br = Reader::new(body);
        for _ in 0..count {
            index.push(IndexEntry { offset: br.i64_le()?, start_unix_ms: br.i64_le()?, flags: br.u8()? });
        }
        valid_up_to = i64::from_le_bytes(head[8..16].try_into().ok()?);
        pos = body_at + need;
    }
    if index.is_empty() || valid_up_to <= 0 {
        return None;
    }
    Some((index, valid_up_to))
}

/// Só as pontas: (blocos, primeiro início, último início).
pub fn sidecar_summary(vms: &Path, creation_unix_ms: i64) -> Option<(usize, i64, i64)> {
    let (idx, _) = read_sidecar(vms, creation_unix_ms)?;
    Some((idx.len(), idx[0].start_unix_ms, idx[idx.len() - 1].start_unix_ms))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    fn entradas(n: usize) -> Vec<IndexEntry> {
        (0..n).map(|i| IndexEntry { offset: 100 + i as i64 * 50, start_unix_ms: 1000 * i as i64, flags: (i % 2) as u8 }).collect()
    }

    #[test]
    fn grava_em_lotes_e_le_de_volta() {
        let dir = TempDir::new("sidecar");
        let vms = dir.path().join("a.vms");
        let mut w = SidecarWriter::create(&vms, 42);
        let idx = entradas(5);
        assert!(w.write_batch(&idx[..3], 250));
        assert!(w.write_batch(&idx, 350));
        assert!(!w.write_batch(&idx, 350), "nada novo");
        w.close(false);
        let (lido, valid) = read_sidecar(&vms, 42).unwrap();
        assert_eq!(lido, idx);
        assert_eq!(valid, 350);
        assert!(read_sidecar(&vms, 43).is_none(), "outra gravação");
        assert_eq!(sidecar_summary(&vms, 42), Some((5, 0, 4000)));
    }

    #[test]
    fn lote_cortado_ou_corrompido_fica_de_fora() {
        let dir = TempDir::new("sidecar2");
        let vms = dir.path().join("b.vms");
        let mut w = SidecarWriter::create(&vms, 7);
        let idx = entradas(4);
        w.write_batch(&idx[..2], 200);
        w.write_batch(&idx, 300);
        w.close(false);
        let mut data = std::fs::read(sidecar_path_of(&vms)).unwrap();
        // Corta o último lote no meio.
        data.truncate(data.len() - 5);
        let (lido, valid) = parse_sidecar(&data, 7).unwrap();
        assert_eq!(lido.len(), 2);
        assert_eq!(valid, 200);
        // Um byte trocado no primeiro lote derruba tudo dali em diante.
        data[HEADER_SIZE + BATCH_HEADER_SIZE] ^= 1;
        assert!(parse_sidecar(&data, 7).is_none());
    }

    #[test]
    fn fechar_com_delete_apaga() {
        let dir = TempDir::new("sidecar3");
        let vms = dir.path().join("c.vms");
        let w = SidecarWriter::create(&vms, 1);
        assert!(sidecar_path_of(&vms).exists());
        w.close(true);
        assert!(!sidecar_path_of(&vms).exists());
    }
}
