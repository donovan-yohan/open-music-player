package validators

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// SoundCloudValidator validates SoundCloud URLs
type SoundCloudValidator struct {
	// usernamePattern matches valid SoundCloud usernames
	usernamePattern *regexp.Regexp
	// trackSlugPattern matches valid track/set slugs
	trackSlugPattern *regexp.Regexp
}

// NewSoundCloudValidator creates a new SoundCloud URL validator
func NewSoundCloudValidator() *SoundCloudValidator {
	return &SoundCloudValidator{
		// SoundCloud usernames: alphanumeric, hyphens, underscores, 3-25 chars
		usernamePattern: regexp.MustCompile(`^[a-zA-Z0-9_-]{3,25}$`),
		// Track/set slugs: alphanumeric, hyphens, underscores
		trackSlugPattern: regexp.MustCompile(`^[a-zA-Z0-9_-]+$`),
	}
}

// SourceType returns the source type for this validator
func (v *SoundCloudValidator) SourceType() SourceType {
	return SourceSoundCloud
}

// CanHandle returns true if the URL appears to be a SoundCloud URL
func (v *SoundCloudValidator) CanHandle(rawURL string) bool {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return false
	}

	host := strings.ToLower(parsed.Host)
	host = strings.TrimPrefix(host, "www.")
	host = strings.TrimPrefix(host, "m.")

	return host == "soundcloud.com" ||
		host == "on.soundcloud.com" ||
		host == "api.soundcloud.com" ||
		host == "w.soundcloud.com"
}

// Validate validates a SoundCloud URL and extracts relevant information
func (v *SoundCloudValidator) Validate(rawURL string) ValidationResult {
	rawURL = strings.TrimSpace(rawURL)

	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
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
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "invalid URL scheme",
		}
	}

	host := strings.ToLower(parsed.Host)
	host = strings.TrimPrefix(host, "www.")
	host = strings.TrimPrefix(host, "m.")

	switch host {
	case "soundcloud.com":
		return v.validateMainURL(rawURL, parsed)

	case "on.soundcloud.com":
		return v.validateShortURL(rawURL, parsed)

	case "api.soundcloud.com":
		return v.validateAPIURL(rawURL, parsed)

	case "w.soundcloud.com":
		return v.validateWidgetURL(rawURL, parsed)

	default:
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "not a SoundCloud URL",
		}
	}
}

// validateMainURL validates soundcloud.com URLs
func (v *SoundCloudValidator) validateMainURL(rawURL string, parsed *url.URL) ValidationResult {
	// Split path into segments, filtering empty strings
	segments := splitPath(parsed.Path)

	if len(segments) == 0 {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "URL path is empty",
		}
	}

	// Filter out reserved paths
	reservedPaths := map[string]bool{
		"discover":     true,
		"stream":       true,
		"you":          true,
		"search":       true,
		"upload":       true,
		"people":       true,
		"groups":       true,
		"tags":         true,
		"popular":      true,
		"charts":       true,
		"terms-of-use": true,
		"privacy":      true,
	}

	if reservedPaths[segments[0]] {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "URL points to a reserved SoundCloud page, not a track or artist",
		}
	}

	username := segments[0]

	// Validate username format
	if !v.usernamePattern.MatchString(username) {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "invalid SoundCloud username format",
		}
	}

	// Just username: artist page
	if len(segments) == 1 {
		return ValidationResult{
			Valid:      true,
			SourceType: SourceSoundCloud,
			MediaID:    username,
			MediaType:  "artist",
			URL:        rawURL,
			Canonical:  fmt.Sprintf("https://soundcloud.com/%s", username),
		}
	}

	// Check for special paths
	switch segments[1] {
	case "sets":
		// Playlist: /username/sets/playlist-name
		if len(segments) < 3 {
			return ValidationResult{
				Valid:      false,
				SourceType: SourceSoundCloud,
				URL:        rawURL,
				Error:      "playlist URL missing playlist name",
			}
		}
		playlistSlug := segments[2]
		if !v.trackSlugPattern.MatchString(playlistSlug) {
			return ValidationResult{
				Valid:      false,
				SourceType: SourceSoundCloud,
				URL:        rawURL,
				Error:      "invalid playlist slug format",
			}
		}
		return ValidationResult{
			Valid:      true,
			SourceType: SourceSoundCloud,
			MediaID:    fmt.Sprintf("%s/sets/%s", username, playlistSlug),
			MediaType:  "playlist",
			URL:        rawURL,
			Canonical:  fmt.Sprintf("https://soundcloud.com/%s/sets/%s", username, playlistSlug),
		}

	case "likes", "tracks", "albums", "playlists", "reposts", "followers", "following":
		// User profile sub-pages
		return ValidationResult{
			Valid:      true,
			SourceType: SourceSoundCloud,
			MediaID:    username,
			MediaType:  "artist",
			URL:        rawURL,
			Canonical:  fmt.Sprintf("https://soundcloud.com/%s", username),
		}

	default:
		// Track: /username/track-name
		trackSlug := segments[1]
		if !v.trackSlugPattern.MatchString(trackSlug) {
			return ValidationResult{
				Valid:      false,
				SourceType: SourceSoundCloud,
				URL:        rawURL,
				Error:      "invalid track slug format",
			}
		}
		return ValidationResult{
			Valid:      true,
			SourceType: SourceSoundCloud,
			MediaID:    fmt.Sprintf("%s/%s", username, trackSlug),
			MediaType:  "track",
			URL:        rawURL,
			Canonical:  fmt.Sprintf("https://soundcloud.com/%s/%s", username, trackSlug),
		}
	}
}

