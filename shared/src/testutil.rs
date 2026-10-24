//! Apoio aos testes (deste crate e dos outros dois).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

/// Pasta temporária própria do teste, apagada no fim.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> Self {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        let p = std::env::temp_dir().join(format!("vms-test-{}-{}-{tag}-{n}", std::process::id(), crate::clock::unix_ms()));
        std::fs::create_dir_all(&p).unwrap();
        Self(p)
    }
    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Uma gravação de teste: `blocks` blocos de vídeo H.264 de `block_ms` cada,
/// começando em `start_ms`, keyframe a cada 4. `close = false` simula a
/// gravação ainda aberta (sem rodapé; o handle fica vivo de propósito).
pub fn write_vms(path: &Path, start_ms: i64, blocks: u32, block_ms: i64, close: bool) {
    use crate::media::{VideoCodec, VideoTrackInfo};
    use crate::vms::format::{Block, Header, SampleEntry, FORMAT_VERSION};
    use crate::vms::writer::{FileRecordingWriter, RecordingWriter};
    let mut w = FileRecordingWriter::create(path).unwrap();
    let h = Header {
        version: FORMAT_VERSION,
        creation_unix_ms: start_ms,
        source_uri: "rtsp://teste".into(),
        video_present: true,
        video: VideoTrackInfo { codec: VideoCodec::H264, timescale: 90_000, width: 640, height: 360, extradata: Vec::new() },
        ..Default::default()
    };
    w.write_header(&h).unwrap();
    for i in 0..blocks {
        let ms = start_ms + i as i64 * block_ms;
        let data = vec![0, 0, 0, 1, if i % 4 == 0 { 0x65 } else { 0x41 }, i as u8];
        w.write_block(&Block {
            seq: i,
            start_unix_ms: ms,
            samples: vec![SampleEntry { track_id: 0, flags: (i % 4 == 0) as u8 | 0x06, pts: i as i64 * block_ms * 90, payload_offset: 0, payload_size: data.len() as u32 }],
            payload: data,
            video_anchor_ms: ms,
            audio_anchor_ms: 0,
        })
        .unwrap();
    }
    if close {
        w.close(true);
    } else {
        std::mem::forget(w);
    }
}
