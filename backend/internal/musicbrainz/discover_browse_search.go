package musicbrainz

import (
	"context"
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
)

const discoverArtistSearchMaxQueryBytes = 160

var discoverTitleLiteral = strings.NewReplacer(`\`, `\\`, `"`, `\"`)

type DiscoverRecording struct {
	RecordingMBID          string         `json:"recordingMbid"`
	Title                  string         `json:"title"`
	Artist                 string         `json:"artist,omitempty"`
	ArtistCredits          []ArtistCredit `json:"artistCredits,omitempty"`
	ArtistCreditsTruncated bool           `json:"artistCreditsTruncated,omitempty"`
	Duration               int            `json:"duration,omitempty"` // milliseconds
	FirstReleaseDate       string         `json:"firstReleaseDate,omitempty"`
	Disambiguation         string         `json:"disambiguation,omitempty"`
}

type discoverRecordingProviderRow struct {
	ID               string                 `json:"id"`
	Title            string                 `json:"title"`
	ArtistCredit     []discoverArtistCredit `json:"artist-credit"`
	Length           int                    `json:"length"`
	FirstReleaseDate string                 `json:"first-release-date"`
	Disambiguation   string                 `json:"disambiguation"`
}

// SearchArtistRecordings queries only recordings credited to this artist ID.
func (c *Client) SearchArtistRecordings(ctx context.Context, id uuid.UUID, query string, limit, offset int) (*DiscoverBrowsePage[DiscoverRecording], error) {
	params, err := discoverArtistSearchParams(id, "recording", query, limit, offset)
	if err != nil {
		return nil, err
	}
	return readDiscoverPage(ctx, c, "/recording", params, "count", "offset", "recordings", limit, offset, func(row discoverRecordingProviderRow) (DiscoverRecording, error) {
		if !validDiscoverID(row.ID) || row.Title == "" || !discoverHasCredit(row.ArtistCredit, id) || row.Length < 0 {
			return DiscoverRecording{}, errInvalidDiscoverResponse
		}
		artist, credits, truncated := projectDiscoverCredits(row.ArtistCredit)
		return DiscoverRecording{
			RecordingMBID: row.ID, Title: row.Title, Artist: artist, ArtistCredits: credits,
			ArtistCreditsTruncated: truncated, Duration: row.Length, FirstReleaseDate: row.FirstReleaseDate,
			Disambiguation: row.Disambiguation,
		}, nil
	})
}

// SearchArtistReleaseGroups queries only release groups credited to this artist ID.
func (c *Client) SearchArtistReleaseGroups(ctx context.Context, id uuid.UUID, query string, limit, offset int) (*DiscoverBrowsePage[DiscoverReleaseGroup], error) {
	params, err := discoverArtistSearchParams(id, "releasegroup", query, limit, offset)
	if err != nil {
		return nil, err
	}
	return readDiscoverPage(ctx, c, "/release-group", params, "count", "offset", "release-groups", limit, offset, func(row discoverGroupProviderRow) (DiscoverReleaseGroup, error) {
		if !discoverHasCredit(row.ArtistCredit, id) {
			return DiscoverReleaseGroup{}, errInvalidDiscoverResponse
		}
		return c.discoverGroupRow(row)
	})
}

func discoverArtistSearchParams(id uuid.UUID, field, query string, limit, offset int) (url.Values, error) {
	if !validDiscoverPage(id, limit, offset) || len(query) > discoverArtistSearchMaxQueryBytes ||
		!utf8.ValidString(query) || strings.ContainsFunc(query, unicode.IsControl) {
		return nil, ErrInvalidDiscoverBrowse
	}
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, ErrInvalidDiscoverBrowse
	}
	// A title phrase is data, not provider query syntax. The identity clause
	// stays outside the quoted literal and cannot be replaced by the caller.
	return url.Values{"query": {field + `:"` + discoverTitleLiteral.Replace(query) + `" AND arid:` + id.String()}}, nil
}

func discoverHasCredit(credits []discoverArtistCredit, id uuid.UUID) bool {
	wanted := id.String()
	for _, credit := range credits {
		if credit.Artist.ID == wanted {
			return true
		}
	}
	return false
}
