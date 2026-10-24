//! PTZ, fala e o registro de interação.
//!
//! O atendimento em si é o `PtzApi`/`FalaRegistry` do `vms-core` (o mesmo do
//! app). O que é só do servidor: câmera gravada por RTSP cujo PTZ fala DVRIP
//! (`ptz` = `dvrip://…` no cadastro) ganha uma sessão DVRIP só de comando,
//! aberta aqui e mantida pelo laço principal.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use vms_core::camera::CameraConfig;
use vms_core::http::{Request, Response};
use vms_core::log::SharedLogger;
use vms_core::ptz::{FalaRegistry, PtzRegistry};
use vms_core::ptz_control::{is_dvrip_ptz, ControlSessions, ESPERA_PRONTA};

use super::ApiRouter;
use crate::db::Db;
use crate::interactions::{to_json, INTERACAO_FALA, INTERACAO_PTZ};

const TICK: Duration = Duration::from_secs(15);

/// (xaddr, usuário, senha) para o ONVIF da câmera; None = sem PTZ ONVIF
/// (vazio, ou DVRIP).
pub fn onvif_de(db: Option<&Db>, camera: &str) -> Option<(String, String, String)> {
    let db = db?;
    let (url, user, pass) = db
        .query(
            "SELECT e.url, e.user_name, e.password FROM camera_endpoint e JOIN camera c ON c.id = e.camera_id WHERE c.name = ? ORDER BY e.ord LIMIT 1",
            p![camera],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
        )
        .ok()?
        .into_iter()
        .next()?;
    let xaddr = endereco_ptz(db, camera);
    if xaddr.is_empty() || xaddr.to_ascii_lowercase().starts_with("dvrip://") {
        return None;
    }
    Some((vms_core::onvif::endereco_onvif(&xaddr, &url), user, pass))
}

pub fn endereco_ptz(db: &Db, camera: &str) -> String {
    db.query_string("SELECT value FROM setting WHERE key = ?", p![format!("ptz.{}.xaddr", camera.to_lowercase())]).unwrap_or_default().trim().to_owned()
}

/// As sessões DVRIP de comando que o cadastro pede (`vms-core::ptz_control`),
/// conferidas contra o banco no laço principal.
pub struct Controles {
    sessoes: ControlSessions,
    tick: Mutex<Option<Instant>>,
}

impl Controles {
    pub fn new(log: SharedLogger, clock: Arc<dyn vms_core::clock::Clock>) -> Self {
        Self { sessoes: ControlSessions::new(log, clock), tick: Mutex::new(None) }
    }

    /// Abre o que o cadastro pede e fecha o que ele não pede mais. Limita-se
    /// no tempo sozinha; `agora` fura o limite (um pedido está esperando).
    pub fn manter(&self, api: &ApiRouter, agora: bool) {
        {
            let mut t = self.tick.lock().unwrap_or_else(|p| p.into_inner());
            if !agora && t.is_some_and(|t| t.elapsed() < TICK) {
                return;
            }
            *t = Some(Instant::now());
        }
        let Some(db) = api.db() else { return };
        for nome in api.cameras_agora() {
            let end = endereco_ptz(db, &nome);
            if !is_dvrip_ptz(&end) || PtzRegistry::achar(&nome).is_some() {
                continue;
            }
            let cred = db
                .query(
                    "SELECT e.user_name, e.password FROM camera_endpoint e JOIN camera c ON c.id = e.camera_id WHERE c.name = ? ORDER BY e.ord LIMIT 1",
                    p![nome.clone()],
                    |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
                )
                .ok()
                .and_then(|v| v.into_iter().next());
            let Some((user, password)) = cred else { continue };
            self.sessoes.ensure(CameraConfig { name: nome.clone(), url: end, user, password, connect_timeout_ms: 8000, rtsp_timeout_ms: 8000, ..Default::default() });
        }
        self.sessoes.retain(|k| is_dvrip_ptz(&endereco_ptz(db, k)));
    }

