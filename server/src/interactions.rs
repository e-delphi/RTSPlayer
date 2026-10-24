//! O registro de quem mexeu na câmera (PTZ e fala), para a linha do tempo
//! pintar esses trechos em outra cor.
//!
//! Comandos da mesma câmera e do mesmo tipo se juntam num trecho enquanto
//! chegam a menos de `GAP_MS` um do outro (um aperto de seta manda dezenas);
//! fechado, o trecho vira UMA linha. O trecho aberto também sai na consulta.
//!
//! Tabela própria (`interaction`), criada na primeira vez que se precisa dela:
//! é aditiva, um executável antigo só a ignora.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use vms_core::clock::Clock;
use vms_core::log::SharedLogger;

use crate::db::Db;

pub const INTERACAO_PTZ: &str = "ptz";
pub const INTERACAO_FALA: &str = "fala";
pub const GAP_MS: i64 = 15_000;
pub const MAX_MS: i64 = 300_000;

const SQL_TABELA: &str = "CREATE TABLE IF NOT EXISTS interaction (\
  id INTEGER PRIMARY KEY,\
  camera_id INTEGER NOT NULL REFERENCES camera(id) ON DELETE CASCADE,\
  start_ms INTEGER NOT NULL,\
  end_ms INTEGER NOT NULL,\
  kind TEXT NOT NULL CHECK (kind IN ('ptz','fala')),\
  detail TEXT NOT NULL DEFAULT '',\
  created_at_ms INTEGER NOT NULL,\
  CHECK (end_ms >= start_ms));\
CREATE INDEX IF NOT EXISTS ix_interaction_window ON interaction (camera_id, start_ms);";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Interacao {
    pub start_ms: i64,
    pub end_ms: i64,
    pub kind: String,
    pub detail: String,
}

struct Aberta {
    camera: String,
    kind: String,
    start_ms: i64,
    end_ms: i64,
    /// Ordenado: o detalhe sai sempre igual para o mesmo trecho.
    contagem: BTreeMap<String, u32>,
}

impl Aberta {
    fn detalhe(&self) -> String {
        self.contagem.iter().map(|(k, n)| format!("{k} x{n}")).collect::<Vec<_>>().join(", ")
    }
}

pub struct InteractionLog {
    db: Option<Arc<Db>>,
    clock: Arc<dyn Clock>,
    log: SharedLogger,
    abertas: Mutex<HashMap<String, Aberta>>,
    pronta: Mutex<bool>,
}

impl InteractionLog {
    pub fn new(db: Option<Arc<Db>>, clock: Arc<dyn Clock>, log: SharedLogger) -> Self {
        Self { db, clock, log, abertas: Mutex::new(HashMap::new()), pronta: Mutex::new(false) }
    }

    fn garantir_tabela(&self) -> Option<&Db> {
        let db = self.db.as_deref()?;
        let mut p = self.pronta.lock().unwrap_or_else(|e| e.into_inner());
        if !*p {
            if let Err(e) = db.exec_script(SQL_TABELA) {
                self.log.warn("interacao", &format!("nao consegui criar a tabela: {e}"));
                return None;
            }
            *p = true;
        }
        Some(db)
    }

    fn fechar(&self, a: Aberta) {
        self.log.info("interacao", &format!("{} {}: {} s ({})", a.camera, a.kind, (a.end_ms - a.start_ms) / 1000, a.detalhe()));
        if let Some(db) = self.garantir_tabela() {
            db.post(
                "INSERT INTO interaction (camera_id, start_ms, end_ms, kind, detail, created_at_ms) VALUES ((SELECT id FROM camera WHERE name = ?), ?, ?, ?, ?, ?)",
                p![a.camera.clone(), a.start_ms, a.end_ms, a.kind.clone(), a.detalhe(), self.clock.now_utc_ms()],
            );
        }
    }

    /// Um comando que acabou de sair; `acao` entra no detalhe.
    pub fn registrar(&self, camera: &str, kind: &str, acao: &str) {
        if camera.trim().is_empty() || kind.trim().is_empty() {
            return;
        }
        let agora = self.clock.now_utc_ms();
        let chave = format!("{}\0{kind}", camera.to_lowercase());
        let mut ab = self.abertas.lock().unwrap_or_else(|e| e.into_inner());
        let vencida = ab.get(&chave).map(|a| agora - a.end_ms > GAP_MS || agora - a.start_ms > MAX_MS).unwrap_or(false);
        if vencida {
            if let Some(a) = ab.remove(&chave) {
                self.fechar(a);
            }
        }
        let a = ab.entry(chave).or_insert_with(|| Aberta { camera: camera.to_owned(), kind: kind.to_owned(), start_ms: agora, end_ms: agora, contagem: BTreeMap::new() });
        // Relógio que volta não pode deixar o fim antes do começo.
        a.end_ms = a.end_ms.max(agora).max(a.start_ms);
        if !acao.is_empty() {
            *a.contagem.entry(acao.to_owned()).or_insert(0) += 1;
        }
    }

