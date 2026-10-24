use soundq_core::{AudioState, Command, Core};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{Arc, mpsc},
    thread,
    time::{Duration, Instant},
};

fn request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    loop {
        let n = stream.read(&mut buffer).unwrap();
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..n]);
        if bytes.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}
fn respond(stream: &mut TcpStream, body: &str) {
    write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
}
fn root(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("soundq-race-{}-{name}", std::process::id()))
}

#[test]
fn revoke_during_held_login_prevents_credentials_or_library_publication() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", listener.local_addr().unwrap());
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        assert!(request(&mut stream).starts_with("POST /api/v1/auth/login"));
        entered_tx.send(()).unwrap();
        release_rx.recv().unwrap();
        respond(
            &mut stream,
            r#"{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","user":{"id":"synthetic-a"}}"#,
        );
    });
    let path = root("login");
    let core = Arc::new(Core::open(&endpoint, path.clone()).unwrap());
    let worker_core = core.clone();
    let worker = thread::spawn(move || {
        worker_core.execute_at(
            Command::Login {
                email: "fixture@example.invalid".into(),
                password: "synthetic-only".into(),
            },
            1,
        )
    });
    entered_rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let begin = Instant::now();
    let epoch = core.revoke();
    assert_eq!(epoch, 2);
    assert!(
        begin.elapsed() < Duration::from_millis(100),
        "revoke blocked on HTTP mutex"
    );
    release_tx.send(()).unwrap();
    let reply = worker.join().unwrap();
    assert_eq!(reply.code, "cancelled");
    assert!(!reply.snapshot.authenticated);
    assert!(reply.credentials.is_none());
    let current = core.execute_at(Command::Credentials {}, epoch);
    assert!(current.credentials.is_none());
    assert!(current.snapshot.queue.is_empty());
    server.join().unwrap();
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn queued_old_intent_is_not_rebased_to_new_account_epoch() {
    let path = root("queued");
    let core = Core::open("http://127.0.0.1:1/api/v1", path.clone()).unwrap();
    let old = 1;
    let epoch = core.revoke();
    let queued = core.execute_at(Command::Seek { position_ms: 6000 }, old);
    assert_eq!(queued.code, "cancelled");
    assert!(queued.audio.is_none());
    let current = core.execute_at(Command::Snapshot {}, epoch);
    assert_eq!(current.snapshot.position_ms, 0);
    assert!(current.snapshot.queue.is_empty());
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn stale_native_state_cannot_replace_new_session() {
    let path = root("report");
    let core = Core::open("http://127.0.0.1:1/api/v1", path.clone()).unwrap();
    let r = core.execute(Command::AudioReport {
        epoch: 1,
        session: 999,
        state: AudioState::Playing,
        position_ms: 6000,
        duration_ms: 30000,
    });
    assert_eq!(r.code, "stale_audio_report");
    assert_eq!(r.snapshot.transport, AudioState::Idle);
    assert_eq!(r.snapshot.position_ms, 0);
    std::fs::remove_dir_all(path).unwrap();
}

#[test]
fn endpoint_rejects_raw_controls_before_url_normalization() {
    for c in [0u8, 9, 10, 13, 31, 127] {
        let endpoint = format!("https://example.invalid/{}/api/v1", c as char);
        assert!(Core::open(&endpoint, PathBuf::new()).is_err());
    }
}

#[test]
fn transport_topic_never_copies_populated_library() {
    let path = root("topic");
    let core = Core::open("http://127.0.0.1:1/api/v1", path.clone()).unwrap();
    let reply = core.execute(Command::Pause {});
    assert!(reply.snapshot.library_unchanged);
    assert!(reply.snapshot.library.is_empty());
    assert!(
        !core
            .execute(Command::Snapshot {})
            .snapshot
            .library_unchanged
    );
    std::fs::remove_dir_all(path).unwrap();
}
