use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

/// User account
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct User {
    pub id: i64,
    pub email: String,
    pub password_hash: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Track metadata and storage information
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct Track {
    pub id: i64,
    /// SHA-256 hash for content deduplication
    pub identity_hash: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_ms: Option<i32>,
    pub version: Option<String>,

    // MusicBrainz identifiers
    pub mb_recording_id: Option<Uuid>,
    pub mb_release_id: Option<Uuid>,
    pub mb_artist_id: Option<Uuid>,
    pub mb_verified: bool,

    // Source and storage info
    pub source_url: Option<String>,
    pub source_type: Option<String>,
    pub storage_key: Option<String>,
    pub file_size_bytes: Option<i64>,

    // Flexible metadata storage
    pub metadata_json: Option<serde_json::Value>,

    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Link between users and tracks in their library
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct UserLibrary {
    pub user_id: i64,
    pub track_id: i64,
    pub added_at: DateTime<Utc>,
}

/// User playlist
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct Playlist {
    pub id: i64,
    pub user_id: i64,
    pub name: String,
    pub description: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Track within a playlist with position
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct PlaylistTrack {
    pub playlist_id: i64,
    pub track_id: i64,
    pub position: i32,
    pub added_at: DateTime<Utc>,
}

/// Download job status
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DownloadStatus {
    Pending,
    Downloading,
    Processing,
    Completed,
    Failed,
}

impl From<String> for DownloadStatus {
    fn from(s: String) -> Self {
        match s.as_str() {
            "pending" => DownloadStatus::Pending,
            "downloading" => DownloadStatus::Downloading,
            "processing" => DownloadStatus::Processing,
            "completed" => DownloadStatus::Completed,
            "failed" => DownloadStatus::Failed,
            _ => DownloadStatus::Pending,
        }
    }
}

impl From<DownloadStatus> for String {
    fn from(status: DownloadStatus) -> Self {
        match status {
            DownloadStatus::Pending => "pending".to_string(),
            DownloadStatus::Downloading => "downloading".to_string(),
            DownloadStatus::Processing => "processing".to_string(),
            DownloadStatus::Completed => "completed".to_string(),
            DownloadStatus::Failed => "failed".to_string(),
        }
    }
}

/// Background download job
#[derive(Debug, Clone, FromRow, Serialize, Deserialize)]
pub struct DownloadJob {
    pub id: i64,
    pub user_id: i64,
    pub url: String,
    pub status: String,
    pub progress: Option<i32>,
    pub error: Option<String>,
    pub metadata_json: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

// Input types for creating new records

/// Input for creating a new user
#[derive(Debug, Clone, Deserialize)]
pub struct CreateUser {
    pub email: String,
    pub password_hash: String,
}

/// Input for creating a new track
#[derive(Debug, Clone, Deserialize)]
pub struct CreateTrack {
    pub identity_hash: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_ms: Option<i32>,
    pub version: Option<String>,
    pub mb_recording_id: Option<Uuid>,
    pub mb_release_id: Option<Uuid>,
    pub mb_artist_id: Option<Uuid>,
    pub source_url: Option<String>,
    pub source_type: Option<String>,
    pub storage_key: Option<String>,
    pub file_size_bytes: Option<i64>,
    pub metadata_json: Option<serde_json::Value>,
}

/// Input for creating a new playlist
#[derive(Debug, Clone, Deserialize)]
pub struct CreatePlaylist {
    pub user_id: i64,
    pub name: String,
    pub description: Option<String>,
}

/// Input for creating a new download job
#[derive(Debug, Clone, Deserialize)]
pub struct CreateDownloadJob {
    pub user_id: i64,
    pub url: String,
    pub metadata_json: Option<serde_json::Value>,
}
