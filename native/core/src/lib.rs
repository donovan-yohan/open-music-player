mod model;
pub use model::*;
use reqwest::blocking::Client;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

const MAX_AUDIO_BYTES: u64 = 128 * 1024 * 1024;
const MAX_CACHE_BYTES: u64 = 256 * 1024 * 1024;

pub struct Core {
    epoch: AtomicU64,
    state: Mutex<State>,
    client: Client,
    endpoint: String,
    root: PathBuf,
}
struct State {
    snapshot: Snapshot,
    credentials: Option<Credentials>,
    credentials_changed: bool,
    credential_version: u64,
    account_scope_v1: u64,
    current_path: Option<PathBuf>,
    next_occurrence: u64,
    retry_target: Option<i64>,
    delivered_paths: HashSet<PathBuf>,
}
type Result<T> = std::result::Result<T, &'static str>;

// Names are only candidates. Exclusive creation, not PID/counter uniqueness,
// establishes ownership across handles, processes and leftovers after restart.
static NEXT_CACHE_TEMPORARY: AtomicU64 = AtomicU64::new(0);
struct CacheTemporary(PathBuf, bool);
impl Drop for CacheTemporary {
    fn drop(&mut self) {
        // Only a successfully created private name is ever eligible for cleanup.
        if self.1 {
            let _ = fs::remove_file(&self.0);
        }
    }
}
impl CacheTemporary {
    // The caller must sync and close its sole writer first. No platform may
    // replace a final name, including one already owned by a decoder.
    fn publish(&mut self, destination: &Path) -> std::io::Result<()> {
        #[cfg(any(target_os = "android", target_os = "linux", target_os = "macos"))]
        {
            use std::{ffi::CString, os::unix::ffi::OsStrExt};
            let from = CString::new(self.0.as_os_str().as_bytes())?;
            let to = CString::new(destination.as_os_str().as_bytes())?;
            #[cfg(any(target_os = "android", target_os = "linux"))]
            // Bionic's renameat2 symbol requires API30; the kernel operation is
            // available independently. Never fall back to overwriting rename.
            let result = unsafe {
                libc::syscall(
                    libc::SYS_renameat2,
                    libc::AT_FDCWD,
                    from.as_ptr(),
                    libc::AT_FDCWD,
                    to.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(target_os = "macos")]
            let result = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) };
            if result != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // Rename consumed our name. It can immediately belong to a new
            // allocator; dropping this guard must not unlink that new owner.
            self.1 = false;
            Ok(())
        }
        #[cfg(not(any(target_os = "android", target_os = "linux", target_os = "macos")))]
        fs::hard_link(&self.0, destination)
    }
}
fn cache_temporary(dir: &Path, prefix: &str, suffix: &str) -> Result<(CacheTemporary, fs::File)> {
    for _ in 0..128 {
        let serial = NEXT_CACHE_TEMPORARY.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!("{prefix}-{}-{serial}.{suffix}", std::process::id()));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => return Ok((CacheTemporary(path, true), file)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err("cache_io"),
        }
    }
    Err("cache_io")
}

fn container_suffix(content_type: &str) -> Result<&'static str> {
    match content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "audio/mpeg" => Ok("mp3"),
        "audio/mp4" => Ok("m4a"),
        "audio/aac" => Ok("aac"),
        "audio/wav" | "audio/x-wav" => Ok("wav"),
        "audio/ogg" => Ok("ogg"),
        "audio/opus" => Ok("opus"),
        "audio/flac" | "audio/x-flac" => Ok("flac"),
        _ => Err("unsupported_container"),
    }
}

