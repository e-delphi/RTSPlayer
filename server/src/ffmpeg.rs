//! FFmpeg carregado em tempo de execução (avcodec/avutil/swscale ao lado do
//! executável). Sem as DLLs, `Ffmpeg::load` devolve None e quem depende de
//! decodificar (miniaturas, análise) desliga com um aviso — o resto do servidor
//! nem percebe.
//!
//! Só os campos públicos do começo de `AVFrame`/`AVPacket` são tocados; o resto
//! fica com os alocadores da própria biblioteca.

use std::ffi::c_void;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use libloading::Library;
use vms_core::media::VideoCodec;

pub const AV_CODEC_ID_MJPEG: i32 = 7;
pub const AV_CODEC_ID_H264: i32 = 27;
pub const AV_CODEC_ID_HEVC: i32 = 173;
pub const AV_PIX_FMT_RGB24: i32 = 2;
pub const SWS_BICUBIC: i32 = 4;
pub const AV_INPUT_BUFFER_PADDING_SIZE: usize = 64;
pub const AV_LOG_FATAL: i32 = 8;

#[repr(C)]
struct AvPacket {
    buf: *mut c_void,
    pts: i64,
    dts: i64,
    data: *mut u8,
    size: i32,
    // ... o resto é do alocador.
}

#[repr(C)]
struct AvFrame {
    data: [*mut u8; 8],
    linesize: [i32; 8],
    extended_data: *mut c_void,
    width: i32,
    height: i32,
    nb_samples: i32,
    format: i32,
}

type FindDecoder = unsafe extern "C" fn(i32) -> *const c_void;
type AllocCtx = unsafe extern "C" fn(*const c_void) -> *mut c_void;
type Open2 = unsafe extern "C" fn(*mut c_void, *const c_void, *mut c_void) -> i32;
type FreeCtx = unsafe extern "C" fn(*mut *mut c_void);
type SendPacket = unsafe extern "C" fn(*mut c_void, *const AvPacket) -> i32;
type ReceiveFrame = unsafe extern "C" fn(*mut c_void, *mut AvFrame) -> i32;
type PacketAlloc = unsafe extern "C" fn() -> *mut AvPacket;
type PacketFree = unsafe extern "C" fn(*mut *mut AvPacket);
type FrameAlloc = unsafe extern "C" fn() -> *mut AvFrame;
type FrameFree = unsafe extern "C" fn(*mut *mut AvFrame);
type Version = unsafe extern "C" fn() -> u32;
type LogSetLevel = unsafe extern "C" fn(i32);
type SwsGetContext = unsafe extern "C" fn(i32, i32, i32, i32, i32, i32, i32, *mut c_void, *mut c_void, *const f64) -> *mut c_void;
type SwsScale = unsafe extern "C" fn(*mut c_void, *const *const u8, *const i32, i32, i32, *const *mut u8, *const i32) -> i32;
type SwsFree = unsafe extern "C" fn(*mut c_void);

/// As funções que se usam, resolvidas uma vez.
pub struct Ffmpeg {
    _libs: Vec<Library>,
    find_decoder: FindDecoder,
    alloc_ctx: AllocCtx,
    open2: Open2,
    free_ctx: FreeCtx,
    send_packet: SendPacket,
    receive_frame: ReceiveFrame,
    packet_alloc: PacketAlloc,
    packet_free: PacketFree,
    frame_alloc: FrameAlloc,
    frame_free: FrameFree,
    sws_get_context: SwsGetContext,
    sws_scale: SwsScale,
    sws_free: SwsFree,
    pub version: u32,
}

// SAFETY: são ponteiros de função de uma biblioteca carregada e mantida viva
// em `_libs`; as funções do FFmpeg usadas aqui são reentrantes por contexto.
unsafe impl Send for Ffmpeg {}
unsafe impl Sync for Ffmpeg {}

const AVCODEC: &[&str] = &["avcodec-61.dll", "avcodec-62.dll", "avcodec-60.dll", "avcodec-59.dll"];
const AVUTIL: &[&str] = &["avutil-59.dll", "avutil-60.dll", "avutil-58.dll", "avutil-57.dll"];
const SWSCALE: &[&str] = &["swscale-8.dll", "swscale-9.dll", "swscale-7.dll", "swscale-6.dll"];

fn open_any(dirs: &[PathBuf], names: &[&str]) -> Option<Library> {
    for d in dirs {
        for n in names {
            let p = d.join(n);
            if p.is_file() {
                // SAFETY: carregar a DLL roda o DllMain dela; é o FFmpeg oficial.
                if let Ok(l) = unsafe { crate::analytics::onnx::load_beside(&p) } {
                    return Some(l);
                }
            }
        }
    }
    None
}

