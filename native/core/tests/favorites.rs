use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use soundq_core::{AudioState, Command, Core, Reply, Track};
use std::{
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

static SERIAL: AtomicU64 = AtomicU64::new(0);
const AUTH: &str = r#"{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","user":{"id":"synthetic-account"}}"#;
const PAGE: &str = r#"{"tracks":[{"id":1,"title":"One","duration_ms":30000,"is_liked":false},{"id":2,"title":"Two","is_liked":true}],"total":2,"offset":0}"#;

fn request(s: &mut TcpStream) -> String {
    s.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut bytes = Vec::new();
    loop {
        let mut buffer = [0; 4096];
        let n = s.read(&mut buffer).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&buffer[..n]);
        if bytes.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8(bytes).unwrap()
}
fn send(s: &mut TcpStream, status: &str, body: &str) {
    write!(s, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
}
fn favorite(id: i64, liked: bool) -> Command {
    serde_json::from_value(json!({"command":"set_favorite","track_id":id,"liked":liked})).unwrap()
}
fn library(offset: u32) -> Command {
    Command::Library {
        offset,
        query: String::new(),
        sort: "title".into(),
        order: "asc".into(),
    }
}
fn ids(r: &Reply) -> Value {
    serde_json::to_value(&r.snapshot).unwrap()["favorite_track_ids"].clone()
}
fn fixture() -> (Arc<Core>, PathBuf, TcpListener) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let root = std::env::temp_dir().join(format!(
        "sq-favorites-{}-{}",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    (
        Arc::new(Core::open(&endpoint, root.clone()).unwrap()),
        root,
        l,
    )
}
fn bootstrap(l: &TcpListener) {
    let (mut s, _) = l.accept().unwrap();
    assert!(request(&mut s).starts_with("POST /api/v1/auth/refresh "));
    send(&mut s, "200 OK", AUTH);
    let (mut s, _) = l.accept().unwrap();
    let r = request(&mut s);
    assert!(r.starts_with("GET /api/v1/library?"));
    assert!(
        r.to_lowercase()
            .contains("authorization: bearer synthetic-access")
    );
    send(&mut s, "200 OK", PAGE);
}
fn load(c: &Core) {
    let r = c.execute_scoped_at(
        Command::Restore {
            access_token: "synthetic-old".into(),
            refresh_token: "synthetic-old-refresh".into(),
            account_id: "synthetic-account".into(),
        },
        1,
        Some(1),
    );
    assert!(r.ok);
    assert!(
        c.execute_scoped_at(
            Command::AcknowledgeCredentials {
                version: r.credentials.unwrap().version
            },
            1,
            Some(1)
        )
        .ok
    );
    let r = c.execute_scoped_at(library(0), 1, Some(1));
    assert!(r.ok);
    assert_eq!(ids(&r), json!([2]));
}
fn no_extra(l: &TcpListener) {
    l.set_nonblocking(true).unwrap();
    assert_eq!(
        l.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock,
        "mutation replayed or refreshed"
    );
}

#[test]
fn explicit_command_and_track_v1_contract() {
    assert!(matches!(
        favorite(7, true),
        Command::SetFavorite {
            track_id: 7,
            liked: true
        }
    ));
    for body in [
        json!({"command":"set_favorite","track_id":7}),
        json!({"command":"set_favorite","track_id":7,"liked":true,"toggle":true}),
    ] {
        assert!(serde_json::from_value::<Command>(body).is_err());
    }
    let old = r#"{"id":7,"title":"Seven","artist":null,"album":null,"duration_ms":null}"#;
    let track: Track = serde_json::from_str(old).unwrap();
    assert_eq!(serde_json::to_string(&track).unwrap(), old);
}

#[test]
fn unauthenticated_favorite_has_no_effect_or_projection() {
    let root = std::env::temp_dir().join(format!(
        "sq-favorites-unauthed-{}-{}",
        std::process::id(),
        SERIAL.fetch_add(1, Ordering::Relaxed)
    ));
    let c = Core::open("http://127.0.0.1:1/api/v1", root.clone()).unwrap();
    let r = c.execute(favorite(1, true));
    assert_eq!(r.code, "unauthenticated");
    assert!(!r.ok);
    assert!(r.audio.is_none());
    assert!(r.credentials.is_none());
    assert_eq!(ids(&r), json!([]));
    assert_eq!(r.snapshot.session, 0);
    assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn explicit_desired_state_preserves_v1_queue_membership_cursor_and_audio() {
    let (c, root, l) = fixture();
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let server = thread::spawn(move || {
        bootstrap(&l);
        for (method, status, body) in [
            ("POST", "201 Created", r#"{"track_id":1,"liked":true}"#),
            ("POST", "201 Created", r#"{"track_id":1,"liked":true}"#),
            ("DELETE", "204 No Content", ""),
        ] {
            let (mut s, _) = l.accept().unwrap();
            let r = request(&mut s);
            assert!(r.starts_with(&format!("{method} /api/v1/library/tracks/1/like HTTP/1.1")));
            assert!(
                r.to_lowercase()
                    .contains("authorization: bearer synthetic-access")
            );
            send(&mut s, status, body);
        }
        l
    });
    load(&c);
    let dir = root.join(format!(
        "{:x}",
        Sha256::digest(format!("{endpoint}\0synthetic-account").as_bytes())
    ));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("listening-queue-v1.json");
    let old = br#"{"version":1,"queue":[{"id":9,"track":{"id":1,"title":"Old title","artist":null,"album":null,"duration_ms":30000}}],"selected":9,"position_ms":4321,"next_occurrence":10}"#;
    fs::write(&path, old).unwrap();
    let cache_index = dir.join("1.json");
    let cache_audio = dir.join("1-fixture.mp3");
    fs::write(&cache_index, b"cache-index-witness").unwrap();
    fs::write(&cache_audio, b"immutable-cache-witness").unwrap();
    assert!(c.execute(Command::QueueRestore {}).ok);
    let restored = c.execute(Command::Snapshot {}).snapshot;
    // Public native report establishes an active transport without constructing
    // any decoder or audio device. Favorite policy must preserve this snapshot.
    assert!(
        c.execute(Command::AudioReport {
            epoch: 1,
            session: restored.session,
            state: AudioState::Playing,
            position_ms: 4321,
            duration_ms: 30000
        })
        .ok
    );
    let before = c.execute(Command::Snapshot {}).snapshot;
    for (liked, expected) in [
        (true, json!([1, 2])),
        (true, json!([1, 2])),
        (false, json!([2])),
    ] {
        let r = c.execute_scoped_at(favorite(1, liked), 1, Some(1));
        assert!(r.ok, "{}", r.code);
        assert_eq!(ids(&r), expected);
        assert!(r.audio.is_none());
        assert!(r.credentials.is_none());
        assert_eq!(
            serde_json::to_value(&r.snapshot.queue).unwrap(),
            serde_json::to_value(&before.queue).unwrap()
        );
        assert_eq!(r.snapshot.library, before.library);
        assert_eq!(
            (
                r.snapshot.total,
                r.snapshot.offset,
                r.snapshot.session,
                r.snapshot.selected_occurrence,
                r.snapshot.position_ms,
                r.snapshot.duration_ms,
                r.snapshot.transport
            ),
            (
                before.total,
                before.offset,
                before.session,
                before.selected_occurrence,
                before.position_ms,
                before.duration_ms,
                before.transport
            )
        );
        assert_eq!(fs::read(&path).unwrap(), old);
        assert_eq!(fs::read(&cache_index).unwrap(), b"cache-index-witness");
        assert_eq!(fs::read(&cache_audio).unwrap(), b"immutable-cache-witness");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 3);
    }
    let l = server.join().unwrap();
    no_extra(&l);
    let topic = c.execute(Command::Pause {});
    assert!(topic.snapshot.library_unchanged);
    assert_eq!(ids(&topic), json!([]));
    assert_eq!(ids(&c.execute(Command::Snapshot {})), json!([2]));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn refused_uncertain_and_malformed_acknowledgments_never_project_or_replay() {
    for (liked, status, body, code) in [
        (true, "401 Unauthorized", "{}", "unauthenticated"),
        (true, "403 Forbidden", "{}", "api_refused"),
        (true, "429 Too Many Requests", "{}", "api_refused"),
        (true, "404 Not Found", "{}", "not_found"),
        (true, "503 Service Unavailable", "{}", "favorite_uncertain"),
        (
            true,
            "500 Internal Server Error",
            "{}",
            "favorite_uncertain",
        ),
        (true, "307 Temporary Redirect", "{}", "favorite_uncertain"),
        (
            true,
            "200 OK",
            r#"{"track_id":1,"liked":true}"#,
            "favorite_uncertain",
        ),
        (true, "204 No Content", "", "favorite_uncertain"),
        (
            true,
            "201 Created",
            r#"{"track_id":2,"liked":true}"#,
            "favorite_uncertain",
        ),
        (
            true,
            "201 Created",
            r#"{"track_id":1,"liked":false}"#,
            "favorite_uncertain",
        ),
        (true, "201 Created", "{", "favorite_uncertain"),
        (
            true,
            "201 Created",
            r#"{"track_id":"1","liked":true}"#,
            "favorite_uncertain",
        ),
        (
            true,
            "201 Created",
            r#"{"track_id":1}"#,
            "favorite_uncertain",
        ),
        (false, "200 OK", "{}", "favorite_uncertain"),
        (
            false,
            "201 Created",
            r#"{"track_id":1,"liked":true}"#,
            "favorite_uncertain",
        ),
    ] {
        let (c, root, l) = fixture();
        let server = thread::spawn(move || {
            bootstrap(&l);
            let (mut s, _) = l.accept().unwrap();
            let method = if liked { "POST" } else { "DELETE" };
            assert!(
                request(&mut s).starts_with(&format!("{method} /api/v1/library/tracks/1/like "))
            );
            send(&mut s, status, body);
            l
        });
        load(&c);
        let r = c.execute(favorite(1, liked));
        assert!(!r.ok);
        assert_eq!(r.code, code);
        assert_eq!(ids(&r), json!([2]));
        assert!(r.audio.is_none());
        assert!(r.credentials.is_none());
        assert!(r.snapshot.authenticated);
        let l = server.join().unwrap();
        no_extra(&l);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn disconnected_response_is_uncertain_and_never_replayed() {
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        let (mut s, _) = l.accept().unwrap();
        assert!(request(&mut s).contains("/tracks/1/like "));
        drop(s);
        l
    });
    load(&c);
    let r = c.execute(favorite(1, true));
    assert_eq!(r.code, "favorite_uncertain");
    assert_eq!(ids(&r), json!([2]));
    assert!(r.audio.is_none());
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn admission_rejects_unloaded_invalid_unauthenticated_and_stale_intents_without_http() {
    let (c, root, l) = fixture();
    assert_eq!(c.execute(favorite(1, true)).code, "unauthenticated");
    let server = thread::spawn(move || {
        bootstrap(&l);
        l
    });
    load(&c);
    for id in [-1, 0, 999] {
        assert_eq!(c.execute(favorite(id, true)).code, "track_not_loaded");
    }
    let epoch = c.revoke();
    assert_eq!(c.execute_at(favorite(1, true), 1).code, "cancelled");
    assert_eq!(c.execute_at(favorite(1, true), epoch).code, "cancelled");
    assert_eq!(
        c.execute_scoped_at(favorite(1, true), epoch, Some(0)).code,
        "cancelled"
    );
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn held_mutation_revoke_never_publishes_and_new_account_retires_projection() {
    let (c, root, l) = fixture();
    let (entered, waiting) = mpsc::channel();
    let (release, resume) = mpsc::channel();
    let server = thread::spawn(move || {
        bootstrap(&l);
        let (mut s, _) = l.accept().unwrap();
        assert!(request(&mut s).starts_with("POST /api/v1/library/tracks/1/like "));
        entered.send(()).unwrap();
        resume.recv_timeout(Duration::from_secs(3)).unwrap();
        send(&mut s, "201 Created", r#"{"track_id":1,"liked":true}"#);
        l
    });
    load(&c);
    let worker = c.clone();
    let call = thread::spawn(move || worker.execute_scoped_at(favorite(1, true), 1, Some(1)));
    waiting.recv_timeout(Duration::from_secs(3)).unwrap();
    let epoch = c.revoke();
    release.send(()).unwrap();
    let r = call.join().unwrap();
    assert_eq!(r.code, "cancelled");
    assert_eq!(ids(&r), json!([]));
    assert!(r.audio.is_none());
    assert!(r.credentials.is_none());
    assert_eq!(
        ids(&c.execute_scoped_at(Command::Snapshot {}, epoch, Some(1))),
        json!([2])
    );
    assert_eq!(
        c.execute_scoped_at(favorite(1, true), 1, Some(2)).code,
        "cancelled"
    );
    let r = c.execute_scoped_at(Command::Snapshot {}, epoch, Some(2));
    assert!(!r.snapshot.authenticated);
    assert_eq!(ids(&r), json!([]));
    assert_eq!(
        c.execute_scoped_at(favorite(1, true), epoch, Some(1)).code,
        "cancelled"
    );
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn library_projection_tracks_loaded_pages_and_membership_independently() {
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        for body in [
            r#"{"tracks":[{"id":3,"title":"Three","is_liked":true}],"offset":2,"total":3}"#,
            r#"{"tracks":[{"id":1,"title":"One"}],"offset":0,"total":1}"#,
            r#"{"tracks":null,"offset":0,"total":0}"#,
        ] {
            let (mut s, _) = l.accept().unwrap();
            assert!(request(&mut s).starts_with("GET /api/v1/library?"));
            send(&mut s, "200 OK", body);
        }
    });
    load(&c);
    assert_eq!(ids(&c.execute(library(2))), json!([2, 3]));
    assert!(c.execute(Command::QueueAppend { track_id: 2 }).ok);
    let r = c.execute(library(0));
    assert_eq!(ids(&r), json!([]));
    assert_eq!(r.snapshot.library.len(), 1);
    assert_eq!(r.snapshot.queue[0].track.id, 2);
    let r = c.execute(library(0));
    assert_eq!(ids(&r), json!([]));
    assert!(r.snapshot.library.is_empty());
    assert_eq!(r.snapshot.queue.len(), 1);
    server.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}
