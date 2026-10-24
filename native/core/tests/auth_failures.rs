use soundq_core::{Command, Core};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};
fn read_request(s: &mut TcpStream) -> String {
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut b = [0; 8192];
    let n = s.read(&mut b).unwrap();
    String::from_utf8_lossy(&b[..n]).into_owned()
}
fn send(s: &mut TcpStream, status: &str, body: &str) {
    write!(s,"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
}
fn root(n: &str) -> PathBuf {
    std::env::temp_dir().join(format!("sq-auth-probe-{}-{n}", std::process::id()))
}
fn restore() -> Command {
    Command::Restore {
        access_token: "synthetic-old-access".into(),
        refresh_token: "synthetic-old-refresh".into(),
        account_id: "synthetic-account".into(),
    }
}
#[test]
fn transient_refresh_failure_does_not_retire_local_session() {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let server = thread::spawn(move || {
        let (mut s, _) = l.accept().unwrap();
        assert!(read_request(&mut s).starts_with("POST /api/v1/auth/refresh"));
        send(&mut s, "503 Service Unavailable", r#"{"code":"temporary"}"#);
    });
    let p = root("503");
    let c = Core::open(&endpoint, p.clone()).unwrap();
    let r = c.execute(restore());
    server.join().unwrap();
    assert!(!r.ok);
    assert_eq!(r.code, "service_unavailable");
    assert!(
        r.snapshot.authenticated,
        "transient HTTP503 retired stored session"
    );
    assert!(
        c.execute(Command::Credentials {}).credentials.is_some(),
        "transient refresh cleared credentials"
    );
    std::fs::remove_dir_all(p).unwrap();
}
#[test]
fn cancelled_restore_never_admits_credentials_in_new_epoch() {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let (tx, rx) = mpsc::channel();
    let (release, resume) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut s, _) = l.accept().unwrap();
        read_request(&mut s);
        tx.send(()).unwrap();
        resume.recv().unwrap();
        send(
            &mut s,
            "200 OK",
            r#"{"accessToken":"synthetic-new-access","refreshToken":"synthetic-new-refresh","user":{"id":"synthetic-account"}}"#,
        );
    });
    let p = root("cancel");
    let c = Arc::new(Core::open(&endpoint, p.clone()).unwrap());
    let worker = c.clone();
    let call = thread::spawn(move || worker.execute_at(restore(), 1));
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let epoch = c.revoke();
    release.send(()).unwrap();
    let r = call.join().unwrap();
    server.join().unwrap();
    assert_eq!(r.code, "cancelled");
    let next = c.execute_at(Command::Credentials {}, epoch);
    assert!(
        next.credentials.is_none(),
        "cancelled restore admitted credentials into newer epoch"
    );
    assert!(!next.snapshot.authenticated);
    std::fs::remove_dir_all(p).unwrap();
}

#[test]
fn definitive_refresh_rejection_retires_session() {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let server = thread::spawn(move || {
        let (mut s, _) = l.accept().unwrap();
        read_request(&mut s);
        send(&mut s, "401 Unauthorized", r#"{"code":"invalid_token"}"#);
    });
    let p = root("401");
    let c = Core::open(&endpoint, p.clone()).unwrap();
    let r = c.execute(restore());
    server.join().unwrap();
    assert_eq!(r.code, "authentication_failed");
    assert!(!r.snapshot.authenticated);
    assert!(c.execute(Command::Credentials {}).credentials.is_none());
    std::fs::remove_dir_all(p).unwrap();
}

#[test]
fn rotated_session_survives_downstream_library_failure() {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let server = thread::spawn(move || {
        for route in ["restore", "library401", "refresh", "library503"] {
            let (mut s, _) = l.accept().unwrap();
            let request = read_request(&mut s);
            match route {
                "restore" | "refresh" => {
                    assert!(request.starts_with("POST /api/v1/auth/refresh"));
                    let suffix = if route == "restore" {
                        "restored"
                    } else {
                        "rotated"
                    };
                    send(
                        &mut s,
                        "200 OK",
                        &format!(
                            r#"{{"accessToken":"{suffix}-access","refreshToken":"{suffix}-refresh","user":{{"id":"synthetic-account"}}}}"#
                        ),
                    );
                }
                "library401" => {
                    assert!(request.starts_with("GET /api/v1/library?"));
                    send(&mut s, "401 Unauthorized", "{}");
                }
                _ => {
                    assert!(request.starts_with("GET /api/v1/library?"));
                    send(&mut s, "503 Service Unavailable", "{}");
                }
            }
        }
    });
    let p = root("rotated");
    let c = Core::open(&endpoint, p.clone()).unwrap();
    assert!(c.execute(restore()).ok);
    let r = c.execute(Command::Library {
        offset: 0,
        query: String::new(),
        sort: "title".into(),
        order: "asc".into(),
    });
    server.join().unwrap();
    assert!(!r.ok);
    assert_eq!(r.code, "service_unavailable");
    assert!(r.snapshot.authenticated);
    assert_eq!(
        r.credentials.as_ref().map(|c| c.refresh_token.as_str()),
        Some("rotated-refresh"),
        "adapter must receive rotated credentials even when subsequent read fails"
    );
    let credentials = c.execute(Command::Credentials {}).credentials.unwrap();
    assert_eq!(credentials.refresh_token, "rotated-refresh");
    std::fs::remove_dir_all(p).unwrap();
}
