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

#[test]
fn liked_filter_favorite_outcomes_preserve_rows_and_fence_shifted_pagination() {
    // Each public-core case starts with an acknowledged partial page and a live
    // queue/cursor. Only outcomes that can change the filtered result retire its
    // append identity. No mutation is refreshed or replayed.
    for (filtered, liked, status, body, code, invalidated) in [
        (true, false, "204 No Content", "", "ok", true),
        (true, false, "", "", "favorite_uncertain", true),
        (
            true,
            false,
            "401 Unauthorized",
            "{}",
            "unauthenticated",
            false,
        ),
        (true, false, "404 Not Found", "{}", "not_found", false),
        (
            true,
            false,
            "429 Too Many Requests",
            "{}",
            "api_refused",
            false,
        ),
        (
            true,
            false,
            "503 Service Unavailable",
            "{}",
            "favorite_uncertain",
            true,
        ),
        (true, false, "200 OK", "{}", "favorite_uncertain", true),
        (true, false, "403 Forbidden", "{}", "api_refused", false),
        (
            true,
            true,
            "201 Created",
            r#"{"track_id":2,"liked":true}"#,
            "ok",
            false,
        ),
        (false, false, "204 No Content", "", "ok", false),
        (
            false,
            true,
            "201 Created",
            r#"{"track_id":2,"liked":true}"#,
            "ok",
            false,
        ),
    ] {
        let (c, root, l) = fixture();
        liked_filter_cached_tracks(&root, &l, &[2, 4]);
        let server = thread::spawn(move || {
            bootstrap(&l);
            liked_filter_page(
                &l,
                filtered,
                0,
                "",
                "title",
                "asc",
                "200 OK",
                r#"{"tracks":[{"id":2,"title":"Two","duration_ms":30000,"is_liked":true},{"id":4,"title":"Four","is_liked":true}],"offset":0,"total":4}"#,
            );
            let mut s = liked_filter_accept(&l);
            let method = if liked { "POST" } else { "DELETE" };
            assert!(
                request(&mut s).starts_with(&format!("{method} /api/v1/library/tracks/2/like "))
            );
            if !status.is_empty() {
                send(&mut s, status, body);
            }
            drop(s);
            l
        });
        load(&c);
        assert!(
            c.execute(liked_filter_command(filtered, 0, "", "title", "asc"))
                .ok
        );
        let selected = c.execute(Command::Select { track_id: 2 });
        assert!(selected.ok && selected.audio.as_ref().is_some_and(|e| e.cached));
        let state = selected.snapshot;
        assert!(state.selected_occurrence.is_some() && state.queue.len() == 2);
        assert!(
            c.execute(Command::AudioReport {
                epoch: 1,
                session: state.session,
                state: AudioState::Playing,
                position_ms: 4321,
                duration_ms: 30000
            })
            .ok
        );
        let before = c.execute(Command::Snapshot {});
        assert_eq!(before.snapshot.transport, AudioState::Playing);
        assert_eq!(before.snapshot.position_ms, 4321);
        assert!(before.snapshot.selected_occurrence.is_some());
        let files = liked_filter_files(&root);
        assert!(
            !files.is_empty(),
            "establish saved queue bytes before mutation"
        );
        let result = c.execute(favorite(2, liked));
        assert_eq!(result.code, code);
        assert_eq!(result.ok, code == "ok");
        assert_eq!(result.snapshot.library, before.snapshot.library);
        assert_eq!(
            (
                result.snapshot.total,
                result.snapshot.offset,
                result.snapshot.library_revision
            ),
            (
                before.snapshot.total,
                before.snapshot.offset,
                before.snapshot.library_revision
            )
        );
        assert_eq!(
            liked_filter_playback(&result),
            liked_filter_playback(&before)
        );
        assert_eq!(
            ids(&result),
            if code == "ok" && !liked {
                json!([4])
            } else {
                json!([2, 4])
            }
        );
        assert!(result.audio.is_none() && result.credentials.is_none());
        assert_eq!(liked_filter_files(&root), files);
        let l = server.join().unwrap();
        no_extra(&l);
        // A bounded responder makes a missing guard fail behaviorally rather than
        // hanging. After unlike the server set is [4,6,8], so stale offset2
        // returns8 and skips the still-unloaded row6.
        let server = thread::spawn(move || {
            l.set_nonblocking(true).unwrap();
            let deadline = std::time::Instant::now() + Duration::from_millis(250);
            let mut dispatched = false;
            while std::time::Instant::now() < deadline {
                match l.accept() {
                    Ok((mut s, _)) => {
                        s.set_nonblocking(false).unwrap();
                        let raw = request(&mut s);
                        assert!(raw.starts_with("GET /api/v1/library?"));
                        assert!(raw.contains("offset=2"));
                        dispatched = true;
                        let page = if invalidated {
                            // Accepted unlike (or a possibly committed one) shifted
                            // the server set; retaining offset2 loses row6.
                            r#"{"tracks":[{"id":8,"title":"Eight","is_liked":true}],"offset":2,"total":3}"#
                        } else {
                            r#"{"tracks":[{"id":6,"title":"Six","is_liked":true}],"offset":2,"total":4}"#
                        };
                        send(&mut s, "200 OK", page);
                        break;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(e) => panic!("accept: {e}"),
                }
            }
            (l, dispatched)
        });
        let append = c.execute(liked_filter_command(filtered, 2, "", "title", "asc"));
        let (l, dispatched) = server.join().unwrap();
        if invalidated && append.ok {
            assert_eq!(liked_filter_rows(&append), vec![2, 4, 8]);
            assert!(
                !liked_filter_rows(&append).contains(&6),
                "positive skipped-server-row witness"
            );
        }
        assert_eq!(
            append.code,
            if invalidated { "invalid_query" } else { "ok" },
            "filtered={filtered}, liked={liked}, outcome={code}: shifted pagination must require explicit offset-zero read"
        );
        assert_eq!(
            dispatched, !invalidated,
            "stale append must be refused before HTTP"
        );
        if invalidated {
            assert_eq!(append.snapshot.library, before.snapshot.library);
            assert_eq!(ids(&append), ids(&result));
            assert_eq!(
                append.snapshot.library_revision,
                before.snapshot.library_revision
            );
        } else {
            assert_eq!(liked_filter_rows(&append), vec![2, 4, 6]);
        }
        assert_eq!(
            liked_filter_playback(&append),
            liked_filter_playback(&before)
        );
        assert_eq!(liked_filter_files(&root), files);
        // Only the user-issued read reconciles membership; its next append must
        // include the previously shifted row and the following page in order.
        let server = thread::spawn(move || {
            liked_filter_page(
                &l,
                filtered,
                0,
                "",
                "title",
                "asc",
                "200 OK",
                r#"{"tracks":[{"id":4,"title":"Four","is_liked":true}],"offset":0,"total":3}"#,
            );
            liked_filter_page(
                &l,
                filtered,
                1,
                "",
                "title",
                "asc",
                "200 OK",
                r#"{"tracks":[{"id":6,"title":"Six","is_liked":true},{"id":8,"title":"Eight","is_liked":true}],"offset":1,"total":3}"#,
            );
            l
        });
        let refresh = c.execute(liked_filter_command(filtered, 0, "", "title", "asc"));
        assert!(refresh.ok);
        assert_eq!(liked_filter_rows(&refresh), vec![4]);
        let append = c.execute(liked_filter_command(filtered, 1, "", "title", "asc"));
        assert!(append.ok);
        assert_eq!(liked_filter_rows(&append), vec![4, 6, 8]);
        assert_eq!(
            liked_filter_playback(&append),
            liked_filter_playback(&before)
        );
        assert_eq!(liked_filter_files(&root), files);
        let l = server.join().unwrap();
        no_extra(&l);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn dispatched_cancelled_liked_unlike_retires_append_after_same_account_next() {
    let (c, root, l) = fixture();
    liked_filter_cached_tracks(&root, &l, &[2, 4]);
    let (entered, waiting) = mpsc::channel();
    let (release, resume) = mpsc::channel();
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","duration_ms":30000,"is_liked":true},{"id":4,"title":"Four","duration_ms":30000,"is_liked":true}],"offset":0,"total":4}"#,
        );
        let mut s = liked_filter_accept(&l);
        assert!(request(&mut s).starts_with("DELETE /api/v1/library/tracks/2/like "));
        entered.send(()).unwrap();
        resume.recv_timeout(Duration::from_secs(3)).unwrap();
        // Commit server membership after local revocation, before acknowledgment.
        let committed = vec![4, 6, 8];
        send(&mut s, "204 No Content", "");
        (l, committed)
    });
    load(&c);
    assert!(
        c.execute(liked_filter_command(true, 0, "", "title", "asc"))
            .ok
    );
    let selected = c.execute(Command::Select { track_id: 2 });
    assert!(selected.ok && selected.audio.unwrap().cached);
    assert!(
        c.execute(Command::AudioReport {
            epoch: 1,
            session: selected.snapshot.session,
            state: AudioState::Playing,
            position_ms: 4321,
            duration_ms: 30000
        })
        .ok
    );
    let before = c.execute(Command::Snapshot {});
    let saved = liked_filter_files(&root);
    assert!(!saved.is_empty());
    let worker = c.clone();
    let mutation = thread::spawn(move || worker.execute_scoped_at(favorite(2, false), 1, Some(1)));
    waiting.recv_timeout(Duration::from_secs(3)).unwrap();
    let epoch = c.revoke();
    let worker = c.clone();
    let next = thread::spawn(move || worker.execute_scoped_at(Command::Next {}, epoch, Some(1)));
    release.send(()).unwrap();
    let cancelled = mutation.join().unwrap();
    assert_eq!(cancelled.code, "cancelled");
    assert!(!cancelled.snapshot.authenticated && cancelled.snapshot.library.is_empty());
    assert_eq!(ids(&cancelled), json!([]));
    assert!(cancelled.audio.is_none() && cancelled.credentials.is_none());
    let next = next.join().unwrap();
    let (l, committed) = server.join().unwrap();
    assert_eq!(committed, vec![4, 6, 8]);
    println!(
        "R2_WITNESS dispatched DELETE; server committed [4,6,8] after revoke; local favorite publication cancelled"
    );
    assert!(
        next.ok
            && next
                .audio
                .as_ref()
                .is_some_and(|e| e.cached && e.epoch == epoch)
    );
    assert_eq!(next.snapshot.library, before.snapshot.library);
    assert_eq!(ids(&next), ids(&before));
    assert_eq!(
        next.snapshot.library_revision,
        before.snapshot.library_revision
    );
    assert_eq!(
        serde_json::to_value(&next.snapshot.queue).unwrap(),
        serde_json::to_value(&before.snapshot.queue).unwrap()
    );
    assert_eq!(
        next.snapshot.selected_occurrence,
        Some(before.snapshot.queue[1].id)
    );
    assert_eq!(next.snapshot.position_ms, 0);
    assert!(next.snapshot.session > before.snapshot.session);
    assert!(next.snapshot.authenticated && next.credentials.is_none());
    let after_next = liked_filter_files(&root);
    for (path, bytes) in &saved {
        if path.file_name().unwrap() != "listening-queue-v1.json" {
            assert_eq!(after_next.get(path), Some(bytes));
        }
    }
    no_extra(&l);
    let server = thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_millis(250);
        let mut dispatched = false;
        while std::time::Instant::now() < deadline {
            match l.accept() {
                Ok((mut s, _)) => {
                    s.set_nonblocking(false).unwrap();
                    let raw = request(&mut s);
                    assert!(raw.starts_with("GET /api/v1/library?") && raw.contains("offset=2"));
                    dispatched = true;
                    send(
                        &mut s,
                        "200 OK",
                        r#"{"tracks":[{"id":8,"title":"Eight","is_liked":true}],"offset":2,"total":3}"#,
                    );
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2))
                }
                Err(e) => panic!("accept: {e}"),
            }
        }
        (l, dispatched)
    });
    let append = c.execute_scoped_at(
        liked_filter_command(true, 2, "", "title", "asc"),
        epoch,
        Some(1),
    );
    let (l, dispatched) = server.join().unwrap();
    if append.ok {
        assert_eq!(liked_filter_rows(&append), vec![2, 4, 8]);
        assert!(!liked_filter_rows(&append).contains(&6));
        println!("R2_WITNESS unsafe HTTP offset2 admitted; still-unloaded row6 skipped");
    }
    assert_eq!(
        append.code, "invalid_query",
        "dispatched cancelled mutation may have committed; require explicit refresh"
    );
    assert!(!dispatched, "stale append must be refused before HTTP");
    assert_eq!(append.snapshot.library, before.snapshot.library);
    assert_eq!(ids(&append), ids(&before));
    assert_eq!(liked_filter_playback(&append), liked_filter_playback(&next));
    assert_eq!(liked_filter_files(&root), after_next);
    let server = thread::spawn(move || {
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":4,"title":"Four","is_liked":true}],"offset":0,"total":3}"#,
        );
        liked_filter_page(
            &l,
            true,
            1,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":6,"title":"Six","is_liked":true},{"id":8,"title":"Eight","is_liked":true}],"offset":1,"total":3}"#,
        );
        l
    });
    assert!(
        c.execute_scoped_at(
            liked_filter_command(true, 0, "", "title", "asc"),
            epoch,
            Some(1)
        )
        .ok
    );
    let recovered = c.execute_scoped_at(
        liked_filter_command(true, 1, "", "title", "asc"),
        epoch,
        Some(1),
    );
    assert!(recovered.ok);
    assert_eq!(liked_filter_rows(&recovered), committed);
    assert_eq!(
        liked_filter_playback(&recovered),
        liked_filter_playback(&next)
    );
    assert_eq!(liked_filter_files(&root), after_next);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cancelled_before_favorite_dispatch_preserves_safe_liked_append() {
    let (c, root, l) = fixture();
    liked_filter_cached_tracks(&root, &l, &[2, 4]);
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","is_liked":true},{"id":4,"title":"Four","is_liked":true}],"offset":0,"total":3}"#,
        );
        l
    });
    load(&c);
    assert!(
        c.execute(liked_filter_command(true, 0, "", "title", "asc"))
            .ok
    );
    assert!(c.execute(Command::Select { track_id: 2 }).ok);
    let epoch = c.revoke();
    assert_eq!(
        c.execute_scoped_at(favorite(2, false), 1, Some(1)).code,
        "cancelled"
    );
    // Even a current enqueue epoch cannot admit metadata before transport adopts it.
    assert_eq!(
        c.execute_scoped_at(favorite(2, false), epoch, Some(1)).code,
        "cancelled"
    );
    let next = c.execute_scoped_at(Command::Next {}, epoch, Some(1));
    assert!(next.ok);
    assert_eq!(
        c.execute_scoped_at(favorite(2, false), 1, Some(1)).code,
        "cancelled"
    );
    let l = server.join().unwrap();
    no_extra(&l);
    let files = liked_filter_files(&root);
    let server = thread::spawn(move || {
        liked_filter_page(
            &l,
            true,
            2,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":6,"title":"Six","is_liked":true}],"offset":2,"total":3}"#,
        );
        l
    });
    let append = c.execute_scoped_at(
        liked_filter_command(true, 2, "", "title", "asc"),
        epoch,
        Some(1),
    );
    assert!(append.ok);
    assert_eq!(liked_filter_rows(&append), vec![2, 4, 6]);
    assert_eq!(liked_filter_playback(&append), liked_filter_playback(&next));
    assert_eq!(liked_filter_files(&root), files);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