impl Ffmpeg {
    /// Procura as DLLs ao lado do executável (e na pasta dada, se houver).
    pub fn load(extra_dir: Option<&Path>) -> Option<Ffmpeg> {
        let mut dirs = Vec::new();
        if let Some(d) = extra_dir {
            dirs.push(d.to_path_buf());
        }
        dirs.push(crate::config::exe_dir());
        // avutil antes: os outros dois dependem dela.
        let util = open_any(&dirs, AVUTIL)?;
        let codec = open_any(&dirs, AVCODEC)?;
        let sws = open_any(&dirs, SWSCALE)?;
        // SAFETY: os nomes e assinaturas seguem a API pública do FFmpeg.
        unsafe {
            let f = Ffmpeg {
                find_decoder: *codec.get::<FindDecoder>(b"avcodec_find_decoder\0").ok()?,
                alloc_ctx: *codec.get::<AllocCtx>(b"avcodec_alloc_context3\0").ok()?,
                open2: *codec.get::<Open2>(b"avcodec_open2\0").ok()?,
                free_ctx: *codec.get::<FreeCtx>(b"avcodec_free_context\0").ok()?,
                send_packet: *codec.get::<SendPacket>(b"avcodec_send_packet\0").ok()?,
                receive_frame: *codec.get::<ReceiveFrame>(b"avcodec_receive_frame\0").ok()?,
                packet_alloc: *codec.get::<PacketAlloc>(b"av_packet_alloc\0").ok()?,
                packet_free: *codec.get::<PacketFree>(b"av_packet_free\0").ok()?,
                frame_alloc: *util.get::<FrameAlloc>(b"av_frame_alloc\0").ok()?,
                frame_free: *util.get::<FrameFree>(b"av_frame_free\0").ok()?,
                sws_get_context: *sws.get::<SwsGetContext>(b"sws_getContext\0").ok()?,
                sws_scale: *sws.get::<SwsScale>(b"sws_scale\0").ok()?,
                sws_free: *sws.get::<SwsFree>(b"sws_freeContext\0").ok()?,
                version: (codec.get::<Version>(b"avcodec_version\0").ok()?)(),
                _libs: Vec::new(),
            };
            if let Ok(l) = util.get::<LogSetLevel>(b"av_log_set_level\0") {
                l(AV_LOG_FATAL);
            }
            let mut f = f;
            f._libs = vec![util, codec, sws];
            Some(f)
        }
    }

