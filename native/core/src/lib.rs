mod imports;
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
const MAX_SAVED_QUEUE_BYTES: usize = 4 * 1024 * 1024;

pub struct Core {
    epoch: AtomicU64,
    state: Mutex<State>,
    client: Client,
    endpoint: String,
    root: PathBuf,
}
#[derive(Clone, PartialEq, Eq)]
struct LibraryQueryIdentity {
    liked: bool,
    query: String,
    sort: String,
    order: String,
}
#[derive(Clone)]
struct State {
    import_receipt: Option<SubmissionReceipt>,
    library_query: Option<LibraryQueryIdentity>,
    snapshot: Snapshot,
    credentials: Option<Credentials>,
    credentials_changed: bool,
    credential_version: u64,
    account_scope_v1: u64,
    current_path: Option<PathBuf>,
    next_occurrence: u64,
    retry_target: Option<i64>,
    delivered_paths: HashSet<PathBuf>,
    persisted_position: Option<(Option<u64>, u64)>,
    // Commit witness only: equal cursor values do not prove whether this command
    // crossed rename. Never persisted and never used as playback state authority.
    queue_write_revision: u64,
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedQueue {
    version: u32,
    #[serde(deserialize_with = "saved_occurrences")]
    queue: Vec<Occurrence>,
    selected: Option<u64>,
    position_ms: u64,
    next_occurrence: u64,
}
// Saved semantics are a closed v1 contract. Remote Library Track JSON remains
// additive; these strict types exist only at the persisted decoding boundary.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedOccurrence {
    id: u64,
    track: SavedTrack,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedTrack {
    id: i64,
    title: String,
    #[serde(default)]
    artist: Option<String>,
    #[serde(default)]
    album: Option<String>,
    #[serde(default)]
    duration_ms: Option<u64>,
}
fn saved_occurrences<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Vec<Occurrence>, D::Error> {
    use serde::Deserialize;
    Ok(Vec::<SavedOccurrence>::deserialize(decoder)?
        .into_iter()
        .map(|o| Occurrence {
            id: o.id,
            track: Track {
                id: o.track.id,
                title: o.track.title,
                artist: o.track.artist,
                album: o.track.album,
                duration_ms: o.track.duration_ms,
            },
        })
        .collect())
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
                import_receipt: None,
                library_query: None,
                snapshot: Snapshot {
                    abi: 1,
                    epoch: 1,
                    revision: 0,
                    session: 0,
                    authenticated: false,
                    library: vec![],
                    library_revision: 0,
                    favorite_track_ids: vec![],
                    library_unchanged: false,
                    total: 0,
                    offset: 0,
                    queue: vec![],
                    queue_unchanged: false,
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
                persisted_position: None,
                queue_write_revision: 0,
            }),
            client,
            endpoint: url.as_str().trim_end_matches('/').into(),
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
        let import_command = matches!(
            &command,
            Command::ImportLink { .. } | Command::ImportJobs {} | Command::ImportJob { .. }
        );
        let mut transport_only = matches!(
            &command,
            Command::AudioReport { .. }
                | Command::Pause {}
                | Command::Resume {}
                | Command::Seek { .. }
        );
        let persist = matches!(
            &command,
            Command::Select { .. }
                | Command::QueueAppend { .. }
                | Command::QueuePlay { .. }
                | Command::QueueRemove { .. }
                | Command::QueueMove { .. }
                | Command::QueueClear {}
                | Command::Next {}
                | Command::Previous {}
                | Command::Pause {}
                | Command::Seek { .. }
        );
        let resting_report = matches!(
            &command,
            Command::AudioReport {
                state: AudioState::Paused | AudioState::Ended,
                ..
            }
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
                import_result: None,
                ok: false,
                code: "cancelled".into(),
                snapshot: Snapshot {
                    epoch: self.epoch.load(Ordering::SeqCst),
                    authenticated: false,
                    library: vec![],
                    favorite_track_ids: vec![],
                    queue: vec![],
                    selected_occurrence: None,
                    transport: AudioState::Idle,
                    ..state.snapshot.clone()
                },
                audio: None,
                credentials: None,
            };
        }
        // Favorite metadata intent cannot acquire a new playback epoch or reset
        // its session/cursor. The adapter must admit it in the loaded epoch.
        let admission = if (matches!(&command, Command::SetFavorite { .. }) || import_command)
            && state.snapshot.epoch != epoch
        {
            Err("cancelled")
        } else {
            self.validate_queue_command(&state, &command)
        };
        if state.snapshot.epoch != epoch && admission.is_ok() {
            state.snapshot.epoch = epoch;
            state.snapshot.session += 1;
            state.snapshot.transport = AudioState::Idle;
            state.snapshot.position_ms = 0;
            state.current_path = None;
        }
        let can_replace = matches!(
            &command,
            Command::Select { .. }
                | Command::QueuePlay { .. }
                | Command::QueueRemove { .. }
                | Command::Next {}
                | Command::Previous {}
                | Command::Resume {}
                | Command::Retry {}
                | Command::AudioReport {
                    state: AudioState::Ended,
                    ..
                }
        );
        let checkpoint = can_replace.then(|| state.clone());
        // Validate the complete durable candidate before queue/decoder admission.
        // Local IO faults remain independent of an otherwise valid audio effect.
        // Read projections live only in this reply, never in shared State.
        let mut import_result = ImportResult::default();
        let result = admission.and_then(|()| match command {
            Command::ImportJobs {} => {
                import_result.jobs = Some(self.read_import_jobs(&mut state, epoch)?);
                Ok((None, None))
            }
            Command::ImportJob { job_id } => {
                import_result.job = Some(self.read_import_job(&mut state, &job_id, epoch)?);
                Ok((None, None))
            }
            command => self.apply(&mut state, command, epoch),
        });
        let cancelled_before_persistence = self.check(epoch).is_err();
        if matches!(&result, Ok((Some(effect), _)) if effect.action == "load") {
            transport_only = false;
        }
        let mut persistence_error = None;
        let durable_cursor = Some((
            state.snapshot.selected_occurrence,
            state.snapshot.position_ms,
        ));
        let selection_changed = checkpoint.as_ref().is_some_and(|previous| {
            previous.snapshot.selected_occurrence != state.snapshot.selected_occurrence
        });
        if ((result.is_ok()
            && (persist || resting_report && state.persisted_position != durable_cursor))
            || selection_changed && self.check(epoch).is_ok())
            && state.credentials.is_some()
        {
            if let Err(code) = self.persist_queue(&mut state, epoch) {
                if code != "cancelled" {
                    state.snapshot.error = Some(code.into());
                }
                persistence_error = Some(code)
            }
        }
        // A replacement whose write was cancelled is still provisional. Restore
        // its selection/cursor owners, but never roll back a committed write or
        // account credential rotation merely because reply delivery was revoked.
        if cancelled_before_persistence || persistence_error == Some("cancelled") {
            if let Some(ref previous) = checkpoint
                .as_ref()
                .filter(|previous| previous.queue_write_revision == state.queue_write_revision)
            {
                state.snapshot = previous.snapshot.clone();
                state.current_path = previous.current_path.clone();
                state.next_occurrence = previous.next_occurrence;
                state.retry_target = previous.retry_target;
                state.persisted_position = previous.persisted_position
            }
        }
        state.snapshot.revision = state.snapshot.revision.saturating_add(1);
        let (mut ok, mut code, audio, mut credentials) = match result {
            Ok((audio, credentials)) => (true, "ok", audio, credentials),
            Err(code) => {
                if code != "cancelled" {
                    state.snapshot.error = Some(code.into());
                }
                (false, code, None, None)
            }
        };
        // A local persistence fault must not drop the decoder effect while
        // publishing its new selection. Report the fault, retain coherent audio.
        if let Some(error) = persistence_error {
            ok = false;
            code = error
        }
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
                library_revision: state.snapshot.library_revision,
                favorite_track_ids: vec![],
                library_unchanged: true,
                total: state.snapshot.total,
                offset: state.snapshot.offset,
                queue: vec![],
                queue_unchanged: true,
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
            snapshot.favorite_track_ids.clear();
            snapshot.queue.clear();
            snapshot.selected_occurrence = None;
            snapshot.authenticated = false;
            snapshot.transport = AudioState::Idle;
            snapshot.epoch = self.epoch.load(Ordering::SeqCst);
            return Reply {
                ok: false,
                code: "cancelled".into(),
                snapshot,
                import_result: None,
                audio: None,
                credentials: None,
            };
        }
        Reply {
            import_result: import_command.then(|| {
                import_result.receipt = state.import_receipt.clone();
                import_result
            }),
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
    fn read_library(
        &self,
        s: &mut State,
        identity: LibraryQueryIdentity,
        offset: u32,
        epoch: u64,
    ) -> Result<()> {
        let LibraryQueryIdentity {
            query, sort, order, ..
        } = &identity;
        if query.len() > 512
            || !matches!(sort.as_str(), "added_at" | "title" | "artist" | "duration")
            || !matches!(order.as_str(), "asc" | "desc")
            || offset > 1_000_000
        {
            return Err("invalid_query");
        }
        if offset > 0 && s.library_query.as_ref() != Some(&identity) {
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
        if identity.liked {
            path.query_pairs_mut().append_pair("liked", "true");
        }
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
            || tracks
                .iter()
                .any(|t| t.track.id <= 0 || t.track.title.len() > 16384)
        {
            return Err("invalid_library");
        }
        self.check(epoch)?;
        let mut favorites: HashSet<i64> = if offset == 0 {
            HashSet::new()
        } else {
            s.snapshot.favorite_track_ids.iter().copied().collect()
        };
        for t in &tracks {
            if t.is_liked {
                favorites.insert(t.track.id);
            } else {
                favorites.remove(&t.track.id);
            }
        }
        if offset == 0 {
            s.snapshot.library = tracks.into_iter().map(|t| t.track).collect();
        } else {
            for t in tracks {
                if !s.snapshot.library.iter().any(|x| x.id == t.track.id) {
                    s.snapshot.library.push(t.track);
                }
            }
        }
        s.snapshot.favorite_track_ids = s
            .snapshot
            .library
            .iter()
            .filter(|t| favorites.contains(&t.id))
            .map(|t| t.id)
            .collect();
        s.snapshot.total = page.total;
        s.snapshot.offset = offset;
        s.library_query = Some(identity);
        s.snapshot.library_revision += 1;
        Ok(())
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
                s.library_query = None;
                s.snapshot.library_revision = 0;
                s.snapshot.library.clear();
                s.snapshot.favorite_track_ids.clear();
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
                self.read_library(
                    s,
                    LibraryQueryIdentity {
                        liked: false,
                        query,
                        sort,
                        order,
                    },
                    offset,
                    epoch,
                )?;
            }
            Command::LibraryLiked {
                offset,
                query,
                sort,
                order,
            } => {
                self.read_library(
                    s,
                    LibraryQueryIdentity {
                        liked: true,
                        query,
                        sort,
                        order,
                    },
                    offset,
                    epoch,
                )?;
            }
            Command::SetFavorite { track_id, liked } => {
                if !s.snapshot.authenticated || s.credentials.is_none() {
                    return Err("unauthenticated");
                }
                if track_id <= 0 || !s.snapshot.library.iter().any(|t| t.id == track_id) {
                    return Err("track_not_loaded");
                }
                let method = if liked { "POST" } else { "DELETE" };
                // No refresh/replay: the server may have committed a mutation
                // even if the response is lost. Only a read can reconcile it.
                let mut dispatched = false;
                let outcome = (|| {
                    let response = self
                        .request_response(
                            s,
                            method,
                            &format!("/library/tracks/{track_id}/like"),
                            None,
                            epoch,
                            false,
                            &mut dispatched,
                        )
                        .map_err(|code| {
                            if code == "cancelled" {
                                code
                            } else {
                                "favorite_uncertain"
                            }
                        })?;
                    let status = response.status().as_u16();
                    if (400..500).contains(&status) {
                        return Err(Self::api_error(status));
                    }
                    if status != if liked { 201 } else { 204 } {
                        return Err("favorite_uncertain");
                    }
                    if liked {
                        let ack = self.read_json(response, epoch).map_err(|code| {
                            if code == "cancelled" {
                                code
                            } else {
                                "favorite_uncertain"
                            }
                        })?;
                        if ack.get("track_id").and_then(Value::as_i64) != Some(track_id)
                            || ack.get("liked").and_then(Value::as_bool) != Some(true)
                        {
                            return Err("favorite_uncertain");
                        }
                    }
                    self.check(epoch)
                })();
                // A changed (or possibly changed) server-filtered set makes its
                // old offset unsafe. Retain rows/revision/playback, but require
                // an explicit offset-zero read before any further append.
                if s.library_query.as_ref().is_some_and(|q| q.liked)
                    && (outcome == Err("favorite_uncertain")
                        || dispatched && outcome == Err("cancelled")
                        || outcome.is_ok()
                            && (!liked || !s.snapshot.favorite_track_ids.contains(&track_id)))
                {
                    s.library_query = None;
                }
                outcome?;
                let mut favorites: HashSet<i64> =
                    s.snapshot.favorite_track_ids.iter().copied().collect();
                if liked {
                    favorites.insert(track_id);
                } else {
                    favorites.remove(&track_id);
                }
                s.snapshot.favorite_track_ids = s
                    .snapshot
                    .library
                    .iter()
                    .filter(|t| favorites.contains(&t.id))
                    .map(|t| t.id)
                    .collect();
            }
            Command::Select { track_id } => {
                if s.snapshot.library.len() > 10000 {
                    return Err("queue_full");
                }
                let index = s
                    .snapshot
                    .library
                    .iter()
                    .position(|t| t.id == track_id)
                    .ok_or("track_not_loaded")?;
                s.snapshot.queue = s
                    .snapshot
                    .library
                    .iter()
                    .cloned()
                    .map(|track| {
                        let id = s.next_occurrence;
                        s.next_occurrence += 1;
                        Occurrence { id, track }
                    })
                    .collect();
                return self.load_occurrence(s, s.snapshot.queue[index].id, epoch);
            }
            Command::QueueAppend { track_id } => {
                if s.snapshot.queue.len() >= 10000 {
                    return Err("queue_full");
                }
                let track = s
                    .snapshot
                    .library
                    .iter()
                    .find(|t| t.id == track_id)
                    .cloned()
                    .ok_or("track_not_loaded")?;
                let id = s.next_occurrence;
                s.next_occurrence += 1;
                s.snapshot.queue.push(Occurrence { id, track });
            }
            Command::QueuePlay { occurrence_id } => {
                return self.load_occurrence(s, occurrence_id, epoch);
            }
            Command::Next {} => return self.step_queue(s, 1, epoch),
            Command::Previous {} => return self.step_queue(s, -1, epoch),
            Command::QueueMove {
                occurrence_id,
                to_index,
            } => {
                if to_index as usize >= s.snapshot.queue.len() {
                    return Err("invalid_queue_index");
                }
                let old = s
                    .snapshot
                    .queue
                    .iter()
                    .position(|o| o.id == occurrence_id)
                    .ok_or("unknown_occurrence")?;
                let occurrence = s.snapshot.queue.remove(old);
                s.snapshot.queue.insert(to_index as usize, occurrence);
            }
            Command::QueueRemove { occurrence_id } => {
                let index = s
                    .snapshot
                    .queue
                    .iter()
                    .position(|o| o.id == occurrence_id)
                    .ok_or("unknown_occurrence")?;
                let selected = s.snapshot.selected_occurrence == Some(occurrence_id);
                s.snapshot.queue.remove(index);
                if selected {
                    if s.snapshot.queue.is_empty() {
                        return self.apply(s, Command::QueueClear {}, epoch);
                    }
                    let target = index.min(s.snapshot.queue.len() - 1);
                    return self.load_occurrence(s, s.snapshot.queue[target].id, epoch);
                }
            }
            Command::QueueClear {} => {
                s.snapshot.queue.clear();
                s.snapshot.selected_occurrence = None;
                s.snapshot.position_ms = 0;
                s.snapshot.duration_ms = 0;
                s.current_path = None;
                s.retry_target = None;
                s.snapshot.session += 1;
                s.snapshot.transport = AudioState::Idle;
                return Ok((Some(self.effect(s, "stop", None, false)), None));
            }
            Command::Pause {} => {
                s.snapshot.transport = AudioState::Paused;
                return Ok((Some(self.effect(s, "pause", None, false)), None));
            }
            Command::Resume {} => {
                if s.current_path.is_none() {
                    let id = s.snapshot.selected_occurrence.ok_or("no_selection")?;
                    let position = s.snapshot.position_ms;
                    let (mut effect, credentials) = self.load_occurrence(s, id, epoch)?;
                    s.snapshot.position_ms = position;
                    if let Some(ref mut effect) = effect {
                        effect.position_ms = position
                    }
                    return Ok((effect, credentials));
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
                if report_epoch != epoch
                    || session != s.snapshot.session
                    || state == AudioState::Ended
                        && !matches!(
                            s.snapshot.transport,
                            AudioState::Playing | AudioState::Preparing
                        )
                {
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
                if state == AudioState::Ended {
                    if let Some(index) = s
                        .snapshot
                        .queue
                        .iter()
                        .position(|o| Some(o.id) == s.snapshot.selected_occurrence)
                    {
                        if index + 1 < s.snapshot.queue.len() {
                            return self.load_occurrence(s, s.snapshot.queue[index + 1].id, epoch);
                        }
                    }
                }
            }
            Command::Retry {} => {
                if s.current_path.is_none() {
                    if let Some(id) = s.snapshot.selected_occurrence {
                        return self.load_occurrence(s, id, epoch);
                    }
                    let id = s.retry_target.ok_or("no_selection")?;
                    return self.apply(s, Command::Select { track_id: id }, epoch);
                }
                let id = s.retry_target.ok_or("no_selection")?;
                let (path, cached) = self.prepare(s, id, epoch)?;
                self.check(epoch)?;
                s.current_path = Some(path.clone());
                s.delivered_paths.insert(path.clone());
                s.snapshot.session += 1;
                s.snapshot.transport = AudioState::Preparing;
                s.snapshot.position_ms = 0;
                return Ok((Some(self.effect(s, "load", Some(path), cached)), None));
            }
            Command::QueueRestore {} => {
                let path = self.account_dir(s)?.join("listening-queue-v1.json");
                let Some(saved) = self.read_saved_queue(&path)? else {
                    return Ok((None, None));
                };
                self.check(epoch)?;
                s.snapshot.queue = saved.queue;
                s.snapshot.selected_occurrence = saved.selected;
                s.next_occurrence = s.next_occurrence.max(saved.next_occurrence);
                let track = s
                    .snapshot
                    .queue
                    .iter()
                    .find(|o| Some(o.id) == saved.selected)
                    .map(|o| &o.track);
                s.snapshot.duration_ms = track.and_then(|t| t.duration_ms).unwrap_or(0);
                // Zero denotes an unknown bound, not a zero-length recording.
                // Only clamp against positive metadata; decoder duration is not
                // stored in v1, but its accepted resting cursor is.
                s.snapshot.position_ms = if track.is_none() {
                    0
                } else if s.snapshot.duration_ms > 0 {
                    saved.position_ms.min(s.snapshot.duration_ms)
                } else {
                    saved.position_ms
                };
                s.snapshot.session += 1;
                s.current_path = None;
                s.snapshot.transport = if saved.selected.is_some() {
                    AudioState::Paused
                } else {
                    AudioState::Idle
                };
                s.persisted_position =
                    Some((s.snapshot.selected_occurrence, s.snapshot.position_ms));
                return Ok((Some(self.effect(s, "stop", None, false)), None));
            }
            Command::ImportLink { operation_id, url } => {
                self.submit_import(s, operation_id, &url, epoch)?
            }
            Command::ImportJobs {} | Command::ImportJob { .. } => return Err("import_unavailable"),
            Command::ClearCache {} => {
                let dir = self.account_dir(s)?;
                for entry in fs::read_dir(dir).map_err(|_| "cache_io")? {
                    let path = entry.map_err(|_| "cache_io")?.path();
                    if !s.delivered_paths.contains(&path)
                        && path.is_file()
                        && !path
                            .file_name()
                            .is_some_and(|n| n.to_string_lossy().starts_with("listening-queue-v1"))
                    {
                        fs::remove_file(path).map_err(|_| "cache_io")?;
                    }
                }
            }
        }
        Ok((None, None))
    }
    fn read_saved_queue(&self, path: &Path) -> Result<Option<SavedQueue>> {
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err("queue_storage_failed"),
        };
        if bytes.len() > MAX_SAVED_QUEUE_BYTES {
            return Err("invalid_saved_queue");
        }
        let saved: SavedQueue =
            serde_json::from_slice(&bytes).map_err(|_| "invalid_saved_queue")?;
        let mut ids = HashSet::new();
        if saved.version != 1
            || saved.queue.len() > 10000
            || saved.queue.iter().any(|o| {
                o.id == 0 || o.track.id <= 0 || o.track.title.len() > 16384 || !ids.insert(o.id)
            })
            || saved.selected.is_some_and(|id| !ids.contains(&id))
            || saved.queue.iter().any(|o| o.id >= saved.next_occurrence)
        {
            return Err("invalid_saved_queue");
        }
        Ok(Some(saved))
    }
    fn persist_queue(&self, s: &mut State, epoch: u64) -> Result<()> {
        self.check(epoch)?;
        let saved = SavedQueue {
            version: 1,
            queue: s.snapshot.queue.clone(),
            selected: s.snapshot.selected_occurrence,
            position_ms: s.snapshot.position_ms,
            next_occurrence: s.next_occurrence,
        };
        let dir = self.account_dir(s)?;
        let target = dir.join("listening-queue-v1.json");
        // Validate existing bytes on every write, not only at startup. A failed
        // restore or externally corrupted file is never permission to erase it.
        self.read_saved_queue(&target)?;
        // Compatible legacy queues may lack the new admission headroom. Their
        // live transport/effect remains valid even when this durable write cannot
        // fit. Classify that as storage failure, not a refused queue command.
        let bytes = Self::saved_queue_bytes(&saved).map_err(|code| {
            if code == "queue_full" {
                "queue_storage_failed"
            } else {
                code
            }
        })?;
        let (mut pending, mut file) = cache_temporary(&dir, "listening-queue-v1", "pending")?;
        file.write_all(&bytes).map_err(|_| "queue_storage_failed")?;
        file.sync_all().map_err(|_| "queue_storage_failed")?;
        self.check(epoch)?;
        drop(file);
        fs::rename(&pending.0, target).map_err(|_| "queue_storage_failed")?;
        pending.1 = false;
        s.queue_write_revision = s.queue_write_revision.wrapping_add(1);
        s.persisted_position = Some((s.snapshot.selected_occurrence, s.snapshot.position_ms));
        Ok(())
    }
    fn saved_queue_bytes(saved: &SavedQueue) -> Result<Vec<u8>> {
        let bytes = serde_json::to_vec(saved).map_err(|_| "queue_storage_failed")?;
        if bytes.len() > MAX_SAVED_QUEUE_BYTES {
            return Err("queue_full");
        }
        Ok(bytes)
    }
    fn validate_queue_command(&self, s: &State, command: &Command) -> Result<()> {
        // Only content admission can increase metadata or assign occurrence IDs.
        // Current native truth must not clone/serialize the queue every tick, or
        // be refused by storage budgeting (including compatible legacy queues).
        if !matches!(
            command,
            Command::Select { .. } | Command::QueueAppend { .. }
        ) {
            return Ok(());
        }
        let mut saved = SavedQueue {
            version: 1,
            queue: s.snapshot.queue.clone(),
            selected: s.snapshot.selected_occurrence,
            position_ms: s.snapshot.position_ms,
            next_occurrence: s.next_occurrence,
        };
        match command {
            Command::Select { track_id } => {
                if s.snapshot.library.len() > 10000 {
                    return Err("queue_full");
                }
                if !s.snapshot.library.iter().any(|t| t.id == *track_id) {
                    return Err("track_not_loaded");
                }
                saved.queue.clear();
                for track in &s.snapshot.library {
                    let id = saved.next_occurrence;
                    saved.next_occurrence = id.checked_add(1).ok_or("queue_full")?;
                    saved.queue.push(Occurrence {
                        id,
                        track: track.clone(),
                    });
                }
            }
            Command::QueueAppend { track_id } => {
                if saved.queue.len() >= 10000 {
                    return Err("queue_full");
                }
                let track = s
                    .snapshot
                    .library
                    .iter()
                    .find(|t| t.id == *track_id)
                    .ok_or("track_not_loaded")?
                    .clone();
                let id = saved.next_occurrence;
                saved.next_occurrence = id.checked_add(1).ok_or("queue_full")?;
                saved.queue.push(Occurrence { id, track });
            }
            _ => return Ok(()),
        }
        // Reserve the full supported scalar envelope before any live mutation,
        // next-ID consumption or decoder work. Existing occurrence IDs and all
        // escaped metadata are counted exactly; later content edits revalidate.
        saved.selected = Some(u64::MAX);
        saved.position_ms = u64::MAX;
        saved.next_occurrence = u64::MAX;
        Self::saved_queue_bytes(&saved).map(|_| ())
    }
    fn step_queue(
        &self,
        s: &mut State,
        delta: isize,
        epoch: u64,
    ) -> Result<(Option<AudioEffect>, Option<Credentials>)> {
        let index = s
            .snapshot
            .queue
            .iter()
            .position(|o| Some(o.id) == s.snapshot.selected_occurrence)
            .ok_or("no_selection")?;
        let target = index
            .checked_add_signed(delta)
            .filter(|i| *i < s.snapshot.queue.len())
            .ok_or("queue_boundary")?;
        self.load_occurrence(s, s.snapshot.queue[target].id, epoch)
    }
    fn load_occurrence(
        &self,
        s: &mut State,
        id: u64,
        epoch: u64,
    ) -> Result<(Option<AudioEffect>, Option<Credentials>)> {
        let track = s
            .snapshot
            .queue
            .iter()
            .find(|o| o.id == id)
            .map(|o| o.track.clone())
            .ok_or("unknown_occurrence")?;
        let eof_selection =
            s.snapshot.transport == AudioState::Ended && s.snapshot.selected_occurrence != Some(id);
        s.snapshot.selected_occurrence = Some(id);
        s.snapshot.session += 1;
        s.snapshot.position_ms = 0;
        s.snapshot.duration_ms = track.duration_ms.unwrap_or(0);
        s.snapshot.transport = AudioState::Preparing;
        s.current_path = None;
        s.retry_target = Some(track.id);
        // EOF selection is accepted before preparation can block or fail. Make its
        // retryable zero cursor durable now, not on a later native Pause report.
        // execute_scoped_at still publishes any local save error with the valid
        // load effect, and retries/report failures after preparation settles.
        if eof_selection && s.credentials.is_some() {
            let _ = self.persist_queue(s, epoch);
        }
        let prepared = self.prepare(s, track.id, epoch);
        self.check(epoch)?;
        match prepared {
            Ok((path, cached)) => {
                s.current_path = Some(path.clone());
                // Delivered immutable paths outlive all decoder use, including
                // replacement/EOF. Platform close, not command ACK, retires it.
                s.delivered_paths.insert(path.clone());
                Ok((Some(self.effect(s, "load", Some(path), cached)), None))
            }
            Err(code) => {
                s.snapshot.transport = AudioState::Failed;
                Err(code)
            }
        }
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
        s.import_receipt = None;
        s.library_query = None;
        s.snapshot.library_revision = 0;
        s.credentials = None;
        s.credentials_changed = false;
        s.current_path = None;
        s.retry_target = None;
        s.snapshot.authenticated = false;
        s.snapshot.library.clear();
        s.snapshot.favorite_track_ids.clear();
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
            s.library_query = None;
            s.snapshot.library_revision = 0;
            s.snapshot.library.clear();
            s.import_receipt = None;
            s.snapshot.favorite_track_ids.clear();
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
        let response =
            self.request_response(s, method, path, data, epoch, retry_read, &mut false)?;
        if !response.status().is_success() {
            return Err(Self::api_error(response.status().as_u16()));
        }
        if response.status().as_u16() == 204 {
            return Ok(json!({}));
        }
        self.read_json(response, epoch)
    }
    fn api_error(status: u16) -> &'static str {
        match status {
            401 => "unauthenticated",
            404 => "not_found",
            503 => "service_unavailable",
            _ => "api_refused",
        }
    }
    // Preserve the authenticated request and credential-rotation fences while
    // allowing a mutation to validate its method-specific acknowledgment.
    fn request_response(
        &self,
        s: &mut State,
        method: &str,
        path: &str,
        data: Option<Value>,
        epoch: u64,
        retry_read: bool,
        dispatched: &mut bool,
    ) -> Result<reqwest::blocking::Response> {
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
            // Once send begins, cancellation cannot prove the server did not
            // commit. Pre-dispatch cancellation leaves append authority intact.
            self.check(epoch)?;
            *dispatched = true;
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
            return Ok(response);
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
            static NEXT: AtomicU64 = AtomicU64::new(1);
            NEXT.fetch_add(1, Ordering::SeqCst) as u128
        }
    }
    #[test]
    fn endpoint_normalization_keeps_one_canonical_prefix_without_network() {
        for (raw, expected) in [
            (
                "HTTPS://EXAMPLE.INVALID:443/prefix/api/v1///",
                "https://example.invalid/prefix/api/v1",
            ),
            ("HTTP://LOCALHOST:80/api/v1/", "http://localhost/api/v1"),
            (
                "https://Example.Invalid/music/é/",
                "https://example.invalid/music/%C3%A9",
            ),
        ] {
            let root =
                std::env::temp_dir().join(format!("sq-endpoint-policy-{}", SystemTimeSeed::next()));
            let core = Core::open(raw, root.clone()).unwrap();
            assert_eq!(core.endpoint, expected);
            fs::remove_dir_all(root).unwrap();
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
    #[test]
    fn saved_queue_restores_paused_account_scoped_occurrences_and_cursor() {
        let c = populated_queue_core();
        let r = c.execute(Command::Select { track_id: 3 });
        let selected = r.snapshot.selected_occurrence;
        c.execute(Command::QueueAppend { track_id: 3 });
        c.execute(Command::Seek { position_ms: 6000 });
        let path = c.root.clone();
        drop(c);
        let next = Core::open("http://127.0.0.1:1/api/v1", path.clone()).unwrap();
        {
            let mut s = next.state.lock().unwrap();
            s.credentials = Some(Credentials {
                version: 0,
                access_token: "synthetic".into(),
                refresh_token: "synthetic".into(),
                account_id: "queue-test".into(),
            });
            s.snapshot.authenticated = true;
        }
        let restored = next.execute(Command::QueueRestore {});
        assert!(restored.ok);
        assert_eq!(restored.snapshot.queue.len(), 9);
        assert_eq!(restored.snapshot.selected_occurrence, selected);
        assert_eq!(restored.snapshot.position_ms, 6000);
        assert_eq!(restored.snapshot.transport, AudioState::Paused);
        assert_eq!(restored.audio.unwrap().action, "stop");
        let resumed = next.execute(Command::Resume {});
        assert!(resumed.ok);
        assert_eq!(resumed.audio.unwrap().position_ms, 6000);
        let other = Core::open("http://127.0.0.1:1/api/v1", path.clone()).unwrap();
        {
            let mut s = other.state.lock().unwrap();
            s.credentials = Some(Credentials {
                version: 0,
                access_token: "synthetic".into(),
                refresh_token: "synthetic".into(),
                account_id: "other-account".into(),
            });
            s.snapshot.authenticated = true;
        }
        let other = other.execute(Command::QueueRestore {});
        assert!(other.ok);
        assert!(other.snapshot.queue.is_empty());
        assert!(other.audio.is_none());
        std::fs::remove_dir_all(path).unwrap();
    }
    #[test]
    fn corrupt_saved_queue_does_not_replace_live_truth() {
        let c = populated_queue_core();
        let before = c.execute(Command::Select { track_id: 3 });
        let dir = c.account_dir(&c.state.lock().unwrap()).unwrap();
        fs::write(dir.join("listening-queue-v1.json"), b"{broken").unwrap();
        let restored = c.execute(Command::QueueRestore {});
        assert_eq!(restored.code, "invalid_saved_queue");
        assert_eq!(
            restored.snapshot.selected_occurrence,
            before.snapshot.selected_occurrence
        );
        assert_eq!(restored.snapshot.queue.len(), 8);
        c.execute(Command::ClearCache {});
        assert!(dir.join("listening-queue-v1.json").exists());
    }
    fn populated_queue_core() -> Core {
        let c = core();
        {
            let mut s = c.state.lock().unwrap();
            s.credentials = Some(Credentials {
                version: 0,
                access_token: "synthetic".into(),
                refresh_token: "synthetic".into(),
                account_id: "queue-test".into(),
            });
            s.snapshot.authenticated = true;
            s.snapshot.library = (1..=8)
                .map(|id| Track {
                    id,
                    title: format!("track{id}"),
                    artist: None,
                    album: None,
                    duration_ms: Some(30000),
                })
                .collect();
            let dir = c.account_dir(&s).unwrap();
            for id in 1..=8 {
                let bytes = b"synthetic-cache-only";
                let hash = format!("{:x}", Sha256::digest(bytes));
                let name = format!("{id}-{hash}.wav");
                fs::write(dir.join(&name), bytes).unwrap();
                fs::write(
                    dir.join(format!("{id}.json")),
                    json!({"name":name,"sha256":hash}).to_string(),
                )
                .unwrap();
            }
        }
        c
    }
    #[test]
    fn visible_library_selection_queues_all_rows_not_four_entries() {
        let c = populated_queue_core();
        let r = c.execute(Command::Select { track_id: 3 });
        assert!(r.ok, "{}", r.code);
        assert_eq!(r.snapshot.queue.len(), 8);
        assert_eq!(
            r.snapshot.queue[2].id,
            r.snapshot.selected_occurrence.unwrap()
        );
        assert_eq!(r.audio.unwrap().position_ms, 0);
    }
    #[test]
    fn duplicate_occurrences_move_remove_without_reloading_current() {
        let c = populated_queue_core();
        let r = c.execute(Command::Select { track_id: 3 });
        let selected = r.snapshot.selected_occurrence;
        let session = r.snapshot.session;
        let appended = c.execute(Command::QueueAppend { track_id: 3 });
        let duplicate = appended.snapshot.queue.last().unwrap().id;
        assert_ne!(Some(duplicate), selected);
        let moved = c.execute(Command::QueueMove {
            occurrence_id: duplicate,
            to_index: 0,
        });
        assert!(moved.ok, "{}", moved.code);
        assert!(moved.audio.is_none());
        assert_eq!(moved.snapshot.selected_occurrence, selected);
        assert_eq!(moved.snapshot.session, session);
        let removed = c.execute(Command::QueueRemove {
            occurrence_id: duplicate,
        });
        assert!(removed.ok);
        assert!(removed.audio.is_none());
        assert_eq!(removed.snapshot.selected_occurrence, selected);
        assert_eq!(removed.snapshot.session, session);
    }
    #[test]
    fn eof_advances_once_and_old_completion_is_refused() {
        let c = populated_queue_core();
        let first = c.execute(Command::Select { track_id: 3 });
        let r = c.execute(Command::AudioReport {
            epoch: 1,
            session: first.snapshot.session,
            state: AudioState::Ended,
            position_ms: 30000,
            duration_ms: 30000,
        });
        assert!(r.ok);
        assert_eq!(
            r.snapshot.selected_occurrence,
            Some(first.snapshot.queue[3].id)
        );
        assert_eq!(r.audio.unwrap().action, "load");
        let late = c.execute(Command::AudioReport {
            epoch: 1,
            session: first.snapshot.session,
            state: AudioState::Ended,
            position_ms: 30000,
            duration_ms: 30000,
        });
        assert_eq!(late.code, "stale_audio_report");
    }
    #[test]
    fn selected_remove_chooses_successor_and_clear_stops() {
        let c = populated_queue_core();
        let r = c.execute(Command::Select { track_id: 3 });
        let next = r.snapshot.queue[3].id;
        let removed = c.execute(Command::QueueRemove {
            occurrence_id: r.snapshot.selected_occurrence.unwrap(),
        });
        assert!(removed.ok);
        assert_eq!(removed.snapshot.selected_occurrence, Some(next));
        assert_eq!(removed.audio.unwrap().position_ms, 0);
        let cleared = c.execute(Command::QueueClear {});
        assert!(cleared.snapshot.queue.is_empty());
        assert_eq!(cleared.audio.unwrap().action, "stop");
        assert_eq!(c.execute(Command::Next {}).code, "no_selection");
    }
    #[test]
    fn transport_topic_does_not_copy_queue_and_invalid_move_is_atomic() {
        let c = populated_queue_core();
        c.execute(Command::Select { track_id: 3 });
        let before = c
            .execute(Command::Snapshot {})
            .snapshot
            .queue
            .iter()
            .map(|o| o.id)
            .collect::<Vec<_>>();
        let paused = c.execute(Command::Pause {});
        assert!(paused.snapshot.queue_unchanged);
        assert!(paused.snapshot.queue.is_empty());
        assert_eq!(
            c.execute(Command::QueueMove {
                occurrence_id: before[0],
                to_index: 999
            })
            .code,
            "invalid_queue_index"
        );
        assert_eq!(
            c.execute(Command::Snapshot {})
                .snapshot
                .queue
                .iter()
                .map(|o| o.id)
                .collect::<Vec<_>>(),
            before
        );
    }
}