// Prepared source-only regressions. Decode the proposed additive command through
// the real serde contract before creating a server: an unsupported command must
// fail an assertion, not compilation or a blocked server thread.
fn liked_filter_command(liked: bool, offset: u32, query: &str, sort: &str, order: &str) -> Command {
    let decoded = serde_json::from_value::<Command>(json!({
        "command": if liked { "library_liked" } else { "library" },
        "offset": offset, "query": query, "sort": sort, "order": order
    }));
    assert!(
        decoded.is_ok(),
        "Library filter JSON must be admitted by the real Command decoder: {}",
        decoded
            .as_ref()
            .err()
            .map(ToString::to_string)
            .unwrap_or_default()
    );
    decoded.unwrap()
}

fn liked_filter_accept(l: &TcpListener) -> TcpStream {
    l.set_nonblocking(true).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        match l.accept() {
            Ok((s, _)) => {
                s.set_nonblocking(false).unwrap();
                return s;
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(
                    std::time::Instant::now() < deadline,
                    "expected loopback request did not arrive"
                );
                thread::sleep(Duration::from_millis(5));
            }
            Err(e) => panic!("loopback accept failed: {e}"),
        }
    }
}

fn liked_filter_page(
    l: &TcpListener,
    liked: bool,
    offset: u32,
    query: &str,
    sort: &str,
    order: &str,
    status: &str,
    body: &str,
) {
    let mut s = liked_filter_accept(l);
    let raw = request(&mut s);
    let mut first = raw.lines().next().unwrap().split_whitespace();
    assert_eq!(first.next(), Some("GET"));
    let url = reqwest::Url::parse(&format!("http://127.0.0.1{}", first.next().unwrap())).unwrap();
    assert_eq!(url.path(), "/api/v1/library");
    let pairs: Vec<_> = url
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    let mut expected: Vec<(String, String)> = vec![
        ("limit".into(), "50".into()),
        ("offset".into(), offset.to_string()),
        ("q".into(), query.into()),
        ("sort".into(), sort.into()),
        ("order".into(), order.into()),
    ];
    if liked {
        expected.push(("liked".into(), "true".into()));
    }
    let mut actual = pairs;
    actual.sort();
    expected.sort();
    assert_eq!(
        actual, expected,
        "exact query, including no liked=false on plain Library"
    );
    assert!(
        raw.to_lowercase()
            .contains("authorization: bearer synthetic-access")
    );
    send(&mut s, status, body);
}

