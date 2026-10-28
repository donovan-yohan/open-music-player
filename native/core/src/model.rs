use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    ImportLink {
        operation_id: u64,
        url: String,
    },
    ImportJobs {},
    ImportJob {
        job_id: String,
    },
    Login {
        email: String,
        password: String,
    },
    Register {
        email: String,
        password: String,
        username: String,
    },
    Restore {
        access_token: String,
        refresh_token: String,
        account_id: String,
    },
    Library {
        offset: u32,
        query: String,
        sort: String,
        order: String,
    },
    LibraryLiked {
        offset: u32,
        query: String,
        sort: String,
        order: String,
    },
    SetFavorite {
        track_id: i64,
        liked: bool,
    },
    Select {
        track_id: i64,
    },
    QueueAppend {
        track_id: i64,
    },
    QueuePlay {
        occurrence_id: u64,
    },
    QueueRemove {
        occurrence_id: u64,
    },
    QueueMove {
        occurrence_id: u64,
        to_index: u32,
    },
    QueueClear {},
    QueueRestore {},
    Next {},
    Previous {},
    Pause {},
    Resume {},
    Seek {
        position_ms: u64,
    },
    AudioReport {
        epoch: u64,
        session: u64,
        state: AudioState,
        position_ms: u64,
        duration_ms: u64,
    },
    Retry {},
    Logout {},
    Snapshot {},
    Credentials {},
    // Additive JSON contract v1: acknowledge only after durable private storage.
    AcknowledgeCredentials {
        version: u64,
    },
    ClearCache {},
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum AudioState {
    Idle,
    Preparing,
    Playing,
    Paused,
    Ended,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Track {
    pub id: i64,
    pub title: String,
    #[serde(default)]
    pub artist: Option<String>,
    #[serde(default)]
    pub album: Option<String>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Occurrence {
    pub id: u64,
    pub track: Track,
}

#[derive(Clone, Debug, Serialize)]
pub struct Snapshot {
    pub abi: u32,
    pub epoch: u64,
    pub revision: u64,
    pub session: u64,
    pub authenticated: bool,
    pub library: Vec<Track>,
    // Successful membership publication only; transient, never saved queue state.
    pub library_revision: u64,
    // Same topic as library: empty when library_unchanged, otherwise a complete
    // projection of favorites among the currently loaded library IDs only.
    pub favorite_track_ids: Vec<i64>,
    pub library_unchanged: bool,
    pub total: u64,
    pub offset: u32,
    pub queue: Vec<Occurrence>,
    pub queue_unchanged: bool,
    pub selected_occurrence: Option<u64>,
    pub transport: AudioState,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub error: Option<String>,
}

#[derive(Serialize)]
pub struct Reply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub import_result: Option<ImportResult>,
    pub ok: bool,
    pub code: String,
    pub snapshot: Snapshot,
    // Private adapter messages. Never feed these into UI snapshots or logs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio: Option<AudioEffect>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credentials: Option<Credentials>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateImportAck {
    pub job_id: String,
    pub status: ImportStatus,
    #[serde(rename = "sourceDecisionId")]
    pub source_decision_id: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ImportStatus {
    Queued,
    Downloading,
    Processing,
    Uploading,
    Complete,
    Failed,
}
#[derive(Clone, Debug, Serialize)]
pub struct SubmissionReceipt {
    pub operation_id: u64,
    pub outcome: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ack: Option<CreateImportAck>,
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct ImportResult {
    pub receipt: Option<SubmissionReceipt>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jobs: Option<Vec<ImportJob>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job: Option<ImportJob>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ImportJob {
    pub job_id: String,
    pub status: ImportStatus,
    pub progress: u8,
    pub error: Option<String>,
    pub url: String,
    pub source_type: String,
    pub track_id: Option<i64>,
    pub created_at: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

#[derive(Serialize)]
pub struct AudioEffect {
    pub action: &'static str,
    pub epoch: u64,
    pub session: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<PathBuf>,
    pub position_ms: u64,
    pub cached: bool,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct Credentials {
    #[serde(default)]
    pub version: u64,
    pub access_token: String,
    pub refresh_token: String,
    pub account_id: String,
}

#[derive(Deserialize)]
pub struct LibraryTrack {
    #[serde(flatten)]
    pub track: Track,
    #[serde(default)]
    pub is_liked: bool,
}

#[derive(Deserialize)]
pub struct LibraryPage {
    pub tracks: Option<Vec<LibraryTrack>>,
    pub total: u64,
    pub offset: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub user: User,
}
#[derive(Deserialize)]
pub struct User {
    pub id: String,
}
#[derive(Deserialize)]
pub struct PlaybackResponse {
    pub urls: Vec<Descriptor>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Descriptor {
    pub track_id: i64,
    pub url: String,
    pub content_type: String,
    pub size_bytes: u64,
    #[serde(default)]
    pub etag: String,
    #[serde(default)]
    pub storage_key_version: String,
}
