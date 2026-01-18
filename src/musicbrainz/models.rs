use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// MusicBrainz artist credit (appears on recordings/releases)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistCredit {
    pub name: String,
    pub artist: ArtistRef,
    #[serde(default)]
    pub joinphrase: String,
}

/// Reference to an artist (minimal info in nested contexts)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistRef {
    pub id: Uuid,
    pub name: String,
    #[serde(rename = "sort-name")]
    pub sort_name: Option<String>,
    pub disambiguation: Option<String>,
}

/// Full artist entity from lookup
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artist {
    pub id: Uuid,
    pub name: String,
    #[serde(rename = "sort-name")]
    pub sort_name: Option<String>,
    #[serde(rename = "type")]
    pub artist_type: Option<String>,
    pub country: Option<String>,
    pub disambiguation: Option<String>,
    #[serde(rename = "life-span")]
    pub life_span: Option<LifeSpan>,
    #[serde(default)]
    pub recordings: Vec<RecordingRef>,
    #[serde(default)]
    pub releases: Vec<ReleaseRef>,
}

/// Life span information for artists
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LifeSpan {
    pub begin: Option<String>,
    pub end: Option<String>,
    pub ended: Option<bool>,
}

/// Reference to a recording (minimal info)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingRef {
    pub id: Uuid,
    pub title: String,
    pub length: Option<u64>,
    pub disambiguation: Option<String>,
}

/// Full recording entity from lookup
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recording {
    pub id: Uuid,
    pub title: String,
    pub length: Option<u64>,
    pub disambiguation: Option<String>,
    #[serde(rename = "first-release-date")]
    pub first_release_date: Option<String>,
    #[serde(rename = "artist-credit", default)]
    pub artist_credit: Vec<ArtistCredit>,
    #[serde(default)]
    pub releases: Vec<ReleaseRef>,
}

/// Reference to a release (minimal info)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseRef {
    pub id: Uuid,
    pub title: String,
    pub status: Option<String>,
    pub date: Option<String>,
    pub country: Option<String>,
    #[serde(rename = "release-group")]
    pub release_group: Option<ReleaseGroupRef>,
}

/// Full release entity from lookup
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Release {
    pub id: Uuid,
    pub title: String,
    pub status: Option<String>,
    pub date: Option<String>,
    pub country: Option<String>,
    #[serde(rename = "artist-credit", default)]
    pub artist_credit: Vec<ArtistCredit>,
    #[serde(rename = "release-group")]
    pub release_group: Option<ReleaseGroupRef>,
}

/// Reference to a release group
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseGroupRef {
    pub id: Uuid,
    pub title: Option<String>,
    #[serde(rename = "primary-type")]
    pub primary_type: Option<String>,
}

/// Search result wrapper for recordings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingSearchResult {
    pub created: Option<String>,
    pub count: u32,
    pub offset: u32,
    pub recordings: Vec<RecordingSearchHit>,
}

/// Individual recording in search results
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordingSearchHit {
    pub id: Uuid,
    pub score: u8,
    pub title: String,
    pub length: Option<u64>,
    #[serde(rename = "first-release-date")]
    pub first_release_date: Option<String>,
    #[serde(rename = "artist-credit", default)]
    pub artist_credit: Vec<ArtistCredit>,
    #[serde(default)]
    pub releases: Vec<ReleaseRef>,
}

/// Search result wrapper for artists
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistSearchResult {
    pub created: Option<String>,
    pub count: u32,
    pub offset: u32,
    pub artists: Vec<ArtistSearchHit>,
}

/// Individual artist in search results
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistSearchHit {
    pub id: Uuid,
    pub score: u8,
    pub name: String,
    #[serde(rename = "sort-name")]
    pub sort_name: Option<String>,
    #[serde(rename = "type")]
    pub artist_type: Option<String>,
    pub country: Option<String>,
    pub disambiguation: Option<String>,
    #[serde(rename = "life-span")]
    pub life_span: Option<LifeSpan>,
}

/// Search result wrapper for releases
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseSearchResult {
    pub created: Option<String>,
    pub count: u32,
    pub offset: u32,
    pub releases: Vec<ReleaseSearchHit>,
}

/// Individual release in search results
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseSearchHit {
    pub id: Uuid,
    pub score: u8,
    pub title: String,
    pub status: Option<String>,
    pub date: Option<String>,
    pub country: Option<String>,
    #[serde(rename = "artist-credit", default)]
    pub artist_credit: Vec<ArtistCredit>,
    #[serde(rename = "release-group")]
    pub release_group: Option<ReleaseGroupRef>,
}
