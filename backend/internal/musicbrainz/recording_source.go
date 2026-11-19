package musicbrainz

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/validators"
)

const (
	recordingSourceTimeout  = 5 * time.Second
	recordingSourceMaxBytes = 256 << 10
	recordingSourceMaxURL   = 2048
	// MusicBrainz recording-to-URL "free streaming" relation (not the
	// release/artist variants). Its optional "video" attribute is not audio.
	freeRecordingStream = "7e41ef12-a124-4324-afdb-fdbae687a89c"
)

type recordingSourceReadKey struct{}

func recordingSourceRead(ctx context.Context) bool {
	return ctx.Value(recordingSourceReadKey{}) == true
}

// GetRecordingSource returns a canonical audio source only when the exact
// recording directly names a unique qualified URL. It never opens that URL.
func (c *Client) GetRecordingSource(ctx context.Context, id uuid.UUID) (*string, error) {
	if id == uuid.Nil {
		return nil, fmt.Errorf("recording ID is required")
	}
	ctx, cancel := context.WithTimeout(ctx, recordingSourceTimeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	ctx = context.WithValue(ctx, recordingSourceReadKey{}, true)
	mbID := id.String()
	// This deadline-bound read shares concurrent provider work, but skips the
	// Redis cache, whose socket deadlines are independent of the caller's.
	body, err := c.doRequest(ctx, baseURL+"/recording/"+mbID+"?fmt=json&inc=url-rels")
	if err != nil {
		return nil, err
	}
	source, err := selectRecordingSource(body, mbID)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return source, nil
}

func selectRecordingSource(body []byte, mbID string) (*string, error) {
	var recording struct {
		ID        string `json:"id"`
		Video     *bool  `json:"video"`
		Relations []struct {
			TypeID     string   `json:"type-id"`
			TargetType string   `json:"target-type"`
			Direction  string   `json:"direction"`
			Attributes []string `json:"attributes"`
			Ended      bool     `json:"ended"`
			URL        struct {
				Resource string `json:"resource"`
			} `json:"url"`
		} `json:"relations"`
	}
	if err := json.Unmarshal(body, &recording); err != nil {
		return nil, fmt.Errorf("invalid recording source response: %w", err)
	}
	if recording.ID != mbID {
		return nil, fmt.Errorf("recording source response did not match the requested ID")
	}
	// Video recordings are distinct MusicBrainz entities, even when their
	// audio sounds the same. Missing video metadata cannot attest audio.
	if recording.Video == nil || *recording.Video {
		return nil, nil
	}
	if recording.Relations == nil {
		return nil, fmt.Errorf("recording source response did not contain URL relationships")
	}

	var source string
	for _, rel := range recording.Relations {
		if rel.TypeID != freeRecordingStream || rel.TargetType != "url" || rel.Direction != "forward" || len(rel.Attributes) != 0 || rel.Ended {
			continue
		}
		canonical := canonicalRecordingSourceURL(rel.URL.Resource)
		if canonical == "" {
			continue
		}
		if source != "" && canonical != source {
			return nil, nil // distinct qualified sources; do not guess
		}
		source = canonical
	}
	if source == "" {
		return nil, nil
	}
	return &source, nil
}

var recordingSourceValidators = validators.DefaultRegistry()

// Provider validators canonicalize IDs and URLs. Restrict their broader input
// shapes first: a generic video, playlist, redirect or profile cannot attest
// an audio track, even if a validator could extract an ID from it.
func canonicalRecordingSourceURL(raw string) string {
	if len(raw) > recordingSourceMaxURL {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.User != nil || u.RawPath != "" || (u.Scheme != "http" && u.Scheme != "https") {
		return ""
	}
	query, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return ""
	}
	var sourceType validators.SourceType
	var mediaType string
	switch strings.ToLower(u.Host) {
	case "soundcloud.com", "www.soundcloud.com", "m.soundcloud.com":
		user, track, ok := strings.Cut(strings.TrimSuffix(strings.TrimPrefix(u.Path, "/"), "/"), "/")
		if !ok || user == "" || track == "" || strings.Contains(track, "/") || query.Has("secret_token") {
			return ""
		}
		switch strings.ToLower(user) {
		case "pages", "settings": // provider pages, not user profiles
			return ""
		}
		if strings.EqualFold(track, "popular-tracks") {
			return "" // profile subpage, not a recording
		}
		sourceType, mediaType = validators.SourceSoundCloud, "track"
	case "music.youtube.com":
		if u.Path != "/watch" || len(query["v"]) != 1 || strings.ContainsAny(query.Get("v"), "/?") || query.Has("list") {
			return ""
		}
		sourceType, mediaType = validators.SourceYouTube, "video" // validator's name for the /watch URL shape
	default:
		return ""
	}
	validated := recordingSourceValidators.Validate(raw)
	if !validated.Valid || validated.SourceType != sourceType || validated.MediaType != mediaType {
		return ""
	}
	return validated.Canonical
}
