//! Onde a rota HTTP encontra a sessão viva de uma câmera, para mandar PTZ e
//! abrir a fala.
//!
//! O comando sai pela conexão que JÁ está autenticada — logar de novo a cada
//! clique custaria um login por toque. Quem tem sessão viva se anuncia pelo
//! nome da câmera; quem quer mandar comando procura. Sessão que cai se
//! desanuncia, e a procura devolve `None`: é como a rota sabe dizer "essa
//! câmera não está conectada".

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::json;

/// O que uma sessão capaz de PTZ oferece. `iniciar = false` é a PARADA do
/// mesmo comando — no DVRIP andar e parar são a mesma mensagem.
pub trait PtzSession: Send + Sync {
    fn mover_ptz(&self, comando: &str, passo: i32, canal: i32, iniciar: bool) -> bool;
    /// Comando vazio = ir para o preset.
    fn ir_para_preset(&self, preset: i32, canal: i32, comando: &str) -> bool;
    /// Pede uma seção da configuração; a resposta vai para o log.
    fn perguntar_config(&self, nome: &str) -> bool;
    /// Abre a fala (conexão própria). Bloqueia até a câmera responder.
    fn abrir_fala(&self) -> Result<Arc<dyn FalaSession>, String>;
}

/// Uma conversa aberta com o alto-falante da câmera.
pub trait FalaSession: Send + Sync {
    /// PCM 16 bits LE, 8 kHz, mono. `false` = a conversa já acabou.
    fn enviar(&self, pcm: &[u8]) -> bool;
    /// Encerra e espera as threads. Duas vezes não faz mal.
    fn fechar(&self);
    fn viva(&self) -> bool;
}

type Map<T> = Mutex<HashMap<String, T>>;

fn chave(camera: &str) -> String {
    camera.trim().to_lowercase()
}

fn ptz_map() -> &'static Map<Arc<dyn PtzSession>> {
    static M: OnceLock<Map<Arc<dyn PtzSession>>> = OnceLock::new();
    M.get_or_init(Default::default)
}

pub struct PtzRegistry;

impl PtzRegistry {
    /// Anunciar de novo substitui: reconexão troca a sessão.
    pub fn anunciar(camera: &str, s: Arc<dyn PtzSession>) {
        if camera.trim().is_empty() {
            return;
        }
        ptz_map().lock().unwrap_or_else(|p| p.into_inner()).insert(chave(camera), s);
    }

    /// Sai do registro só se ainda for ESTA sessão: uma reconexão que já se
    /// anunciou não pode ser apagada pela sessão velha que está saindo.
    pub fn apagar(camera: &str, s: &Arc<dyn PtzSession>) {
        let mut m = ptz_map().lock().unwrap_or_else(|p| p.into_inner());
        if m.get(&chave(camera)).is_some_and(|x| Arc::ptr_eq(x, s)) {
            m.remove(&chave(camera));
        }
    }

    pub fn achar(camera: &str) -> Option<Arc<dyn PtzSession>> {
        ptz_map().lock().unwrap_or_else(|p| p.into_inner()).get(&chave(camera)).cloned()
    }
}

fn fala_map() -> &'static Map<Arc<dyn FalaSession>> {
    static M: OnceLock<Map<Arc<dyn FalaSession>>> = OnceLock::new();
    M.get_or_init(Default::default)
}

/// As falas abertas, uma por câmera. A página manda o áudio em vários POSTs;
/// a primeira abre e as seguintes acham a mesma aqui.
pub struct FalaRegistry;

impl FalaRegistry {
    fn enviar(camera: &str, pcm: &[u8]) -> Result<(), String> {
        let k = chave(camera);
        // Duas voltas: a fala pode se encerrar por silêncio entre o achar e o
        // enviar, e aí a segunda volta abre outra.
        for _ in 0..2 {
            let fala = {
                // A trava fica presa durante a abertura, de propósito: dois POSTs
                // juntos no começo abririam duas conversas, e a câmera só tem um
                // alto-falante.
                let mut m = fala_map().lock().unwrap_or_else(|p| p.into_inner());
                if m.get(&k).is_some_and(|f| !f.viva()) {
                    m.remove(&k);
                }
                match m.get(&k) {
                    Some(f) => f.clone(),
                    None => {
                        let s = PtzRegistry::achar(camera).ok_or_else(|| format!("sem sessao DVRIP viva para {camera}"))?;
                        let f = s.abrir_fala()?;
                        m.insert(k.clone(), f.clone());
                        f
                    }
                }
            };
            if fala.enviar(pcm) {
                return Ok(());
            }
        }
        Err("a conversa com a camera caiu".into())
    }

    fn fechar(camera: &str) {
        let f = fala_map().lock().unwrap_or_else(|p| p.into_inner()).remove(&chave(camera));
        // Fora da trava: fechar espera as threads da fala.
        if let Some(f) = f {
            f.fechar();
        }
    }