impl Core {
    pub fn open(endpoint: &str, root: PathBuf) -> Result<Self> {
        if endpoint.bytes().any(|b| b <= 0x20 || b == 0x7f) {
            return Err("invalid_endpoint");
        }
        let url = reqwest::Url::parse(endpoint).map_err(|_| "invalid_endpoint")?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("invalid_endpoint");
        }
        if url.scheme() == "http"
            && !matches!(
                url.host_str(),
                Some("localhost" | "127.0.0.1" | "10.0.2.2" | "[::1]")
            )
        {
            return Err("insecure_endpoint");
        }
        fs::create_dir_all(&root).map_err(|_| "storage_unavailable")?;
        let client = Client::builder()
            .timeout(Duration::from_secs(20))
            .connect_timeout(Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "http_unavailable")?;
        Ok(Self {
            epoch: AtomicU64::new(1),
            state: Mutex::new(State {
                snapshot: Snapshot {
                    abi: 1,
                    epoch: 1,
                    revision: 0,
                    session: 0,
                    authenticated: false,
                    library: vec![],
                    library_unchanged: false,
                    total: 0,
                    offset: 0,
                    queue: vec![],
                    selected_occurrence: None,
                    transport: AudioState::Idle,
                    position_ms: 0,
                    duration_ms: 0,
                    error: None,
                },
                credentials: None,
                credentials_changed: false,
                credential_version: 0,
                account_scope_v1: 0,
                current_path: None,
                next_occurrence: 1,
                retry_target: None,
                delivered_paths: HashSet::new(),
            }),
            client,
            endpoint: endpoint.trim_end_matches('/').into(),
            root,
        })
    }

    /// Revokes publication immediately; native caller must stop its decoder before
    /// another account/selection is dispatched. This is not a physical stop ACK.
    pub fn revoke(&self) -> u64 {
        self.epoch.fetch_add(1, Ordering::SeqCst) + 1
    }
    fn check(&self, epoch: u64) -> Result<()> {
        if self.epoch.load(Ordering::SeqCst) == epoch {
            Ok(())
        } else {
            Err("cancelled")
        }
    }
    pub fn execute(&self, command: Command) -> Reply {
        let epoch = self.epoch.load(Ordering::SeqCst);
        self.execute_at(command, epoch)
    }
    /// Capture epoch at enqueue, not at dequeue. Old queued intent must never
    /// acquire authority over a later selection merely because it ran later.
    pub fn execute_at(&self, command: Command, epoch: u64) -> Reply {
        self.execute_scoped_at(command, epoch, None)
    }
    // Additive adapter envelope v1. Account intent must retire the previous
    // account even if a later selection already cancelled its playback epoch.
    pub fn execute_scoped_at(&self, command: Command, epoch: u64, scope: Option<u64>) -> Reply {
        let transport_only = matches!(
            &command,
            Command::AudioReport { .. }
                | Command::Pause {}
                | Command::Resume {}
                | Command::Seek { .. }
        );
        let mut state = match self.state.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };
        let stale_account = scope.is_some_and(|scope| scope < state.account_scope_v1);
        if let Some(scope) = scope.filter(|scope| *scope > state.account_scope_v1) {
            // Preserve the pair only through this current explicit logout's
            // single best-effort request. A cancelled logout retires immediately.
            if !matches!(&command, Command::Logout {}) || self.check(epoch).is_err() {
                self.retire_account(&mut state);
            }
            state.account_scope_v1 = scope;
        }
        if stale_account || self.check(epoch).is_err() {
            return Reply {
                ok: false,
                code: "cancelled".into(),
                snapshot: Snapshot {
                    epoch: self.epoch.load(Ordering::SeqCst),
                    authenticated: false,
                    library: vec![],
                    queue: vec![],
                    selected_occurrence: None,
                    transport: AudioState::Idle,
                    ..state.snapshot.clone()
                },
                audio: None,
                credentials: None,
            };
        }
        if state.snapshot.epoch != epoch {
            state.snapshot.epoch = epoch;
            state.snapshot.session += 1;
            state.snapshot.transport = AudioState::Idle;
            state.snapshot.position_ms = 0;
            state.snapshot.queue.clear();
            state.snapshot.selected_occurrence = None;
            state.current_path = None;
        }
        let result = self.apply(&mut state, command, epoch);
        state.snapshot.revision = state.snapshot.revision.saturating_add(1);
        let (ok, code, audio, mut credentials) = match result {
            Ok((audio, credentials)) => (true, "ok", audio, credentials),
            Err(code) => {
                if code != "cancelled" {
                    state.snapshot.error = Some(code.into());
                }
                (false, code, None, None)
            }
        };
        // Delivery is not durable acknowledgement. Keep the current account's
        // rotation pending across playback revocation and failed storage until
        // an exact version is acknowledged by its private adapter.
        if state.credentials_changed {
            credentials = state.credentials.clone();
        }
        let mut snapshot = if transport_only {
            Snapshot {
                abi: 1,
                epoch: state.snapshot.epoch,
                revision: state.snapshot.revision,
                session: state.snapshot.session,
                authenticated: state.snapshot.authenticated,
                library: vec![],
                library_unchanged: true,
                total: state.snapshot.total,
                offset: state.snapshot.offset,
                queue: state.snapshot.queue.clone(),
                selected_occurrence: state.snapshot.selected_occurrence,
                transport: state.snapshot.transport,
                position_ms: state.snapshot.position_ms,
                duration_ms: state.snapshot.duration_ms,
                error: state.snapshot.error.clone(),
            }
        } else {
            state.snapshot.clone()
        };
        // Revocation can race even a snapshot copy. Mark the returned snapshot's
        // epoch; native consumers also gate private effects against current epoch.
        if self.check(epoch).is_err() {
            snapshot.library.clear();
            snapshot.queue.clear();
            snapshot.selected_occurrence = None;
            snapshot.authenticated = false;
            snapshot.transport = AudioState::Idle;
            snapshot.epoch = self.epoch.load(Ordering::SeqCst);
            return Reply {
                ok: false,
                code: "cancelled".into(),
                snapshot,
                audio: None,
                credentials: None,
            };
        }
        Reply {
            ok,
            code: code.into(),
            snapshot,
            audio,
            credentials,
        }
    }
    fn effect(
        &self,
        s: &State,
        action: &'static str,
        path: Option<PathBuf>,
        cached: bool,
    ) -> AudioEffect {
        AudioEffect {
            action,
            epoch: s.snapshot.epoch,
            session: s.snapshot.session,
            path,
            position_ms: s.snapshot.position_ms,
            cached,
        }
    }
    fn apply(
        &self,
        s: &mut State,
        command: Command,
        epoch: u64,
    ) -> Result<(Option<AudioEffect>, Option<Credentials>)> {
        self.check(epoch)?;
        if !matches!(
            &command,
            Command::Snapshot {} | Command::Credentials {} | Command::AudioReport { .. }
        ) {
            s.snapshot.error = None;
        }
        match command {
            Command::Snapshot {} => {}
            Command::Credentials {} => return Ok((None, s.credentials.clone())),
            Command::AcknowledgeCredentials { version } => {
                if s.credentials.as_ref().is_some_and(|c| c.version == version) {
                    s.credentials_changed = false;
                }
            }
            Command::Login { email, password } => {
                self.retire_account(s);
                if email.len() > 254 || password.len() > 1024 {
                    return Err("invalid_credentials");
                }
                let response =
                    self.auth("login", json!({"email":email,"password":password}), epoch)?;
                self.admit(s, response, epoch)?;
            }
            Command::Register {
                email,
                password,
                username,
            } => {
                self.retire_account(s);
                if email.len() > 254 || password.len() > 1024 || username.len() > 50 {
                    return Err("invalid_credentials");
                }
                let response = self.auth(
                    "register",
                    json!({"email":email,"password":password,"username":username}),
                    epoch,
                )?;
                self.admit(s, response, epoch)?;
            }
            Command::Restore {
                access_token,
                refresh_token,
                account_id,
            } => {
                self.retire_account(s);
                if access_token.is_empty() || refresh_token.is_empty() || account_id.is_empty() {
                    return Err("invalid_credentials");
                }
                let c = Credentials {
                    version: 0,
                    access_token,
                    refresh_token,
                    account_id,
                };
                let response = self.auth("refresh", json!({"refreshToken":c.refresh_token}), epoch);
                // Restore is provisional until the held request completes in
                // its admitted epoch. Cancellation must not commit credentials.
                self.check(epoch)?;
                if let Ok(response) = response {
                    if response.user.id != c.account_id {
                        self.retire_account(s);
                        return Err("account_mismatch");
                    }
                    self.admit(s, response, epoch)?;
                } else if matches!(response, Err("authentication_failed")) {
                    self.retire_account(s);
                    return Err("authentication_failed");
                } else {
                    // The secure-store session remains usable for explicit
                    // retry/offline work after a transient service failure.
                    // Retire any previous account's content before accepting it.
                    self.retire_account(s);
                    s.credential_version += 1;
                    let mut c = c;
                    c.version = s.credential_version;
                    s.credentials = Some(c);
                    s.credentials_changed = true;
                    s.snapshot.authenticated = true;
                    return Err(response.err().unwrap_or("network_unavailable"));
                }
            }
            Command::Logout {} => {
                // Local intent retirement has already been synchronously revoked
                // by adapter. Remote logout is best effort, never auto-replayed.
                if s.credentials.is_some() {
                    let _ = self.request(s, "POST", "/auth/logout", None, epoch, false);
                }
                s.credentials = None;
                s.credentials_changed = false;
                s.snapshot.authenticated = false;
                s.snapshot.library.clear();
                s.snapshot.total = 0;
                s.snapshot.queue.clear();
                s.snapshot.selected_occurrence = None;
                s.snapshot.transport = AudioState::Idle;
                s.current_path = None;
                s.snapshot.session += 1;
                return Ok((Some(self.effect(s, "stop", None, false)), None));
            }
            Command::Library {
                offset,
                query,
                sort,
                order,
            } => {
                if query.len() > 512
                    || !matches!(sort.as_str(), "added_at" | "title" | "artist" | "duration")
                    || !matches!(order.as_str(), "asc" | "desc")
                    || offset > 1_000_000
                {
                    return Err("invalid_query");
                }
                let mut path = reqwest::Url::parse(&format!("{}/library", self.endpoint))
                    .map_err(|_| "invalid_endpoint")?;
                path.query_pairs_mut()
                    .append_pair("limit", "50")
                    .append_pair("offset", &offset.to_string())
                    .append_pair("q", &query)
                    .append_pair("sort", &sort)
                    .append_pair("order", &order);
                let relative = path
                    .as_str()
                    .strip_prefix(&self.endpoint)
                    .ok_or("invalid_endpoint")?;
                let page: LibraryPage =
                    serde_json::from_value(self.request(s, "GET", relative, None, epoch, true)?)
                        .map_err(|_| "invalid_library")?;
                let tracks = page.tracks.unwrap_or_default();
                if page.offset != offset
                    || tracks.len() > 50
                    || tracks.iter().any(|t| t.id <= 0 || t.title.len() > 16384)
                {
                    return Err("invalid_library");
                }
                self.check(epoch)?;
                if offset == 0 {
                    s.snapshot.library = tracks;
                } else {
                    for t in tracks {
                        if !s.snapshot.library.iter().any(|x| x.id == t.id) {
                            s.snapshot.library.push(t);
                        }
                    }
                }
                s.snapshot.total = page.total;
                s.snapshot.offset = offset;
            }
            Command::Select { track_id } => {
                let track = s
                    .snapshot
                    .library
                    .iter()
                    .find(|t| t.id == track_id)
                    .cloned()
                    .ok_or("track_not_loaded")?;
                s.retry_target = Some(track_id);
                let (path, cached) = self.prepare(s, track_id, epoch)?;
                self.check(epoch)?;
                let id = s.next_occurrence;
                s.next_occurrence += 1;
                s.snapshot.session += 1;
                s.snapshot.queue = vec![Occurrence {
                    id,
                    track: track.clone(),
                }];
                s.snapshot.selected_occurrence = Some(id);
                s.snapshot.transport = AudioState::Preparing;
                s.snapshot.position_ms = 0;
                s.snapshot.duration_ms = track.duration_ms.unwrap_or(0);
                s.current_path = Some(path.clone());
                // AVPlayer does not provide a general decoder/file-retirement
                // barrier. Retain every delivered immutable path for this core
                // lifetime rather than infer safety from pause/EOF/replacement.
                s.delivered_paths.insert(path.clone());
                return Ok((Some(self.effect(s, "load", Some(path), cached)), None));
            }
            Command::Pause {} => {
                s.snapshot.transport = AudioState::Paused;
                return Ok((Some(self.effect(s, "pause", None, false)), None));
            }
            Command::Resume {} => {
                if s.current_path.is_none() {
                    return Err("no_selection");
                }
                s.snapshot.transport = AudioState::Preparing;
                return Ok((Some(self.effect(s, "play", None, false)), None));
            }
            Command::Seek { position_ms } => {
                if s.current_path.is_none() || position_ms > s.snapshot.duration_ms {
                    return Err("invalid_seek");
                }
                s.snapshot.position_ms = position_ms;
                return Ok((Some(self.effect(s, "seek", None, false)), None));
            }
            Command::AudioReport {
                epoch: report_epoch,
                session,
                state,
                position_ms,
                duration_ms,
            } => {
                if report_epoch != epoch || session != s.snapshot.session {
                    return Err("stale_audio_report");
                }
                s.snapshot.transport = state;
                s.snapshot.position_ms = position_ms;
                // Android may transiently report zero while a freshly prepared
                // decoder settles. Zero is unknown, not evidence of an empty
                // source. Do not erase authoritative selected-track bounds.
                if duration_ms > 0 {
                    s.snapshot.duration_ms = duration_ms;
                }
                if state == AudioState::Failed {
                    s.snapshot.error = Some("native_playback_failed".into());
                }
            }
            Command::Retry {} => {
                let id = s.retry_target.ok_or("no_selection")?;
                if s.current_path.is_none() {
                    return self.apply(s, Command::Select { track_id: id }, epoch);
                }
                let (path, cached) = self.prepare(s, id, epoch)?;
                self.check(epoch)?;
                s.current_path = Some(path.clone());
                s.delivered_paths.insert(path.clone());
                s.snapshot.session += 1;
                s.snapshot.transport = AudioState::Preparing;
                s.snapshot.position_ms = 0;
                return Ok((Some(self.effect(s, "load", Some(path), cached)), None));
            }
            Command::ClearCache {} => {
                let dir = self.account_dir(s)?;
                for entry in fs::read_dir(dir).map_err(|_| "cache_io")? {
                    let path = entry.map_err(|_| "cache_io")?.path();
                    if !s.delivered_paths.contains(&path) && path.is_file() {
                        fs::remove_file(path).map_err(|_| "cache_io")?;
                    }
                }
            }
        }
        Ok((None, None))
    }
    fn auth(&self, route: &str, data: Value, epoch: u64) -> Result<AuthResponse> {
        self.auth_response(route, data, Some(epoch))
    }
    fn auth_response(&self, route: &str, data: Value, epoch: Option<u64>) -> Result<AuthResponse> {
        let response = self
            .client
            .post(format!("{}/auth/{route}", self.endpoint))
            .json(&data)
            .send()
            .map_err(|_| "network_unavailable")?;
        if let Some(epoch) = epoch {
            self.check(epoch)?;
        }
        if !response.status().is_success() {
            return Err(match response.status().as_u16() {
                401 | 403 => "authentication_failed",
                429 => "rate_limited",
                500..=599 => "service_unavailable",
                _ => "authentication_refused",
            });
        }
        let result: AuthResponse = serde_json::from_value(self.read_json_scoped(response, epoch)?)
            .map_err(|_| "invalid_auth_response")?;
        if result.access_token.is_empty()
            || result.refresh_token.is_empty()
            || result.user.id.is_empty()
        {
            return Err("invalid_auth_response");
        }
        Ok(result)
    }
    fn retire_account(&self, s: &mut State) {
        s.credentials = None;
        s.credentials_changed = false;
        s.current_path = None;
        s.retry_target = None;
        s.snapshot.authenticated = false;
        s.snapshot.library.clear();
        s.snapshot.total = 0;
        s.snapshot.queue.clear();
        s.snapshot.selected_occurrence = None;
        s.snapshot.transport = AudioState::Idle;
        s.snapshot.position_ms = 0;
        s.snapshot.session += 1;
    }
    fn admit(&self, s: &mut State, a: AuthResponse, epoch: u64) -> Result<()> {
        self.check(epoch)?;
        self.admit_credentials(s, a)
    }
    fn admit_credentials(&self, s: &mut State, a: AuthResponse) -> Result<()> {
        if s.credentials
            .as_ref()
            .is_some_and(|c| c.account_id != a.user.id)
        {
            s.snapshot.library.clear();
            s.snapshot.queue.clear();
            s.snapshot.selected_occurrence = None;
            s.snapshot.transport = AudioState::Idle;
            s.current_path = None;
            s.snapshot.session += 1;
        }
        s.credential_version += 1;
        s.credentials = Some(Credentials {
            version: s.credential_version,
            access_token: a.access_token,
            refresh_token: a.refresh_token,
            account_id: a.user.id,
        });
        s.credentials_changed = true;
        s.snapshot.authenticated = true;
        Ok(())
    }
    fn request(
        &self,
        s: &mut State,
        method: &str,
        path: &str,
        data: Option<Value>,
        epoch: u64,
        retry_read: bool,
    ) -> Result<Value> {
        for attempt in 0..2 {
            self.check(epoch)?;
            let token = s
                .credentials
                .as_ref()
                .ok_or("unauthenticated")?
                .access_token
                .clone();
            let mut request = self
                .client
                .request(
                    method.parse().map_err(|_| "invalid_method")?,
                    format!("{}{path}", self.endpoint),
                )
                .bearer_auth(token);
            if let Some(ref data) = data {
                request = request.json(data);
            }
            let response = request.send().map_err(|_| "network_unavailable")?;
            self.check(epoch)?;
            if response.status().as_u16() == 401 && attempt == 0 && retry_read {
                let refresh = s
                    .credentials
                    .as_ref()
                    .ok_or("unauthenticated")?
                    .refresh_token
                    .clone();
                // This is an existing admitted account's rotation, not a new
                // login/restore. Selection may cancel the read, but cannot
                // discard a server-committed replacement pair. The state mutex
                // retains that account until a queued newer account scope retires it.
                let auth = self.auth_response("refresh", json!({"refreshToken":refresh}), None)?;
                if Some(&auth.user.id) != s.credentials.as_ref().map(|c| &c.account_id) {
                    return Err("account_mismatch");
                }
                self.admit_credentials(s, auth)?;
                continue;
            }
            if !response.status().is_success() {
                return Err(match response.status().as_u16() {
                    401 => "unauthenticated",
                    404 => "not_found",
                    503 => "service_unavailable",
                    _ => "api_refused",
                });
            }
            if response.status().as_u16() == 204 {
                return Ok(json!({}));
            }
            return self.read_json(response, epoch);
        }
        Err("unauthenticated")
    }
    fn read_json(&self, response: reqwest::blocking::Response, epoch: u64) -> Result<Value> {
        self.read_json_scoped(response, Some(epoch))
    }
    fn read_json_scoped(
        &self,
        response: reqwest::blocking::Response,
        epoch: Option<u64>,
    ) -> Result<Value> {
        const MAX_JSON: u64 = 4 * 1024 * 1024;
        if response.content_length().is_some_and(|n| n > MAX_JSON) {
            return Err("response_too_large");
        }
        let mut bytes = Vec::new();
        response
            .take(MAX_JSON + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "network_unavailable")?;
        if let Some(epoch) = epoch {
            self.check(epoch)?;
        }
        if bytes.len() as u64 > MAX_JSON {
            return Err("response_too_large");
        }
        serde_json::from_slice(&bytes).map_err(|_| "invalid_response")
    }
    fn account_dir(&self, s: &State) -> Result<PathBuf> {
        let c = s.credentials.as_ref().ok_or("unauthenticated")?;
        let key = format!(
            "{:x}",
            Sha256::digest(format!("{}\0{}", self.endpoint, c.account_id).as_bytes())
        );
        let dir = self.root.join(key);
        fs::create_dir_all(&dir).map_err(|_| "cache_io")?;
        Ok(dir)
    }
    fn prepare(&self, s: &mut State, id: i64, epoch: u64) -> Result<(PathBuf, bool)> {
        let dir = self.account_dir(s)?;
        let index = dir.join(format!("{id}.json"));
        // Only our account-scoped cache index is read. Never trust a stored path.
        if let Ok(bytes) = fs::read(&index) {
            if let Ok(v) = serde_json::from_slice::<Value>(&bytes) {
                if let (Some(name), Some(hash)) = (v["name"].as_str(), v["sha256"].as_str()) {
                    if Path::new(name).components().count() == 1
                        && name.starts_with(&format!("{id}-"))
                    {
                        let path = dir.join(name);
                        if let Ok(mut file) = fs::File::open(&path) {
                            if file
                                .metadata()
                                .map(|m| m.len() <= MAX_AUDIO_BYTES)
                                .unwrap_or(false)
                            {
                                let mut digest = Sha256::new();
                                let mut buffer = [0u8; 65536];
                                loop {
                                    self.check(epoch)?;
                                    let count = file.read(&mut buffer).map_err(|_| "cache_io")?;
                                    if count == 0 {
                                        break;
                                    }
                                    digest.update(&buffer[..count]);
                                }
                                if format!("{:x}", digest.finalize()) == hash {
                                    self.check(epoch)?;
                                    return Ok((path, true));
                                }
                            }
                        }
                    }
                }
            }
        }
        let response: PlaybackResponse = serde_json::from_value(self.request(
            s,
            "POST",
            "/playback/urls",
            Some(json!({"trackIds":[id],"ttlSeconds":600})),
            epoch,
            false,
        )?)
        .map_err(|_| "invalid_descriptor")?;
        let d = response
            .urls
            .into_iter()
            .find(|d| d.track_id == id)
            .ok_or("audio_unavailable")?;
        if d.size_bytes == 0 || d.size_bytes > MAX_AUDIO_BYTES {
            return Err("audio_too_large");
        }
        let suffix = container_suffix(&d.content_type)?;
        let url = reqwest::Url::parse(&d.url).map_err(|_| "invalid_descriptor")?;
        if !matches!(url.scheme(), "https" | "http")
            || !url.username().is_empty()
            || url.password().is_some()
            || (url.scheme() == "http"
                && !matches!(
                    url.host_str(),
                    Some("localhost" | "127.0.0.1" | "10.0.2.2" | "[::1]")
                ))
        {
            return Err("invalid_descriptor");
        }
        let mut response = self.client.get(url).send().map_err(|_| "download_failed")?;
        if !response.status().is_success() {
            return Err("download_failed");
        }
        let (mut stage, mut file) = cache_temporary(&dir, &format!("{id}-{epoch}"), "partial")?;
        (|| {
            let mut hash = Sha256::new();
            let mut buffer = [0u8; 65536];
            let mut size = 0u64;
            loop {
                self.check(epoch)?;
                let n = response.read(&mut buffer).map_err(|_| "download_failed")?;
                if n == 0 {
                    break;
                }
                size += n as u64;
                if size > MAX_AUDIO_BYTES || size > d.size_bytes {
                    return Err("invalid_audio_size");
                }
                hash.update(&buffer[..n]);
                file.write_all(&buffer[..n]).map_err(|_| "cache_io")?;
            }
            if size != d.size_bytes {
                return Err("invalid_audio_size");
            }
            file.sync_all().map_err(|_| "cache_io")?;
            drop(file); // Retire the sole writer before publishing this inode.
            self.check(epoch)?;
            let digest = format!("{:x}", hash.finalize());
            let name = format!("{id}-{digest}.{suffix}");
            let path = dir.join(&name);
            let used: u64 = fs::read_dir(&dir)
                .map_err(|_| "cache_io")?
                .filter_map(|e| e.ok())
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum();
            if used > MAX_CACHE_BYTES {
                return Err("cache_full");
            }
            // Publish only the closed, exclusively created inode. A peer may
            // win the same-content name; verify it rather than replace it.
            match stage.publish(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    // An existing name is not proof of identical bytes. Never
                    // replace or unlink it: a decoder may own that exact inode.
                    let mut existing = fs::File::open(&path).map_err(|_| "cache_io")?;
                    if existing.metadata().map_err(|_| "cache_io")?.len() != size {
                        return Err("cache_corrupt");
                    }
                    let mut actual = Sha256::new();
                    loop {
                        self.check(epoch)?;
                        let n = existing.read(&mut buffer).map_err(|_| "cache_io")?;
                        if n == 0 {
                            break;
                        }
                        actual.update(&buffer[..n]);
                    }
                    if format!("{:x}", actual.finalize()) != digest {
                        return Err("cache_corrupt");
                    }
                }
                Err(_) => return Err("cache_io"),
            }
            let record =
                json!({"name":name,"sha256":digest,"etag":d.etag,"version":d.storage_key_version});
            let (mut pending, mut record_file) =
                cache_temporary(&dir, &format!("{id}-{epoch}"), "json.pending")?;
            record_file
                .write_all(&serde_json::to_vec(&record).map_err(|_| "cache_io")?)
                .map_err(|_| "cache_io")?;
            record_file.sync_all().map_err(|_| "cache_io")?;
            drop(record_file);
            self.check(epoch)?;
            fs::rename(&pending.0, index).map_err(|_| "cache_io")?;
            pending.1 = false;
            Ok((path, false))
        })()
    }
}

