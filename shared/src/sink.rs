//! Para onde vai a mídia de uma sessão de câmera: o ao vivo em memória, a
//! gravação, o servidor RTSP... Todos chamados na thread da sessão — quem
//! precisar da thread da interface que se vire para chegar lá.

use std::sync::{Arc, Mutex};

use crate::media::{AudioCodec, Sample, VideoCodec};

pub trait MediaSink: Send + Sync {
    fn on_video_format(&self, codec: VideoCodec, width: u16, height: u16, extradata: &[u8]);
    fn on_audio_format(&self, codec: AudioCodec, sample_rate: u32, channels: u8, extradata: &[u8]);
    fn on_sample(&self, s: &Sample);
    fn on_stream_stopped(&self);
}

pub type SharedSink = Arc<dyn MediaSink>;

/// Repassa para vários sinks (gravação + ao vivo, por exemplo).
pub struct FanoutSink(pub Vec<SharedSink>);

impl MediaSink for FanoutSink {
    fn on_video_format(&self, c: VideoCodec, w: u16, h: u16, e: &[u8]) {
        self.0.iter().for_each(|s| s.on_video_format(c, w, h, e));
    }
    fn on_audio_format(&self, c: AudioCodec, r: u32, ch: u8, e: &[u8]) {
        self.0.iter().for_each(|s| s.on_audio_format(c, r, ch, e));
    }
    fn on_sample(&self, x: &Sample) {
        self.0.iter().for_each(|s| s.on_sample(x));
    }
    fn on_stream_stopped(&self) {
        self.0.iter().for_each(|s| s.on_stream_stopped());
    }
}

/// Guarda tudo o que chegou: para teste.
#[derive(Default)]
pub struct RecordingSink {
    pub events: Mutex<Vec<String>>,
    pub samples: Mutex<Vec<Sample>>,
}

impl MediaSink for RecordingSink {
    fn on_video_format(&self, c: VideoCodec, w: u16, h: u16, e: &[u8]) {
        self.events.lock().unwrap().push(format!("video {c} {w}x{h} {}", e.len()));
    }
    fn on_audio_format(&self, c: AudioCodec, r: u32, ch: u8, _e: &[u8]) {
        self.events.lock().unwrap().push(format!("audio {c} {r} {ch}"));
    }
    fn on_sample(&self, s: &Sample) {
        self.samples.lock().unwrap().push(s.clone());
    }
    fn on_stream_stopped(&self) {
        self.events.lock().unwrap().push("stopped".into());
    }
}