fn liked_filter_rows(r: &Reply) -> Vec<i64> {
    r.snapshot.library.iter().map(|t| t.id).collect()
}
fn liked_filter_playback(r: &Reply) -> Value {
    json!({"queue":r.snapshot.queue,"selected":r.snapshot.selected_occurrence,
        "session":r.snapshot.session,"epoch":r.snapshot.epoch,"transport":r.snapshot.transport,
        "position":r.snapshot.position_ms,"duration":r.snapshot.duration_ms})
}
fn liked_filter_files(root: &std::path::Path) -> std::collections::BTreeMap<PathBuf, Vec<u8>> {
    fn visit(
        root: &std::path::Path,
        dir: &std::path::Path,
        files: &mut std::collections::BTreeMap<PathBuf, Vec<u8>>,
    ) {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                visit(root, &path, files);
            } else {
                files.insert(
                    path.strip_prefix(root).unwrap().to_path_buf(),
                    fs::read(path).unwrap(),
                );
            }
        }
    }
    let mut files = std::collections::BTreeMap::new();
    visit(root, root, &mut files);
    files
}
fn liked_filter_cached_tracks(root: &std::path::Path, l: &TcpListener, tracks: &[i64]) {
    let endpoint = format!("http://{}/api/v1", l.local_addr().unwrap());
    let dir = root.join(format!(
        "{:x}",
        Sha256::digest(format!("{endpoint}\0synthetic-account").as_bytes())
    ));
    fs::create_dir_all(&dir).unwrap();
    // Policy-only immutable cache witness, deliberately never decoded or played.
    let bytes = b"synthetic-owned-cache-witness";
    for id in tracks {
        let name = format!("{id}-liked-filter.wav");
        fs::write(dir.join(&name), bytes).unwrap();
        fs::write(
            dir.join(format!("{id}.json")),
            serde_json::to_vec(&json!({
                "name":name,"sha256":format!("{:x}",Sha256::digest(bytes))
            }))
            .unwrap(),
        )
        .unwrap();
    }
}

