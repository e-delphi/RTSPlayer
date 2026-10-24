//! Detecção de objetos com YOLO (ONNX), pelo crate `ort` com o onnxruntime
//! carregado em tempo de execução (`analytics.onnxDll`, versão 1.17 ou mais
//! nova) — sem a DLL ou sem o `.onnx`, o detector fica indisponível e a
//! análise segue só com movimento.
//!
//! O pipeline é o do Ultralytics: letterbox (cinza 114, RGB NCHW em 0..1), e
//! três formatos de saída reconhecidos pelo shape:
//!   A) end-to-end `[1, N<=1024, 6]`: x1, y1, x2, y2, score, classe (sem NMS);
//!   B) YOLOv8/11 `[1, 4+nc, A]`: cx, cy, w, h, scores…  (com NMS);
//!   C) YOLOv5 `[1, A, 5+nc]`: cx, cy, w, h, objectness, scores… (com NMS).
//! As caixas saem normalizadas 0..1 sobre o quadro de entrada.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use vms_core::log::SharedLogger;

use super::{EventBox, ObjectDetector, ObjectHit};
use crate::ffmpeg::RgbImage;

const MAX_END_TO_END_ROWS: usize = 1024;
const IOU: f32 = 0.45;
const MAX_DETECTIONS: usize = 300;
/// O corte do decoder fica baixo: o limiar de verdade é o `min_score` de cada
/// chamada (é da configuração, não do modelo).
const DECODE_FLOOR: f32 = 0.01;

// ------------------------------------------------------------ pré e pós

/// `src = (net - pad) / scale`
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Transform {
    pub scale: f32,
    pub pad_x: f32,
    pub pad_y: f32,
    pub src_w: usize,
    pub src_h: usize,
}

impl Transform {
    fn x(&self, v: f32) -> f32 {
        (v - self.pad_x) / self.scale
    }
    fn y(&self, v: f32) -> f32 {
        (v - self.pad_y) / self.scale
    }
    fn len(&self, v: f32) -> f32 {
        v / self.scale
    }
}

