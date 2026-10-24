//! Host Win32 + WebView2, sem framework: janela criada à mão, `WebView2Loader`
//! pelo `webview2-com`, loop `GetMessage` puro (o mesmo modelo do NoOBS).
//!
//! * a interface e a API saem do MESMO origin `https://rtsplayer.app`: o
//!   `WebResourceRequested` serve os arquivos embutidos e manda `/api/*` para
//!   o roteador do app (`app::App`) numa thread de trabalho, com deferral — a
//!   resposta volta pela fila da main thread (os objetos do WebView2 são STA);
//! * microfone liberado (a fala usa `getUserMedia`), o resto negado;
//! * só o próprio origin navega; link externo abre no navegador do sistema.

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::Arc;

use webview2_com::Microsoft::Web::WebView2::Win32::*;
use webview2_com::{
    take_pwstr, CoreWebView2EnvironmentOptions, CreateCoreWebView2ControllerCompletedHandler, CreateCoreWebView2EnvironmentCompletedHandler, NavigationStartingEventHandler,
    NewWindowRequestedEventHandler, PermissionRequestedEventHandler, WebResourceRequestedEventHandler,
};
use windows::core::{w, Interface, BOOL, HSTRING, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, COLORREF, E_FAIL, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, DrawTextW, EndPaint, FillRect, SelectObject, SetBkMode, SetTextColor, UpdateWindow, CLEARTYPE_QUALITY,
    CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DT_CENTER, DT_SINGLELINE, DT_VCENTER, FF_DONTCARE, FW_BOLD, HBRUSH, HGDIOBJ, OUT_DEFAULT_PRECIS, PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, IStream, COINIT_APARTMENTTHREADED};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::Shell::{SHCreateMemStream, ShellExecuteW};
use windows::Win32::UI::WindowsAndMessaging::*;

use vms_core::http::{Handler, Request, Response};

use crate::mainthread;

pub const UI_HOST: &str = "rtsplayer.app";
pub const CLASS_NAME: &str = "TRTSPlayerRust";
const MUTEX_NAME: &str = "RTSPlayer.SingleInstance";
const SHOW_MSG_NAME: &str = "RTSPlayer.ShowInstance";
const TITLE: &str = "RTSPlayer";
const SPLASH_BG: u32 = 0x000C0A0A; // #0a0a0c (BGR)
const SPLASH_TEXT: u32 = 0x00E7E4E4;
/// O corpo de um pedido da página (o envio da fala é o maior: ~10 KB).
const MAX_BODY: usize = 16 * 1024 * 1024;

static MAIN_HWND: AtomicIsize = AtomicIsize::new(0);
static TOPMOST: AtomicBool = AtomicBool::new(false);

struct WebState {
    controller: ICoreWebView2Controller,
}

thread_local! {
    static WEB: RefCell<Option<WebState>> = const { RefCell::new(None) };
    static WEB_READY: Cell<bool> = const { Cell::new(false) };
    static HANDLER: RefCell<Option<Arc<dyn Handler>>> = const { RefCell::new(None) };
    static SHOW_MSG: Cell<u32> = const { Cell::new(0) };
}

pub fn main_window() -> HWND {
    HWND(MAIN_HWND.load(Ordering::SeqCst) as *mut _)
}

