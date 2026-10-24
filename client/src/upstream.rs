//! Encaminhar um pedido da página para o vmsserver. Atrás de uma porta
//! (`Upstream`): o app usa o WinHTTP (http e https, proxy do sistema — o
//! `tailscale serve` publica em https), o teste usa o cliente HTTP do
//! `vms-core` contra um servidor de verdade em 127.0.0.1.

use std::time::Duration;

use vms_core::http::Response;

pub const MAX_ENCAMINHADO: usize = 8 * 1024 * 1024;

pub trait Upstream: Send + Sync {
    /// (status, cabeçalhos, corpo). Err = nem chegou resposta.
    fn send(&self, method: &str, url: &str, headers: &[(String, String)], body: &[u8]) -> Result<Response, String>;
}

/// O cliente do `vms-core` (só http://).
pub struct PlainHttp;

impl Upstream for PlainHttp {
    fn send(&self, method: &str, url: &str, headers: &[(String, String)], body: &[u8]) -> Result<Response, String> {
        let h: Vec<(&str, &str)> = headers.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
        vms_core::http::fetch(method, url, &h, body, Duration::from_secs(30)).map_err(|e| e.to_string())
    }
}

#[cfg(windows)]
pub use winhttp::WinHttp;

#[cfg(windows)]
mod winhttp {
    use std::ffi::c_void;

    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::Networking::WinHttp::*;

    use super::{Response, Upstream, MAX_ENCAMINHADO};

    pub struct WinHttp;

    /// O erro do WinHTTP em palavras: as mensagens dele não vêm do sistema.
    fn explicar(etapa: &str, e: &windows::core::Error) -> String {
        let motivo = match (e.code().0 as u32) & 0xFFFF {
            12002 => "o servidor demorou demais para responder",
            12007 => "o nome do servidor nao foi encontrado",
            12029 => "nao consegui conectar (o servidor esta desligado ou a porta esta errada?)",
            12030 => "a conexao caiu",
            12175 | 12045 | 12038 | 12037 | 12044 => "falha no certificado https do servidor",
            _ => return format!("{etapa}: {e}"),
        };
        format!("{motivo} ({etapa}: {:#010X})", e.code().0 as u32)
    }

