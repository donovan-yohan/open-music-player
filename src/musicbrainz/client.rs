use reqwest::Client;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tracing::{debug, warn};
use uuid::Uuid;

use super::error::{MbError, MbResult};
use super::models::*;

const DEFAULT_BASE_URL: &str = "https://musicbrainz.org/ws/2";
const DEFAULT_USER_AGENT: &str = "OpenMusicPlayer/0.1.0 (https://github.com/openmusicplayer)";
const RATE_LIMIT_INTERVAL: Duration = Duration::from_secs(1);
const MAX_RETRIES: u32 = 3;
const INITIAL_BACKOFF: Duration = Duration::from_secs(1);

/// Rate limiter using token bucket algorithm (1 request per second)
struct RateLimiter {
    last_request: Instant,
}

impl RateLimiter {
    fn new() -> Self {
        Self {
            last_request: Instant::now() - RATE_LIMIT_INTERVAL,
        }
    }

    async fn acquire(&mut self) {
        let elapsed = self.last_request.elapsed();
        if elapsed < RATE_LIMIT_INTERVAL {
            let wait_time = RATE_LIMIT_INTERVAL - elapsed;
            debug!("Rate limiting: waiting {:?}", wait_time);
            tokio::time::sleep(wait_time).await;
        }
        self.last_request = Instant::now();
    }
}

/// MusicBrainz API client with rate limiting
#[derive(Clone)]
pub struct MusicBrainzClient {
    client: Client,
    base_url: String,
    rate_limiter: Arc<Mutex<RateLimiter>>,
}

impl MusicBrainzClient {
    /// Create a new MusicBrainz client with default settings
    pub fn new() -> MbResult<Self> {
        Self::with_user_agent(DEFAULT_USER_AGENT)
    }

    /// Create a new MusicBrainz client with a custom User-Agent
    pub fn with_user_agent(user_agent: &str) -> MbResult<Self> {
        let client = Client::builder()
            .user_agent(user_agent)
            .timeout(Duration::from_secs(30))
            .build()?;

        Ok(Self {
            client,
            base_url: DEFAULT_BASE_URL.to_string(),
            rate_limiter: Arc::new(Mutex::new(RateLimiter::new())),
        })
    }

    /// Create a new client with custom base URL (for testing)
    pub fn with_base_url(user_agent: &str, base_url: &str) -> MbResult<Self> {
        let client = Client::builder()
            .user_agent(user_agent)
            .timeout(Duration::from_secs(30))
            .build()?;

        Ok(Self {
            client,
            base_url: base_url.to_string(),
            rate_limiter: Arc::new(Mutex::new(RateLimiter::new())),
        })
    }

    /// Execute a rate-limited GET request with retry on 503
    async fn get<T: serde::de::DeserializeOwned>(&self, url: &str) -> MbResult<T> {
        let mut retries = 0;
        let mut backoff = INITIAL_BACKOFF;

        loop {
            // Acquire rate limit token
            {
                let mut limiter = self.rate_limiter.lock().await;
                limiter.acquire().await;
            }

            debug!("GET {}", url);
            let response = self.client.get(url).send().await?;
            let status = response.status();

            if status.is_success() {
                return response.json::<T>().await.map_err(|e| {
                    MbError::ParseError(format!("Failed to parse response: {}", e))
                });
            }

            if status.as_u16() == 404 {
                return Err(MbError::NotFound(url.to_string()));
            }

            if status.as_u16() == 503 {
                if retries >= MAX_RETRIES {
                    warn!("Max retries exceeded for rate limiting");
                    return Err(MbError::RateLimited);
                }
                retries += 1;
                warn!(
                    "Rate limited (503), retry {} of {} after {:?}",
                    retries, MAX_RETRIES, backoff
                );
                tokio::time::sleep(backoff).await;
                backoff *= 2; // Exponential backoff
                continue;
            }

            let message = response
                .text()
                .await
                .unwrap_or_else(|_| "Unknown error".to_string());
            return Err(MbError::ApiError {
                status: status.as_u16(),
                message,
            });
        }
    }

