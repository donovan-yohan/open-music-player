use soundq_core::{Command, Core};
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

#[test]
fn held_rotated_read_delivers_until_exact_durable_ack_and_account_scope_retires_it() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", listener.local_addr().unwrap());
    let (entered, waiting) = mpsc::channel();
    let (release, resume) = mpsc::channel();
    let server = thread::spawn(move || {
        for step in 0..4 {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = [0; 8192];
            let n = stream.read(&mut bytes).unwrap();
            let request = String::from_utf8_lossy(&bytes[..n]);
            let (status, body) = match step {
                0 | 2 => {
                    assert!(request.starts_with("POST /api/v1/auth/refresh"));
                    let version = if step == 0 { 1 } else { 2 };
                    (
                        "200 OK",
                        format!(
                            r#"{{"accessToken":"synthetic-access-{version}","refreshToken":"synthetic-refresh-{version}","user":{{"id":"synthetic-account"}}}}"#
                        ),
                    )
                }
                1 => {
                    assert!(request.starts_with("GET /api/v1/library?"));
                    ("401 Unauthorized", "{}".into())
                }
                _ => {
                    assert!(request.starts_with("GET /api/v1/library?"));
                    entered.send(()).unwrap();
                    resume.recv_timeout(Duration::from_secs(3)).unwrap();
                    ("200 OK", r#"{"tracks":[],"total":0,"offset":0}"#.into())
                }
            };
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        }
    });
    let root = std::env::temp_dir().join(format!("sq-repair-contract-{}", std::process::id()));
    let core = Arc::new(Core::open(&endpoint, root.clone()).unwrap());
    let initial = core.execute_scoped_at(
        Command::Restore {
            access_token: "synthetic-access".into(),
            refresh_token: "synthetic-refresh".into(),
            account_id: "synthetic-account".into(),
        },
        1,
        Some(1),
    );
    let first = initial.credentials.unwrap().version;
    assert!(
        core.execute_scoped_at(
            Command::AcknowledgeCredentials { version: first },
            1,
            Some(1)
        )
        .ok
    );
    let worker = core.clone();
    let call = thread::spawn(move || {
        worker.execute_scoped_at(
            Command::Library {
                offset: 0,
                query: String::new(),
                sort: "title".into(),
                order: "asc".into(),
            },
            1,
            Some(1),
        )
    });
    waiting.recv_timeout(Duration::from_secs(3)).unwrap();
    let epoch = core.revoke();
    release.send(()).unwrap();
    let cancelled = call.join().unwrap();
    assert_eq!(cancelled.code, "cancelled");
    assert!(cancelled.credentials.is_none());
    let pending = core
        .execute_scoped_at(Command::Snapshot {}, epoch, Some(1))
        .credentials
        .unwrap();
    assert_eq!(pending.refresh_token, "synthetic-refresh-2");
    assert!(pending.version > first);
    core.execute_scoped_at(
        Command::AcknowledgeCredentials { version: first },
        epoch,
        Some(1),
    );
    assert!(
        core.execute_scoped_at(Command::Snapshot {}, epoch, Some(1))
            .credentials
            .is_some()
    );
    core.execute_scoped_at(
        Command::AcknowledgeCredentials {
            version: pending.version,
        },
        epoch,
        Some(1),
    );
    assert!(
        core.execute_scoped_at(Command::Snapshot {}, epoch, Some(1))
            .credentials
            .is_none()
    );
    // A newer account intent must retire the old pair even when its playback
    // epoch is already stale. No account HTTP request is sent in this branch.
    assert_eq!(
        core.execute_scoped_at(
            Command::Login {
                email: "dummy@example.invalid".into(),
                password: "dummy".into()
            },
            epoch - 1,
            Some(2)
        )
        .code,
        "cancelled"
    );
    let current = core.execute_scoped_at(Command::Credentials {}, epoch, Some(2));
    assert!(current.credentials.is_none());
    assert!(!current.snapshot.authenticated);
    assert!(
        core.execute_scoped_at(Command::Credentials {}, epoch, Some(1))
            .credentials
            .is_none()
    );
    server.join().unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