    struct H(*mut c_void);
    impl Drop for H {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: handle aberto pelo WinHTTP e fechado uma vez só.
                unsafe {
                    let _ = WinHttpCloseHandle(self.0);
                }
            }
        }
    }

    fn split(url: &str) -> Option<(bool, String, u16, String)> {
        let (sec, rest) = if let Some(r) = url.strip_prefix("https://") { (true, r) } else { (false, url.strip_prefix("http://")?) };
        let (aut, path) = match rest.find('/') {
            Some(i) => (&rest[..i], rest[i..].to_owned()),
            None => (rest, "/".to_owned()),
        };
        let aut = aut.rsplit('@').next().unwrap_or(aut);
        let (host, port) = match aut.rsplit_once(':') {
            Some((h, p)) if p.parse::<u16>().is_ok() => (h.to_owned(), p.parse().ok()?),
            _ => (aut.to_owned(), if sec { 443 } else { 80 }),
        };
        Some((sec, host, port, path))
    }

    fn raw_headers(h: *mut c_void) -> Vec<(String, String)> {
        let mut len = 0u32;
        // SAFETY: primeira chamada só pergunta o tamanho.
        unsafe {
            let _ = WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, PCWSTR::null(), None, &mut len, std::ptr::null_mut());
            if len == 0 {
                return Vec::new();
            }
            let mut buf = vec![0u16; len as usize / 2 + 1];
            if WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, PCWSTR::null(), Some(buf.as_mut_ptr() as *mut c_void), &mut len, std::ptr::null_mut()).is_err() {
                return Vec::new();
            }
            String::from_utf16_lossy(&buf[..len as usize / 2])
                .split("\r\n")
                .skip(1)
                .filter_map(|l| l.split_once(':').map(|(a, b)| (a.trim().to_owned(), b.trim().to_owned())))
                .collect()
        }
    }

    impl Upstream for WinHttp {
        fn send(&self, method: &str, url: &str, headers: &[(String, String)], body: &[u8]) -> Result<Response, String> {
            let (sec, host, port, path) = split(url).ok_or("url invalida")?;
            let err = |stage: &str| format!("{stage}: {}", windows::core::Error::from_win32());
            // SAFETY: cada handle vive no seu `H` e é fechado no fim.
            unsafe {
                let s = H(WinHttpOpen(&HSTRING::from("RTSPlayer"), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, PCWSTR::null(), PCWSTR::null(), 0));
                if s.0.is_null() {
                    return Err(err("WinHttpOpen"));
                }
                let _ = WinHttpSetTimeouts(s.0, 5000, 8000, 30_000, 30_000);
                let c = H(WinHttpConnect(s.0, &HSTRING::from(host.as_str()), port, 0));
                if c.0.is_null() {
                    return Err(err("WinHttpConnect"));
                }
                let flags = if sec { WINHTTP_FLAG_SECURE } else { WINHTTP_OPEN_REQUEST_FLAGS(0) };
                let r = H(WinHttpOpenRequest(c.0, &HSTRING::from(method), &HSTRING::from(path.as_str()), PCWSTR::null(), PCWSTR::null(), std::ptr::null(), flags));
                if r.0.is_null() {
                    return Err(err("WinHttpOpenRequest"));
                }
                let hs: String = headers.iter().map(|(k, v)| format!("{k}: {v}\r\n")).collect();
                let hw: Vec<u16> = hs.encode_utf16().collect();
                let opt = if body.is_empty() { None } else { Some(body.as_ptr() as *const c_void) };
                WinHttpSendRequest(r.0, if hw.is_empty() { None } else { Some(&hw) }, opt, body.len() as u32, body.len() as u32, 0).map_err(|e| explicar("envio", &e))?;
                WinHttpReceiveResponse(r.0, std::ptr::null_mut()).map_err(|e| explicar("resposta", &e))?;
                let mut code = 0u32;
                let mut cl = 4u32;
                let _ = WinHttpQueryHeaders(r.0, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, PCWSTR::null(), Some(&mut code as *mut u32 as *mut c_void), &mut cl, std::ptr::null_mut());
                let hdrs = raw_headers(r.0);
                let mut out = Vec::new();
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    let mut got = 0u32;
                    WinHttpReadData(r.0, buf.as_mut_ptr() as *mut c_void, buf.len() as u32, &mut got).map_err(|e| explicar("leitura", &e))?;
                    if got == 0 {
                        break;
                    }
                    out.extend_from_slice(&buf[..got as usize]);
                    if out.len() > MAX_ENCAMINHADO {
                        return Err("resposta grande demais".into());
                    }
                }
                let ctype = hdrs.iter().find(|(k, _)| k.eq_ignore_ascii_case("Content-Type")).map(|(_, v)| v.clone()).unwrap_or_default();
                let mut resp = Response::new(code as u16, &ctype, out);
                resp.headers = hdrs.into_iter().filter(|(k, _)| !k.eq_ignore_ascii_case("Content-Type") && !k.eq_ignore_ascii_case("Content-Length")).collect();
                Ok(resp)
            }
        }
    }

    #[cfg(test)]
    mod tests {
        #[test]
        fn url() {
            assert_eq!(super::split("https://casa.ts.net/api/x?y=1"), Some((true, "casa.ts.net".into(), 443, "/api/x?y=1".into())));
            assert_eq!(super::split("http://u:p@h:81"), Some((false, "h".into(), 81, "/".into())));
            assert_eq!(super::split("ftp://x"), None);
        }

        #[test]
        fn erro_em_palavras() {
            let e = windows::core::Error::from(windows::core::HRESULT(0x80072EFDu32 as i32));
            assert!(super::explicar("envio", &e).starts_with("nao consegui conectar"), "{}", super::explicar("envio", &e));
            let outro = windows::core::Error::from(windows::core::HRESULT(0x80004005u32 as i32));
            assert!(super::explicar("envio", &outro).starts_with("envio: "));
        }
    }
}
