//! O banco do vmsserver (SQLite, WAL): configuração, inventário das gravações,
//! eventos, miniaturas, interações e log. O vídeo fica fora — é `.vms`.
//!
//! Duas conexões: uma para quem pergunta e espera (leituras, escritas que
//! precisam do resultado), e uma thread dona da outra, para quem só quer gravar
//! e seguir (`post`) — a sessão RTSP que loga não pode esperar disco.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use rusqlite::types::Value;
use rusqlite::{params_from_iter, Connection, Row};

pub type Params = Vec<Value>;

/// `p![a, b, c]` → parâmetros posicionais.
#[macro_export]
macro_rules! p {
    () => { Vec::<rusqlite::types::Value>::new() };
    ($($x:expr),+ $(,)?) => { vec![$($crate::db::IntoDb::into_db($x)),+] };
}

/// O que pode ir como parâmetro no `p!`.
pub trait IntoDb {
    fn into_db(self) -> Value;
}

impl IntoDb for &str {
    fn into_db(self) -> Value {
        Value::Text(self.to_owned())
    }
}
impl IntoDb for &String {
    fn into_db(self) -> Value {
        Value::Text(self.clone())
    }
}
impl IntoDb for String {
    fn into_db(self) -> Value {
        Value::Text(self)
    }
}
impl IntoDb for f64 {
    fn into_db(self) -> Value {
        Value::Real(self)
    }
}
impl IntoDb for bool {
    fn into_db(self) -> Value {
        Value::Integer(self as i64)
    }
}
impl IntoDb for Value {
    fn into_db(self) -> Value {
        self
    }
}
impl IntoDb for &[u8] {
    fn into_db(self) -> Value {
        Value::Blob(self.to_vec())
    }
}
impl IntoDb for Vec<u8> {
    fn into_db(self) -> Value {
        Value::Blob(self)
    }
}
impl<T: IntoDb> IntoDb for Option<T> {
    fn into_db(self) -> Value {
        self.map(IntoDb::into_db).unwrap_or(Value::Null)
    }
}
macro_rules! into_db_int {
    ($($t:ty),*) => { $(impl IntoDb for $t { fn into_db(self) -> Value { Value::Integer(self as i64) } })* };
}
into_db_int!(i64, i32, u32, u16, u8, usize, u64);

#[derive(Debug)]
pub struct DbError(pub String);

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DbError {}

impl From<rusqlite::Error> for DbError {
    fn from(e: rusqlite::Error) -> Self {
        DbError(e.to_string())
    }
}

pub type DbResult<T> = Result<T, DbError>;

enum Job {
    Exec(String, Params),
    Script(String),
    Flush(Sender<()>),
}

pub struct Db {
    path: PathBuf,
    conn: Mutex<Connection>,
    tx: Mutex<Option<Sender<Job>>>,
    writer: Mutex<Option<JoinHandle<()>>>,
    pending: Arc<AtomicUsize>,
}

fn open_conn(path: &Path) -> DbResult<Connection> {
    let c = Connection::open(path)?;
    c.busy_timeout(std::time::Duration::from_secs(10))?;
    c.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")?;
    Ok(c)
}

