package ytdlp

import (
	"regexp"
	"strings"
)

// Metadata contains extracted information about the downloaded media
type Metadata struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Uploader    string  `json:"uploader"`
	Duration    float64 `json:"duration"`
	Thumbnail   string  `json:"thumbnail"`
	WebpageURL  string  `json:"webpage_url"`
	Extractor   string  `json:"extractor"`
	Description string  `json:"description"`

	// Parsed fields
	Artist    string `json:"-"`
	TrackName string `json:"-"`
}

// YtdlpOutput represents the JSON output from yt-dlp --dump-json
type YtdlpOutput struct {
	ID              string   `json:"id"`
	Title           string   `json:"title"`
	Uploader        string   `json:"uploader"`
	UploaderID      string   `json:"uploader_id"`
	Channel         string   `json:"channel"`
	ChannelID       string   `json:"channel_id"`
	Duration        float64  `json:"duration"`
	Thumbnail       string   `json:"thumbnail"`
	Thumbnails      []Thumb  `json:"thumbnails"`
	WebpageURL      string   `json:"webpage_url"`
	Extractor       string   `json:"extractor"`
	ExtractorKey    string   `json:"extractor_key"`
	Description     string   `json:"description"`
	Artist          string   `json:"artist"`
	Track           string   `json:"track"`
	Album           string   `json:"album"`
	RequestedFormat *Format  `json:"requested_formats"`
	Formats         []Format `json:"formats"`
}

// Thumb represents a thumbnail entry
type Thumb struct {
	URL    string `json:"url"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

// Format represents a media format option
type Format struct {
	FormatID   string  `json:"format_id"`
	Ext        string  `json:"ext"`
	Resolution string  `json:"resolution"`
	Filesize   int64   `json:"filesize"`
	Abr        float64 `json:"abr"`
	Vbr        float64 `json:"vbr"`
}

// ToMetadata converts YtdlpOutput to Metadata with parsed artist/track
func (o *YtdlpOutput) ToMetadata() *Metadata {
	m := &Metadata{
		ID:          o.ID,
		Title:       o.Title,
		Uploader:    o.Uploader,
		Duration:    o.Duration,
		Thumbnail:   o.Thumbnail,
		WebpageURL:  o.WebpageURL,
		Extractor:   o.Extractor,
		Description: o.Description,
	}

	// Use best thumbnail if available
	if m.Thumbnail == "" && len(o.Thumbnails) > 0 {
		m.Thumbnail = o.Thumbnails[len(o.Thumbnails)-1].URL
	}

	// Try to get artist/track from yt-dlp metadata first
	if o.Artist != "" {
		m.Artist = o.Artist
		m.TrackName = o.Track
		if m.TrackName == "" {
			m.TrackName = o.Title
		}
	} else {
		// Parse from title
		m.Artist, m.TrackName = parseArtistTrack(o.Title, o.Uploader, o.Channel)
	}

	return m
}

// parseArtistTrack attempts to extract artist and track from title
// Common patterns: "Artist - Track", "Artist — Track", "Artist | Track"
func parseArtistTrack(title, uploader, channel string) (artist, track string) {
	// Try common separators
	separators := []string{" - ", " — ", " – ", " | "}

	for _, sep := range separators {
		if idx := strings.Index(title, sep); idx > 0 {
			artist = strings.TrimSpace(title[:idx])
			track = strings.TrimSpace(title[idx+len(sep):])
			// Clean up common suffixes
			track = cleanTrackName(track)
			return artist, track
		}
	}

	// No separator found, use uploader/channel as artist
	artist = uploader
	if artist == "" {
		artist = channel
	}
	track = cleanTrackName(title)

	return artist, track
}

// cleanTrackName removes common suffixes like "(Official Video)", "[HD]", etc.
func cleanTrackName(track string) string {
	patterns := []string{
		`\s*\(Official.*?\)`,
		`\s*\(Lyric.*?\)`,
		`\s*\(Audio.*?\)`,
		`\s*\(Music Video.*?\)`,
		`\s*\(Visualizer.*?\)`,
		`\s*\[Official.*?\]`,
		`\s*\[HD\]`,
		`\s*\[HQ\]`,
		`\s*\[4K\]`,
		`\s*\[Lyrics\]`,
	}

	result := track
	for _, pattern := range patterns {
		re := regexp.MustCompile(`(?i)` + pattern)
		result = re.ReplaceAllString(result, "")
	}

	return strings.TrimSpace(result)
}
