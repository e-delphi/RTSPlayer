//! Fala: áudio que vai PARA a câmera tocar no alto-falante (OPTalk).
//!
//! ```text
//! login → Claim (1434, espera Ret=100) → Start (1430)
//!       → um frame a cada 40 ms no 1432 (8 bytes de sub-header + 320 de A-law)
//!       → Stop (1430) e desconecta
//! ```
//!
//! Duas threads: o RITMO tira da fila um quadro a cada 40 ms (a página entrega
//! aos pedaços, a câmera toca em tempo real); o LEITOR drena o microfone da
//! câmera, que volta por esta conexão — com o buffer TCP cheio ela para.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::protocol::*;
use crate::error::Error;
use crate::g711;
use crate::log::SharedLogger;
use crate::net::TcpConn;
use crate::ptz::FalaSession;
use crate::stop::StopToken;

const PERIODO_MS: u64 = 40;
/// Folga antes de tocar (e depois de a fila secar): o POST não é pontual.
const PREENCHER: usize = OPTALK_QUADRO * 8;
/// Teto da fila (~1,5 s): acima disto, atraso é pior que um corte.
const FILA_MAX: usize = OPTALK_QUADRO * 38;
/// Sem áudio por isto, com a fila vazia, a conversa se encerra sozinha.
pub const OCIOSA_MS: u64 = 3000;
const ATRASO_MAX_MS: u64 = 200;

struct Fila {
    alaw: Vec<u8>,
    enchendo: bool,
    ultimo_enviar: Instant,
}

struct Estado {
    writer: DvripWriter,
    fila: Mutex<Fila>,
    parar: StopToken,
    viva: AtomicBool,
    log: SharedLogger,
    tag: String,
    quadros: AtomicU32,
    faltas: AtomicU32,
    descartados: AtomicU64,
    recebidos: AtomicU64,
}

pub struct DvripTalk {
    st: Arc<Estado>,
    threads: Mutex<Vec<JoinHandle<()>>>,
    fechou: AtomicBool,
}

impl DvripTalk {
    /// Conecta, loga, Claim e Start.
    pub fn abrir(host: &str, port: u16, user: &str, password: &str, timeout_ms: u64, log: SharedLogger, tag: &str) -> Result<Arc<DvripTalk>, String> {
        let r = (|| -> Result<(DvripReader, DvripWriter), String> {
            let t = Duration::from_millis(timeout_ms.max(1000));
            let c = TcpConn::connect(host, port, timeout_ms.max(1000)).map_err(|e| format!("fala: {e}"))?;
            let w = DvripWriter::new(Box::new(c.try_clone().map_err(|e| e.to_string())?));
            let mut rd = DvripReader::new(Box::new(c));
            login(&mut rd, &w, user, password, t).map_err(|e| match e {
                Error::Auth(_) => "login DVRIP da fala falhou".to_owned(),
                e => format!("fala: {e}"),
            })?;
            w.send_cmd(OPTALK_CLAIM, &talk_json("Claim", w.session())).map_err(|e| e.to_string())?;
            ler_claim(&mut rd, &log, tag)?;
            // A resposta do Start chega pelo leitor, que a põe no log.
            w.send_cmd(OPTALK, &talk_json("Start", w.session())).map_err(|e| e.to_string())?;
            Ok((rd, w))
        })();
        let (rd, w) = match r {
            Ok(x) => x,
            Err(m) => {
                log.warn(tag, &m);
                return Err(m);
            }
        };
        let st = Arc::new(Estado {
            writer: w,
            fila: Mutex::new(Fila { alaw: Vec::new(), enchendo: true, ultimo_enviar: Instant::now() }),
            parar: StopToken::new(),
            viva: AtomicBool::new(true),
            log: log.clone(),
            tag: tag.to_owned(),
            quadros: AtomicU32::new(0),
            faltas: AtomicU32::new(0),
            descartados: AtomicU64::new(0),
            recebidos: AtomicU64::new(0),
        });
        let s1 = st.clone();
        let s2 = st.clone();
        let threads = vec![
            std::thread::Builder::new().name("fala-ritmo".into()).spawn(move || laco_ritmo(&s1)).unwrap(),
            std::thread::Builder::new().name("fala-leitor".into()).spawn(move || laco_leitor(&s2, rd)).unwrap(),
        ];
        log.info(tag, &format!("fala aberta em {host}:{port} (SessionID=0x{:x})", st.writer.session()));
        Ok(Arc::new(DvripTalk { st, threads: Mutex::new(threads), fechou: AtomicBool::new(false) }))
    }
}

