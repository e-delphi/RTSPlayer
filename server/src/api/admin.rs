//! Administração: SQL livre, ajustes, cadastro de câmeras e procura de ONVIF.

use std::collections::HashMap;
use std::time::Instant;

use serde_json::{json, Value};
use vms_core::http::{Request, Response};

use super::ApiRouter;
use crate::config::set_setting;

const SQL_DEFAULT_LIMIT: usize = 500;
const SQL_MAX_LIMIT: usize = 10_000;

impl ApiRouter {
    /// SQL livre (diagnóstico). A primeira palavra escolhe leitura ou escrita;
    /// os valores saem como texto e null continua null.
    pub(super) fn sql(&self, req: &Request) -> Response {
        let Some(db) = self.db() else { return Response::error(503, "servidor sem banco aberto") };
        let mut sql = req.body_text();
        if sql.trim().is_empty() {
            sql = req.param("q");
        }
        let sql = sql.trim().to_owned();
        if sql.is_empty() {
            return Response::error(400, "informe o sql em q= ou no corpo");
        }
        let limite = (req.param_i64("limit", SQL_DEFAULT_LIMIT as i64).max(0) as usize).clamp(1, SQL_MAX_LIMIT);
        let primeira = sql.trim_start().chars().take(7).collect::<String>().to_lowercase();
        let leitura = ["select", "pragma", "explain", "with"].iter().any(|p| primeira.starts_with(p));
        self.d.log.info("api.sql", &sql);
        let t = Instant::now();
        let mut j = json!({ "sql": sql });
        if leitura {
            match db.query_table(&sql, limite) {
                Ok((cols, rows, scanned)) => {
                    let truncated = scanned > limite;
                    j["kind"] = json!("read");
                    j["columns"] = json!(cols);
                    j["count"] = json!(rows.len());
                    j["rows"] = json!(rows);
                    j["scanned"] = json!(scanned);
                    j["truncated"] = json!(truncated);
                    if truncated {
                        j["hint"] = json!(format!("use limit= (max {SQL_MAX_LIMIT}) ou refine o sql"));
                    }
                }
                Err(e) => return Response::json_status(400, &json!({ "error": e.to_string(), "sql": sql })),
            }
        } else {
            match db.exec(&sql, p![]) {
                Ok(n) => {
                    j["kind"] = json!("write");
                    j["affected"] = json!(n);
                }
                Err(e) => return Response::json_status(400, &json!({ "error": e.to_string(), "sql": sql })),
            }
        }
        j["elapsedMs"] = json!(t.elapsed().as_millis() as u64);
        Response::json(&j)
    }

