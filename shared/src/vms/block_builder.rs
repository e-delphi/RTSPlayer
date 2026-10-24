//! Junta samples em blocos do `.vms`.
//!
//! O bloco fecha por quantidade, tamanho ou tempo — não por keyframe. Por isso
//! "este bloco tem keyframe" é algo a descobrir olhando os samples.
//!
//! ## A âncora de parede
//!
//! O leitor calcula o instante de cada sample como
//! `âncora do bloco + (pts - primeiro pts do bloco) / timescale`. Se a âncora
//! fosse o relógio de chegada, dentro do bloco mandaria o pts e na virada o
//! relógio de chegada; quando a câmera segura quadros e despeja de uma vez, os
//! blocos passavam a cobrir o mesmo intervalo (medido: até 2,1 s de
//! sobreposição). Então a âncora é derivada de uma referência única da
//! GRAVAÇÃO, e o relógio de chegada só serve para descobrir que o pts parou de
//! fazer sentido (desvio acima de 10 s): aí a referência é refeita, nunca para
//! trás do fim do bloco anterior.

use super::format::{Block, SampleEntry};
use crate::media::{Sample, TrackKind};

const MAX_DESVIO_ANCORA_MS: i64 = 10_000;

#[derive(Debug, Clone, Copy, Default)]
struct AncoraTrilha {
    valida: bool,
    wall_ms: i64,
    pts: i64,
    /// 0 = desconhecida; aí vale o relógio de chegada.
    timescale: u32,
    /// Parede do fim do último bloco emitido.
    fim_ms: i64,
}

#[derive(Debug, Clone, Copy, Default)]
struct PorTrilha {
    ancora: AncoraTrilha,
    primeiro_pts: i64,
    ultimo_pts: i64,
    /// Parede do primeiro sample desta trilha no bloco; 0 = não apareceu.
    primeiro_ms: i64,
}

#[derive(Debug, Clone, Copy)]
pub struct BlockLimits {
    pub max_samples: usize,
    pub max_duration_ms: i64,
    pub max_size_bytes: usize,
}

impl Default for BlockLimits {
    fn default() -> Self {
        Self { max_samples: 256, max_duration_ms: 2000, max_size_bytes: 1024 * 1024 }
    }
}

impl BlockLimits {
    /// Zeros viram o padrão, como no Delphi.
    pub fn sanitized(self) -> Self {
        let d = Self::default();
        Self {
            max_samples: if self.max_samples == 0 { d.max_samples } else { self.max_samples },
            max_duration_ms: if self.max_duration_ms <= 0 { d.max_duration_ms } else { self.max_duration_ms },
            max_size_bytes: if self.max_size_bytes == 0 { d.max_size_bytes } else { self.max_size_bytes },
        }
    }
}

pub struct BlockBuilder {
    limits: BlockLimits,
    seq: u32,
    start_unix_ms: i64,
    start_mono_ms: i64,
    video: PorTrilha,
    audio: PorTrilha,
    samples: Vec<SampleEntry>,
    payload: Vec<u8>,
}

impl BlockBuilder {
    pub fn new(limits: BlockLimits) -> Self {
        Self {
            limits: limits.sanitized(),
            seq: 0,
            start_unix_ms: 0,
            start_mono_ms: 0,
            video: PorTrilha::default(),
            audio: PorTrilha::default(),
            samples: Vec::with_capacity(128),
            payload: Vec::with_capacity(64 * 1024),
        }
    }

