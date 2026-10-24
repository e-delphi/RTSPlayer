//! RTSPlayer: as câmeras do próprio app ao vivo e as gravações dos servidores
//! cadastrados, numa janela Win32 + WebView2 com a mesma interface web do
//! vmsserver.
//!
//! O app conecta nas câmeras com a MESMA sessão do servidor (`vms-core`), uma
//! por vez, e publica num anel em memória que a página lê por `/api/live`.
//! Gravações, eventos, miniaturas e ao vivo de servidor são do vmsserver: o app
//! encaminha (`app::App`).

pub mod app;
pub mod cameras;
pub mod live;
#[cfg(windows)]
pub mod mainthread;
pub mod servers;
#[cfg(windows)]
pub mod ui;
pub mod upstream;

#[cfg(windows)]
use std::sync::Arc;

#[cfg(windows)]
use vms_core::clock::{Clock, SystemClock};
#[cfg(windows)]
use vms_core::log::{ConsoleLogger, MemoryLogger, SharedLogger, TeeLogger};

/// A janela de verdade para o roteador.
#[cfg(windows)]
struct RealWindow;

#[cfg(windows)]
impl app::Window for RealWindow {
    fn sair(&self) {
        ui::request_close();
    }
    fn frente(&self, pedido: &str) -> Option<bool> {
        ui::set_topmost(pedido)
    }
}

/// O ponto de entrada do exe.
#[cfg(windows)]
pub fn run_app() {
    let memo = Arc::new(MemoryLogger::new(2000));
    let log: SharedLogger = if cfg!(debug_assertions) { Arc::new(TeeLogger(vec![memo.clone(), Arc::new(ConsoleLogger)])) } else { memo.clone() };
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let dir = app::data_dir_or(std::env::var_os("RTSPLAYER_DATA_DIR").map(std::path::PathBuf::from).as_deref());
    log.info("main", &format!("cadastro em {}", dir.display()));
    log.info("main", &vms_core::ui::describe());
    let a = app::App::new(app::AppDeps {
        dir,
        log: log.clone(),
        memo,
        clock: clock.clone(),
        upstream: Arc::new(upstream::WinHttp),
        starter: live::default_starter(log.clone(), clock),
        window: Arc::new(RealWindow),
    });
    let a2 = a.clone();
    ui::run(Arc::new(app::SharedApp(a)), move || {
        log.info("sair", "encerrando o ao vivo");
        a2.encerrar();
    });
}