mod ffi;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn published_temporary_cleanup_cannot_unlink_reused_name() {
        let dir = std::env::temp_dir().join(format!("sq-publish-{}", SystemTimeSeed::next()));
        fs::create_dir(&dir).unwrap();
        let (mut stage, mut writer) = cache_temporary(&dir, "owned", "partial").unwrap();
        writer.write_all(b"verified-complete").unwrap();
        writer.sync_all().unwrap();
        drop(writer);
        let name = stage.0.clone();
        let destination = dir.join("immutable.wav");
        stage.publish(&destination).unwrap();
        // Rename has consumed our stage name. A new exclusive owner may now
        // reuse it before the old guard is dropped.
        #[cfg(any(target_os = "android", target_os = "linux", target_os = "macos"))]
        {
            let mut peer = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&name)
                .unwrap();
            peer.write_all(b"foreign-new-owner").unwrap();
            drop(peer);
            drop(stage);
            assert_eq!(fs::read(&name).unwrap(), b"foreign-new-owner");
        }
        #[cfg(not(any(target_os = "android", target_os = "linux", target_os = "macos")))]
        drop(stage);
        assert_eq!(fs::read(&destination).unwrap(), b"verified-complete");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn exclusive_publication_preserves_existing_destination_and_owned_stage() {
        let dir = std::env::temp_dir().join(format!("sq-collision-{}", SystemTimeSeed::next()));
        fs::create_dir(&dir).unwrap();
        let (mut stage, mut writer) = cache_temporary(&dir, "owned", "partial").unwrap();
        writer.write_all(b"new-complete").unwrap();
        writer.sync_all().unwrap();
        drop(writer);
        let name = stage.0.clone();
        let destination = dir.join("immutable.wav");
        fs::write(&destination, b"decoder-owned").unwrap();
        assert_eq!(
            stage.publish(&destination).unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert_eq!(fs::read(&destination).unwrap(), b"decoder-owned");
        assert_eq!(fs::read(&name).unwrap(), b"new-complete");
        drop(stage);
        assert!(!name.exists());
        assert_eq!(fs::read(&destination).unwrap(), b"decoder-owned");
        fs::remove_dir_all(dir).unwrap();
    }

    fn core() -> Core {
        let path = std::env::temp_dir().join(format!(
            "sq-core-test-{}-{}",
            std::process::id(),
            SystemTimeSeed::next()
        ));
        Core::open("http://127.0.0.1:1/api/v1", path).unwrap()
    }
    struct SystemTimeSeed;
    impl SystemTimeSeed {
        fn next() -> u128 {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        }
    }
    #[test]
    fn endpoint_rejects_credentials_and_public_cleartext() {
        assert!(Core::open("http://example.com/api/v1", PathBuf::new()).is_err());
        assert!(Core::open("https://secret@example.com/api/v1", PathBuf::new()).is_err());
    }
    #[test]
    fn revoke_rejects_old_reports() {
        let c = core();
        let epoch = c.revoke();
        let r = c.execute(Command::AudioReport {
            epoch: epoch - 1,
            session: 0,
            state: AudioState::Playing,
            position_ms: 123,
            duration_ms: 200,
        });
        assert!(!r.ok);
        assert_eq!(r.code, "stale_audio_report");
        assert_eq!(r.snapshot.transport, AudioState::Idle);
    }
    #[test]
    fn query_boundary_is_not_sent() {
        let c = core();
        let r = c.execute(Command::Library {
            offset: 0,
            query: "".into(),
            sort: "injection".into(),
            order: "asc".into(),
        });
        assert_eq!(r.code, "invalid_query");
    }
    #[test]
    fn secrets_are_absent_from_snapshot() {
        let c = core();
        let r = c.execute(Command::Snapshot {});
        let v = serde_json::to_string(&r.snapshot).unwrap();
        assert!(!v.contains("token"));
        assert!(!v.contains("password"));
    }
    #[test]
    fn rejects_unknown_commands_and_fields() {
        assert!(serde_json::from_str::<Command>(r#"{"command":"pause","secret":"x"}"#).is_err());
    }
    #[test]
    fn no_selection_cannot_play_or_seek() {
        let c = core();
        assert_eq!(c.execute(Command::Resume {}).code, "no_selection");
        assert_eq!(
            c.execute(Command::Seek { position_ms: 0 }).code,
            "invalid_seek"
        );
    }
    #[test]
    fn original_codec_containers_keep_their_native_suffix() {
        assert_eq!(container_suffix("audio/aac"), Ok("aac"));
        assert_eq!(container_suffix("audio/mp4"), Ok("m4a"));
        assert_eq!(container_suffix("Audio/OGG; codecs=vorbis"), Ok("ogg"));
        assert_eq!(container_suffix("audio/opus"), Ok("opus"));
        assert_eq!(
            container_suffix("application/octet-stream"),
            Err("unsupported_container")
        );
    }
}
