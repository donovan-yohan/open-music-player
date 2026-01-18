package validators

// SourceType identifies the platform a URL belongs to
type SourceType string

const (
	SourceYouTube    SourceType = "youtube"
	SourceSoundCloud SourceType = "soundcloud"
	SourceUnknown    SourceType = "unknown"
)

// ValidationResult contains the result of URL validation
type ValidationResult struct {
	Valid      bool       `json:"valid"`
	SourceType SourceType `json:"source_type"`
	MediaID    string     `json:"media_id,omitempty"`
	MediaType  string     `json:"media_type,omitempty"` // e.g., "video", "track", "playlist"
	URL        string     `json:"url"`
	Canonical  string     `json:"canonical_url,omitempty"`
	Error      string     `json:"error,omitempty"`
}

// Validator defines the interface for URL validators
type Validator interface {
	// SourceType returns the source type this validator handles
	SourceType() SourceType

	// CanHandle returns true if this validator can handle the given URL
	CanHandle(url string) bool

	// Validate validates the URL and extracts relevant information
	Validate(url string) ValidationResult
}