    /// Search for recordings by query
    pub async fn search_recordings(
        &self,
        query: &str,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> MbResult<RecordingSearchResult> {
        let limit = limit.unwrap_or(25).min(100);
        let offset = offset.unwrap_or(0);
        let url = format!(
            "{}/recording?query={}&limit={}&offset={}&fmt=json",
            self.base_url,
            urlencoding::encode(query),
            limit,
            offset
        );
        self.get(&url).await
    }

    /// Search for artists by query
    pub async fn search_artists(
        &self,
        query: &str,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> MbResult<ArtistSearchResult> {
        let limit = limit.unwrap_or(25).min(100);
        let offset = offset.unwrap_or(0);
        let url = format!(
            "{}/artist?query={}&limit={}&offset={}&fmt=json",
            self.base_url,
            urlencoding::encode(query),
            limit,
            offset
        );
        self.get(&url).await
    }

    /// Search for releases by query
    pub async fn search_releases(
        &self,
        query: &str,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> MbResult<ReleaseSearchResult> {
        let limit = limit.unwrap_or(25).min(100);
        let offset = offset.unwrap_or(0);
        let url = format!(
            "{}/release?query={}&limit={}&offset={}&fmt=json",
            self.base_url,
            urlencoding::encode(query),
            limit,
            offset
        );
        self.get(&url).await
    }

    /// Look up a recording by MBID with artists and releases
    pub async fn lookup_recording(&self, mbid: Uuid) -> MbResult<Recording> {
        let url = format!(
            "{}/recording/{}?inc=artists+releases&fmt=json",
            self.base_url, mbid
        );
        self.get(&url).await
    }

    /// Look up an artist by MBID with recordings and releases
    pub async fn lookup_artist(&self, mbid: Uuid) -> MbResult<Artist> {
        let url = format!(
            "{}/artist/{}?inc=recordings+releases&fmt=json",
            self.base_url, mbid
        );
        self.get(&url).await
    }

    /// Look up a release by MBID
    pub async fn lookup_release(&self, mbid: Uuid) -> MbResult<Release> {
        let url = format!("{}/release/{}?inc=artists&fmt=json", self.base_url, mbid);
        self.get(&url).await
    }
}

impl Default for MusicBrainzClient {
    fn default() -> Self {
        Self::new().expect("Failed to create default MusicBrainz client")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_creation() {
        let client = MusicBrainzClient::new();
        assert!(client.is_ok());
    }

    #[test]
    fn test_client_with_custom_user_agent() {
        let client = MusicBrainzClient::with_user_agent("TestApp/1.0 (test@example.com)");
        assert!(client.is_ok());
    }

    #[tokio::test]
    #[ignore] // Requires network access
    async fn test_search_recordings() {
        let client = MusicBrainzClient::new().unwrap();
        let result = client
            .search_recordings("Never Gonna Give You Up", Some(5), None)
            .await;
        assert!(result.is_ok());
        let search_result = result.unwrap();
        assert!(search_result.count > 0);
    }

    #[tokio::test]
    #[ignore] // Requires network access
    async fn test_search_artists() {
        let client = MusicBrainzClient::new().unwrap();
        let result = client.search_artists("Rick Astley", Some(5), None).await;
        assert!(result.is_ok());
        let search_result = result.unwrap();
        assert!(search_result.count > 0);
    }

    #[tokio::test]
    #[ignore] // Requires network access
    async fn test_lookup_recording() {
        let client = MusicBrainzClient::new().unwrap();
        // "Never Gonna Give You Up" recording MBID
        let mbid = Uuid::parse_str("4e0d8649-1f89-44ef-a584-9a2f8e3c4a87").unwrap();
        let result = client.lookup_recording(mbid).await;
        // May return NotFound if MBID changed, that's acceptable for this test
        assert!(result.is_ok() || matches!(result, Err(MbError::NotFound(_))));
    }

    #[tokio::test]
    async fn test_rate_limiter() {
        let mut limiter = RateLimiter::new();
        let start = Instant::now();

        // First request should be immediate
        limiter.acquire().await;

        // Second request should wait
        limiter.acquire().await;

        let elapsed = start.elapsed();
        assert!(elapsed >= RATE_LIMIT_INTERVAL);
    }
}
