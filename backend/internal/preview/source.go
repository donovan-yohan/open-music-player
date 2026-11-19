package preview

import (
	"net/url"
	"regexp"
	"strings"
	"unicode"

	"github.com/openmusicplayer/backend/internal/validators"
)

var (
	apiTrack         = regexp.MustCompile(`^/tracks/[1-9][0-9]*$`)
	sourceValidators = validators.DefaultRegistry()
)

func parseSource(raw string) *url.URL {
	if len(raw) > maxURLBytes || strings.IndexFunc(raw, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsControl(r) || r == '\\' || r == '#'
	}) >= 0 {
		return nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.String() != raw {
		return nil
	}
	return u
}

// canonicalSource is the exact manifest-key authority. The import validators
// alone are more permissive (e.g. they accept extra path and query components).
func canonicalSource(u *url.URL) validators.SourceType {
	if u == nil {
		return validators.SourceUnknown
	}
	switch u.Host {
	case "www.youtube.com", "music.youtube.com", "soundcloud.com", "api.soundcloud.com":
	default:
		return validators.SourceUnknown
	}
	raw := u.String()
	result := sourceValidators.Validate(raw)
	if !result.Valid {
		return validators.SourceUnknown
	}
	switch {
	case u.Host == "www.youtube.com" && result.MediaType == "video" && raw == result.Canonical:
		return validators.SourceYouTube
	case u.Host == "music.youtube.com" && result.MediaType == "video" && raw == strings.Replace(result.Canonical, "www.youtube.com", "music.youtube.com", 1):
		return validators.SourceYouTube
	case u.Host == "soundcloud.com" && validators.IsSoundCloudTrackPermalinkPath(u.Path) && result.MediaType == "track" && raw == result.Canonical:
		return validators.SourceSoundCloud
	case u.Host == "api.soundcloud.com" && result.MediaType == "track" && !u.ForceQuery && u.RawQuery == "" && u.RawPath == "" && apiTrack.MatchString(u.Path):
		return validators.SourceSoundCloud
	}
	return validators.SourceUnknown
}

// SourceKey projects a candidate URL to an exact manifest key without checking
// clip availability. Only Search uses alias resolution; the manifest and POST
// still take exact keys. No other candidate fields or network lookup are used.
func SourceKey(provider, raw string) string {
	source := validators.SourceType(provider)
	if source != validators.SourceYouTube && source != validators.SourceSoundCloud {
		return ""
	}
	u := parseSource(raw)
	if u == nil {
		return ""
	}
	if canonicalSource(u) == source {
		return raw
	}
	if u.RawPath != "" || u.ForceQuery {
		return ""
	}

	watch := source == validators.SourceYouTube && (u.Host == "www.youtube.com" || u.Host == "music.youtube.com") && u.Path == "/watch"
	short := source == validators.SourceYouTube && u.Host == "youtu.be"
	permalink := source == validators.SourceSoundCloud && u.Host == "soundcloud.com"
	if !watch && !short && !permalink {
		return ""
	}
	videoID, ok := previewQuery(u.RawQuery, watch)
	if !ok {
		return ""
	}
	u.RawQuery = ""
	if short {
		videoID = strings.TrimPrefix(u.Path, "/")
		u.Host = "www.youtube.com"
		u.Path = "/watch"
	}
	if watch || short {
		u.RawQuery = "v=" + videoID
	}
	key := u.String()
	if canonicalSource(parseSource(key)) == source {
		return key
	}
	return ""
}

// Accept only literal, single-occurrence parameter names. In particular, do
// not use URL.Query().Get("v"): it silently picks the first of duplicate IDs
// and can ignore malformed query fields. Unknown keys may carry identity or
// access semantics, so do not discard them.
func previewQuery(raw string, watch bool) (videoID string, ok bool) {
	if raw == "" {
		return "", !watch
	}
	values, err := url.ParseQuery(raw)
	if err != nil || len(values) != strings.Count(raw, "&")+1 {
		return "", false
	}
	for field := range strings.SplitSeq(raw, "&") {
		name, value, ok := strings.Cut(field, "=")
		if !ok {
			return "", false
		}
		switch name {
		case "v":
			if !watch {
				return "", false
			}
			videoID = value // The exact canonical-key predicate validates this ID.
		case "si", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id":
		default:
			return "", false
		}
	}
	return videoID, !watch || videoID != ""
}
