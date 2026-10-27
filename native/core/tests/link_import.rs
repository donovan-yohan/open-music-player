use serde_json::{Value, json};
use soundq_core::{Command, Core};
use std::{
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};
static SERIAL: AtomicU64 = AtomicU64::new(0);
#[test]
fn duplicate_older_and_failed_dispatch_never_replay() {
    for (status, body, outcome) in [
        ("201 Created", ACK, "accepted"),
        ("401 Unauthorized", "{}", "rejected"),
        ("503 Unavailable", "{}", "uncertain"),
        ("201 Created", "{}", "uncertain"),
        ("200 OK", ACK, "uncertain"),
        ("DROP", "", "uncertain"),
    ] {
        let (c, root, l) = fixture();
        let server = thread::spawn(move || {
            auth(&l);
            let (mut s, _) = l.accept().unwrap();
            assert!(read(&mut s).starts_with("POST /api/v1/downloads "));
            if status != "DROP" {
                send(&mut s, status, body)
            }
            l
        });
        restore(&c);
        let r = c.execute(post(9, "https://youtu.be/dQw4w9WgXcQ"));
        let j = serde_json::to_value(r).unwrap();
        assert_eq!(
            j["import_result"]["receipt"]["outcome"], outcome,
            "{status}"
        );
        for n in [9, 8] {
            let r = c.execute(post(n, "https://youtu.be/dQw4w9WgXcQ"));
            assert_eq!(r.code, "import_duplicate");
            assert_eq!(
                serde_json::to_value(r).unwrap()["import_result"]["receipt"]["operation_id"],
                9
            )
        }
        no_extra(server.join().unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
#[test]
fn invalid_urls_and_unauthenticated_submission_are_not_sent() {
    let (c, root, l) = fixture();
    for (i, url) in [
        "https://@youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ",
        "https://evilyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/playlist?list=one",
        "http://youtu.be/dQw4w9WgXcQ",
        "https://soundcloud.com/artist/sets",
        "https://soundcloud.com/artist",
        "https://youtu.be/dQw4w9WgXcQ\ninside",
        "https://youtu.be/dQw4w9WgXcQ%xx",
        "https://youtu.be/dQw4w9WgXcQ?x=%xx",
    ]
    .iter()
    .enumerate()
    {
        let r = c.execute(post(i as u64 + 1, url));
        assert_eq!(r.code, "invalid_import_url", "{url}");
        assert!(r.audio.is_none())
    }
    let r = c.execute(post(20, "https://youtu.be/dQw4w9WgXcQ"));
    assert_eq!(r.code, "unauthenticated");
    assert_eq!(
        serde_json::to_value(r).unwrap()["import_result"]["receipt"]["outcome"],
        "not_sent"
    );
    no_extra(l);
    fs::remove_dir_all(root).unwrap();
}
const ID: &str = "12345678-1234-4234-8234-123456789abc";
#[test]
fn strict_ack_fields_and_oversized_results_stay_uncertain() {
    for body in [
        "{}".to_string(),
        ACK.replace("queued", "completed"),
        ACK.replace(ID, "not-a-uuid"),
        ACK.replace("sourceDecisionId", "source_decision_id"),
        " ".repeat(4 * 1024 * 1024 + 1),
    ] {
        let (c, root, l) = fixture();
        let server = thread::spawn(move || {
            auth(&l);
            let (mut s, _) = l.accept().unwrap();
            read(&mut s);
            let _ = write!(
                s,
                "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            l
        });
        restore(&c);
        let r = c.execute(post(1, "https://youtu.be/dQw4w9WgXcQ"));
        assert!(!r.ok);
        assert_eq!(
            serde_json::to_value(&r).unwrap()["import_result"]["receipt"]["outcome"],
            "uncertain"
        );
        assert!(r.audio.is_none());
        no_extra(server.join().unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
#[test]
fn soundcloud_is_one_exact_original_track_submission_and_invalid_paths_do_not_dispatch() {
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        auth(&l);
        let (mut s, _) = l.accept().unwrap();
        let r = read(&mut s);
        let body: Value = serde_json::from_str(r.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(
            body,
            json!({"url":"https://soundcloud.com/artist/track?in=artist/sets/album#original","source_type":"soundcloud"})
        );
        send(&mut s, "201 Created", ACK);
        l
    });
    restore(&c);
    for (n, url) in [
        (1, "https://soundcloud.com/artist/sets/album".to_string()),
        (
            2,
            "https://youtu.be/dQw4w9WgXcQ?x=".to_string() + &"a".repeat(4096),
        ),
    ] {
        assert_eq!(c.execute(post(n, &url)).code, "invalid_import_url")
    }
    assert!(
        c.execute(post(
            3,
            "https://soundcloud.com/artist/track?in=artist/sets/album#original"
        ))
        .ok
    );
    assert_eq!(
        c.execute(cmd(
            json!({"command":"import_job","job_id":"../auth/logout"})
        ))
        .code,
        "invalid_import_job"
    );
    no_extra(server.join().unwrap());
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn loaded_epoch_refusal_never_resets_transport_or_dispatches_import() {
    let (c, root, l) = fixture();
    let epoch = c.revoke();
    let before = c.execute_at(Command::Snapshot {}, 1).snapshot;
    let r = c.execute_at(post(1, "https://youtu.be/dQw4w9WgXcQ"), epoch);
    assert_eq!(r.code, "cancelled");
    assert!(r.audio.is_none());
    assert_eq!(r.snapshot.session, before.session);
    assert_eq!(r.snapshot.position_ms, before.position_ms);
    no_extra(l);
    fs::remove_dir_all(root).unwrap();
}
fn job() -> Value {
    json!({"job_id":ID,"status":"complete","progress":100,"url":"https://youtu.be/dQw4w9WgXcQ","source_type":"youtube","track_id":7,"created_at":"2026-10-27T12:00:00Z"})
}
#[test]
fn owned_reads_validate_job_and_retain_receipt_on_failure() {
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        auth(&l);
        for (path, status, body) in [
            ("/downloads".to_string(), "201 Created", ACK.to_string()),
            (format!("/downloads/{ID}"), "200 OK", job().to_string()),
            (
                "/downloads".into(),
                "200 OK",
                json!({"jobs":[job()]}).to_string(),
            ),
            (format!("/downloads/{ID}"), "404 Not Found", "{}".into()),
        ] {
            let (mut s, _) = l.accept().unwrap();
            assert!(read(&mut s).starts_with(&format!(
                "{} /api/v1{path} ",
                if status == "201 Created" {
                    "POST"
                } else {
                    "GET"
                }
            )));
            send(&mut s, status, &body)
        }
        l
    });
    restore(&c);
    assert!(c.execute(post(1, "https://youtu.be/dQw4w9WgXcQ")).ok);
    let before = serde_json::to_value(c.execute(Command::Snapshot {}).snapshot).unwrap();
    let r = c.execute(cmd(json!({"command":"import_job","job_id":ID})));
    assert!(r.ok, "{}", r.code);
    let j = serde_json::to_value(r).unwrap();
    assert_eq!(j["import_result"]["job"]["track_id"], 7);
    let r = c.execute(cmd(json!({"command":"import_jobs"})));
    assert!(r.ok);
    assert_eq!(
        serde_json::to_value(r).unwrap()["import_result"]["jobs"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let r = c.execute(cmd(json!({"command":"import_job","job_id":ID})));
    assert!(!r.ok);
    assert_eq!(
        serde_json::to_value(&r).unwrap()["import_result"]["receipt"]["outcome"],
        "accepted"
    );
    assert!(r.audio.is_none());
    let after = serde_json::to_value(r.snapshot).unwrap();
    for key in [
        "queue",
        "session",
        "selected_occurrence",
        "position_ms",
        "library",
        "library_revision",
        "transport",
    ] {
        assert_eq!(before[key], after[key], "{key}")
    }
    no_extra(server.join().unwrap());
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn malformed_read_never_publishes_and_complete_without_track_is_valid() {
    let mut bodies = vec![job()];
    bodies[0].as_object_mut().unwrap().remove("track_id");
    for (key, value) in [
        ("status", json!("completed")),
        ("progress", json!(101)),
        ("progress", json!(1.5)),
        ("track_id", json!(0)),
        ("job_id", json!("32345678-1234-4234-8234-123456789abc")),
        ("created_at", json!("bad")),
    ] {
        let mut j = job();
        j[key] = value;
        bodies.push(j)
    }
    let (c, root, l) = fixture();
    let count = bodies.len();
    let server = thread::spawn(move || {
        auth(&l);
        for body in bodies {
            let (mut s, _) = l.accept().unwrap();
            assert!(read(&mut s).starts_with(&format!("GET /api/v1/downloads/{ID} ")));
            send(&mut s, "200 OK", &body.to_string())
        }
        l
    });
    restore(&c);
    for i in 0..count {
        let r = c.execute(cmd(json!({"command":"import_job","job_id":ID})));
        assert_eq!(r.ok, i == 0, "i={i} {}", r.code);
        if i == 0 {
            assert!(serde_json::to_value(r).unwrap()["import_result"]["job"]["track_id"].is_null())
        }
    }
    no_extra(server.join().unwrap());
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn dispatched_epoch_cancellation_recovers_uncertainty_and_account_replacement_clears_it() {
    use std::sync::mpsc;
    let (c, root, l) = fixture();
    let (tx, rx) = mpsc::channel();
    let (release, held) = mpsc::channel();
    let server = thread::spawn(move || {
        auth(&l);
        let (mut s, _) = l.accept().unwrap();
        assert!(read(&mut s).starts_with("POST /api/v1/downloads "));
        tx.send(()).unwrap();
        held.recv().unwrap();
        send(&mut s, "201 Created", ACK);
        drop(s);
        let (mut s, _) = l.accept().unwrap();
        assert!(read(&mut s).starts_with("GET /api/v1/downloads "));
        send(&mut s, "503 Unavailable", "{}");
        l
    });
    restore(&c);
    let other = c.clone();
    let worker = thread::spawn(move || {
        other.execute_scoped_at(post(1, "https://youtu.be/dQw4w9WgXcQ"), 1, Some(1))
    });
    rx.recv_timeout(Duration::from_secs(3)).unwrap();
    let epoch = c.revoke();
    release.send(()).unwrap();
    let r = worker.join().unwrap();
    assert_eq!(r.code, "cancelled");
    assert!(
        serde_json::to_value(r)
            .unwrap()
            .get("import_result")
            .is_none()
    );
    // Ordinary snapshot adopts the playback epoch, not an import operation.
    c.execute_at(Command::Snapshot {}, epoch);
    let r = c.execute_at(cmd(json!({"command":"import_jobs"})), epoch);
    assert_eq!(
        serde_json::to_value(r).unwrap()["import_result"]["receipt"]["outcome"],
        "uncertain"
    );
    let r = c.execute_scoped_at(cmd(json!({"command":"import_jobs"})), epoch, Some(2));
    assert_eq!(r.code, "unauthenticated");
    assert!(serde_json::to_value(r).unwrap()["import_result"]["receipt"].is_null());
    no_extra(server.join().unwrap());
    fs::remove_dir_all(root).unwrap();
}
const ACK: &str = r#"{"job_id":"12345678-1234-4234-8234-123456789abc","status":"queued","sourceDecisionId":"22345678-1234-4234-8234-123456789abc"}"#;
fn cmd(v: Value) -> Command {
    serde_json::from_value(v).expect("additive import JSON command")
}
fn post(n: u64, url: &str) -> Command {
    cmd(json!({"command":"import_link","operation_id":n,"url":url}))
}
fn read(s: &mut TcpStream) -> String {
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut b = vec![];
    loop {
        let mut x = [0; 4096];
        let n = s.read(&mut x).unwrap();
        assert!(n > 0);
        b.extend_from_slice(&x[..n]);
        if let Some(p) = b.windows(4).position(|x| x == b"\r\n\r\n") {
            let h = String::from_utf8_lossy(&b[..p]);
            let len = h
                .lines()
                .find_map(|l| {
                    l.to_lowercase()
                        .strip_prefix("content-length:")
                        .map(|x| x.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            if b.len() >= p + 4 + len {
                break;
            }
        }
    }
    String::from_utf8(b).unwrap()
}
fn send(s: &mut TcpStream, status: &str, body: &str) {
    write!(s,"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap()
}
fn fixture() -> (Arc<Core>, std::path::PathBuf, TcpListener) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let root = std::env::temp_dir().join(format!(
        "sq-import-{}-{}",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    (
        Arc::new(
            Core::open(
                &format!("http://{}/api/v1", l.local_addr().unwrap()),
                root.clone(),
            )
            .unwrap(),
        ),
        root,
        l,
    )
}
fn auth(l: &TcpListener) {
    let (mut s, _) = l.accept().unwrap();
    assert!(read(&mut s).starts_with("POST /api/v1/auth/refresh "));
    send(
        &mut s,
        "200 OK",
        r#"{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","user":{"id":"synthetic-account"}}"#,
    )
}
fn restore(c: &Core) {
    assert!(
        c.execute_scoped_at(
            Command::Restore {
                access_token: "old".into(),
                refresh_token: "old-r".into(),
                account_id: "synthetic-account".into()
            },
            1,
            Some(1)
        )
        .ok
    )
}
fn no_extra(l: TcpListener) {
    l.set_nonblocking(true).unwrap();
    assert_eq!(
        l.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    )
}
#[test]
fn authenticated_submission_is_one_real_post_with_validated_receipt() {
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        auth(&l);
        let (mut s, _) = l.accept().unwrap();
        let r = read(&mut s);
        assert!(r.starts_with("POST /api/v1/downloads "));
        assert!(
            r.to_lowercase()
                .contains("authorization: bearer synthetic-access")
        );
        let body: Value = serde_json::from_str(r.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(
            body,
            json!({"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=one#original","source_type":"youtube"})
        );
        send(&mut s, "201 Created", ACK);
        l
    });
    restore(&c);
    let r = c.execute_scoped_at(
        post(
            1,
            "  https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=one#original  ",
        ),
        1,
        Some(1),
    );
    assert!(r.ok, "{}", r.code);
    let j = serde_json::to_value(&r).unwrap();
    assert_eq!(j["import_result"]["receipt"]["outcome"], "accepted");
    assert_eq!(j["import_result"]["receipt"]["ack"]["job_id"], ID);
    assert!(r.audio.is_none());
    assert!(r.snapshot.queue.is_empty());
    no_extra(server.join().unwrap());
    fs::remove_dir_all(root).unwrap();
}
