package db

import (
	"encoding/json"
	"net/url"
	"strings"
)

// ArtworkKind identifies what a display image represents. Provider thumbnails
// are deliberately distinct from enriched/release cover art so clients never
// present a useful fallback as verified album artwork.
type ArtworkKind string

const (
	ArtworkKindCoverArt          ArtworkKind = "cover_art"
	ArtworkKindReleaseCover      ArtworkKind = "release_cover"
	ArtworkKindProviderThumbnail ArtworkKind = "provider_thumbnail"
	ArtworkKindNone              ArtworkKind = "none"
)

// ArtworkDescriptor is the one effective display-artwork contract shared by
// collection APIs. URL is empty only for ArtworkKindNone.
type ArtworkDescriptor struct {
	URL  string      `json:"url,omitempty"`
	Kind ArtworkKind `json:"kind"`
}

// LegacyCoverArtURL projects this descriptor into the pre-descriptor cover
// field without resolving the track a second time.
func (artwork ArtworkDescriptor) LegacyCoverArtURL() string {
	switch artwork.Kind {
	case ArtworkKindCoverArt, ArtworkKindReleaseCover:
		return artwork.URL
	default:
		return ""
	}
}

// ResolveTrackArtwork applies the additive display fallback contract:
//
//  1. stored enriched cover
//  2. Cover Art Archive release cover
//  3. retained provider thumbnail
//  4. no remote artwork
//
// Metadata is read only. Resolving artwork never rematches or rewrites a track.
func ResolveTrackArtwork(track Track) ArtworkDescriptor {
	if track.CoverArtURL.Valid {
		if artworkURL := safeRemoteArtworkURL(track.CoverArtURL.String); artworkURL != "" {
			return ArtworkDescriptor{URL: artworkURL, Kind: ArtworkKindCoverArt}
		}
	}
	if track.MBReleaseID != nil {
		return ArtworkDescriptor{
			URL:  "https://coverartarchive.org/release/" + track.MBReleaseID.String() + "/front-250",
			Kind: ArtworkKindReleaseCover,
		}
	}
	for _, document := range []json.RawMessage{
		track.MetadataJSON,
		track.MetadataProvenance,
	} {
		if artworkURL := retainedProviderThumbnail(document); artworkURL != "" {
			return ArtworkDescriptor{
				URL:  artworkURL,
				Kind: ArtworkKindProviderThumbnail,
			}
		}
	}
	return ArtworkDescriptor{Kind: ArtworkKindNone}
}

// LegacyCoverArtURL preserves the old cover field without relabeling a
// provider thumbnail as album art.
func LegacyCoverArtURL(track Track) string {
	return ResolveTrackArtwork(track).LegacyCoverArtURL()
}

func retainedProviderThumbnail(document json.RawMessage) string {
	if len(document) == 0 {
		return ""
	}
	var decoded map[string]any
	if err := json.Unmarshal(document, &decoded); err != nil {
		return ""
	}
	provider, ok := decoded["raw_provider"].(map[string]any)
	if !ok {
		return ""
	}
	for _, key := range []string{"thumbnail", "thumbnail_url"} {
		if raw, ok := provider[key].(string); ok {
			if artworkURL := safeRemoteArtworkURL(raw); artworkURL != "" {
				return artworkURL
			}
		}
	}
	return ""
}

func safeRemoteArtworkURL(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.User != nil || parsed.Host == "" {
		return ""
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
		return trimmed
	default:
		return ""
	}
}