impl Db {
    pub fn open(path: &Path) -> DbResult<Arc<Db>> {
        if let Some(d) = path.parent() {
            if !d.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(d);
            }
        }
        let conn = open_conn(path)?;
        let wconn = open_conn(path)?;
        let (tx, rx) = channel::<Job>();
        let pending = Arc::new(AtomicUsize::new(0));
        let pend = pending.clone();
        let writer = std::thread::Builder::new()
            .name("db-writer".into())
            .spawn(move || {
                for job in rx {
                    match job {
                        Job::Exec(sql, params) => {
                            if let Err(e) = wconn.execute(&sql, params_from_iter(params.iter())) {
                                // Falha do log NÃO vai para o log (geraria outra
                                // escrita); vai para o console de emergência.
                                eprintln!("[db] escrita assincrona falhou: {e} -- {}", sql.chars().take(120).collect::<String>());
                            }
                            pend.fetch_sub(1, Ordering::SeqCst);
                        }
                        Job::Script(s) => {
                            if let Err(e) = wconn.execute_batch(&s) {
                                eprintln!("[db] script assincrono falhou: {e}");
                            }
                            pend.fetch_sub(1, Ordering::SeqCst);
                        }
                        Job::Flush(done) => {
                            let _ = done.send(());
                        }
                    }
                }
                let _ = wconn.execute_batch("PRAGMA optimize;");
            })
            .map_err(|e| DbError(e.to_string()))?;
        Ok(Arc::new(Db {
            path: path.to_path_buf(),
            conn: Mutex::new(conn),
            tx: Mutex::new(Some(tx)),
            writer: Mutex::new(Some(writer)),
            pending,
        }))
    }

    /// Um banco em memória compartilhada (teste): as duas conexões veem o mesmo.
    pub fn memory(tag: &str) -> Arc<Db> {
        let dir = std::env::temp_dir().join(format!("vmsdb-{}-{tag}-{}", std::process::id(), vms_core::clock::unix_ms()));
        let _ = std::fs::create_dir_all(&dir);
        Db::open(&dir.join("t.db")).expect("banco de teste")
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub fn exec(&self, sql: &str, params: Params) -> DbResult<usize> {
        Ok(self.conn().execute(sql, params_from_iter(params.iter()))?)
    }

    pub fn exec_script(&self, sql: &str) -> DbResult<()> {
        Ok(self.conn().execute_batch(sql)?)
    }

    /// Uma linha → um valor, para cada linha.
    pub fn query<T>(&self, sql: &str, params: Params, mut f: impl FnMut(&Row) -> rusqlite::Result<T>) -> DbResult<Vec<T>> {
        let c = self.conn();
        let mut st = c.prepare(sql)?;
        let rows = st.query_map(params_from_iter(params.iter()), |r| f(r))?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }

    pub fn query_i64(&self, sql: &str, params: Params, default: i64) -> i64 {
        self.query(sql, params, |r| r.get::<_, i64>(0)).ok().and_then(|v| v.into_iter().next()).unwrap_or(default)
    }

    pub fn query_string(&self, sql: &str, params: Params) -> Option<String> {
        self.query(sql, params, |r| r.get::<_, String>(0)).ok().and_then(|v| v.into_iter().next())
    }

    /// Colunas e linhas como texto (o `/api/sql`).
    pub fn query_table(&self, sql: &str, limit: usize) -> DbResult<(Vec<String>, Vec<Vec<Option<String>>>, usize)> {
        let c = self.conn();
        let mut st = c.prepare(sql)?;
        let cols: Vec<String> = st.column_names().iter().map(|s| s.to_string()).collect();
        let n = cols.len();
        let mut rows = st.query([])?;
        let mut out = Vec::new();
        let mut scanned = 0;
        while let Some(r) = rows.next()? {
            scanned += 1;
            if out.len() >= limit {
                continue;
            }
            let mut line = Vec::with_capacity(n);
            for i in 0..n {
                let v: Value = r.get(i)?;
                line.push(match v {
                    Value::Null => None,
                    Value::Integer(x) => Some(x.to_string()),
                    Value::Real(x) => Some(x.to_string()),
                    Value::Text(t) => Some(t),
                    Value::Blob(b) => Some(format!("<{} bytes>", b.len())),
                });
            }
            out.push(line);
        }
        Ok((cols, out, scanned))
    }

    /// Grava sem esperar. Falha vai para o console de emergência.
    pub fn post(&self, sql: &str, params: Params) {
        if let Some(tx) = self.tx.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
            self.pending.fetch_add(1, Ordering::SeqCst);
            if tx.send(Job::Exec(sql.to_owned(), params)).is_err() {
                self.pending.fetch_sub(1, Ordering::SeqCst);
            }
        }
    }

    pub fn post_script(&self, sql: &str) {
        if let Some(tx) = self.tx.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
            self.pending.fetch_add(1, Ordering::SeqCst);
            let _ = tx.send(Job::Script(sql.to_owned()));
        }
    }

    pub fn pending(&self) -> usize {
        self.pending.load(Ordering::SeqCst)
    }

    /// Espera a fila assíncrona esvaziar (teste, desligamento).
    pub fn flush(&self) {
        let (tx, rx) = channel();
        if let Some(q) = self.tx.lock().unwrap_or_else(|p| p.into_inner()).as_ref() {
            if q.send(Job::Flush(tx)).is_ok() {
                let _ = rx.recv();
            }
        }
    }

    /// Fecha a fila (drena o que estiver nela) e a thread escritora.
    pub fn close(&self) {
        self.tx.lock().unwrap_or_else(|p| p.into_inner()).take();
        if let Some(h) = self.writer.lock().unwrap_or_else(|p| p.into_inner()).take() {
            let _ = h.join();
        }
    }
}

impl Drop for Db {
    fn drop(&mut self) {
        self.close();
    }
}

// ------------------------------------------------------------------ esquema

pub const SCHEMA_SQL: &str = include_str!("schema-v1.sql");
pub const SCHEMA_VERSION: i64 = 1;