// validateShortURL validates on.soundcloud.com short URLs
func (v *SoundCloudValidator) validateShortURL(rawURL string, parsed *url.URL) ValidationResult {
	segments := splitPath(parsed.Path)

	if len(segments) == 0 {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "short URL missing code",
		}
	}

	shortCode := segments[0]

	// Short codes are typically alphanumeric
	if len(shortCode) < 5 || len(shortCode) > 20 {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "invalid short URL code format",
		}
	}

	// Short URLs are valid but we can't resolve them without an API call
	// Mark as valid with the short code as the ID
	return ValidationResult{
		Valid:      true,
		SourceType: SourceSoundCloud,
		MediaID:    shortCode,
		MediaType:  "short_url",
		URL:        rawURL,
		Canonical:  fmt.Sprintf("https://on.soundcloud.com/%s", shortCode),
	}
}

// validateAPIURL validates api.soundcloud.com URLs
func (v *SoundCloudValidator) validateAPIURL(rawURL string, parsed *url.URL) ValidationResult {
	segments := splitPath(parsed.Path)

	if len(segments) < 2 {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "invalid API URL format",
		}
	}

	resourceType := segments[0]
	resourceID := segments[1]

	switch resourceType {
	case "tracks", "playlists", "users":
		mediaType := resourceType
		if mediaType == "tracks" {
			mediaType = "track"
		} else if mediaType == "playlists" {
			mediaType = "playlist"
		} else if mediaType == "users" {
			mediaType = "artist"
		}

		return ValidationResult{
			Valid:      true,
			SourceType: SourceSoundCloud,
			MediaID:    resourceID,
			MediaType:  mediaType,
			URL:        rawURL,
			Canonical:  rawURL, // API URLs are their own canonical form
		}

	default:
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "unsupported API resource type",
		}
	}
}

// validateWidgetURL validates w.soundcloud.com widget/player URLs
func (v *SoundCloudValidator) validateWidgetURL(rawURL string, parsed *url.URL) ValidationResult {
	// Widget URLs have the actual URL in the 'url' query parameter
	embedURL := parsed.Query().Get("url")
	if embedURL == "" {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "widget URL missing embedded URL parameter",
		}
	}

	// Recursively validate the embedded URL
	embedParsed, err := url.Parse(embedURL)
	if err != nil {
		return ValidationResult{
			Valid:      false,
			SourceType: SourceSoundCloud,
			URL:        rawURL,
			Error:      "invalid embedded URL in widget",
		}
	}

	// Check if it's an API URL or main URL
	host := strings.ToLower(embedParsed.Host)
	if host == "api.soundcloud.com" {
		result := v.validateAPIURL(embedURL, embedParsed)
		result.URL = rawURL // Keep the original widget URL
		return result
	}

	return ValidationResult{
		Valid:      false,
		SourceType: SourceSoundCloud,
		URL:        rawURL,
		Error:      "widget contains unsupported embedded URL",
	}
}

// splitPath splits a URL path into non-empty segments
func splitPath(path string) []string {
	parts := strings.Split(path, "/")
	segments := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			segments = append(segments, p)
		}
	}
	return segments
}