/// A resposta do Claim pode vir depois de outra mensagem (AlarmInfo).
fn ler_claim(rd: &mut DvripReader, log: &SharedLogger, tag: &str) -> Result<(), String> {
    for _ in 0..6 {
        let (h, p) = match rd.recv(Duration::from_millis(3000)) {
            Ok(x) => x,
            Err(Error::Timeout(_)) => return Err("a camera nao respondeu ao OPTalk Claim".into()),
            Err(e) => return Err(format!("resposta do OPTalk Claim ilegivel: {e}")),
        };
        let resp = String::from_utf8_lossy(&p).into_owned();
        if h.msg_id != OPTALK_CLAIM_RSP && h.msg_id != OPTALK_CLAIM && !resp.contains("OPTalk") {
            log.debug(tag, &format!("antes do Claim, MsgID={}: {}", h.msg_id, resp.trim_end_matches(['\n', '\0'])));
            continue;
        }
        let ret = json_get_int(&resp, "Ret", -1);
        log.info(tag, &format!("OPTalk Claim Ret={ret}"));
        if ret == 100 {
            return Ok(());
        }
        // Câmera sem alto-falante, ou com outra conversa aberta.
        return Err(format!("a camera recusou a fala (OPTalk Claim Ret={ret})"));
    }
    Err("a camera nao respondeu ao OPTalk Claim".into())
}

fn laco_ritmo(st: &Estado) {
    let mut proximo = Instant::now();
    let mut ultimo_ka = Instant::now();
    let res: Result<(), Error> = (|| {
        loop {
            let agora = Instant::now();
            // Relógio absoluto: a imprecisão de um sono se compensa no seguinte.
            let espera = proximo.saturating_duration_since(agora).as_millis() as u64;
            if st.parar.wait_ms(espera) {
                return Ok(());
            }
            proximo += Duration::from_millis(PERIODO_MS);
            let agora = Instant::now();
            if agora > proximo + Duration::from_millis(ATRASO_MAX_MS) {
                proximo = agora;
            }
            let (quadro, ocioso) = {
                let mut f = st.fila.lock().unwrap_or_else(|p| p.into_inner());
                if f.enchendo && f.alaw.len() >= PREENCHER {
                    f.enchendo = false;
                }
                let mut q = None;
                if !f.enchendo {
                    if f.alaw.len() >= OPTALK_QUADRO {
                        q = Some(f.alaw.drain(..OPTALK_QUADRO).collect::<Vec<u8>>());
                    } else {
                        // Secou: a pessoa parou de falar, ou o POST atrasou.
                        f.enchendo = true;
                        st.faltas.fetch_add(1, Ordering::Relaxed);
                    }
                }
                let ocioso = f.alaw.is_empty() && agora.saturating_duration_since(f.ultimo_enviar) > Duration::from_millis(OCIOSA_MS);
                (q, ocioso)
            };
            if let Some(q) = quadro {
                st.writer.send_bin(OPTALK_DATA, &talk_frame(&q))?;
                st.quadros.fetch_add(1, Ordering::Relaxed);
            }
            if ultimo_ka.elapsed() >= Duration::from_secs(10) {
                st.writer.send_cmd(KEEPALIVE, &keepalive_json(st.writer.session()))?;
                ultimo_ka = Instant::now();
            }
            if ocioso {
                st.log.info(&st.tag, "fala sem audio ha mais de 3 s; encerrando");
                return Ok(());
            }
        }
    })();
    if let Err(e) = res {
        if !st.parar.is_stopped() {
            st.log.warn(&st.tag, &format!("fala: {e}"));
        }
    }
    // O encerramento é todo daqui: um só, venha de onde vier o fim.
    st.viva.store(false, Ordering::SeqCst);
    st.parar.stop();
    // "Stop" não foi visto em captura: se a câmera entender, solta o
    // alto-falante na hora.
    let _ = st.writer.send_cmd(OPTALK, &talk_json("Stop", st.writer.session()));
    st.writer.close();
    let q = st.quadros.load(Ordering::Relaxed);
    st.log.info(
        &st.tag,
        &format!(
            "fala encerrada: {q} quadros ({} ms), {} buracos, {} bytes descartados, {} bytes recebidos da camera",
            q as u64 * PERIODO_MS,
            st.faltas.load(Ordering::Relaxed),
            st.descartados.load(Ordering::Relaxed),
            st.recebidos.load(Ordering::Relaxed)
        ),
    );
}