    pub(super) fn settings_get(&self) -> Response {
        let Some(db) = self.db() else { return Response::error(503, "banco indisponivel") };
        match db.query("SELECT key, value FROM setting ORDER BY key", p![], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))) {
            // O hash da senha nunca sai.
            Ok(l) => Response::json(&json!({ "settings": l.into_iter().filter(|(k, _)| !k.eq_ignore_ascii_case("auth.hash")).map(|(k, v)| json!({ "key": k, "value": v })).collect::<Vec<_>>() })),
            Err(e) => Response::error(500, &e.to_string()),
        }
    }

    /// Só altera chaves que existem (e nunca `auth.hash`). `analytics.*`
    /// vale na hora.
    pub(super) fn settings_post(&self, req: &Request) -> Response {
        let Some(db) = self.db() else { return Response::error(503, "banco indisponivel") };
        if req.body.iter().all(|b| b.is_ascii_whitespace()) {
            return Response::error(400, "corpo vazio");
        }
        let Some(obj) = serde_json::from_slice::<Value>(&req.body).ok().and_then(|v| v.as_object().cloned()) else { return Response::error(400, "esperava um objeto JSON") };
        let agora = self.d.clock.now_utc_ms();
        let (mut gravadas, mut recusadas, mut analise) = (0, Vec::new(), false);
        for (k, v) in obj {
            if k.eq_ignore_ascii_case("auth.hash") || db.query_i64("SELECT COUNT(*) FROM setting WHERE key = ?", p![k.clone()], 0) == 0 {
                recusadas.push(k);
                continue;
            }
            let val = match &v {
                Value::String(s) => s.clone(),
                Value::Bool(b) => (if *b { "1" } else { "0" }).to_owned(),
                Value::Null => String::new(),
                o => o.to_string(),
            };
            if let Err(e) = db.exec("UPDATE setting SET value = ?, updated_at_ms = ? WHERE key = ?", p![val, agora, k.clone()]) {
                return Response::error(500, &e.to_string());
            }
            gravadas += 1;
            analise |= k.to_ascii_lowercase().starts_with("analytics.");
        }
        let mut note = "gravado".to_owned();
        if gravadas > 0 && analise {
            if let Some(f) = self.on_analytics.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
                f();
                note = "ja esta valendo".into();
            }
        }
        Response::json(&json!({ "saved": gravadas, "unknown": recusadas, "note": note }))
    }

    /// O cadastro inteiro, sem senhas (`temSenha` diz se há uma).
    pub(super) fn config_cameras_get(&self) -> Response {
        let Some(db) = self.db() else { return Response::error(503, "banco indisponivel") };
        let cams = db.query("SELECT id, name, enabled, record_audio FROM camera ORDER BY name COLLATE NOCASE", p![], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)? != 0, r.get::<_, i64>(3)? != 0))
        });
        let Ok(cams) = cams else { return Response::error(500, "falha lendo cameras") };
        let list: Vec<Value> = cams
            .into_iter()
            .map(|(id, name, en, au)| {
                let eps = db
                    .query("SELECT label, url, user_name, password, transports, uses_tailscale FROM camera_endpoint WHERE camera_id = ? ORDER BY ord", p![id], |r| {
                        Ok(json!({
                            "label": r.get::<_, String>(0)?,
                            "url": r.get::<_, String>(1)?,
                            "user": r.get::<_, String>(2)?,
                            "temSenha": !r.get::<_, String>(3)?.is_empty(),
                            "transport": r.get::<_, String>(4)?,
                            "tailscale": r.get::<_, i64>(5)? != 0,
                        }))
                    })
                    .unwrap_or_default();
                let ptz = db.query_string("SELECT value FROM setting WHERE key = ?", p![format!("ptz.{}.xaddr", name.to_lowercase())]).unwrap_or_default();
                json!({ "id": id, "name": name, "enabled": en, "recordAudio": au, "endpoints": eps, "ptz": ptz })
            })
            .collect();
        Response::json(&json!({ "cameras": list }))
    }

    /// Cria ou altera uma câmera. Senha em branco mantém a que havia naquela
    /// posição; o nome não muda (é a pasta e a rota). Vale no próximo giro do
    /// laço principal.
    pub(super) fn config_cameras_post(&self, req: &Request) -> Response {
        let Some(db) = self.db() else { return Response::error(503, "banco indisponivel") };
        if req.body.iter().all(|b| b.is_ascii_whitespace()) {
            return Response::error(400, "corpo vazio");
        }
        let Some(o) = serde_json::from_slice::<Value>(&req.body).ok().and_then(|v| v.as_object().cloned()) else { return Response::error(400, "esperava um objeto JSON") };
        let s = |k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").trim().to_owned();
        let b = |k: &str| o.get(k).and_then(Value::as_bool).unwrap_or(true);
        let nome = s("name");
        let id = o.get("id").and_then(Value::as_i64).unwrap_or(0);
        let (ligada, com_audio, ptz) = (b("enabled"), b("recordAudio"), s("ptz"));
        if nome.is_empty() {
            return Response::error(400, "a camera precisa de um nome");
        }
        if nome.contains(['/', '\\', ':']) || nome.contains("..") {
            return Response::error(400, "o nome vira pasta em disco: sem / \\ : nem ..");
        }
        let Some(eps) = o.get("endpoints").and_then(Value::as_array).filter(|a| !a.is_empty()) else { return Response::error(400, "informe ao menos um endereco em endpoints") };
        for e in eps {
            let Some(eo) = e.as_object() else { return Response::error(400, "endpoint invalido") };
            if eo.get("url").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
                return Response::error(400, "endereco sem url");
            }
        }
        let agora = self.d.clock.now_utc_ms();
        let id = if id > 0 {
            let Some(atual) = db.query_string("SELECT name FROM camera WHERE id = ?", p![id]) else { return Response::error(404, "nao ha camera com este id") };
            if !atual.eq_ignore_ascii_case(&nome) {
                return Response::error(400, "o nome e a pasta em disco e a rota da camera: renomear a separaria das gravacoes dela. Crie outra camera.");
            }
            if let Err(e) = db.exec("UPDATE camera SET enabled = ?, record_audio = ?, updated_at_ms = ? WHERE id = ?", p![ligada, com_audio, agora, id]) {
                return Response::error(500, &e.to_string());
            }
            id
        } else {
            if db.query_i64("SELECT COUNT(*) FROM camera WHERE name = ?", p![nome.clone()], 0) > 0 {
                return Response::error(409, "ja existe uma camera com este nome");
            }
            if let Err(e) = db.exec("INSERT INTO camera (name, enabled, record_audio, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?)", p![nome.clone(), ligada, com_audio, agora, agora]) {
                return Response::error(500, &e.to_string());
            }
            db.query_i64("SELECT id FROM camera WHERE name = ?", p![nome.clone()], 0)
        };
        let antigas: HashMap<i64, String> = db.query("SELECT ord, password FROM camera_endpoint WHERE camera_id = ?", p![id], |r| Ok((r.get(0)?, r.get(1)?))).unwrap_or_default().into_iter().collect();
        let _ = db.exec("DELETE FROM camera_endpoint WHERE camera_id = ?", p![id]);
        for (i, e) in eps.iter().enumerate() {
            let es = |k: &str| e.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            let mut senha = es("password");
            if senha.is_empty() {
                senha = antigas.get(&(i as i64)).cloned().unwrap_or_default();
            }
            let transport = Some(es("transport")).filter(|t| !t.trim().is_empty()).unwrap_or_else(|| "tcp,udp".into());
            if let Err(err) = db.exec(
                "INSERT INTO camera_endpoint (camera_id, ord, label, url, user_name, password, transports, uses_tailscale) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                p![id, i as i64, es("label"), es("url").trim().to_owned(), es("user"), senha, transport, e.get("tailscale").and_then(Value::as_bool).unwrap_or(false)],
            ) {
                return Response::error(500, &err.to_string());
            }
        }
        let chave = format!("ptz.{}.xaddr", nome.to_lowercase());
        let _ = if ptz.is_empty() { db.exec("DELETE FROM setting WHERE key = ?", p![chave]).map(|_| ()) } else { set_setting(db, &chave, &ptz, agora) };
        self.anotar_pendente(&nome);
        self.ptz.onvif_cache().forget();
        self.d.log.info("api", &format!("cadastro da camera {nome} gravado ({} enderecos)", eps.len()));
        Response::json(&json!({ "id": id, "name": nome, "aplicando": true }))
    }

    /// A procura roda AQUI: é esta máquina que vai mandar o comando depois.
    pub(super) fn procurar_ptz(&self, req: &Request) -> Response {
        if req.body.iter().all(|b| b.is_ascii_whitespace()) {
            return Response::error(400, "corpo vazio");
        }
        let Some(o) = serde_json::from_slice::<Value>(&req.body).ok().filter(Value::is_object) else { return Response::error(400, "mande {url, user, password}") };
        let s = |k: &str| o.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        let host = vms_core::onvif::host_da_url(&s("url"));
        if host.is_empty() {
            return Response::error(400, "a url nao tem host");
        }
        vms_core::ptz_api::procurar(&host, &s("user"), &s("password"), self.d.log.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{local, router};
    use vms_core::http::Handler;

    #[test]
    fn sql_ajustes_e_cadastro() {
        let d = vms_core::testutil::TempDir::new("api-admin");
        let (r, db) = router("api-admin", d.path(), &["cam"]);
        let j = r.handle(&local("GET", "/api/sql?q=select%20key%20from%20setting%20where%20key%3D'rtspPort'")).json_value();
        assert_eq!(j["rows"][0][0], "rtspPort");
        assert_eq!(r.handle(&local("GET", "/api/sql?q=selec%20x")).status, 400);
        let w = r.handle(&local("POST", "/api/sql").with_body(b"update setting set value='1' where key='rtspPort'".to_vec())).json_value();
        assert_eq!(w["affected"], 1);

        let s = r.handle(&local("GET", "/api/settings")).json_value();
        assert!(s["settings"].as_array().unwrap().iter().all(|x| x["key"] != "auth.hash"));
        let fired = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let f2 = fired.clone();
        r.on_analytics_mudou(move || f2.store(true, std::sync::atomic::Ordering::SeqCst));
        let p = r.handle(&local("POST", "/api/settings").with_body(br#"{"analytics.stepMs": 3000, "auth.hash": "x", "inventada": 1}"#.to_vec())).json_value();
        assert_eq!(p["saved"], 1);
        assert_eq!(p["unknown"].as_array().unwrap().len(), 2);
        assert!(fired.load(std::sync::atomic::Ordering::SeqCst));

        // Cria, lê sem senha, altera mantendo a senha.
        let body = br#"{"name":"Nova","endpoints":[{"label":"LAN","url":"rtsp://a/1","user":"u","password":"segredo"}],"ptz":"10.0.0.2:8899"}"#;
        let c = r.handle(&local("POST", "/api/config/cameras").with_body(body.to_vec())).json_value();
        let id = c["id"].as_i64().unwrap();
        assert_eq!(r.tomar_cameras_pendentes(), vec!["Nova".to_string()]);
        assert_eq!(r.handle(&local("POST", "/api/config/cameras").with_body(body.to_vec())).status, 409);
        let g = r.handle(&local("GET", "/api/config/cameras")).json_value();
        let nova = g["cameras"].as_array().unwrap().iter().find(|c| c["name"] == "Nova").unwrap().clone();
        assert_eq!(nova["endpoints"][0]["temSenha"], true);
        assert!(nova["endpoints"][0].get("password").is_none());
        assert_eq!(nova["ptz"], "10.0.0.2:8899");
        let upd = format!(r#"{{"id":{id},"name":"nova","enabled":false,"endpoints":[{{"url":"rtsp://b/2","password":""}}]}}"#);
        assert_eq!(r.handle(&local("POST", "/api/config/cameras").with_body(upd.into_bytes())).status, 200);
        assert_eq!(db.query_string("SELECT password FROM camera_endpoint e JOIN camera c ON c.id = e.camera_id WHERE c.name = 'Nova'", vec![]).as_deref(), Some("segredo"));
        assert_eq!(db.query_i64("SELECT COUNT(*) FROM setting WHERE key = 'ptz.nova.xaddr'", vec![], -1), 0, "ptz vazio apaga");
        let ren = format!(r#"{{"id":{id},"name":"Outra","endpoints":[{{"url":"rtsp://b/2"}}]}}"#);
        assert_eq!(r.handle(&local("POST", "/api/config/cameras").with_body(ren.into_bytes())).status, 400);
        assert_eq!(r.handle(&local("POST", "/api/config/cameras").with_body(br#"{"name":"a/b","endpoints":[{"url":"x"}]}"#.to_vec())).status, 400);
        db.close();
    }
}
