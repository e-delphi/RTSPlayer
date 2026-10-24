//! Fila de trabalho para a main thread (a do WebView2, STA). O loop é Win32
//! puro, então nada drena sozinho: `queue` guarda o closure e posta
//! `WM_APP_WAKE` na janela; o `WndProc` chama `drain`.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::Mutex;

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WM_APP};

pub const WM_APP_WAKE: u32 = WM_APP + 1;

type Job = Box<dyn FnOnce() + Send + 'static>;

static QUEUE: Mutex<VecDeque<Job>> = Mutex::new(VecDeque::new());
static WAKE_HWND: AtomicIsize = AtomicIsize::new(0);

pub fn set_wake_window(hwnd: HWND) {
    WAKE_HWND.store(hwnd.0 as isize, Ordering::SeqCst);
}

/// Roda `job` na main thread. Seguro de qualquer thread.
pub fn queue(job: impl FnOnce() + Send + 'static) {
    QUEUE.lock().unwrap_or_else(|p| p.into_inner()).push_back(Box::new(job));
    let hwnd = WAKE_HWND.load(Ordering::SeqCst);
    if hwnd != 0 {
        // SAFETY: só posta uma mensagem; janela inválida apenas falha.
        unsafe {
            let _ = PostMessageW(Some(HWND(hwnd as *mut _)), WM_APP_WAKE, WPARAM(0), LPARAM(0));
        }
    }
}

/// Roda o que estiver pendente. Só o `WndProc` chama.
pub fn drain() {
    loop {
        // O lock sai antes de rodar: o job pode enfileirar outro.
        let job = QUEUE.lock().unwrap_or_else(|p| p.into_inner()).pop_front();
        match job {
            Some(job) => {
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
            }
            None => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Arc;

    #[test]
    fn drena_em_ordem_e_sobrevive_a_panico() {
        let n = Arc::new(AtomicUsize::new(0));
        let (a, b) = (n.clone(), n.clone());
        queue(move || {
            a.fetch_add(1, Ordering::SeqCst);
        });
        queue(|| panic!("falha de uma tarefa"));
        queue(move || {
            b.fetch_add(10, Ordering::SeqCst);
        });
        drain();
        assert_eq!(n.load(Ordering::SeqCst), 11);
    }
}