/// Bilinear em RGB24 (o mesmo do `Vision.Image`).
pub fn resample_bilinear(src: &RgbImage, w: usize, h: usize) -> RgbImage {
    let mut out = RgbImage { width: w, height: h, pixels: vec![0; w * h * 3] };
    let (sx, sy) = (src.width as f32 / w as f32, src.height as f32 / h as f32);
    for y in 0..h {
        let fy = ((y as f32 + 0.5) * sy - 0.5).max(0.0);
        let y0 = (fy as usize).min(src.height - 1);
        let y1 = (y0 + 1).min(src.height - 1);
        let wy = fy - y0 as f32;
        for x in 0..w {
            let fx = ((x as f32 + 0.5) * sx - 0.5).max(0.0);
            let x0 = (fx as usize).min(src.width - 1);
            let x1 = (x0 + 1).min(src.width - 1);
            let wx = fx - x0 as f32;
            for c in 0..3 {
                let p = |xx: usize, yy: usize| src.pixels[(yy * src.width + xx) * 3 + c] as f32;
                let top = p(x0, y0) * (1.0 - wx) + p(x1, y0) * wx;
                let bot = p(x0, y1) * (1.0 - wx) + p(x1, y1) * wx;
                out.pixels[(y * w + x) * 3 + c] = (top * (1.0 - wy) + bot * wy).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

/// Letterbox centralizado → tensor `[1, 3, net_h, net_w]` em 0..1.
pub fn letterbox(img: &RgbImage, net_w: usize, net_h: usize) -> (Vec<f32>, Transform) {
    let scale = (net_w as f32 / img.width as f32).min(net_h as f32 / img.height as f32);
    let nw = ((img.width as f32 * scale).round() as usize).clamp(1, net_w);
    let nh = ((img.height as f32 * scale).round() as usize).clamp(1, net_h);
    let (ox, oy) = ((net_w - nw) / 2, (net_h - nh) / 2);
    let plane = net_w * net_h;
    let mut data = vec![114.0 / 255.0; plane * 3];
    let r = resample_bilinear(img, nw, nh);
    for y in 0..nh {
        for x in 0..nw {
            let i = (oy + y) * net_w + ox + x;
            let s = (y * nw + x) * 3;
            data[i] = r.pixels[s] as f32 / 255.0;
            data[plane + i] = r.pixels[s + 1] as f32 / 255.0;
            data[plane * 2 + i] = r.pixels[s + 2] as f32 / 255.0;
        }
    }
    (data, Transform { scale, pad_x: ox as f32, pad_y: oy as f32, src_w: img.width, src_h: img.height })
}

/// `{0: 'person', 1: 'bicycle'}` (o `names` que o Ultralytics grava) → lista.
pub fn parse_names_map(text: &str) -> Vec<String> {
    let b: Vec<char> = text.chars().collect();
    let mut pairs: Vec<(usize, String)> = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if !b[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        let k0 = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        let Ok(key) = b[k0..i].iter().collect::<String>().parse::<usize>() else { continue };
        if i < b.len() && (b[i] == '\'' || b[i] == '"') {
            i += 1;
        }
        while i < b.len() && b[i] == ' ' {
            i += 1;
        }
        if i >= b.len() || b[i] != ':' {
            continue;
        }
        i += 1;
        while i < b.len() && b[i] == ' ' {
            i += 1;
        }
        if i >= b.len() || (b[i] != '\'' && b[i] != '"') {
            continue;
        }
        let q = b[i];
        i += 1;
        let v0 = i;
        while i < b.len() && b[i] != q {
            i += 1;
        }
        pairs.push((key, b[v0..i.min(b.len())].iter().collect()));
        i += 1;
    }
    let n = pairs.iter().map(|(k, _)| k + 1).max().unwrap_or(0);
    let mut out = vec![String::new(); n];
    for (k, v) in pairs {
        out[k] = v;
    }
    out
}

#[derive(Debug, Clone, PartialEq)]
pub struct Detection {
    pub class_id: usize,
    pub score: f32,
    /// Em pixels da imagem de entrada.
    pub l: f32,
    pub t: f32,
    pub r: f32,
    pub b: f32,
}

fn iou(a: &Detection, b: &Detection) -> f32 {
    let iw = (a.r.min(b.r) - a.l.max(b.l)).max(0.0);
    let ih = (a.b.min(b.b) - a.t.max(b.t)).max(0.0);
    let inter = iw * ih;
    let ua = (a.r - a.l) * (a.b - a.t) + (b.r - b.l) * (b.b - b.t) - inter;
    if ua <= 0.0 {
        0.0
    } else {
        inter / ua
    }
}

/// NMS por classe, do maior score para o menor.
pub fn nms(mut d: Vec<Detection>, thr: f32, limit: usize) -> Vec<Detection> {
    d.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    let mut keep: Vec<Detection> = Vec::new();
    for c in d {
        if keep.iter().any(|k| k.class_id == c.class_id && iou(k, &c) > thr) {
            continue;
        }
        keep.push(c);
        if limit > 0 && keep.len() >= limit {
            break;
        }
    }
    keep
}

/// Uma saída: shape e dados (só float32).
#[derive(Debug, Clone)]
pub struct Tensor {
    pub shape: Vec<i64>,
    pub data: Vec<f32>,
}

/// Lê `[1, A, B]` sem saber se vem canais primeiro ou âncoras primeiro.
struct View<'a> {
    data: &'a [f32],
    anchors: usize,
    channels: usize,
    anchors_first: bool,
}

impl View<'_> {
    fn of(t: &Tensor) -> Option<View<'_>> {
        let (d1, d2) = match t.shape.as_slice() {
            [a, b] => (*a, *b),
            [1, a, b] => (*a, *b),
            _ => return None,
        };
        if d1 <= 0 || d2 <= 0 {
            return None;
        }
        let (d1, d2) = (d1 as usize, d2 as usize);
        let (anchors, channels, af) = if d1 >= d2 { (d1, d2, true) } else { (d2, d1, false) };
        (t.data.len() >= anchors * channels).then_some(View { data: &t.data, anchors, channels, anchors_first: af })
    }
    fn v(&self, a: usize, c: usize) -> f32 {
        if self.anchors_first {
            self.data[a * self.channels + c]
        } else {
            self.data[c * self.anchors + a]
        }
    }
}

/// As saídas do modelo → detecções (em pixels da imagem de entrada).
pub fn decode(outputs: &[Tensor], tr: &Transform, declared_classes: usize, floor: f32) -> Vec<Detection> {
    let Some(t) = outputs.iter().filter(|t| t.shape.len() == 2 || t.shape.len() == 3).max_by_key(|t| t.data.len()) else { return Vec::new() };
    let Some(v) = View::of(t) else { return Vec::new() };
    let clamp = |mut d: Detection| {
        d.l = d.l.clamp(0.0, tr.src_w as f32);
        d.r = d.r.clamp(0.0, tr.src_w as f32);
        d.t = d.t.clamp(0.0, tr.src_h as f32);
        d.b = d.b.clamp(0.0, tr.src_h as f32);
        (d.r > d.l && d.b > d.t).then_some(d)
    };
    // A) end-to-end: já filtrado e em ordem de score.
    if v.anchors_first && v.channels == 6 && v.anchors <= MAX_END_TO_END_ROWS {
        let mut out = Vec::new();
        for a in 0..v.anchors {
            let s = v.v(a, 4);
            if s < floor {
                break;
            }
            let d = Detection { class_id: v.v(a, 5).round().max(0.0) as usize, score: s, l: tr.x(v.v(a, 0)), t: tr.y(v.v(a, 1)), r: tr.x(v.v(a, 2)), b: tr.y(v.v(a, 3)) };
            out.extend(clamp(d));
            if out.len() >= MAX_DETECTIONS {
                break;
            }
        }
        return out;
    }
    // B/C) crua: melhor classe por âncora, depois NMS.
    let avail = v.channels.saturating_sub(4);
    if avail == 0 {
        return Vec::new();
    }
    let (first, n, obj) = if declared_classes > 0 && avail == declared_classes + 1 { (5, declared_classes, true) } else { (4, avail, false) };
    let mut list = Vec::new();
    for a in 0..v.anchors {
        let o = if obj { v.v(a, 4) } else { 1.0 };
        if o < floor {
            continue;
        }
        let (mut best, mut cid) = (f32::MIN, 0);
        for c in 0..n {
            let s = v.v(a, first + c);
            if s > best {
                best = s;
                cid = c;
            }
        }
        let s = best * o;
        if s < floor {
            continue;
        }
        let (cx, cy, w, h) = (tr.x(v.v(a, 0)), tr.y(v.v(a, 1)), tr.len(v.v(a, 2)), tr.len(v.v(a, 3)));
        list.extend(clamp(Detection { class_id: cid, score: s, l: cx - w / 2.0, t: cy - h / 2.0, r: cx + w / 2.0, b: cy + h / 2.0 }));
    }
    nms(list, IOU, MAX_DETECTIONS)
}

pub fn class_name(names: &[String], id: usize) -> String {
    names.get(id).filter(|n| !n.is_empty()).cloned().unwrap_or_else(|| format!("classe_{id}"))
}

// ------------------------------------------------------------ onnxruntime (`ort`)

/// Carrega a DLL da pasta DELA (o runtime do VC++ mora ao lado), para que o
/// `ort` a ache já carregada.
///
/// # Safety
/// Roda o código de inicialização da DLL.
pub unsafe fn load_beside(p: &Path) -> Result<libloading::Library, libloading::Error> {
    #[cfg(windows)]
    {
        const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;
        libloading::os::windows::Library::load_with_flags(p, LOAD_WITH_ALTERED_SEARCH_PATH).map(libloading::Library::from)
    }
    #[cfg(not(windows))]
    {
        libloading::Library::new(p)
    }
}

/// O `ort` aceita UM ambiente por processo: criado na primeira vez, reusado
/// (ou o mesmo erro) depois.
fn environment(dll: &Path) -> Result<ort::environment::Environment, String> {
    static ENV: OnceLock<Result<ort::environment::Environment, String>> = OnceLock::new();
    ENV.get_or_init(|| {
        if !dll.is_file() {
            return Err(format!("{} nao existe", dll.display()));
        }
        // SAFETY: é o onnxruntime oficial; a biblioteca fica carregada até o
        // fim do processo (o `ort` guarda a dele, que é a mesma).
        let lib = unsafe { load_beside(dll) }.map_err(|e| format!("{}: {e}", dll.display()))?;
        std::mem::forget(lib);
        ort::init_from(dll).map_err(|e| e.to_string())?.with_name("vmsserver").build().map_err(|e| e.to_string())
    })
    .clone()
}

struct Session {
    s: ort::session::Session,
    input: String,
    net_w: usize,
    net_h: usize,
    names: Vec<String>,
}

impl Session {
    fn open(dll: &Path, model: &Path, threads: usize) -> Result<Session, String> {
        let env = environment(dll)?;
        let s = ort::session::Session::builder(&env)
            .map_err(|e| e.to_string())?
            .with_intra_threads(threads.max(1))
            .map_err(|e| e.to_string())?
            .commit_from_file(model)
            .map_err(|e| e.to_string())?;
        if s.inputs().len() != 1 {
            return Err(format!("o modelo tem {} entradas; esperava 1 (imagem)", s.inputs().len()));
        }
        let input = s.inputs()[0].name().to_owned();
        let shape: Vec<i64> = s.inputs()[0].dtype().tensor_shape().map(|d| d.to_vec()).unwrap_or_default();
        let md = s.metadata().ok();
        let meta = |k: &str| md.as_ref().and_then(|m| m.custom(k)).unwrap_or_default();
        let (mut net_w, mut net_h) = (640, 640);
        if shape.len() == 4 && shape[2] > 0 && shape[3] > 0 {
            (net_h, net_w) = (shape[2] as usize, shape[3] as usize);
        } else {
            // Entrada dinâmica: o imgsz do Ultralytics, senão 640.
            let sz: Vec<usize> = meta("imgsz").split(|c: char| !c.is_ascii_digit()).filter_map(|x| x.parse().ok()).collect();
            match sz.as_slice() {
                [h, w, ..] => (net_h, net_w) = (*h, *w),
                [x] => (net_h, net_w) = (*x, *x),
                _ => {}
            }
        }
        let names = parse_names_map(&meta("names"));
        drop(md);
        Ok(Session { s, input, net_w, net_h, names })
    }

    fn run(&mut self, data: Vec<f32>) -> Result<Vec<Tensor>, String> {
        let t = ort::value::Tensor::from_array((vec![1i64, 3, self.net_h as i64, self.net_w as i64], data)).map_err(|e| e.to_string())?;
        let outs = self.s.run(ort::inputs![self.input.as_str() => t]).map_err(|e| e.to_string())?;
        Ok(outs
            .values()
            .filter_map(|v| v.try_extract_tensor::<f32>().ok().map(|(sh, d)| Tensor { shape: sh.to_vec(), data: d.to_vec() }))
            .collect())
    }
}

// ------------------------------------------------------------ o detector

pub struct OnnxObjectDetector {
    session: Option<Mutex<Session>>,
    description: String,
    log: SharedLogger,
}

impl OnnxObjectDetector {
    /// Nunca falha: sem DLL ou sem modelo, fica indisponível e diz por quê.
    pub fn new(model: &Path, dll: &str, threads: i32, log: SharedLogger) -> Self {
        let dll_path = {
            let p = Path::new(dll);
            if p.is_absolute() {
                p.to_path_buf()
            } else {
                crate::config::exe_dir().join(p)
            }
        };
        let r = (|| -> Result<Session, String> {
            if !model.is_file() {
                return Err(format!("modelo nao encontrado: {}", model.display()));
            }
            Session::open(&dll_path, model, threads.max(1) as usize)
        })();
        match r {
            Ok(s) => {
                let d = format!("{} (deteccao, {}x{}, {} classes)", model.file_name().unwrap_or_default().to_string_lossy(), s.net_w, s.net_h, s.names.len());
                log.info("analytics", &format!("modelo: {d}"));
                Self { session: Some(Mutex::new(s)), description: d, log }
            }
            Err(e) => {
                log.warn("analytics", &format!("modelo nao carregou ({}): {e}. A analise segue so com movimento.", model.display()));
                Self { session: None, description: format!("falhou: {e}"), log }
            }
        }
    }
}

impl ObjectDetector for OnnxObjectDetector {
    fn available(&self) -> bool {
        self.session.is_some()
    }

    fn describe(&self) -> String {
        self.description.clone()
    }

    fn detect(&self, img: &RgbImage, min_score: f32) -> Option<Vec<ObjectHit>> {
        let s = self.session.as_ref()?;
        if !img.is_valid() || img.width < 16 || img.height < 16 {
            return None;
        }
        let mut s = s.lock().unwrap_or_else(|p| p.into_inner());
        let (data, tr) = letterbox(img, s.net_w, s.net_h);
        let outs = match s.run(data) {
            Ok(o) => o,
            Err(e) => {
                // Uma inferência que falha não para a análise.
                self.log.warn("analytics", &format!("inferencia falhou: {e}"));
                return None;
            }
        };
        let (w, h) = (img.width as f32, img.height as f32);
        Some(
            decode(&outs, &tr, s.names.len(), DECODE_FLOOR)
                .into_iter()
                .filter(|d| d.score >= min_score)
                .map(|d| ObjectHit { name: class_name(&s.names, d.class_id).to_lowercase(), score: d.score, bbox: EventBox::new(d.l / w, d.t / h, d.r / w, d.b / h).clamped() })
                .collect(),
        )
    }
}

/// Metade dos núcleos (a outra metade é da gravação), no mínimo 1.
pub fn threads_for_inference() -> i32 {
    (std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2) / 2).max(1) as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nomes_do_ultralytics() {
        assert_eq!(parse_names_map("{0: 'person', 1: 'bicycle', 3: \"car\"}"), vec!["person", "bicycle", "", "car"]);
        assert_eq!(parse_names_map(r#"{"0": "a", "1": "b"}"#), vec!["a", "b"]);
        assert!(parse_names_map("").is_empty());
        assert_eq!(class_name(&["x".into()], 3), "classe_3");
    }

    #[test]
    fn letterbox_centraliza_e_volta() {
        let img = RgbImage { width: 200, height: 100, pixels: vec![255; 200 * 100 * 3] };
        let (d, tr) = letterbox(&img, 64, 64);
        assert_eq!(d.len(), 3 * 64 * 64);
        assert_eq!((tr.scale, tr.pad_x, tr.pad_y), (0.32, 0.0, 16.0));
        assert!((d[0] - 114.0 / 255.0).abs() < 1e-6, "faixa de cima e cinza");
        assert!((d[32 * 64 + 32] - 1.0).abs() < 1e-6, "o meio e a imagem");
        assert!((tr.x(32.0) - 100.0).abs() < 1e-3 && (tr.y(32.0) - 50.0).abs() < 1e-3);
    }

    #[test]
    fn decodifica_os_tres_formatos() {
        let tr = Transform { scale: 1.0, pad_x: 0.0, pad_y: 0.0, src_w: 100, src_h: 100 };
        // A) end-to-end
        // (300 linhas no YOLO26; aqui 8, a 2ª já abaixo do piso encerra)
        let mut data = vec![10., 10., 30., 30., 0.9, 2., 0., 0., 1., 1., 0.005, 0.];
        data.extend(std::iter::repeat([0f32; 6]).take(6).flatten());
        let a = Tensor { shape: vec![1, 8, 6], data };
        let d = decode(&[a], &tr, 3, 0.01);
        assert_eq!(d.len(), 1);
        assert_eq!((d[0].class_id, d[0].l, d[0].r), (2, 10.0, 30.0));
        // B) [1, 4+nc, A] com nc=2 e 8 âncoras (8400 no YOLOv8): as duas
        // primeiras se sobrepõem (NMS fica com uma); as vazias somem.
        let anc = [(20., 20., 0.8, 0.1), (21., 20., 0.7, 0.1), (80., 80., 0.1, 0.6)];
        let mut data = vec![0f32; 6 * 8];
        for (i, (cx, cy, s0, s1)) in anc.iter().enumerate() {
            for (c, v) in [*cx, *cy, 10., 10., *s0, *s1].into_iter().enumerate() {
                data[c * 8 + i] = v;
            }
        }
        let b = Tensor { shape: vec![1, 6, 8], data };
        let d = decode(&[b], &tr, 2, 0.01);
        assert_eq!(d.len(), 2);
        assert_eq!((d[0].class_id, d[0].score), (0, 0.8));
        assert_eq!(d[1].class_id, 1);
        // C) [1, A, 5+nc] com objectness
        // (mais linhas que colunas, como os 25200 do YOLOv5; só a 1ª tem objeto)
        let mut data = vec![50., 50., 20., 20., 0.5, 0.2, 0.8];
        data.extend(std::iter::repeat([0f32; 7]).take(9).flatten());
        let c = Tensor { shape: vec![1, 10, 7], data };
        let d = decode(&[c], &tr, 2, 0.01);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].class_id, 1);
        assert!((d[0].score - 0.4).abs() < 1e-6);
    }

    /// Com o onnxruntime, o modelo e o FFmpeg de verdade (fora da suíte padrão):
    ///   set VMS_TEST_BIN=...\delphimsin   (onnxruntime.dll, yolo26s.onnx, FFmpeg)
    ///   set VMS_TEST_IMG=...us.jpg
    ///   cargo test -p vmsserver -- --ignored modelo_de_verdade
    #[test]
    #[ignore]
    fn modelo_de_verdade() {
        let bin = std::path::PathBuf::from(std::env::var("VMS_TEST_BIN").expect("VMS_TEST_BIN"));
        let jpg = std::fs::read(std::env::var("VMS_TEST_IMG").expect("VMS_TEST_IMG")).unwrap();
        let ff = std::sync::Arc::new(crate::ffmpeg::Ffmpeg::load(Some(&bin)).expect("FFmpeg"));
        let img = crate::ffmpeg::Decoder::open(ff, vms_core::media::VideoCodec::Mjpeg, &[], 1280, 1280).unwrap().decode_one(&jpg).expect("jpeg");
        let model = std::fs::read_dir(&bin).unwrap().flatten().map(|e| e.path()).find(|p| p.extension().is_some_and(|x| x == "onnx")).expect(".onnx");
        let dll = bin.join("onnxruntime.dll");
        let d = OnnxObjectDetector::new(&model, &dll.to_string_lossy(), 2, std::sync::Arc::new(vms_core::log::ConsoleLogger));
        assert!(d.available(), "{}", d.describe());
        let hits = d.detect(&img, 0.35).unwrap();
        for h in &hits {
            eprintln!("{} {:.2} {:?}", h.name, h.score, h.bbox);
        }
        assert!(hits.iter().any(|h| h.name == "person"), "{hits:?}");
        assert!(hits.iter().all(|h| h.bbox.l >= 0.0 && h.bbox.r <= 1.0 && h.bbox.r > h.bbox.l));
    }

    #[test]
    fn sem_dll_ou_modelo_fica_indisponivel() {
        let d = OnnxObjectDetector::new(Path::new("nao-existe.onnx"), "onnxruntime.dll", 1, vms_core::log::null());
        assert!(!d.available());
        assert!(d.describe().contains("nao encontrado"));
        let img = RgbImage { width: 32, height: 32, pixels: vec![0; 32 * 32 * 3] };
        assert!(d.detect(&img, 0.3).is_none());
    }
}