/// Fecha a janela (o `/api/app/sair`).
pub fn request_close() {
    let h = main_window();
    if !h.0.is_null() {
        // SAFETY: só posta a mensagem.
        unsafe {
            let _ = PostMessageW(Some(h), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }
}

/// Sempre à frente: "1" liga, "0" desliga, "" só pergunta.
pub fn set_topmost(pedido: &str) -> Option<bool> {
    let h = main_window();
    if h.0.is_null() {
        return None;
    }
    if !pedido.is_empty() {
        let on = pedido == "1" || pedido.eq_ignore_ascii_case("true");
        // SAFETY: SetWindowPos pode ser chamado de qualquer thread.
        unsafe {
            let _ = SetWindowPos(h, Some(if on { HWND_TOPMOST } else { HWND_NOTOPMOST }), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        TOPMOST.store(on, Ordering::SeqCst);
    }
    Some(TOPMOST.load(Ordering::SeqCst))
}

fn set_dark_mode(hwnd: HWND) {
    let v = BOOL::from(true);
    // SAFETY: ponteiro para um BOOL vivo durante a chamada.
    unsafe {
        let _ = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &v as *const BOOL as *const _, std::mem::size_of::<BOOL>() as u32);
    }
}

fn shell_open(url: &str) {
    // SAFETY: strings vivas durante a chamada.
    unsafe {
        let _ = ShellExecuteW(None, w!("open"), &HSTRING::from(url), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

/// O caminho da página sob o origin (`https://rtsplayer.app/api/x?y` →
/// `/api/x?y`). None = não é nosso.
pub fn local_uri(uri: &str) -> Option<String> {
    let base = format!("https://{UI_HOST}");
    let rest = uri.strip_prefix(&base)?;
    if !(rest.is_empty() || rest.starts_with('/') || rest.starts_with('?')) {
        return None;
    }
    let rest = rest.split('#').next().unwrap_or("");
    Some(if rest.is_empty() || rest.starts_with('?') { format!("/{rest}") } else { rest.to_owned() })
}

/// O cabeçalho do `CreateWebResourceResponse`.
pub fn response_headers(r: &Response) -> String {
    let mut h = format!("Content-Type: {}", if r.content_type.is_empty() { "application/octet-stream" } else { &r.content_type });
    for (k, v) in &r.headers {
        h.push_str(&format!("\r\n{k}: {v}"));
    }
    h
}

/// Os objetos COM só são tocados na main thread; o `Send` é para atravessar a
/// fila até lá.
struct OnMain<T>(T);
// SAFETY: o valor só é usado dentro de `mainthread::queue`, na main thread.
unsafe impl<T> Send for OnMain<T> {}

fn read_stream(s: &IStream) -> Vec<u8> {
    let mut out = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let mut got = 0u32;
        // SAFETY: buffer vivo e do tamanho informado.
        let hr = unsafe { s.Read(buf.as_mut_ptr() as *mut _, buf.len() as u32, Some(&mut got)) };
        if hr.is_err() || got == 0 || out.len() > MAX_BODY {
            break;
        }
        out.extend_from_slice(&buf[..got as usize]);
    }
    out
}

fn on_resource(env: &ICoreWebView2Environment, args: &ICoreWebView2WebResourceRequestedEventArgs) -> windows::core::Result<()> {
    // SAFETY: chamadas COM na main thread, dentro do evento.
    unsafe {
        let req = args.Request()?;
        let mut p = PWSTR::null();
        req.Uri(&mut p)?;
        let Some(path) = local_uri(&take_pwstr(p)) else { return Ok(()) };
        let mut m = PWSTR::null();
        req.Method(&mut m)?;
        let method = take_pwstr(m).to_ascii_uppercase();
        let body = req.Content().ok().map(|s| read_stream(&s)).unwrap_or_default();
        let mut r = Request::new(&method, &path).with_body(body);
        if let Ok(h) = req.Headers() {
            for name in ["Content-Type", "Range"] {
                let mut v = PWSTR::null();
                if h.GetHeader(&HSTRING::from(name), &mut v).is_ok() {
                    let v = take_pwstr(v);
                    if !v.is_empty() {
                        r.headers.add(name, &v);
                    }
                }
            }
        }
        let Some(handler) = HANDLER.with(|h| h.borrow().clone()) else { return Ok(()) };
        // Arquivo da interface: na hora. API: numa thread, que pode esperar
        // a câmera ou o servidor sem travar a janela.
        let api = path.to_ascii_lowercase().starts_with("/api/");
        if !api {
            return set_response(env, args, &handler.handle(&r));
        }
        let deferral = args.GetDeferral()?;
        let pend = OnMain((env.clone(), args.clone(), deferral));
        std::thread::Builder::new()
            .name("api".into())
            .spawn(move || {
                let resp = handler.handle(&r);
                mainthread::queue(move || {
                    // Usa o embrulho inteiro: captura por campo levaria o COM
                    // cru (não-Send) para dentro do closure.
                    let p = pend;
                    let OnMain((env, args, deferral)) = p;
                    let _ = set_response(&env, &args, &resp);
                    let _ = deferral.Complete();
                });
            })
            .map_err(|_| windows::core::Error::from(E_FAIL))?;
        Ok(())
    }
}

fn set_response(env: &ICoreWebView2Environment, args: &ICoreWebView2WebResourceRequestedEventArgs, r: &Response) -> windows::core::Result<()> {
    // SAFETY: SHCreateMemStream copia os bytes; nada aponta para os nossos depois.
    unsafe {
        let stream = SHCreateMemStream(Some(&r.body));
        let reason = vms_core::rtsp::message::status_text(r.status);
        let resp = env.CreateWebResourceResponse(stream.as_ref(), r.status as i32, &HSTRING::from(reason), &HSTRING::from(response_headers(r)))?;
        args.SetResponse(&resp)
    }
}

fn resize_webview(hwnd: HWND) {
    WEB.with(|w| {
        if let Some(ws) = w.borrow().as_ref() {
            let mut rc = RECT::default();
            // SAFETY: janela e controller vivos na main thread.
            unsafe {
                let _ = GetClientRect(hwnd, &mut rc);
                let _ = ws.controller.SetBounds(rc);
            }
        }
    });
}

fn on_controller_ready(hwnd: HWND, controller: ICoreWebView2Controller, env: &ICoreWebView2Environment) -> windows::core::Result<()> {
    // SAFETY: tudo na main thread, com objetos recém-criados pelo WebView2.
    unsafe {
        let webview = controller.CoreWebView2()?;
        let _ = controller.SetZoomFactor(1.0);
        if let Ok(s) = webview.Settings() {
            let _ = s.SetAreDevToolsEnabled(cfg!(debug_assertions));
            let _ = s.SetAreDefaultContextMenusEnabled(false);
            let _ = s.SetIsStatusBarEnabled(false);
            if let Ok(s3) = s.cast::<ICoreWebView2Settings3>() {
                let _ = s3.SetAreBrowserAcceleratorKeysEnabled(false);
            }
        }
        let mut token = Default::default();

        // Microfone (a fala) e notificação; o resto, não.
        let h = PermissionRequestedEventHandler::create(Box::new(|_, args| {
            if let Some(args) = args {
                let mut kind = COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
                let _ = args.PermissionKind(&mut kind);
                let ok = kind == COREWEBVIEW2_PERMISSION_KIND_MICROPHONE || kind == COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS;
                let _ = args.SetState(if ok { COREWEBVIEW2_PERMISSION_STATE_ALLOW } else { COREWEBVIEW2_PERMISSION_STATE_DENY });
            }
            Ok(())
        }));
        webview.add_PermissionRequested(&h, &mut token)?;

        // Só o próprio origin navega.
        let h = NavigationStartingEventHandler::create(Box::new(|_, args| {
            if let Some(args) = args {
                let mut p = PWSTR::null();
                if args.Uri(&mut p).is_ok() {
                    let uri = take_pwstr(p);
                    if local_uri(&uri).is_none() && !uri.starts_with("about:") {
                        let _ = args.SetCancel(true);
                        if uri.starts_with("http://") || uri.starts_with("https://") {
                            shell_open(&uri);
                        }
                    }
                }
            }
            Ok(())
        }));
        webview.add_NavigationStarting(&h, &mut token)?;

        let h = NewWindowRequestedEventHandler::create(Box::new(|_, args| {
            if let Some(args) = args {
                let _ = args.SetHandled(true);
                let mut p = PWSTR::null();
                if args.Uri(&mut p).is_ok() {
                    let uri = take_pwstr(p);
                    if uri.starts_with("http://") || uri.starts_with("https://") {
                        shell_open(&uri);
                    }
                }
            }
            Ok(())
        }));
        webview.add_NewWindowRequested(&h, &mut token)?;

        let env2 = env.clone();
        let h = WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
            if let Some(args) = args {
                let _ = on_resource(&env2, &args);
            }
            Ok(())
        }));
        webview.AddWebResourceRequestedFilter(&HSTRING::from(format!("https://{UI_HOST}/*")), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)?;
        webview.add_WebResourceRequested(&h, &mut token)?;

        WEB.with(|w| *w.borrow_mut() = Some(WebState { controller }));
        WEB_READY.with(|r| r.set(true));
        resize_webview(hwnd);
        webview.Navigate(&HSTRING::from(format!("https://{UI_HOST}/")))?;
    }
    Ok(())
}

fn user_data_dir() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")?;
    let d = std::path::PathBuf::from(base).join("RTSPlayer").join("WebView2");
    std::fs::create_dir_all(&d).ok()?;
    Some(d)
}

fn create_webview(hwnd: HWND) {
    let opcoes = CoreWebView2EnvironmentOptions::default();
    // Argumentos extras do navegador para diagnóstico, por exemplo
    // `RTSPLAYER_WEBVIEW_ARGS=--remote-debugging-port=9333`.
    if let Ok(args) = std::env::var("RTSPLAYER_WEBVIEW_ARGS") {
        // SAFETY: as opções ainda não foram entregues ao WebView2.
        unsafe { opcoes.set_additional_browser_arguments(args) };
    }
    let options: ICoreWebView2EnvironmentOptions = opcoes.into();
    let handler = CreateCoreWebView2EnvironmentCompletedHandler::create(Box::new(move |err, env| {
        err?;
        let env = env.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
        let env_ui = env.clone();
        let ch = CreateCoreWebView2ControllerCompletedHandler::create(Box::new(move |err, controller| {
            err?;
            let controller = controller.ok_or_else(|| windows::core::Error::from(E_FAIL))?;
            on_controller_ready(hwnd, controller, &env_ui)
        }));
        // SAFETY: janela viva; handler mantido pelo WebView2.
        unsafe { env.CreateCoreWebView2Controller(hwnd, &ch) }
    }));
    let udf = user_data_dir().map(|p| HSTRING::from(p.to_string_lossy().as_ref())).unwrap_or_default();
    // SAFETY: strings vivas durante a chamada.
    if let Err(e) = unsafe { CreateCoreWebView2EnvironmentWithOptions(PCWSTR::null(), PCWSTR(udf.as_ptr()), &options, &handler) } {
        // SAFETY: caixa de mensagem simples.
        unsafe {
            MessageBoxW(Some(hwnd), &HSTRING::from(format!("O WebView2 nao abriu ({e}). Instale o Microsoft Edge WebView2 Runtime.")), &HSTRING::from(TITLE), MB_ICONERROR);
        }
    }
}

fn draw_splash(hwnd: HWND) {
    // SAFETY: pintura padrão do WM_PAINT.
    unsafe {
        let mut ps = PAINTSTRUCT::default();
        let dc = BeginPaint(hwnd, &mut ps);
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        let brush = CreateSolidBrush(COLORREF(SPLASH_BG));
        FillRect(dc, &rc, brush);
        let _ = DeleteObject(HGDIOBJ(brush.0));
        let font = CreateFontW(-22, 0, 0, 0, FW_BOLD.0 as i32, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FF_DONTCARE.0 as u32, w!("Segoe UI"));
        let old = SelectObject(dc, HGDIOBJ(font.0));
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, COLORREF(SPLASH_TEXT));
        let mut text: Vec<u16> = TITLE.encode_utf16().collect();
        DrawTextW(dc, &mut text, &mut rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(dc, old);
        let _ = DeleteObject(HGDIOBJ(font.0));
        let _ = EndPaint(hwnd, &ps);
    }
}

extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let show = SHOW_MSG.with(|s| s.get());
    if show != 0 && msg == show {
        // SAFETY: a 2ª instância pediu para trazer esta à frente.
        unsafe {
            let _ = ShowWindow(hwnd, if IsIconic(hwnd).as_bool() { SW_RESTORE } else { SW_SHOW });
            let _ = SetForegroundWindow(hwnd);
        }
        return LRESULT(0);
    }
    let ready = WEB_READY.with(|r| r.get());
    match msg {
        WM_CREATE => {
            MAIN_HWND.store(hwnd.0 as isize, Ordering::SeqCst);
            mainthread::set_wake_window(hwnd);
            set_dark_mode(hwnd);
            create_webview(hwnd);
            LRESULT(0)
        }
        mainthread::WM_APP_WAKE => {
            mainthread::drain();
            LRESULT(0)
        }
        WM_PAINT if !ready => {
            draw_splash(hwnd);
            LRESULT(0)
        }
        WM_ERASEBKGND if !ready => LRESULT(1),
        WM_SIZE => {
            resize_webview(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            // SAFETY: encerra o loop.
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        // SAFETY: o resto é do Windows.
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// A janela e o loop. `handler` atende a página; `on_shutdown` roda com o STA
/// ainda vivo, antes do `CoUninitialize`.
pub fn run(handler: Arc<dyn Handler>, on_shutdown: impl FnOnce()) {
    HANDLER.with(|h| *h.borrow_mut() = Some(handler));
    // SAFETY: sequência padrão Win32/COM na thread principal.
    unsafe {
        let show = RegisterWindowMessageW(&HSTRING::from(SHOW_MSG_NAME));
        SHOW_MSG.with(|s| s.set(show));
        let mutex = windows::Win32::System::Threading::CreateMutexW(None, false, &HSTRING::from(MUTEX_NAME));
        if windows::Win32::Foundation::GetLastError() == windows::Win32::Foundation::ERROR_ALREADY_EXISTS {
            // Já aberto: acorda o outro e sai.
            if let Ok(w) = FindWindowW(&HSTRING::from(CLASS_NAME), PCWSTR::null()) {
                let _ = PostMessageW(Some(w), show, WPARAM(0), LPARAM(0));
            }
            if let Ok(m) = mutex {
                let _ = CloseHandle(m);
            }
            return;
        }
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok();
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let hinst: HINSTANCE = GetModuleHandleW(None).map(|h| HINSTANCE(h.0)).unwrap_or_default();
        let class = HSTRING::from(CLASS_NAME);
        let wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(window_proc),
            hInstance: hinst,
            hIcon: LoadIconW(Some(hinst), w!("MAINICON")).unwrap_or_default(),
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH(CreateSolidBrush(COLORREF(SPLASH_BG)).0),
            lpszClassName: PCWSTR(class.as_ptr()),
            ..Default::default()
        };
        RegisterClassW(&wc);
        let mut work = RECT::default();
        let _ = SystemParametersInfoW(SPI_GETWORKAREA, 0, Some(&mut work as *mut RECT as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
        let (ww, wh) = (work.right - work.left, work.bottom - work.top);
        let (w_, h_) = (1400.min(ww * 9 / 10), 900.min(wh * 9 / 10));
        let Ok(hwnd) = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            &class,
            &HSTRING::from(TITLE),
            WS_OVERLAPPEDWINDOW,
            work.left + (ww - w_) / 2,
            work.top + (wh - h_) / 2,
            w_,
            h_,
            None,
            None,
            Some(hinst),
            None,
        ) else {
            return;
        };
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = UpdateWindow(hwnd);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        on_shutdown();
        WEB.with(|w| *w.borrow_mut() = None);
        HANDLER.with(|h| *h.borrow_mut() = None);
        CoUninitialize();
        if let Ok(m) = mutex {
            let _ = CloseHandle(m);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caminho_local_e_cabecalhos() {
        assert_eq!(local_uri("https://rtsplayer.app/"), Some("/".into()));
        assert_eq!(local_uri("https://rtsplayer.app"), Some("/".into()));
        assert_eq!(local_uri("https://rtsplayer.app/api/live?camera=a#x"), Some("/api/live?camera=a".into()));
        assert_eq!(local_uri("https://rtsplayer.appx/"), None);
        assert_eq!(local_uri("https://outro.com/"), None);
        let r = Response::new(200, "application/x-vms", vec![]).with_header("X-Vms-Cursor", "c");
        assert_eq!(response_headers(&r), "Content-Type: application/x-vms\r\nX-Vms-Cursor: c");
    }
}