    /// O mesmo FFmpeg para o processo inteiro: carregar de novo não ajuda.
    pub fn shared() -> Option<Arc<Ffmpeg>> {
        static F: OnceLock<Option<Arc<Ffmpeg>>> = OnceLock::new();
        F.get_or_init(|| Ffmpeg::load(None).map(Arc::new)).clone()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RgbImage {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl RgbImage {
    pub fn is_valid(&self) -> bool {
        self.width > 0 && self.height > 0 && self.pixels.len() >= self.width * self.height * 3
    }
}

fn codec_id(c: VideoCodec) -> i32 {
    match c {
        VideoCodec::H264 => AV_CODEC_ID_H264,
        VideoCodec::H265 => AV_CODEC_ID_HEVC,
        VideoCodec::Mjpeg => AV_CODEC_ID_MJPEG,
        VideoCodec::None => 0,
    }
}

/// O AU já traz VPS/SPS/PPS? (câmera que manda in-band)
pub fn has_parameter_sets(data: &[u8], codec: VideoCodec) -> bool {
    vms_core::h26x::nals(data).iter().any(|n| {
        let Some(&h) = n.first() else { return false };
        if codec == VideoCodec::H265 {
            matches!((h >> 1) & 0x3F, 32..=34)
        } else {
            matches!(h & 0x1F, 7 | 8)
        }
    })
}

/// O tamanho de saída: cabe em max_w×max_h, sem ampliar, lados pares.
pub fn fit(src_w: i32, src_h: i32, max_w: i32, max_h: i32) -> (i32, i32) {
    let e = (max_w as f64 / src_w as f64).min(max_h as f64 / src_h as f64).min(1.0);
    let mut w = ((src_w as f64 * e).round() as i32).max(2);
    let mut h = ((src_h as f64 * e).round() as i32).max(2);
    w += w & 1;
    h += h & 1;
    (w, h)
}

/// Um decodificador aberto, para uma sequência de quadros do mesmo fluxo.
pub struct Decoder {
    ff: Arc<Ffmpeg>,
    ctx: *mut c_void,
    frame: *mut AvFrame,
    pkt: *mut AvPacket,
    codec: VideoCodec,
    extra: Vec<u8>,
    seen_ps: bool,
    max_w: i32,
    max_h: i32,
}

// SAFETY: o contexto é usado por uma thread de cada vez (&mut self).
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn open(ff: Arc<Ffmpeg>, codec: VideoCodec, extra: &[u8], max_w: i32, max_h: i32) -> Option<Decoder> {
        let id = codec_id(codec);
        if id == 0 || max_w <= 0 || max_h <= 0 {
            return None;
        }
        // SAFETY: API pública; cada recurso alocado é liberado no Drop.
        unsafe {
            let c = (ff.find_decoder)(id);
            if c.is_null() {
                return None;
            }
            let ctx = (ff.alloc_ctx)(c);
            if ctx.is_null() {
                return None;
            }
            let mut d = Decoder { ff: ff.clone(), ctx, frame: (ff.frame_alloc)(), pkt: (ff.packet_alloc)(), codec, extra: extra.to_vec(), seen_ps: false, max_w, max_h };
            if d.frame.is_null() || d.pkt.is_null() || (ff.open2)(ctx, c, std::ptr::null_mut()) < 0 {
                return None; // o Drop libera o que houver
            }
            d.seen_ps = false;
            Some(d)
        }
    }

    fn convert(&mut self) -> Option<RgbImage> {
        // SAFETY: o quadro acabou de ser preenchido por receive_frame.
        unsafe {
            let f = &*self.frame;
            if f.width <= 0 || f.height <= 0 {
                return None;
            }
            let (w, h) = fit(f.width, f.height, self.max_w, self.max_h);
            let sws = (self.ff.sws_get_context)(f.width, f.height, f.format, w, h, AV_PIX_FMT_RGB24, SWS_BICUBIC, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null());
            if sws.is_null() {
                return None;
            }
            let mut img = RgbImage { width: w as usize, height: h as usize, pixels: vec![0u8; (w * h * 3) as usize] };
            let dst: [*mut u8; 4] = [img.pixels.as_mut_ptr(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()];
            let lines: [i32; 4] = [w * 3, 0, 0, 0];
            let src: [*const u8; 8] = f.data.map(|p| p as *const u8);
            let r = (self.ff.sws_scale)(sws, src.as_ptr(), f.linesize.as_ptr(), 0, f.height, dst.as_ptr(), lines.as_ptr());
            (self.ff.sws_free)(sws);
            (r > 0).then_some(img)
        }
    }

    fn send(&mut self, au: &[u8]) -> bool {
        if has_parameter_sets(au, self.codec) {
            self.seen_ps = true;
        }
        let mut buf = Vec::with_capacity(self.extra.len() + au.len() + AV_INPUT_BUFFER_PADDING_SIZE);
        if !self.extra.is_empty() && !self.seen_ps {
            buf.extend_from_slice(&self.extra);
        }
        buf.extend_from_slice(au);
        let len = buf.len();
        buf.resize(len + AV_INPUT_BUFFER_PADDING_SIZE, 0);
        // SAFETY: o pacote aponta para `buf` só durante a chamada.
        unsafe {
            (*self.pkt).data = buf.as_mut_ptr();
            (*self.pkt).size = len as i32;
            let r = (self.ff.send_packet)(self.ctx, self.pkt);
            (*self.pkt).data = std::ptr::null_mut();
            (*self.pkt).size = 0;
            r >= 0
        }
    }

    /// Um AU entra; sai a imagem quando o decodificador já tem quadro.
    pub fn feed(&mut self, au: &[u8]) -> Option<RgbImage> {
        if au.is_empty() || !self.send(au) {
            return None;
        }
        // SAFETY: contexto e quadro válidos.
        if unsafe { (self.ff.receive_frame)(self.ctx, self.frame) } < 0 {
            return None;
        }
        self.convert()
    }

    /// Um quadro só (miniatura): se não sair na hora, drena o decodificador.
    pub fn decode_one(mut self, au: &[u8]) -> Option<RgbImage> {
        if au.is_empty() || !self.send(au) {
            return None;
        }
        // SAFETY: contexto e quadro válidos; pacote nulo sinaliza fim.
        unsafe {
            if (self.ff.receive_frame)(self.ctx, self.frame) < 0 {
                (self.ff.send_packet)(self.ctx, std::ptr::null());
                if (self.ff.receive_frame)(self.ctx, self.frame) < 0 {
                    return None;
                }
            }
        }
        self.convert()
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: cada ponteiro veio do alocador correspondente.
        unsafe {
            if !self.pkt.is_null() {
                (self.ff.packet_free)(&mut self.pkt);
            }
            if !self.frame.is_null() {
                (self.ff.frame_free)(&mut self.frame);
            }
            if !self.ctx.is_null() {
                (self.ff.free_ctx)(&mut self.ctx);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tamanho_de_saida() {
        assert_eq!(fit(1920, 1080, 160, 120), (160, 90));
        assert_eq!(fit(100, 50, 160, 120), (100, 50), "nao amplia");
        assert_eq!(fit(641, 361, 1000, 1000), (642, 362), "lados pares");
    }

    #[test]
    fn parametros_in_band() {
        assert!(has_parameter_sets(&[0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x65, 2], VideoCodec::H264));
        assert!(!has_parameter_sets(&[0, 0, 0, 1, 0x65, 1], VideoCodec::H264));
        assert!(has_parameter_sets(&[0, 0, 1, 0x40, 1, 2], VideoCodec::H265));
    }
}