    /// `/api/fala?camera=X&acao=testar|enviar|fechar`. Devolve (status, JSON).
    pub fn atender(camera: &str, acao: &str, pcm: &[u8]) -> (u16, String) {
        let mut status = 200;
        let (ok, motivo) = match acao {
            "testar" => {
                let ok = PtzRegistry::achar(camera).is_some();
                (ok, if ok { String::new() } else { format!("sem sessao DVRIP viva para {camera}") })
            }
            "enviar" if pcm.is_empty() => {
                status = 400;
                (false, "corpo vazio: mande PCM 16 bits, 8 kHz, mono".to_owned())
            }
            "enviar" => match Self::enviar(camera, pcm) {
                Ok(()) => (true, String::new()),
                Err(m) => (false, m),
            },
            "fechar" => {
                Self::fechar(camera);
                (true, String::new())
            }
            _ => {
                status = 400;
                (false, format!("{acao} nao existe: use testar, enviar ou fechar"))
            }
        };
        let mut j = json!({ "camera": camera, "acao": acao, "via": "dvrip", "ok": ok });
        if !motivo.is_empty() {
            j["motivo"] = json!(motivo);
        }
        (status, j.to_string())
    }
}

/// Dublês de câmera para os testes (deste crate, do servidor e do app).
pub mod fakes {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    #[derive(Default)]
    pub struct FalaFalsa {
        pub bytes: AtomicUsize,
        pub fechada: AtomicBool,
    }
    impl FalaSession for FalaFalsa {
        fn enviar(&self, pcm: &[u8]) -> bool {
            self.bytes.fetch_add(pcm.len(), Ordering::SeqCst);
            !self.fechada.load(Ordering::SeqCst)
        }
        fn fechar(&self) {
            self.fechada.store(true, Ordering::SeqCst);
        }
        fn viva(&self) -> bool {
            !self.fechada.load(Ordering::SeqCst)
        }
    }

    #[derive(Default)]
    pub struct PtzFalsa {
        pub comandos: Mutex<Vec<String>>,
        pub aberturas: AtomicUsize,
    }
    impl PtzSession for PtzFalsa {
        fn mover_ptz(&self, c: &str, p: i32, _: i32, i: bool) -> bool {
            self.comandos.lock().unwrap().push(format!("{c} {p} {i}"));
            true
        }
        fn ir_para_preset(&self, n: i32, _: i32, c: &str) -> bool {
            self.comandos.lock().unwrap().push(format!("preset {n} {c}"));
            true
        }
        fn perguntar_config(&self, n: &str) -> bool {
            self.comandos.lock().unwrap().push(format!("config {n}"));
            true
        }
        fn abrir_fala(&self) -> Result<Arc<dyn FalaSession>, String> {
            self.aberturas.fetch_add(1, Ordering::SeqCst);
            Ok(Arc::new(FalaFalsa::default()))
        }
    }

}

#[cfg(test)]
pub(crate) mod tests {
    pub use super::fakes::*;
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn registro_por_nome_sem_caixa_e_apagar_so_a_propria() {
        let a: Arc<dyn PtzSession> = Arc::new(PtzFalsa::default());
        let b: Arc<dyn PtzSession> = Arc::new(PtzFalsa::default());
        PtzRegistry::anunciar(" Reg1 ", a.clone());
        assert!(PtzRegistry::achar("reg1").is_some());
        PtzRegistry::anunciar("reg1", b.clone());
        PtzRegistry::apagar("reg1", &a);
        assert!(PtzRegistry::achar("REG1").is_some(), "a velha não apaga a nova");
        PtzRegistry::apagar("reg1", &b);
        assert!(PtzRegistry::achar("reg1").is_none());
    }

    #[test]
    fn fala_abre_uma_vez_e_fecha() {
        let p = Arc::new(PtzFalsa::default());
        let dyn_p: Arc<dyn PtzSession> = p.clone();
        PtzRegistry::anunciar("fala1", dyn_p.clone());
        let (st, j) = FalaRegistry::atender("fala1", "testar", &[]);
        assert_eq!(st, 200);
        assert!(j.contains("\"ok\":true"));
        assert_eq!(FalaRegistry::atender("fala1", "enviar", &[1, 2]).0, 200);
        assert_eq!(FalaRegistry::atender("fala1", "enviar", &[3]).0, 200);
        assert_eq!(p.aberturas.load(Ordering::SeqCst), 1);
        assert_eq!(FalaRegistry::atender("fala1", "enviar", &[]).0, 400);
        assert!(FalaRegistry::atender("fala1", "fechar", &[]).1.contains("\"ok\":true"));
        FalaRegistry::atender("fala1", "enviar", &[9]);
        assert_eq!(p.aberturas.load(Ordering::SeqCst), 2, "depois de fechar abre outra");
        PtzRegistry::apagar("fala1", &dyn_p);
        let (_, j) = FalaRegistry::atender("fala1", "testar", &[]);
        assert!(j.contains("sem sessao DVRIP viva"));
        assert_eq!(FalaRegistry::atender("fala1", "xyz", &[]).0, 400);
    }
}
