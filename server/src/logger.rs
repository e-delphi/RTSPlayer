//! O log em tabela, e no console ao mesmo tempo.
//!
//! `level` é coluna, nunca filtro. A escrita é `post` (assíncrona): quem loga
//! são as sessões que também leem RTP, e I/O de banco ali perderia pacote.
//! A câmera sai da tag (`session.frente` → `frente`); sem casar, fica NULL.

use std::sync::Arc;

use vms_core::clock::Clock;
use vms_core::log::{Level, Logger, SharedLogger};

use crate::db::Db;

pub struct DbLogger {
    db: Arc<Db>,
    clock: Arc<dyn Clock>,
    console: Option<SharedLogger>,
}

impl DbLogger {
    pub fn new(db: Arc<Db>, clock: Arc<dyn Clock>, console: Option<SharedLogger>) -> Self {
        Self { db, clock, console }
    }
}

pub fn camera_of_tag(tag: &str) -> &str {
    tag.find('.').map(|p| &tag[p + 1..]).unwrap_or("")
}

fn level_num(l: Level) -> i64 {
    match l {
        Level::Debug => 0,
        Level::Info => 1,
        Level::Warn => 2,
        Level::Error => 3,
    }
}

impl Logger for DbLogger {
    fn log(&self, level: Level, tag: &str, msg: &str) {
        if let Some(c) = &self.console {
            c.log(level, tag, msg);
        }
        self.db.post(
            "INSERT INTO log (at_ms, level, tag, camera_id, message) VALUES (?, ?, ?, (SELECT id FROM camera WHERE name = ?), ?)",
            p![self.clock.now_utc_ms(), level_num(level), tag, camera_of_tag(tag), msg],
        );
    }
}

/// Apaga as linhas anteriores a `keep_from_ms`. Falha não vira log (seria
/// escrever no log que se está limpando).
pub fn prune_log(db: &Db, keep_from_ms: i64) -> usize {
    db.exec("DELETE FROM log WHERE at_ms < ?", p![keep_from_ms]).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::clock::ManualClock;

    #[test]
    fn grava_com_a_camera_da_tag() {
        let db = Db::memory("logdb");
        crate::db::ensure_schema(&db, 1).unwrap();
        db.exec("INSERT INTO camera (name, created_at_ms, updated_at_ms) VALUES ('frente', 0, 0)", p![]).unwrap();
        let l = DbLogger::new(db.clone(), Arc::new(ManualClock::new(5000)), None);
        l.info("session.frente", "oi");
        l.warn("main", "geral");
        db.flush();
        assert_eq!(db.query_i64("SELECT COUNT(*) FROM log WHERE camera_id IS NOT NULL", p![], 0), 1);
        assert_eq!(db.query_i64("SELECT level FROM log WHERE tag = 'main'", p![], -1), 2);
        assert_eq!(prune_log(&db, 6000), 2);
        assert_eq!(camera_of_tag("a.b.c"), "b.c");
        db.close();
    }
}
