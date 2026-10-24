//! Grava um `.vms`: header, blocos, e no fechamento o índice VIDX e o rodapé.
//!
//! Enquanto grava, o índice vai para o sidecar a cada [`BATCH_BLOCKS`] blocos.
//! O sidecar só some quando o VIDX E o rodapé que aponta para ele entraram —
//! fechamento torto mantém o sidecar.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use super::format::{encode_block, encode_footer, encode_header, encode_index_chunk, Block, Footer, Header, IndexEntry, IDX_FLAG_KEYFRAME};
use super::sidecar::{SidecarWriter, BATCH_BLOCKS};

/// Válvula: acima disto (~23 dias com blocos de 2 s) o índice é abandonado e
/// o arquivo fecha sem ele.
const MAX_INDEX_ENTRIES: usize = 1_000_000;

/// O que um gravador oferece (o `IRecordingWriter` do Delphi). Existe como
/// trait para quem grava poder ser testado sem disco.
pub trait RecordingWriter: Send {
    fn write_header(&mut self, h: &Header) -> io::Result<()>;
    fn write_block(&mut self, b: &Block) -> io::Result<()>;
    fn close(&mut self, write_footer: bool);
    fn header_written(&self) -> bool;
    fn blocks_written(&self) -> u32;
    fn bytes_written(&self) -> u64;
    fn file_path(&self) -> &Path;
}

pub struct FileRecordingWriter {
    path: PathBuf,
    file: Option<File>,
    header_done: bool,
    blocks: u32,
    bytes: u64,
    first_unix_ms: i64,
    last_unix_ms: i64,
    last_block_offset: u64,
    index: Vec<IndexEntry>,
    index_overflow: bool,
    sidecar: Option<SidecarWriter>,
}

fn open_for_recording(path: &Path) -> io::Result<File> {
    let mut o = OpenOptions::new();
    o.create(true).write(true).truncate(true);
    // Nega escrita e exclusão a terceiros, como o fmShareDenyWrite do Delphi:
    // quem lê (servidor, ao vivo) continua lendo, e a retenção não consegue
    // apagar a gravação em curso.
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_SHARE_READ: u32 = 0x1;
        o.share_mode(FILE_SHARE_READ);
    }
    o.open(path)
}

impl FileRecordingWriter {
    pub fn create(path: &Path) -> io::Result<Self> {
        if let Some(dir) = path.parent() {
            if !dir.as_os_str().is_empty() {
                std::fs::create_dir_all(dir)?;
            }
        }
        let file = open_for_recording(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            file: Some(file),
            header_done: false,
            blocks: 0,
            bytes: 0,
            first_unix_ms: 0,
            last_unix_ms: 0,
            last_block_offset: 0,
            index: Vec::new(),
            index_overflow: false,
            sidecar: None,
        })
    }

    fn file(&mut self) -> io::Result<&mut File> {
        self.file.as_mut().ok_or_else(|| io::Error::other("gravação já fechada"))
    }

    fn flush_sidecar(&mut self) {
        if let Some(s) = self.sidecar.as_mut() {
            if s.ok() {
                s.write_batch(&self.index, self.bytes as i64);
            }
        }
    }

    fn note_block(&mut self, b: &Block, offset: u64) {
        if self.index_overflow {
            return;
        }
        if self.index.len() >= MAX_INDEX_ENTRIES {
            self.index_overflow = true;
            self.index = Vec::new();
            return;
        }
        self.index.push(IndexEntry {
            offset: offset as i64,
            start_unix_ms: b.start_unix_ms,
            flags: if b.has_keyframe() { IDX_FLAG_KEYFRAME } else { 0 },
        });
    }
}

impl RecordingWriter for FileRecordingWriter {
    fn write_header(&mut self, h: &Header) -> io::Result<()> {
        if self.header_done {
            return Err(io::Error::other("header já escrito"));
        }
        let b = encode_header(h);
        self.file()?.write_all(&b)?;
        self.bytes += b.len() as u64;
        self.header_done = true;
        self.first_unix_ms = h.creation_unix_ms;
        self.sidecar = Some(SidecarWriter::create(&self.path, h.creation_unix_ms));
        Ok(())
    }

