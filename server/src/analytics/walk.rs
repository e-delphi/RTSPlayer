//! Um percurso pela gravação entregando quadros no ritmo pedido (`step_ms`), e
//! não no do GOP: decodifica tudo desde o keyframe e entrega só o quadro que
//! alcança o próximo alvo. Atravessa arquivos.

use std::path::PathBuf;
use std::sync::Arc;

use vms_core::media::VideoCodec;
use vms_core::vms::format::{index_block_at_time, index_keyframe_at_or_before, IDX_FLAG_KEYFRAME};
use vms_core::vms::{Block, VmsReader};

use crate::ffmpeg::{Decoder, Ffmpeg, RgbImage};
use crate::index_cache::{FileInfo, IndexCache};

const MAX_SEM_SAIDA: usize = 10_000;

/// Um decodificador de sequência (o FFmpeg, ou um dublê no teste).
pub trait FrameSequence: Send {
    fn feed(&mut self, au: &[u8]) -> Option<RgbImage>;
}

pub trait SequenceOpener: Send + Sync {
    fn open(&self, codec: VideoCodec, extra: &[u8], max_w: i32, max_h: i32) -> Option<Box<dyn FrameSequence>>;
}

impl FrameSequence for Decoder {
    fn feed(&mut self, au: &[u8]) -> Option<RgbImage> {
        Decoder::feed(self, au)
    }
}

pub struct FfmpegOpener(pub Arc<Ffmpeg>);

impl SequenceOpener for FfmpegOpener {
    fn open(&self, codec: VideoCodec, extra: &[u8], max_w: i32, max_h: i32) -> Option<Box<dyn FrameSequence>> {
        Decoder::open(self.0.clone(), codec, extra, max_w, max_h).map(|d| Box::new(d) as Box<dyn FrameSequence>)
    }
}

pub struct WalkSource {
    pub cache: Arc<IndexCache>,
    pub opener: Arc<dyn SequenceOpener>,
}

impl WalkSource {
    pub fn walk(&self, camera: &str, from: i64, to: i64, step: i64, max_w: i32, max_h: i32) -> Option<FrameWalk> {
        if camera.is_empty() || to <= from || step <= 0 {
            return None;
        }
        let mut w = FrameWalk {
            cache: self.cache.clone(),
            opener: self.opener.clone(),
            camera: camera.into(),
            to,
            step,
            alvo: from,
            max_w,
            max_h,
            reader: None,
            seq: None,
            arquivo: PathBuf::new(),
            motivo: String::new(),
            sem_saida: 0,
            bloco: None,
            idx: 0,
            esperando_chave: true,
            ancora: 0,
            primeiro_pts: 0,
            timescale: 90_000,
            acabou: false,
        };
        w.acabou = !w.abrir_em(from);
        if w.acabou && w.motivo.is_empty() {
            w.motivo = "nao ha gravacao no trecho".into();
        }
        Some(w)
    }
}

pub struct FrameWalk {
    cache: Arc<IndexCache>,
    opener: Arc<dyn SequenceOpener>,
    camera: String,
    to: i64,
    step: i64,
    alvo: i64,
    max_w: i32,
    max_h: i32,
    reader: Option<VmsReader>,
    seq: Option<Box<dyn FrameSequence>>,
    arquivo: PathBuf,
    motivo: String,
    sem_saida: usize,
    bloco: Option<Block>,
    idx: usize,
    esperando_chave: bool,
    ancora: i64,
    primeiro_pts: i64,
    timescale: i64,
    acabou: bool,
}

impl FrameWalk {
    fn fechar(&mut self) {
        self.seq = None;
        self.reader = None;
        self.bloco = None;
    }

    fn abrir_em(&mut self, ms: i64) -> bool {
        self.fechar();
        match crate::thumbs::file_at(&self.cache, &self.camera, ms) {
            Some(f) => self.abrir(&f, ms),
            None => false,
        }
    }

    fn abrir(&mut self, info: &FileInfo, ms: i64) -> bool {
        self.fechar();
        if info.start_ms > self.to {
            return false;
        }
        let ms = ms.max(info.start_ms);
        let Some(index) = self.cache.index(&info.path) else { return false };
        let b = index_block_at_time(&index, ms).unwrap_or(0);
        let k = index_keyframe_at_or_before(&index, b).unwrap_or(0);
        let Ok(mut r) = VmsReader::open(&info.path) else { return false };
        if !r.read_header() || !r.header().video_present {
            return false;
        }
        self.timescale = if r.header().video.timescale == 0 { 90_000 } else { r.header().video.timescale as i64 };
        r.seed_index(&index, index[index.len() - 1].offset);
        if !r.seek_to_block(k) {
            return false;
        }
        let Some(seq) = self.opener.open(r.header().video.codec, &r.header().video.extradata, self.max_w, self.max_h) else { return false };
        self.seq = Some(seq);
        self.reader = Some(r);
        self.arquivo = info.path.clone();
        self.esperando_chave = true;
        true
    }