/// O bloco de padrões do `setting` (INSERT OR IGNORE): rodar de novo
/// acrescenta o que a versão nova trouxe e não toca no que o usuário mudou.
pub fn settings_seed_sql() -> &'static str {
    let a = SCHEMA_SQL.find("INSERT OR IGNORE INTO setting").unwrap_or(0);
    let b = SCHEMA_SQL[a..].find("PRAGMA user_version").map(|x| a + x).unwrap_or(SCHEMA_SQL.len());
    &SCHEMA_SQL[a..b]
}

/// Deixa o banco na versão que este executável entende. Banco MAIS NOVO é
/// erro: um binário antigo sobre arquivo novo escreveria pela metade.
pub fn ensure_schema(db: &Db, now_ms: i64) -> DbResult<String> {
    let v = db.query_i64("PRAGMA user_version", p![], 0);
    if v > SCHEMA_VERSION {
        return Err(DbError(format!(
            "o banco {} esta na versao {v} e este vmsserver entende ate a {SCHEMA_VERSION}. Use o executavel novo, ou guarde este arquivo e comece outro.",
            db.path().display()
        )));
    }
    if v == SCHEMA_VERSION {
        if let Err(e) = db.exec_script(settings_seed_sql()) {
            return Ok(format!("esquema v{v}, em dia (nao consegui semear ajustes novos: {e})"));
        }
        return Ok(format!("esquema v{v}, em dia"));
    }
    if v != 0 {
        return Err(DbError(format!("o banco {} esta na versao {v} e nao ha passo de atualizacao dela para a {SCHEMA_VERSION}", db.path().display())));
    }
    db.exec_script(SCHEMA_SQL).map_err(|e| DbError(format!("nao consegui criar o esquema em {}: {e}. Apague o arquivo e suba de novo.", db.path().display())))?;
    db.exec("INSERT OR IGNORE INTO db_meta (key, value) VALUES (?, ?)", p!["created_at_ms", now_ms.to_string()])?;
    db.exec("INSERT OR REPLACE INTO db_meta (key, value) VALUES (?, ?)", p!["schema_version", SCHEMA_VERSION.to_string()])?;
    db.exec(
        "INSERT OR REPLACE INTO db_meta (key, value) VALUES (?, ?)",
        p!["exe", std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default()],
    )?;
    Ok(format!("banco novo: esquema v{SCHEMA_VERSION} criado"))
}

/// Uma linha para o log da subida.
pub fn describe(db: &Db) -> String {
    let tabelas = db.query_i64("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'", p![], 0);
    let bytes = std::fs::metadata(db.path()).map(|m| m.len()).unwrap_or(0);
    format!("{} (v{SCHEMA_VERSION}, {tabelas} tabelas, {} KB)", db.path().display(), bytes / 1024)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cria_o_esquema_e_reabre_em_dia() {
        let db = Db::memory("schema");
        assert!(ensure_schema(&db, 1).unwrap().contains("criado"));
        assert_eq!(db.query_i64("PRAGMA user_version", p![], 0), 1);
        assert_eq!(db.query_string("SELECT value FROM setting WHERE key = ?", p!["rtspPort"]).as_deref(), Some("8554"));
        assert!(ensure_schema(&db, 1).unwrap().contains("em dia"));
        // CHECK de verdade: score impossível é recusado.
        db.exec("INSERT INTO camera (name, created_at_ms, updated_at_ms) VALUES ('a', 0, 0)", p![]).unwrap();
        let r = db.exec("INSERT INTO event (camera_id, start_ms, end_ms, kind, name, score, created_at_ms) VALUES (1, 0, 0, 0, 'm', 17, 0)", p![]);
        assert!(r.is_err());
    }

    #[test]
    fn post_assincrono_e_tabela_de_texto() {
        let db = Db::memory("post");
        ensure_schema(&db, 1).unwrap();
        db.post("INSERT INTO db_meta (key, value) VALUES (?, ?)", p!["x", "1"]);
        db.flush();
        assert_eq!(db.query_string("SELECT value FROM db_meta WHERE key = 'x'", p![]).as_deref(), Some("1"));
        let (cols, rows, n) = db.query_table("SELECT key, value FROM db_meta WHERE key = 'x'", 10).unwrap();
        assert_eq!(cols, vec!["key", "value"]);
        assert_eq!(rows[0][1].as_deref(), Some("1"));
        assert_eq!(n, 1);
        assert!(settings_seed_sql().starts_with("INSERT OR IGNORE INTO setting"));
    }

    #[test]
    fn banco_mais_novo_e_recusado() {
        let db = Db::memory("novo");
        db.exec_script("PRAGMA user_version = 9;").unwrap();
        assert!(ensure_schema(&db, 1).is_err());
    }
}
