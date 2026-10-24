//! A interface web: as mesmas páginas no app (pelo WebView2) e no servidor
//! (pelo navegador). Vêm embutidas no executável; com a variável `VMS_UI_DIR`
//! apontando para uma pasta que existe, vêm de lá, lidas a cada pedido — é o
//! modo de quem edita a interface e só quer recarregar.

use std::borrow::Cow;
use std::path::PathBuf;

include!(concat!(env!("OUT_DIR"), "/ui_assets.rs"));

pub const UI_VAR: &str = "VMS_UI_DIR";

/// A pasta da variável, se ela apontar para algo que existe.
pub fn override_dir() -> Option<PathBuf> {
    let v = std::env::var_os(UI_VAR)?;
    let p = PathBuf::from(v);
    p.is_dir().then_some(p)
}

/// Um arquivo da interface pelo nome (`app-ui.html`). O nome nunca vem do
/// cliente sem passar por aqui, e aqui só se aceita nome simples.
pub fn file(name: &str) -> Option<Cow<'static, [u8]>> {
    if name.is_empty() || name.contains(['/', '\\']) || name.contains("..") {
        return None;
    }
    if let Some(d) = override_dir() {
        if let Ok(b) = std::fs::read(d.join(name)) {
            return Some(Cow::Owned(b));
        }
    }
    UI_FILES.iter().find(|(n, _)| *n == name).map(|(_, b)| Cow::Borrowed(*b))
}

pub fn names() -> Vec<&'static str> {
    UI_FILES.iter().map(|(n, _)| *n).collect()
}

pub fn mime_of(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("").to_ascii_lowercase().as_str() {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        _ => "application/octet-stream",
    }
}

/// Uma linha para a subida: de onde a interface está vindo.
pub fn describe() -> String {
    match override_dir() {
        Some(d) => format!("interface da pasta {} ({UI_VAR})", d.display()),
        None => format!("interface embutida ({} arquivos)", UI_FILES.len()),
    }
}

/// A resposta HTTP de um arquivo da interface, ou 404 dizendo qual falta.
pub fn response(name: &str) -> crate::http::Response {
    match file(name) {
        Some(b) => crate::http::Response::new(200, mime_of(name), b.into_owned()).with_header("Cache-Control", "no-store"),
        None => crate::http::Response::error(404, &format!("nao achei {name} na interface")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paginas_embutidas() {
        for n in ["app-ui.html", "player.js", "vmsreader.js", "ui.css", "favicon.svg", "cameras-ui.html", "events-ui.html", "login-ui.html", "motion-ui.html", "player-ui.html"] {
            assert!(file(n).is_some(), "{n}");
        }
        assert!(file("../Cargo.toml").is_none());
        assert_eq!(mime_of("a.JS"), "text/javascript; charset=utf-8");
        assert_eq!(response("nada.html").status, 404);
    }
}
