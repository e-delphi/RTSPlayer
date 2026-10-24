//! A porta única do servidor (8554 por padrão): RTSP para os players e HTTP
//! para a API e a interface. A primeira linha decide — `… RTSP/1.0` ou
//! `… HTTP/1.1` — e a conexão inteira segue por aquele protocolo.

pub mod packetizer;
pub mod sdp;
pub mod session;

use std::io::Read;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use vms_core::http::Handler;
use vms_core::stop::StopToken;

pub use session::Shared;

/// Lê até a primeira linha (ou 8 KB) e diz se é HTTP. Devolve o que leu.
pub fn sniff(s: &mut TcpStream) -> Option<(bool, Vec<u8>)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
    loop {
        if let Some(p) = buf.iter().position(|&b| b == b'\n') {
            let line = String::from_utf8_lossy(&buf[..p]).to_ascii_uppercase();
            return Some((line.trim_end().contains(" HTTP/"), buf));
        }
        if buf.len() > 8192 {
            return Some((false, buf));
        }
        match s.read(&mut chunk) {
            Ok(0) | Err(_) => return None,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
}

pub struct Listener {
    addr: SocketAddr,
    stop: StopToken,
    handle: Option<JoinHandle<()>>,
}

impl Listener {
    pub fn start(bind: &str, shared: Arc<Shared>, api: Option<Arc<dyn Handler>>) -> vms_core::Result<Listener> {
        let l = TcpListener::bind(bind).map_err(|e| vms_core::Error::Io(format!("bind {bind}: {e}")))?;
        let addr = l.local_addr()?;
        l.set_nonblocking(true)?;
        let stop = StopToken::new();
        let st = stop.clone();
        let log = shared.log.clone();
        log.info("tx.listener", &format!("servidor RTSP e HTTP em {addr}, gravacoes em {}", shared.storage.display()));
        let handle = std::thread::Builder::new()
            .name("tx-accept".into())
            .spawn(move || {
                while !st.is_stopped() {
                    let Ok((mut s, _)) = l.accept() else {
                        st.wait_ms(20);
                        continue;
                    };
                    let _ = s.set_nonblocking(false);
                    let (sh, api, st2) = (shared.clone(), api.clone(), st.clone());
                    let _ = std::thread::Builder::new().name("tx-conn".into()).spawn(move || {
                        let Some((http, initial)) = sniff(&mut s) else { return };
                        if http {
                            match api {
                                Some(h) => vms_core::http::serve_connection(s, initial, &*h),
                                None => {
                                    use std::io::Write;
                                    let _ = s.write_all(&vms_core::http::Response::error(404, "api indisponivel").serialize(false));
                                }
                            }
                        } else {
                            session::serve_rtsp(s, initial, sh, st2);
                        }
                    });
                }
            })
            .map_err(|e| vms_core::Error::Io(e.to_string()))?;
        Ok(Listener { addr, stop, handle: Some(handle) })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn stop(&mut self) {
        self.stop.stop();
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vms_core::clock::SystemClock;
    use vms_core::media::{Sample, VideoCodec};
    use vms_core::session::{RtspSession, SessionRun};
    use vms_core::sink::{MediaSink, RecordingSink};
    use vms_core::testutil::{write_vms, TempDir};

    /// O cliente RTSP do próprio projeto toca o que o servidor publica: pelo
    /// arquivo e pelo anel em memória. E o HTTP sai na mesma porta.
    #[test]
    fn publica_arquivo_e_ao_vivo_na_mesma_porta() {
        let d = TempDir::new("txsrv");
        let dir = vms_core::vms::paths::ensure_camera_dir(d.path(), "cam").unwrap();
        write_vms(&dir.join("cam_1.vms"), 1_000_000, 6, 200, true);
        let log = vms_core::log::null();
        let clock: Arc<dyn vms_core::clock::Clock> = Arc::new(SystemClock);
        let hub = Arc::new(vms_core::live::LiveHub::new(Default::default(), log.clone(), clock.clone()));
        let live = hub.get_or_create("vivo");
        live.publish_video_format(VideoCodec::H264, 640, 360, &[0, 0, 0, 1, 0x67, 0x42, 0, 0x1E, 0, 0, 0, 1, 0x68, 0xCE]);
        let sh = Arc::new(Shared { storage: d.path().to_path_buf(), hub: Some(hub), log: log.clone(), clock: clock.clone() });
        let api: Arc<dyn Handler> = Arc::new(|_: &vms_core::http::Request| vms_core::http::Response::text(200, "text/plain", "oi"));
        let srv = Listener::start("127.0.0.1:0", sh, Some(api)).unwrap();
        let port = srv.addr().port();

        let r = vms_core::http::fetch("GET", &format!("http://127.0.0.1:{port}/x"), &[], &[], Duration::from_secs(5)).unwrap();
        assert_eq!(r.body_text(), "oi");

        // Arquivo (ao vivo pelo arquivo, sem anel para "cam").
        let mut t = vms_core::net::TcpConn::connect("127.0.0.1", port, 5000).unwrap();
        use vms_core::net::Conn;
        const CRLF: &str = "\r\n";
        t.send(format!("DESCRIBE rtsp://127.0.0.1:{port}/live/cam RTSP/1.0{CRLF}CSeq: 2{CRLF}{CRLF}").as_bytes()).unwrap();
        let resp = vms_core::rtsp::wire::WireReader::new().read_response(&mut t, Duration::from_secs(5)).unwrap();
        assert_eq!(resp.status, 200);
        let sdp = resp.body_text();
        assert!(sdp.contains("H264/90000"), "{sdp}");
        assert!(sdp.contains("x-vms-source:file"));
        t.send(format!("DESCRIBE rtsp://127.0.0.1:{port}/live/nada RTSP/1.0{CRLF}CSeq: 3{CRLF}{CRLF}").as_bytes()).unwrap();
        let resp = vms_core::rtsp::wire::WireReader::new().read_response(&mut t, Duration::from_secs(5)).unwrap();
        assert_eq!(resp.status, 404);
        drop(t);

        // Ao vivo pela memória: a sessão do app recebe o que se publica.
        let sink = Arc::new(RecordingSink::default());
        let cfg = vms_core::camera::CameraConfig { name: "t".into(), url: format!("rtsp://127.0.0.1:{port}/live/vivo"), transports: vec![vms_core::media::Transport::Tcp], no_rtp_timeout_ms: 4000, ..Default::default() };
        let stop = StopToken::new();
        let st = stop.clone();
        let sk: Arc<dyn MediaSink> = sink.clone();
        let th = std::thread::spawn(move || {
            let mut s = RtspSession::new(cfg, log, clock, st, Some(sk));
            let _ = s.run();
        });
        for i in 0..60 {
            std::thread::sleep(Duration::from_millis(30));
            let key = i % 10 == 0;
            live.publish(&Sample::video(i * 3000, key, vec![0, 0, 0, 1, if key { 0x65 } else { 0x41 }, i as u8, 1, 2, 3]));
            if sink.samples.lock().unwrap().len() >= 5 {
                break;
            }
        }
        stop.stop();
        th.join().unwrap();
        assert!(sink.samples.lock().unwrap().len() >= 5, "recebeu {}", sink.samples.lock().unwrap().len());
    }
}