    fn proximo_arquivo(&mut self) -> bool {
        let files = self.cache.list_files(&self.camera);
        let Some(i) = files.iter().position(|f| f.path == self.arquivo) else {
            self.motivo = "o arquivo aberto saiu da listagem".into();
            return false;
        };
        let Some(next) = files.get(i + 1).cloned() else {
            self.motivo = format!("nao ha arquivo depois de {}", self.arquivo.file_name().unwrap_or_default().to_string_lossy());
            return false;
        };
        if next.start_ms > self.to {
            self.motivo = "fim do trecho pedido".into();
            return false;
        }
        let ok = self.abrir(&next, next.start_ms);
        if !ok {
            self.motivo = format!("nao consegui abrir {}", next.name);
        }
        ok
    }

    fn proximo_bloco(&mut self) -> bool {
        let mut b = self.reader.as_mut().and_then(|r| r.read_next_block());
        if b.is_none() {
            if !self.proximo_arquivo() {
                return false;
            }
            b = self.reader.as_mut().and_then(|r| r.read_next_block());
        }
        let Some(b) = b else { return false };
        self.ancora = if b.video_anchor_ms != 0 { b.video_anchor_ms } else { b.start_unix_ms };
        self.primeiro_pts = b.samples.iter().find(|s| s.track_id == 0).map(|s| s.pts).unwrap_or(0);
        self.idx = 0;
        self.bloco = Some(b);
        true
    }

    /// Por que o percurso parou (fim do pedido, fim da gravação ou defeito).
    pub fn motivo_do_fim(&self) -> &str {
        &self.motivo
    }

    /// O próximo quadro no ritmo pedido; None = acabou.
    pub fn next_frame(&mut self) -> Option<(RgbImage, i64)> {
        if self.acabou {
            return None;
        }
        loop {
            let fim_do_bloco = self.bloco.as_ref().map(|b| self.idx >= b.samples.len()).unwrap_or(true);
            if fim_do_bloco {
                if !self.proximo_bloco() {
                    self.acabou = true;
                    if self.motivo.is_empty() {
                        self.motivo = "a gravacao acaba aqui".into();
                    }
                    return None;
                }
                continue;
            }
            let b = self.bloco.as_ref()?;
            let s = b.samples[self.idx];
            self.idx += 1;
            if s.track_id != 0 || s.payload_size == 0 {
                continue;
            }
            let parede = self.ancora + (s.pts - self.primeiro_pts) * 1000 / self.timescale;
            if parede > self.to {
                self.acabou = true;
                self.motivo = "fim do trecho pedido".into();
                return None;
            }
            if self.esperando_chave {
                if s.flags & IDX_FLAG_KEYFRAME == 0 {
                    continue;
                }
                self.esperando_chave = false;
            }
            let au = b.sample_data(&s).unwrap_or(&[]).to_vec();
            let saiu = self.seq.as_mut().and_then(|q| q.feed(&au));
            let Some(img) = saiu else {
                self.sem_saida += 1;
                if self.sem_saida > MAX_SEM_SAIDA {
                    self.acabou = true;
                    self.motivo = format!("{} samples sem nenhum quadro sair -- parei aqui", self.sem_saida);
                    return None;
                }
                continue;
            };
            self.sem_saida = 0;
            if parede < self.alvo {
                continue;
            }
            self.alvo = (self.alvo + self.step).max(parede + 1);
            return Some((img, parede));
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use vms_core::testutil::{write_vms, TempDir};
    use vms_core::vms::paths::ensure_camera_dir;

    /// "Decodifica" todo AU num quadro cinza do valor do último byte.
    pub struct SeqFalsa;
    impl FrameSequence for SeqFalsa {
        fn feed(&mut self, au: &[u8]) -> Option<RgbImage> {
            Some(RgbImage { width: 16, height: 9, pixels: vec![*au.last()?; 16 * 9 * 3] })
        }
    }
    pub struct AbreFalsa;
    impl SequenceOpener for AbreFalsa {
        fn open(&self, _: VideoCodec, _: &[u8], _: i32, _: i32) -> Option<Box<dyn FrameSequence>> {
            Some(Box::new(SeqFalsa))
        }
    }

    #[test]
    fn percorre_no_ritmo_e_atravessa_arquivos() {
        let d = TempDir::new("walk");
        let dir = ensure_camera_dir(d.path(), "cam").unwrap();
        write_vms(&dir.join("cam_1.vms"), 100_000, 10, 1000, true);
        write_vms(&dir.join("cam_2.vms"), 112_000, 10, 1000, true);
        let src = WalkSource { cache: Arc::new(IndexCache::new(d.path(), None, vms_core::log::null())), opener: Arc::new(AbreFalsa) };
        let mut w = src.walk("cam", 101_500, 115_000, 3000, 64, 64).unwrap();
        let mut ms = Vec::new();
        while let Some((_, t)) = w.next_frame() {
            ms.push(t);
        }
        // Começa no keyframe de antes (100 s), entrega a partir de 101.5 s a
        // cada 3 s, atravessa para o segundo arquivo (alvo 111 s → 112 s), e
        // o alvo seguinte conta a partir do alvo (114 s), não do quadro.
        assert_eq!(ms, vec![102_000, 105_000, 108_000, 112_000, 114_000]);
        assert_eq!(w.motivo_do_fim(), "fim do trecho pedido");
        assert!(src.walk("cam", 5, 1, 1, 1, 1).is_none());
    }
}