fn laco_leitor(st: &Estado, mut rd: DvripReader) {
    while !st.parar.is_stopped() {
        match rd.recv_resync(Duration::from_millis(500), st.writer.session()) {
            Ok((h, p, _, _)) => {
                if classify(h.msg_id) != MsgKind::Media && looks_like_json(&p) {
                    st.log.info(&st.tag, &format!("fala MsgID={}: {}", h.msg_id, String::from_utf8_lossy(&p).trim_end_matches(['\n', '\0'])));
                } else {
                    st.recebidos.fetch_add(p.len() as u64, Ordering::Relaxed);
                }
            }
            // A câmera pode nem mandar o microfone dela.
            Err(Error::Timeout(_)) => {}
            Err(e) => {
                if !st.parar.is_stopped() {
                    st.log.warn(&st.tag, &format!("fala, leitura: {e}"));
                }
                st.viva.store(false, Ordering::SeqCst);
                st.parar.stop();
                break;
            }
        }
    }
}

impl FalaSession for DvripTalk {
    fn enviar(&self, pcm: &[u8]) -> bool {
        if !self.st.viva.load(Ordering::SeqCst) {
            return false;
        }
        let a = g711::pcm16le_to_alaw(pcm);
        if a.is_empty() {
            return true;
        }
        let mut f = self.st.fila.lock().unwrap_or_else(|p| p.into_inner());
        f.alaw.extend_from_slice(&a);
        if f.alaw.len() > FILA_MAX {
            let sobra = f.alaw.len() - FILA_MAX;
            f.alaw.drain(..sobra);
            self.st.descartados.fetch_add(sobra as u64, Ordering::Relaxed);
        }
        f.ultimo_enviar = Instant::now();
        true
    }

    fn fechar(&self) {
        if self.fechou.swap(true, Ordering::SeqCst) {
            return;
        }
        self.st.parar.stop();
        let hs: Vec<_> = std::mem::take(&mut *self.threads.lock().unwrap_or_else(|p| p.into_inner()));
        for h in hs {
            let _ = h.join();
        }
        self.st.viva.store(false, Ordering::SeqCst);
    }

    fn viva(&self) -> bool {
        self.st.viva.load(Ordering::SeqCst)
    }
}

impl Drop for DvripTalk {
    fn drop(&mut self) {
        self.fechar();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    fn rd(s: &mut std::net::TcpStream) -> Option<(u16, Vec<u8>)> {
        let mut h = [0u8; 20];
        s.read_exact(&mut h).ok()?;
        let hd = decode_header(&h);
        let mut p = vec![0u8; hd.data_len as usize];
        s.read_exact(&mut p).ok()?;
        Some((hd.msg_id, p))
    }

    #[test]
    fn fala_manda_quadros_no_ritmo_e_encerra() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let srv = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            assert_eq!(rd(&mut s).unwrap().0, LOGIN);
            s.write_all(&encode_cmd(7, 0, LOGIN_RSP, "{ \"Ret\" : 100, \"SessionID\" : \"0x00000007\" }")).unwrap();
            assert_eq!(rd(&mut s).unwrap().0, OPTALK_CLAIM);
            s.write_all(&encode_cmd(7, 0, OPTALK_CLAIM_RSP, "{ \"Name\" : \"OPTalk\", \"Ret\" : 100 }")).unwrap();
            assert_eq!(rd(&mut s).unwrap().0, OPTALK);
            let mut quadros = 0;
            let mut stop = false;
            while let Some((id, p)) = rd(&mut s) {
                if id == OPTALK_DATA {
                    assert_eq!(p.len(), 328);
                    quadros += 1;
                }
                if id == OPTALK && String::from_utf8_lossy(&p).contains("Stop") {
                    stop = true;
                }
            }
            (quadros, stop)
        });
        let t = DvripTalk::abrir("127.0.0.1", port, "admin", "", 2000, crate::log::null(), "t").unwrap();
        // 400 ms de áudio: 10 quadros.
        assert!(t.enviar(&vec![0u8; 8000 * 2 * 400 / 1000]));
        std::thread::sleep(Duration::from_millis(900));
        t.fechar();
        assert!(!t.viva());
        assert!(!t.enviar(&[0, 0]));
        let (quadros, stop) = srv.join().unwrap();
        assert_eq!(quadros, 10);
        assert!(stop);
    }

    #[test]
    fn claim_recusado_vira_motivo() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            rd(&mut s);
            s.write_all(&encode_cmd(7, 0, LOGIN_RSP, "{ \"Ret\" : 100, \"SessionID\" : \"0x7\" }")).unwrap();
            rd(&mut s);
            s.write_all(&encode_cmd(7, 0, OPTALK_CLAIM_RSP, "{ \"Name\" : \"OPTalk\", \"Ret\" : 503 }")).unwrap();
            std::thread::sleep(Duration::from_millis(200));
        });
        let e = DvripTalk::abrir("127.0.0.1", port, "a", "", 2000, crate::log::null(), "t").err().unwrap();
        assert!(e.contains("Ret=503"), "{e}");
    }
}
