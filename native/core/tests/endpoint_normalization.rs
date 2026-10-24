use soundq_core::{Command, Core};
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::mpsc,
    thread,
    time::Duration,
};

#[test]
fn normalized_loopback_endpoint_reaches_real_library_request() {
    for prefix in ["/api/v1", "/prefix/api/v1/", "/music%20café/api/v1///"] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let endpoint = format!("HTTP://LOCALHOST:{port}{prefix}");
        let expected = prefix
            .trim_end_matches('/')
            .replace(' ', "%20")
            .replace('é', "%C3%A9");
        let (stop, stopped) = mpsc::channel();
        let server = thread::spawn(move || {
            let mut requests = vec![];
            while stopped.try_recv().is_err() {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut bytes = [0; 8192];
                        let n = stream.read(&mut bytes).unwrap();
                        let request = String::from_utf8_lossy(&bytes[..n]).to_string();
                        let body = if request.starts_with("POST ") {
                            r#"{"accessToken":"synthetic","refreshToken":"synthetic","user":{"id":"test"}}"#
                        } else {
                            r#"{"tracks":[],"total":0,"offset":0}"#
                        };
                        requests.push(request);
                        write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(e) => panic!("{e}"),
                }
            }
            requests
        });
        let root = std::env::temp_dir().join(format!("sq-endpoint-{}-{port}", std::process::id()));
        let core = Core::open(&endpoint, root.clone()).unwrap();
        let auth = core.execute(Command::Restore {
            access_token: "synthetic".into(),
            refresh_token: "synthetic".into(),
            account_id: "test".into(),
        });
        let reply = core.execute(Command::Library {
            offset: 0,
            query: "artist & title/é".into(),
            sort: "title".into(),
            order: "asc".into(),
        });
        stop.send(()).unwrap();
        let requests = server.join().unwrap();
        std::fs::remove_dir_all(root).unwrap();
        assert!(auth.ok, "{}", auth.code);
        assert!(
            reply.ok,
            "normalized endpoint library failed: {}",
            reply.code
        );
        assert_eq!(requests.len(), 2);
        assert!(
            requests[1].starts_with(&format!("GET {expected}/library?")),
            "{}",
            requests[1]
        );
        assert!(requests[1].contains("q=artist+%26+title%2F%C3%A9"));
    }
}

#[test]
fn unacceptable_endpoints_still_refused_before_storage() {
    for endpoint in [
        "https://example.invalid/api?x=1",
        "https://example.invalid/api#fragment",
        "https://user:password@example.invalid/api",
        "http://example.invalid/api",
        "https://example.invalid/api\n",
        " https://example.invalid/api",
        "https://example.invalid/a b",
        "https://example.invalid/api\u{7f}",
    ] {
        let root = std::env::temp_dir().join(format!("sq-endpoint-refusal-{}", std::process::id()));
        assert!(
            Core::open(endpoint, root.clone()).is_err(),
            "accepted {endpoint:?}"
        );
        assert!(!root.exists());
    }
}
