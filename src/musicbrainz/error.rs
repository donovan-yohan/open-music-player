use thiserror::Error;

/// MusicBrainz API error types
#[derive(Error, Debug)]
pub enum MbError {
    #[error("HTTP request error: {0}")]
    Request(#[from] reqwest::Error),

    #[error("Rate limited by MusicBrainz API")]
    RateLimited,

    #[error("Resource not found: {0}")]
    NotFound(String),

    #[error("Invalid MBID format: {0}")]
    InvalidMbid(String),

    #[error("API response parse error: {0}")]
    ParseError(String),

    #[error("API error: {status} - {message}")]
    ApiError { status: u16, message: String },
}

pub type MbResult<T> = Result<T, MbError>;