#[test]
fn liked_filter_json_is_additive_and_plain_library_remains_compatible() {
    let _ = liked_filter_command(true, 0, "Ω & ?", "added_at", "desc");
    assert!(matches!(
        liked_filter_command(false, 0, "", "title", "asc"),
        Command::Library { offset: 0, .. }
    ));
    // No required field was added to old Rust literal constructors.
    let _ = library(0);
    for body in [
        json!({"command":"library_liked","offset":0,"query":"","sort":"title"}),
        json!({"command":"library_liked","offset":0,"query":"","sort":"title","order":"asc","liked":true}),
        json!({"command":"library","offset":0,"query":"","sort":"title","order":"asc","liked":true}),
    ] {
        assert!(serde_json::from_value::<Command>(body).is_err());
    }
}

#[test]
fn liked_filter_pages_search_and_select_use_only_loaded_membership() {
    let first = liked_filter_command(true, 0, "", "title", "asc");
    let (c, root, l) = fixture();
    liked_filter_cached_tracks(&root, &l, &[2, 4, 6]);
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","duration_ms":30000,"is_liked":true},{"id":4,"title":"Four","duration_ms":30000,"is_liked":true}],"total":4,"offset":0}"#,
        );
        liked_filter_page(
            &l,
            true,
            2,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":6,"title":"Six","duration_ms":30000,"is_liked":true}],"total":4,"offset":2}"#,
        );
        liked_filter_page(
            &l,
            true,
            0,
            "Ω & ?",
            "artist",
            "desc",
            "200 OK",
            r#"{"tracks":[{"id":6,"title":"Six","is_liked":true}],"total":1,"offset":0}"#,
        );
        liked_filter_page(&l, false, 0, "", "title", "asc", "200 OK", PAGE);
        l
    });
    load(&c);
    let before = c.execute(Command::Snapshot {});
    let files = liked_filter_files(&root);
    let r = c.execute(first);
    assert!(r.ok, "{}", r.code);
    assert_eq!(liked_filter_rows(&r), vec![2, 4]);
    assert_eq!(ids(&r), json!([2, 4]));
    assert_eq!(r.snapshot.total, 4);
    assert_eq!(r.snapshot.abi, 1);
    assert!(r.audio.is_none());
    assert_eq!(liked_filter_playback(&r), liked_filter_playback(&before));
    let r = c.execute(liked_filter_command(true, 2, "", "title", "asc"));
    assert!(r.ok, "{}", r.code);
    assert_eq!(liked_filter_rows(&r), vec![2, 4, 6]);
    assert_eq!(ids(&r), json!([2, 4, 6]));
    assert_eq!(r.snapshot.offset, 2);
    assert_eq!(r.snapshot.total, 4);
    assert!(r.audio.is_none());
    assert_eq!(liked_filter_files(&root), files);
    // Select is the production queue builder, not a test-side filtered queue.
    let selected = c.execute(Command::Select { track_id: 4 });
    assert!(selected.ok, "{}", selected.code);
    assert!(selected.audio.as_ref().unwrap().cached);
    assert_eq!(
        selected
            .snapshot
            .queue
            .iter()
            .map(|o| o.track.id)
            .collect::<Vec<_>>(),
        vec![2, 4, 6]
    );
    let occurrence = selected.snapshot.selected_occurrence.unwrap();
    let next = c.execute(Command::Next {});
    assert!(next.ok);
    assert_eq!(
        next.snapshot
            .queue
            .iter()
            .find(|o| Some(o.id) == next.snapshot.selected_occurrence)
            .unwrap()
            .track
            .id,
        6
    );
    let previous = c.execute(Command::Previous {});
    assert!(previous.ok);
    assert_eq!(previous.snapshot.selected_occurrence, Some(occurrence));
    assert!(
        c.execute(Command::AudioReport {
            epoch: 1,
            session: previous.snapshot.session,
            state: AudioState::Playing,
            position_ms: 4321,
            duration_ms: 30000
        })
        .ok
    );
    let playing = c.execute(Command::Snapshot {});
    let files = liked_filter_files(&root);
    let searched = c.execute(liked_filter_command(true, 0, "Ω & ?", "artist", "desc"));
    assert!(searched.ok);
    assert_eq!(liked_filter_rows(&searched), vec![6]);
    assert_eq!(ids(&searched), json!([6]));
    assert!(searched.audio.is_none());
    assert_eq!(
        liked_filter_playback(&searched),
        liked_filter_playback(&playing)
    );
    let all = c.execute(liked_filter_command(false, 0, "", "title", "asc"));
    assert!(all.ok);
    assert_eq!(liked_filter_rows(&all), vec![1, 2]);
    assert_eq!(ids(&all), json!([2]));
    assert!(all.audio.is_none());
    assert_eq!(liked_filter_playback(&all), liked_filter_playback(&playing));
    assert_eq!(liked_filter_files(&root), files);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn liked_filter_rejects_invalid_query_without_transport_or_projection_change() {
    let _ = liked_filter_command(true, 0, "", "title", "asc");
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        l
    });
    load(&c);
    let l = server.join().unwrap();
    let baseline = c.execute(Command::Snapshot {});
    for (offset, query, sort, order) in [
        (0, "x".repeat(513), "title", "asc"),
        (1_000_001, String::new(), "title", "asc"),
        (0, String::new(), "favorite_time", "asc"),
        (0, String::new(), "title", "sideways"),
    ] {
        let r = c.execute(liked_filter_command(true, offset, &query, sort, order));
        assert!(!r.ok);
        assert_eq!(r.code, "invalid_query");
        assert_eq!(r.snapshot.library, baseline.snapshot.library);
        assert_eq!(ids(&r), ids(&baseline));
        assert!(r.audio.is_none());
    }
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn liked_filter_plain_library_cross_query_append_is_refused_without_http() {
    // Independently reaches today's Library implementation even before the new
    // additive command is supported; do not confuse decoder RED with this guard.
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        l
    });
    load(&c);
    let l = server.join().unwrap();
    let baseline = c.execute(Command::Snapshot {});
    let files = liked_filter_files(&root);
    // Close admission immediately, not a blocking extra server loop: today's
    // unexpected HTTP request fails locally instead of hanging the test.
    drop(l);
    let r = c.execute(liked_filter_command(
        false,
        2,
        "different query",
        "title",
        "asc",
    ));
    assert_eq!(
        r.code, "invalid_query",
        "cross-query append must be refused before transport"
    );
    assert!(!r.ok);
    assert_eq!(r.snapshot.library, baseline.snapshot.library);
    assert_eq!(ids(&r), ids(&baseline));
    assert_eq!(liked_filter_playback(&r), liked_filter_playback(&baseline));
    assert!(r.audio.is_none());
    assert_eq!(liked_filter_files(&root), files);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn liked_filter_query_identity_refuses_cross_filter_query_sort_order_append() {
    let liked = liked_filter_command(true, 0, "", "title", "asc");
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","is_liked":true}],"total":2,"offset":0}"#,
        );
        liked_filter_page(
            &l,
            true,
            1,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":4,"title":"Four","is_liked":true}],"total":2,"offset":1}"#,
        );
        l
    });
    load(&c);
    for (liked, query, sort, order) in [
        (true, "", "title", "asc"),
        (false, "other", "title", "asc"),
        (false, "", "artist", "asc"),
        (false, "", "title", "desc"),
    ] {
        let r = c.execute(liked_filter_command(liked, 2, query, sort, order));
        assert!(!r.ok, "cross-identity append must be refused before HTTP");
        assert_eq!(r.code, "invalid_query");
        assert_eq!(liked_filter_rows(&r), vec![1, 2]);
        assert_eq!(ids(&r), json!([2]));
        assert!(r.audio.is_none());
    }
    let r = c.execute(liked);
    assert!(r.ok);
    assert_eq!(liked_filter_rows(&r), vec![2]);
    let r = c.execute(liked_filter_command(false, 1, "", "title", "asc"));
    assert!(!r.ok);
    assert_eq!(r.code, "invalid_query");
    assert_eq!(liked_filter_rows(&r), vec![2]);
    let r = c.execute(liked_filter_command(true, 1, "", "title", "asc"));
    assert!(r.ok);
    assert_eq!(liked_filter_rows(&r), vec![2, 4]);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn liked_filter_failed_zero_preserves_acknowledged_projection_and_identity() {
    let liked = liked_filter_command(true, 0, "", "title", "asc");
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","is_liked":true}],"total":2,"offset":0}"#,
        );
        liked_filter_page(
            &l,
            false,
            0,
            "other",
            "artist",
            "desc",
            "503 Service Unavailable",
            "{}",
        );
        liked_filter_page(
            &l,
            true,
            0,
            "other",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":9,"title":"Wrong offset","is_liked":true}],"total":1,"offset":1}"#,
        );
        liked_filter_page(&l, true, 0, "other", "title", "asc", "403 Forbidden", "{}");
        liked_filter_page(
            &l,
            true,
            1,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":4,"title":"Four","is_liked":true}],"total":2,"offset":1}"#,
        );
        liked_filter_page(
            &l,
            true,
            0,
            "no matches",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":null,"total":0,"offset":0}"#,
        );
        l
    });
    load(&c);
    assert!(c.execute(liked).ok);
    let before = c.execute(Command::Snapshot {});
    let files = liked_filter_files(&root);
    for (liked, query, sort, order, code) in [
        (false, "other", "artist", "desc", "service_unavailable"),
        (true, "other", "title", "asc", "invalid_library"),
        (true, "other", "title", "asc", "api_refused"),
    ] {
        let r = c.execute(liked_filter_command(liked, 0, query, sort, order));
        assert!(!r.ok);
        assert_eq!(r.code, code);
        assert_eq!(r.snapshot.library, before.snapshot.library);
        assert_eq!(ids(&r), ids(&before));
        assert_eq!((r.snapshot.total, r.snapshot.offset), (2, 0));
        assert!(r.audio.is_none());
        assert_eq!(liked_filter_playback(&r), liked_filter_playback(&before));
        assert_eq!(liked_filter_files(&root), files);
    }
    let mismatch = c.execute(liked_filter_command(false, 1, "other", "artist", "desc"));
    assert!(!mismatch.ok);
    assert_eq!(mismatch.code, "invalid_query");
    let appended = c.execute(liked_filter_command(true, 1, "", "title", "asc"));
    assert!(appended.ok);
    assert_eq!(liked_filter_rows(&appended), vec![2, 4]);
    let empty = c.execute(liked_filter_command(true, 0, "no matches", "title", "asc"));
    assert!(empty.ok);
    assert!(empty.snapshot.library.is_empty());
    assert_eq!(ids(&empty), json!([]));
    assert_eq!(empty.snapshot.total, 0);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn liked_filter_safe_read_refresh_retries_same_filtered_request_once() {
    let liked = liked_filter_command(true, 0, "Two", "duration", "desc");
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "Two",
            "duration",
            "desc",
            "401 Unauthorized",
            "{}",
        );
        let mut s = liked_filter_accept(&l);
        assert!(request(&mut s).starts_with("POST /api/v1/auth/refresh "));
        send(&mut s, "200 OK", AUTH);
        liked_filter_page(
            &l,
            true,
            0,
            "Two",
            "duration",
            "desc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","is_liked":true}],"total":1,"offset":0}"#,
        );
        l
    });
    load(&c);
    let before = c.execute(Command::Snapshot {});
    let files = liked_filter_files(&root);
    let r = c.execute(liked);
    assert!(r.ok, "{}", r.code);
    assert_eq!(liked_filter_rows(&r), vec![2]);
    assert_eq!(ids(&r), json!([2]));
    assert!(r.credentials.is_some());
    assert!(r.audio.is_none());
    assert_eq!(liked_filter_playback(&r), liked_filter_playback(&before));
    assert_eq!(liked_filter_files(&root), files);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn liked_filter_held_read_revocation_suppresses_publication_and_account_retires_identity() {
    let liked = liked_filter_command(true, 0, "", "title", "asc");
    let (c, root, l) = fixture();
    let (entered, waiting) = mpsc::channel();
    let (release, resume) = mpsc::channel();
    let server = thread::spawn(move || {
        bootstrap(&l);
        let mut s = liked_filter_accept(&l);
        assert!(request(&mut s).starts_with("GET /api/v1/library?"));
        entered.send(()).unwrap();
        resume.recv_timeout(Duration::from_secs(3)).unwrap();
        send(
            &mut s,
            "200 OK",
            r#"{"tracks":[{"id":9,"title":"Late","is_liked":true}],"total":1,"offset":0}"#,
        );
        let mut s = liked_filter_accept(&l);
        assert!(request(&mut s).starts_with("POST /api/v1/auth/refresh "));
        send(
            &mut s,
            "200 OK",
            r#"{"accessToken":"account-b-access","refreshToken":"account-b-refresh","user":{"id":"account-b"}}"#,
        );
        l
    });
    load(&c);
    let worker = c.clone();
    let call = thread::spawn(move || worker.execute_scoped_at(liked, 1, Some(1)));
    waiting.recv_timeout(Duration::from_secs(3)).unwrap();
    let epoch = c.revoke();
    release.send(()).unwrap();
    let r = call.join().unwrap();
    assert_eq!(r.code, "cancelled");
    assert!(!r.ok);
    assert!(r.snapshot.library.is_empty());
    assert_eq!(ids(&r), json!([]));
    assert!(r.audio.is_none());
    // A stale reply is empty, but the last acknowledged account-A projection was not replaced.
    let old = c.execute_scoped_at(Command::Snapshot {}, epoch, Some(1));
    assert_eq!(liked_filter_rows(&old), vec![1, 2]);
    assert_eq!(ids(&old), json!([2]));
    let b = c.execute_scoped_at(
        Command::Restore {
            access_token: "b-old".into(),
            refresh_token: "b-refresh".into(),
            account_id: "account-b".into(),
        },
        epoch,
        Some(2),
    );
    assert!(b.ok);
    assert!(b.snapshot.library.is_empty());
    assert_eq!(ids(&b), json!([]));
    assert_eq!(
        c.execute_scoped_at(
            liked_filter_command(true, 0, "", "title", "asc"),
            epoch,
            Some(1)
        )
        .code,
        "cancelled"
    );
    let append = c.execute_scoped_at(
        liked_filter_command(false, 2, "", "title", "asc"),
        epoch,
        Some(2),
    );
    assert!(!append.ok);
    assert_eq!(append.code, "invalid_query");
    assert!(append.snapshot.library.is_empty());
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn library_publication_revision_survives_full_scalar_failure_and_retirement() {
    fn revision(r: &Reply) -> u64 {
        let value = serde_json::to_value(&r.snapshot).unwrap();
        assert!(
            value["library_revision"].is_u64(),
            "every snapshot must identify its loaded Library authority"
        );
        value["library_revision"].as_u64().unwrap()
    }
    let (c, root, l) = fixture();
    let server = thread::spawn(move || {
        bootstrap(&l);
        liked_filter_page(
            &l,
            true,
            0,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":2,"title":"Two","is_liked":true}],"offset":0,"total":2}"#,
        );
        liked_filter_page(
            &l,
            true,
            1,
            "",
            "title",
            "asc",
            "200 OK",
            r#"{"tracks":[{"id":3,"title":"Three","is_liked":true}],"offset":1,"total":2}"#,
        );
        let mut s = liked_filter_accept(&l);
        assert!(request(&mut s).starts_with("POST /api/v1/library/tracks/2/like "));
        send(&mut s, "201 Created", r#"{"track_id":2,"liked":true}"#);
        l
    });
    load(&c);
    let initial = c.execute(Command::Snapshot {});
    let first = revision(&initial);
    assert!(first > 0);
    let filtered = c.execute(liked_filter_command(true, 0, "", "title", "asc"));
    assert!(filtered.ok);
    assert_eq!(revision(&filtered), first + 1);
    let epoch = c.revoke();
    // No queue: genuine current transport failure still carries the new topic.
    let next = c.execute_at(Command::Next {}, epoch);
    assert!(!next.ok);
    assert_eq!(revision(&next), first + 1);
    assert_eq!(liked_filter_rows(&next), vec![2]);
    let scalar = c.execute_at(Command::Pause {}, epoch);
    assert!(scalar.snapshot.library_unchanged);
    assert_eq!(revision(&scalar), first + 1);
    let rejected = c.execute_at(liked_filter_command(false, 1, "", "title", "asc"), epoch);
    assert_eq!(rejected.code, "invalid_query");
    assert_eq!(revision(&rejected), first + 1);
    let page = c.execute_at(liked_filter_command(true, 1, "", "title", "asc"), epoch);
    assert!(page.ok);
    assert_eq!(revision(&page), first + 2);
    assert_eq!(liked_filter_rows(&page), vec![2, 3]);
    let favorite = c.execute_at(favorite(2, true), epoch);
    assert!(favorite.ok);
    assert_eq!(revision(&favorite), first + 2);
    let retired = c.execute_scoped_at(Command::Snapshot {}, epoch, Some(2));
    assert!(!retired.snapshot.authenticated);
    assert!(retired.snapshot.library.is_empty());
    assert_eq!(revision(&retired), 0);
    let l = server.join().unwrap();
    no_extra(&l);
    fs::remove_dir_all(root).unwrap();
}
