//! `/api/auth/*`: estado, entrada, saída e definição de senha.

use serde_json::{json, Value};
use vms_core::http::{Request, Response};

use super::ApiRouter;
use crate::auth::{gerar_hash_de_senha, Acesso, COOKIE_SESSAO, SESSAO_PADRAO_HORAS};
use crate::config::set_setting;

fn credencial(req: &Request) -> Option<(String, String)> {
    let v: Value = serde_json::from_slice(&req.body).ok()?;
    let o = v.as_object()?;
    let s = |k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    Some((s("user"), s("password")))
}

fn peer(req: &Request) -> String {
    req.peer.map(|p| p.ip().to_string()).unwrap_or_default()
}

impl ApiRouter {
    pub(super) fn auth_status(&self, req: &Request) -> Response {
        let ligado = self.auth.ligado();
        let autenticado = !ligado || self.auth.avaliar(req.header("Authorization").unwrap_or(""), req.header("Cookie").unwrap_or("")) == Acesso::Liberado;
        let mut j = json!({
            "enabled": ligado,
            "needsSetup": ligado && self.auth.sem_senha(),
            "local": req.is_loopback(),
            "authenticated": autenticado,
        });
        // O usuário só para quem já entrou: é metade do par que se adivinha.
        if autenticado {
            j["user"] = json!(self.auth.usuario());
        }
        Response::json(&j)
    }

    pub(super) fn login(&self, req: &Request) -> Response {
        if req.method != "POST" {
            return Response::error(405, "use POST");
        }
        let Some((u, p)) = credencial(req) else { return Response::error(400, "esperava {user, password}") };
        if self.auth.sem_senha() {
            return Response::error(409, "defina uma senha primeiro");
        }
        if !self.auth.confere(&u, &p) {
            self.d.log.warn("auth", &format!("login recusado de {}", peer(req)));
            return Response::error(401, "usuario ou senha invalidos");
        }
        let token = self.auth.abrir_sessao();
        self.d.log.info("auth", &format!("login aceito de {}", peer(req)));
        let mut cookie = format!("{COOKIE_SESSAO}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={}", SESSAO_PADRAO_HORAS * 3600);
        if req.header("X-Forwarded-Proto").is_some_and(|v| v.trim().eq_ignore_ascii_case("https")) {
            cookie.push_str("; Secure");
        }
        Response::json(&json!({ "ok": true })).with_header("Set-Cookie", &cookie)
    }

    pub(super) fn logout(&self, req: &Request) -> Response {
        self.auth.fechar_sessao(&crate::auth::cookie_de(req.header("Cookie").unwrap_or(""), COOKIE_SESSAO));
        Response::json(&json!({ "ok": true })).with_header("Set-Cookie", &format!("{COOKIE_SESSAO}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"))
    }

    pub(super) fn definir_senha(&self, req: &Request) -> Response {
        if req.method != "POST" {
            return Response::error(405, "use POST");
        }
        let Some(db) = self.db() else { return Response::error(503, "banco indisponivel") };
        let Some((mut u, p)) = credencial(req) else { return Response::error(400, "esperava {user, password}") };
        if p.chars().count() < 8 {
            return Response::error(400, "a senha precisa de ao menos 8 caracteres");
        }
        // Usuário em branco mantém o atual: quem só troca a senha não redigita.
        if u.trim().is_empty() {
            u = self.auth.usuario();
        }
        let u = if u.trim().is_empty() { "admin".to_owned() } else { u.trim().to_owned() };
        let agora = self.d.clock.now_utc_ms();
        if let Err(e) = set_setting(db, "auth.user", &u, agora).and_then(|_| set_setting(db, "auth.hash", &gerar_hash_de_senha(&p), agora)) {
            return Response::error(500, &e.to_string());
        }
        // Já: quem definiu vai entrar em seguida, e as sessões velhas caem.
        self.recarregar_auth();
        self.d.log.info("auth", &format!("senha definida por {}", peer(req)));
        Response::json(&json!({ "ok": true, "user": u }))
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{local, router};
    use vms_core::http::{Handler, Request};

    #[test]
    fn define_senha_e_entra() {
        let d = vms_core::testutil::TempDir::new("api-auth");
        let (r, _db) = router("api-auth", d.path(), &["cam"]);
        let s = r.handle(&local("GET", "/api/auth/status")).json_value();
        assert_eq!(s["needsSetup"], true);
        assert_eq!(r.handle(&local("POST", "/api/auth/password").with_body(br#"{"password":"curta"}"#.to_vec())).status, 400);
        assert_eq!(r.handle(&local("POST", "/api/auth/password").with_body(br#"{"user":"","password":"12345678"}"#.to_vec())).status, 200);
        // Agora nem o próprio computador entra sem credencial.
        assert_eq!(r.handle(&local("GET", "/api/cameras")).status, 401);
        assert_eq!(r.handle(&local("GET", "/ui/app")).status, 302);
        let bad = r.handle(&local("POST", "/api/auth/login").with_body(br#"{"user":"admin","password":"x"}"#.to_vec()));
        assert_eq!(bad.status, 401);
        let ok = r.handle(&local("POST", "/api/auth/login").with_body(br#"{"user":"ADMIN","password":"12345678"}"#.to_vec()));
        assert_eq!(ok.status, 200);
        let cookie = ok.header("Set-Cookie").unwrap().split(';').next().unwrap().to_owned();
        let mut q = Request::new("GET", "/api/cameras");
        q.headers.add("Cookie", &cookie);
        assert_eq!(r.handle(&q).status, 200);
    }
}