    pub fn fechar_todos(&self) {
        self.sessoes.close_all();
    }
}

impl ApiRouter {
    /// Sem sessão viva e com PTZ DVRIP cadastrado: abre a de comando e
    /// espera um pouco por ela.
    fn esperar_controle(&self, camera: &str) {
        if PtzRegistry::achar(camera).is_some() {
            return;
        }
        let Some(db) = self.db() else { return };
        if !is_dvrip_ptz(&endereco_ptz(db, camera)) {
            return;
        }
        self.controles.manter(self, true);
        ControlSessions::wait_ready(camera, ESPERA_PRONTA);
    }

    pub(super) fn ptz_route(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        self.esperar_controle(&cam);
        let r = self.ptz.handle(&cam, req);
        // Comandos aceitos que mexem na câmera viram interação; consultas não.
        let acao = req.param("acao").trim().to_lowercase();
        if r.status == 200 && ["mover", "parar", "foco", "iris", "ronda", "preset", "ir"].contains(&acao.as_str()) {
            self.interacoes.registrar(&cam, INTERACAO_PTZ, &acao);
        }
        r
    }

    pub(super) fn fala(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        self.esperar_controle(&cam);
        let acao = req.param("acao").trim().to_lowercase();
        let (status, body) = FalaRegistry::atender(&cam, &acao, &req.body);
        // Só o áudio que a câmera aceitou conta como interação.
        if status == 200 && acao == "enviar" && serde_json::from_str::<serde_json::Value>(&body).ok().is_some_and(|v| v["ok"] == true) {
            self.interacoes.registrar(&cam, INTERACAO_FALA, "");
        }
        Response::new(status, "application/json; charset=utf-8", body.into_bytes())
    }

    pub(super) fn interacoes_route(&self, req: &Request) -> Response {
        let Some(cam) = self.known_camera(&req.param("camera")) else { return Response::error(404, "camera desconhecida") };
        let (from, to) = (req.param_i64("fromMs", 0), req.param_i64("toMs", 0));
        if from <= 0 || to <= from {
            return Response::error(400, "informe fromMs e toMs");
        }
        if to - from > 7 * super::MS_PER_DAY {
            return Response::error(400, "janela maior que 7 dias");
        }
        Response::json(&to_json(&cam, from, to, &self.interacoes.consultar(&cam, from, to)))
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{local, router};
    use std::sync::Arc;
    use vms_core::http::Handler;
    use vms_core::ptz::fakes::PtzFalsa;
    use vms_core::ptz::{PtzRegistry, PtzSession};

    #[test]
    fn ptz_pela_sessao_viva_registra_interacao() {
        let d = vms_core::testutil::TempDir::new("api-ptz");
        let (r, _db) = router("api-ptz", d.path(), &["ptzsrv1"]);
        let s: Arc<dyn PtzSession> = Arc::new(PtzFalsa::default());
        PtzRegistry::anunciar("ptzsrv1", s.clone());
        let now = vms_core::clock::unix_ms();
        assert_eq!(r.handle(&local("GET", "/api/ptz?camera=PTZSRV1&acao=mover&pan=1000")).json_value()["via"], "dvrip");
        assert_eq!(r.handle(&local("GET", "/api/ptz?camera=ptzsrv1&acao=testar")).status, 200);
        let j = r.handle(&local("GET", &format!("/api/interacoes?camera=ptzsrv1&fromMs={}&toMs={}", now - 1000, now + 60_000))).json_value();
        assert_eq!(j["count"], 1);
        assert_eq!(j["interactions"][0]["detail"], "mover x1", "testar nao conta");
        PtzRegistry::apagar("ptzsrv1", &s);
        assert_eq!(r.handle(&local("GET", "/api/ptz?camera=ptzsrv1&acao=testar")).status, 503);
        assert_eq!(r.handle(&local("GET", "/api/fala?camera=ptzsrv1&acao=testar")).json_value()["ok"], false);
        assert_eq!(r.handle(&local("GET", "/api/interacoes?camera=ptzsrv1")).status, 400);
    }
}