    fn write_block(&mut self, blk: &Block) -> io::Result<()> {
        if !self.header_done {
            return Err(io::Error::other("header antes dos blocos"));
        }
        let b = encode_block(blk);
        let start = self.bytes;
        self.file()?.write_all(&b)?;
        self.bytes += b.len() as u64;
        self.last_block_offset = start;
        self.blocks += 1;
        self.last_unix_ms = blk.start_unix_ms;
        self.note_block(blk, start);
        let pending = self.sidecar.as_ref().map(|s| self.index.len().saturating_sub(s.written())).unwrap_or(0);
        if pending >= BATCH_BLOCKS {
            self.flush_sidecar();
        }
        Ok(())
    }

    fn close(&mut self, write_footer: bool) {
        if self.file.is_none() {
            return;
        }
        // Último lote antes de tudo: se o resto falhar, o sidecar ainda
        // descreve o arquivo inteiro.
        self.flush_sidecar();
        let mut index_offset = 0u64;
        let mut footer_ok = false;
        if write_footer && self.header_done {
            if !self.index.is_empty() && !self.index_overflow {
                let chunk = encode_index_chunk(&self.index);
                let at = self.bytes;
                if self.file.as_mut().unwrap().write_all(&chunk).is_ok() {
                    self.bytes += chunk.len() as u64;
                    index_offset = at;
                }
            }
            let duration = if self.first_unix_ms > 0 && self.last_unix_ms >= self.first_unix_ms {
                self.last_unix_ms - self.first_unix_ms
            } else {
                0
            };
            let f = encode_footer(&Footer {
                total_blocks: self.blocks,
                total_duration_ms: duration,
                last_block_offset: self.last_block_offset,
                index_offset,
                index_count: self.index.len() as u32,
            });
            if self.file.as_mut().unwrap().write_all(&f).is_ok() {
                self.bytes += f.len() as u64;
                footer_ok = true;
            }
        }
        if let Some(f) = self.file.as_mut() {
            let _ = f.sync_all();
        }
        if let Some(s) = self.sidecar.take() {
            s.close(footer_ok && index_offset != 0);
        }
        self.file = None;
    }

    fn header_written(&self) -> bool {
        self.header_done
    }
    fn blocks_written(&self) -> u32 {
        self.blocks
    }
    fn bytes_written(&self) -> u64 {
        self.bytes
    }
    fn file_path(&self) -> &Path {
        &self.path
    }
}

impl Drop for FileRecordingWriter {
    fn drop(&mut self) {
        // Sem passar pelo close: a gravação não fechou direito, então o sidecar
        // é o único índice e fica.
        if let Some(s) = self.sidecar.take() {
            s.close(false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;
    use crate::vms::format::{decode_footer, SampleEntry, FOOTER_SIZE};
    use crate::vms::sidecar::sidecar_path_of;

    pub(crate) fn bloco(seq: u32, ms: i64, key: bool) -> Block {
        Block {
            seq,
            start_unix_ms: ms,
            samples: vec![SampleEntry { track_id: 0, flags: key as u8, pts: seq as i64 * 3600, payload_offset: 0, payload_size: 4 }],
            payload: vec![seq as u8; 4],
            video_anchor_ms: ms,
            audio_anchor_ms: 0,
        }
    }

    #[test]
    fn fechar_escreve_indice_rodape_e_apaga_sidecar() {
        let dir = TempDir::new("writer");
        let p = dir.path().join("cam").join("x.vms");
        let mut w = FileRecordingWriter::create(&p).unwrap();
        let h = Header { creation_unix_ms: 1000, ..Default::default() };
        w.write_header(&h).unwrap();
        for i in 0..20 {
            w.write_block(&bloco(i, 1000 + i as i64 * 2000, i % 5 == 0)).unwrap();
        }
        // 16 blocos já mandaram um lote.
        assert!(sidecar_path_of(&p).exists());
        w.close(true);
        assert!(!sidecar_path_of(&p).exists());
        let data = std::fs::read(&p).unwrap();
        let f = decode_footer(&data[data.len() - FOOTER_SIZE..]).unwrap();
        assert_eq!(f.total_blocks, 20);
        assert_eq!(f.index_count, 20);
        assert_eq!(f.total_duration_ms, 19 * 2000);
        assert_eq!(w.bytes_written(), data.len() as u64);
    }

    #[test]
    fn sem_fechar_o_sidecar_fica() {
        let dir = TempDir::new("writer2");
        let p = dir.path().join("y.vms");
        {
            let mut w = FileRecordingWriter::create(&p).unwrap();
            w.write_header(&Header { creation_unix_ms: 5, ..Default::default() }).unwrap();
            for i in 0..17 {
                w.write_block(&bloco(i, 100 + i as i64, true)).unwrap();
            }
        }
        assert!(sidecar_path_of(&p).exists());
    }
}