    /// Fecha os trechos parados há mais de `GAP_MS`. Barata.
    pub fn varrer(&self) {
        let agora = self.clock.now_utc_ms();
        let mut ab = self.abertas.lock().unwrap_or_else(|e| e.into_inner());
        let vencidas: Vec<String> = ab.iter().filter(|(_, a)| agora - a.end_ms > GAP_MS).map(|(k, _)| k.clone()).collect();
        for k in vencidas {
            if let Some(a) = ab.remove(&k) {
                self.fechar(a);
            }
        }
    }

    /// Fecha tudo (desligando no meio de um gesto: o trecho vai como está).
    pub fn fechar_todas(&self) {
        let todas: Vec<Aberta> = self.abertas.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, a)| a).collect();
        for a in todas {
            self.fechar(a);
        }
    }

    pub fn consultar(&self, camera: &str, from: i64, to: i64) -> Vec<Interacao> {
        if camera.trim().is_empty() || to <= from {
            return Vec::new();
        }
        let mut out = Vec::new();
        if let Some(db) = self.garantir_tabela() {
            match db.query(
                "SELECT i.start_ms, i.end_ms, i.kind, i.detail FROM interaction i JOIN camera c ON c.id = i.camera_id \
                 WHERE c.name = ? AND i.start_ms >= ? AND i.start_ms <= ? AND i.end_ms >= ? ORDER BY i.start_ms LIMIT 4000",
                p![camera, from - MAX_MS, to, from],
                |r| Ok(Interacao { start_ms: r.get(0)?, end_ms: r.get(1)?, kind: r.get(2)?, detail: r.get(3)? }),
            ) {
                Ok(l) => out = l,
                Err(e) => self.log.warn("interacao", &format!("consulta falhou: {e}")),
            }
        }
        let ab = self.abertas.lock().unwrap_or_else(|e| e.into_inner());
        for a in ab.values() {
            if a.camera.eq_ignore_ascii_case(camera) && a.start_ms <= to && a.end_ms >= from {
                out.push(Interacao { start_ms: a.start_ms, end_ms: a.end_ms, kind: a.kind.clone(), detail: a.detalhe() });
            }
        }
        out
    }
}

impl Drop for InteractionLog {
    fn drop(&mut self) {
        self.fechar_todas();
    }
}

pub fn to_json(camera: &str, from: i64, to: i64, l: &[Interacao]) -> Value {
    json!({
        "camera": camera,
        "fromMs": from,
        "toMs": to,
        "count": l.len(),
        "interactions": l.iter().map(|i| json!({ "startMs": i.start_ms, "endMs": i.end_ms, "kind": i.kind, "detail": i.detail })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::clock::ManualClock;

    #[test]
    fn junta_em_trechos_e_grava_ao_fechar() {
        let db = Db::memory("interacao");
        crate::db::ensure_schema(&db, 1).unwrap();
        db.exec("INSERT INTO camera (name, created_at_ms, updated_at_ms) VALUES ('Frente', 0, 0)", p![]).unwrap();
        let clock = Arc::new(ManualClock::new(1_000_000));
        let l = InteractionLog::new(Some(db.clone()), clock.clone(), vms_core::log::null());
        l.registrar("Frente", INTERACAO_PTZ, "mover");
        clock.advance(5000);
        l.registrar("frente", INTERACAO_PTZ, "parar");
        l.registrar("frente", INTERACAO_FALA, "");
        let q = l.consultar("FRENTE", 999_000, 1_010_000);
        assert_eq!(q.len(), 2, "os abertos aparecem");
        let ptz = q.iter().find(|i| i.kind == "ptz").unwrap();
        assert_eq!((ptz.start_ms, ptz.end_ms), (1_000_000, 1_005_000));
        assert_eq!(ptz.detail, "mover x1, parar x1");

        clock.advance(GAP_MS + 1);
        l.varrer();
        db.flush();
        assert_eq!(db.query_i64("SELECT COUNT(*) FROM interaction", p![], 0), 2);
        // Depois do intervalo, é outro trecho.
        l.registrar("Frente", INTERACAO_PTZ, "mover");
        assert_eq!(l.consultar("Frente", 999_000, 2_000_000).len(), 3);
        let j = to_json("Frente", 1, 2, &q);
        assert_eq!(j["count"], 2);
        assert_eq!(j["interactions"][0]["kind"].as_str().map(|s| s == "ptz" || s == "fala"), Some(true));
        db.close();
    }
}
