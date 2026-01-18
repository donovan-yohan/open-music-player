package validators

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// YouTubeValidator validates YouTube URLs
type YouTubeValidator struct {
	// videoIDPattern matches YouTube video IDs (11 characters, alphanumeric with - and _)
	videoIDPattern *regexp.Regexp
}

// NewYouTubeValidator creates a new YouTube URL validator
func NewYouTubeValidator() *YouTubeValidator {
	return &YouTubeValidator{
		videoIDPattern: regexp.MustCompile(`^[a-zA-Z0-9_-]{11}$`),
	}
}

// SourceType returns the source type for this validator
func (v *YouTubeValidator) SourceType() SourceType {
	return SourceYouTube
}

// CanHandle returns true if the URL appears to be a YouTube URL
func (v *YouTubeValidator) CanHandle(rawURL string) bool {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return false
	}

	host := strings.ToLower(parsed.Host)
	host = strings.TrimPrefix(host, "www.")
	host = strings.TrimPrefix(host, "m.")

	return host == "youtube.com" ||
		host == "youtu.be" ||
		host == "music.youtube.com"
}

// Validate validates a YouTube URL and extracts the video ID
func (v *YouTubeValidator) Validate(rawURL string) ValidationResult {
	rawURL = strings.TrimSpace(rawURL)

	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceYouTube,
			URL:        rawURL,
			Error:      "invalid URL format",
		}
	}

	// Ensure scheme is present
	if parsed.Scheme == "" {
		parsed.Scheme = "https"
		rawURL = parsed.String()
	}

	// Only allow http/https schemes
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceYouTube,
			URL:        rawURL,
			Error:      "invalid URL scheme",
		}
	}

	host := strings.ToLower(parsed.Host)
	host = strings.TrimPrefix(host, "www.")
	host = strings.TrimPrefix(host, "m.")

	var videoID string
	var mediaType string

	switch host {
	case "youtu.be":
		// Short URL format: youtu.be/VIDEO_ID
		videoID = strings.TrimPrefix(parsed.Path, "/")
		mediaType = "video"

	case "youtube.com", "music.youtube.com":
		videoID, mediaType = v.extractFromYouTubeCom(parsed)

	default:
		return ValidationResult{
			Valid:      false,
			SourceType: SourceYouTube,
			URL:        rawURL,
			Error:      "not a YouTube URL",
		}
	}

	// Validate the extracted video ID
	if videoID == "" {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceYouTube,
			URL:        rawURL,
			Error:      "could not extract video ID from URL",
		}
	}

	if !v.videoIDPattern.MatchString(videoID) {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceYouTube,
			URL:        rawURL,
			MediaID:    videoID,
			Error:      "invalid video ID format",
		}
	}

	return ValidationResult{
		Valid:      true,
		SourceType: SourceYouTube,
		MediaID:    videoID,
		MediaType:  mediaType,
		URL:        rawURL,
		Canonical:  fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID),
	}
}

// extractFromYouTubeCom extracts video ID from youtube.com URLs
func (v *YouTubeValidator) extractFromYouTubeCom(parsed *url.URL) (videoID, mediaType string) {
	path := parsed.Path
	query := parsed.Query()

	// Check various path formats
	switch {
	case strings.HasPrefix(path, "/watch"):
		// Standard watch URL: /watch?v=VIDEO_ID
		videoID = query.Get("v")
		mediaType = "video"

	case strings.HasPrefix(path, "/shorts/"):
		// YouTube Shorts: /shorts/VIDEO_ID
		videoID = strings.TrimPrefix(path, "/shorts/")
		mediaType = "short"

	case strings.HasPrefix(path, "/embed/"):
		// Embed URL: /embed/VIDEO_ID
		videoID = strings.TrimPrefix(path, "/embed/")
		mediaType = "video"

	case strings.HasPrefix(path, "/v/"):
		// Old embed format: /v/VIDEO_ID
		videoID = strings.TrimPrefix(path, "/v/")
		mediaType = "video"

	case strings.HasPrefix(path, "/live/"):
		// Live stream: /live/VIDEO_ID
		videoID = strings.TrimPrefix(path, "/live/")
		mediaType = "live"
	}

	// Clean up video ID (remove any trailing path segments or query params)
	if idx := strings.Index(videoID, "/"); idx != -1 {
		videoID = videoID[:idx]
	}
	if idx := strings.Index(videoID, "?"); idx != -1 {
		videoID = videoID[:idx]
	}

	return videoID, mediaType
}