    /// As escalas das trilhas, do header. Sem elas a âncora é o relógio de
    /// chegada.
    pub fn set_timescales(&mut self, video: u32, audio: u32) {
        self.video.ancora.timescale = video;
        self.audio.ancora.timescale = audio;
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    pub fn current_seq(&self) -> u32 {
        self.seq
    }

    fn trilha(&mut self, k: TrackKind) -> &mut PorTrilha {
        match k {
            TrackKind::Video => &mut self.video,
            TrackKind::Audio => &mut self.audio,
        }
    }

    fn ancora_de(t: &mut AncoraTrilha, pts: i64, chegou_ms: i64) -> i64 {
        if t.timescale == 0 || !t.valida {
            t.valida = true;
            t.wall_ms = chegou_ms;
            t.pts = pts;
            return chegou_ms;
        }
        // Inteiro: pts de 90 kHz num dia inteiro vezes mil sai da faixa exata
        // do double.
        let derivada = t.wall_ms + ((pts - t.pts) * 1000) / t.timescale as i64;
        if (derivada - chegou_ms).abs() <= MAX_DESVIO_ANCORA_MS {
            return derivada;
        }
        let r = chegou_ms.max(t.fim_ms);
        t.wall_ms = r;
        t.pts = pts;
        r
    }

    fn fechar_ancora(t: &mut PorTrilha) {
        if t.primeiro_ms == 0 {
            return;
        }
        let ts = t.ancora.timescale;
        t.ancora.fim_ms = if ts == 0 {
            t.primeiro_ms
        } else {
            t.primeiro_ms + ((t.ultimo_pts - t.primeiro_pts) * 1000) / ts as i64
        };
    }

    fn start_new(&mut self, now_unix_ms: i64, now_mono_ms: i64) {
        self.samples.clear();
        self.payload.clear();
        self.start_unix_ms = now_unix_ms;
        self.start_mono_ms = now_mono_ms;
        for t in [&mut self.video, &mut self.audio] {
            t.primeiro_ms = 0;
            t.primeiro_pts = 0;
            t.ultimo_pts = 0;
        }
    }

    fn should_close(&self, now_mono_ms: i64) -> bool {
        !self.samples.is_empty()
            && (self.samples.len() >= self.limits.max_samples
                || self.payload.len() >= self.limits.max_size_bytes
                || now_mono_ms - self.start_mono_ms >= self.limits.max_duration_ms)
    }

    fn emit(&mut self) -> Option<Block> {
        if self.samples.is_empty() {
            return None;
        }
        // O start acompanha a âncora, e não a chegada: dele saem índice, régua e
        // busca; das âncoras saem os quadros.
        let start = if self.video.primeiro_ms > 0 {
            self.video.primeiro_ms
        } else if self.audio.primeiro_ms > 0 {
            self.audio.primeiro_ms
        } else {
            self.start_unix_ms
        };
        Self::fechar_ancora(&mut self.video);
        Self::fechar_ancora(&mut self.audio);
        let blk = Block {
            seq: self.seq,
            start_unix_ms: start,
            samples: std::mem::take(&mut self.samples),
            payload: std::mem::take(&mut self.payload),
            video_anchor_ms: self.video.primeiro_ms,
            audio_anchor_ms: self.audio.primeiro_ms,
        };
        self.seq = self.seq.wrapping_add(1);
        self.samples = Vec::with_capacity(128);
        self.payload = Vec::with_capacity(64 * 1024);
        Some(blk)
    }

    /// Acrescenta um sample. Devolve o bloco que fechou, se fechou.
    pub fn add(&mut self, s: &Sample, now_unix_ms: i64, now_mono_ms: i64) -> Option<Block> {
        if s.data.is_empty() {
            return None;
        }
        if self.samples.is_empty() {
            self.start_new(now_unix_ms, now_mono_ms);
        }
        let t = self.trilha(s.kind);
        if t.primeiro_ms == 0 {
            t.primeiro_pts = s.pts;
            t.ultimo_pts = s.pts;
            t.primeiro_ms = Self::ancora_de(&mut t.ancora, s.pts, now_unix_ms);
        } else if s.pts > t.ultimo_pts {
            // Maior, e não o último: com quadros B o pts não sobe em ordem.
            t.ultimo_pts = s.pts;
        }
        self.samples.push(SampleEntry {
            track_id: s.track_id,
            flags: s.flags,
            pts: s.pts,
            payload_offset: self.payload.len() as u32,
            payload_size: s.data.len() as u32,
        });
        self.payload.extend_from_slice(&s.data);
        if self.should_close(now_mono_ms) {
            self.emit()
        } else {
            None
        }
    }

    /// Fecha o bloco em curso, se houver.
    pub fn flush(&mut self) -> Option<Block> {
        self.emit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limites(n: usize) -> BlockLimits {
        BlockLimits { max_samples: n, max_duration_ms: 1_000_000, max_size_bytes: 1 << 30 }
    }

    #[test]
    fn fecha_por_quantidade_e_numera() {
        let mut b = BlockBuilder::new(limites(2));
        assert!(b.add(&Sample::video(0, true, vec![1]), 1000, 0).is_none());
        let blk = b.add(&Sample::video(3600, false, vec![2, 3]), 1040, 40).unwrap();
        assert_eq!(blk.seq, 0);
        assert_eq!(blk.samples.len(), 2);
        assert_eq!(blk.payload, vec![1, 2, 3]);
        assert_eq!(blk.samples[1].payload_offset, 1);
        assert!(blk.has_keyframe());
        assert_eq!(b.current_seq(), 1);
        assert!(b.is_empty());
    }

    #[test]
    fn ancora_vem_do_pts_e_nao_da_chegada() {
        let mut b = BlockBuilder::new(limites(1));
        b.set_timescales(90000, 8000);
        let a = b.add(&Sample::video(0, true, vec![1]), 10_000, 0).unwrap();
        assert_eq!(a.video_anchor_ms, 10_000);
        // Chega 500 ms "atrasado" pelo relógio, mas o pts diz 1 s depois.
        let c = b.add(&Sample::video(90000, false, vec![1]), 11_500, 1500).unwrap();
        assert_eq!(c.video_anchor_ms, 11_000);
        assert_eq!(c.start_unix_ms, 11_000);
    }

    #[test]
    fn pts_que_salta_reancora_sem_voltar() {
        let mut b = BlockBuilder::new(limites(1));
        b.set_timescales(90000, 0);
        b.add(&Sample::video(0, true, vec![1]), 10_000, 0);
        // Pts voltou a zero (câmera reconectou) com a parede 60 s à frente.
        let c = b.add(&Sample::video(0, true, vec![1]), 70_000, 60_000).unwrap();
        assert_eq!(c.video_anchor_ms, 70_000);
    }

    #[test]
    fn flush_fecha_o_que_sobrou() {
        let mut b = BlockBuilder::new(limites(100));
        b.add(&Sample::audio(0, vec![9; 10]), 5000, 0);
        let blk = b.flush().unwrap();
        assert_eq!(blk.audio_anchor_ms, 5000);
        assert_eq!(blk.video_anchor_ms, 0);
        assert_eq!(blk.start_unix_ms, 5000);
        assert!(b.flush().is_none());
    }
}
