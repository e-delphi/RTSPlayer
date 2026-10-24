//! RTSPlayer — o exe. Tudo mora na biblioteca (`src/lib.rs`); aqui fica só o
//! subsistema GUI (sem console) e a chamada de entrada.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    rtsplayer::run_app();
}
