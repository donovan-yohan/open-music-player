package musicbrainz

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"

	"github.com/google/uuid"
)

const (
	discoverTracklistMaxBytes  = 4 << 20
	discoverTracklistMaxMedia  = 256
	discoverTracklistMaxTracks = 4096
)

type DiscoverEdition struct {
	ReleaseMBID            string         `json:"releaseMbid"`
	ReleaseGroupMBID       string         `json:"releaseGroupMbid"`
	Title                  string         `json:"title"`
	Artist                 string         `json:"artist,omitempty"`
	ArtistCredits          []ArtistCredit `json:"artistCredits,omitempty"`
	ArtistCreditsTruncated bool           `json:"artistCreditsTruncated,omitempty"`
	Date                   string         `json:"date,omitempty"`
	Country                string         `json:"country,omitempty"`
	Status                 string         `json:"status,omitempty"`
	Disambiguation         string         `json:"disambiguation,omitempty"`
	DiscCount              int            `json:"discCount"`
	Formats                []string       `json:"formats,omitempty"`
	CoverArtURL            string         `json:"coverArtUrl"`
}

type DiscoverEditionTracklist struct {
	DiscoverEdition
	TrackCount int                    `json:"trackCount"` // actual number of returned track rows
	Tracks     []DiscoverEditionTrack `json:"tracks"`
}

type DiscoverEditionTrack struct {
	TrackMBID              string         `json:"trackMbid"` // placement identity; never the recording's ID
	RecordingMBID          string         `json:"recordingMbid,omitempty"`
	DiscPosition           int            `json:"discPosition"`
	TrackPosition          int            `json:"trackPosition"`
	Number                 string         `json:"number,omitempty"` // printed number, e.g. A1
	Kind                   string         `json:"kind"`             // track, pregap, or data
	Title                  string         `json:"title"`
	Duration               *int           `json:"duration,omitempty"` // milliseconds; unknown is absent
	Artist                 string         `json:"artist,omitempty"`
	ArtistCredits          []ArtistCredit `json:"artistCredits,omitempty"`
	ArtistCreditsTruncated bool           `json:"artistCreditsTruncated,omitempty"`
}

type discoverReleaseProviderRow struct {
	ID             string                 `json:"id"`
	Title          string                 `json:"title"`
	ArtistCredit   []discoverArtistCredit `json:"artist-credit"`
	Date           string                 `json:"date"`
	Country        string                 `json:"country"`
	Status         string                 `json:"status"`
	Disambiguation string                 `json:"disambiguation"`
	ReleaseGroup   struct {
		ID string `json:"id"`
	} `json:"release-group"`
	Media []discoverMedium `json:"media"`
}

type discoverMedium struct {
	Position    int                     `json:"position"`
	Format      string                  `json:"format"`
	TrackCount  *int                    `json:"track-count"`
	TrackOffset int                     `json:"track-offset"`
	Tracks      []discoverProviderTrack `json:"tracks"`
	Pregap      *discoverProviderTrack  `json:"pregap"`
	DataTracks  []discoverProviderTrack `json:"data-tracks"`
}

type discoverProviderTrack struct {
	ID           string                 `json:"id"`
	Position     *int                   `json:"position"`
	Number       string                 `json:"number"`
	Title        string                 `json:"title"`
	Length       *int                   `json:"length"`
	ArtistCredit []discoverArtistCredit `json:"artist-credit"`
	Recording    struct {
		ID           string                 `json:"id"`
		Title        string                 `json:"title"`
		ArtistCredit []discoverArtistCredit `json:"artist-credit"`
	} `json:"recording"`
}

// BrowseReleaseGroupEditions pages concrete releases, with no tracklist fetches.
func (c *Client) BrowseReleaseGroupEditions(ctx context.Context, id uuid.UUID, limit, offset int) (*DiscoverBrowsePage[DiscoverEdition], error) {
	if !validDiscoverPage(id, limit, offset) {
		return nil, ErrInvalidDiscoverBrowse
	}
	params := url.Values{"release-group": {id.String()}, "inc": {"artist-credits media release-groups"}}
	return readDiscoverPage(ctx, c, "/release", params, "release-count", "release-offset", "releases", limit, offset, func(row discoverReleaseProviderRow) (DiscoverEdition, error) {
		if row.ReleaseGroup.ID != id.String() {
			return DiscoverEdition{}, errInvalidDiscoverResponse
		}
		return c.discoverEditionRow(row)
	})
}

// GetEditionTracklist reads exactly one concrete release. Multiple placements
// of the same recording are preserved, as are the disc, ordinal, and label.
func (c *Client) GetEditionTracklist(ctx context.Context, id uuid.UUID) (*DiscoverEditionTracklist, error) {
	if id == uuid.Nil {
		return nil, ErrInvalidDiscoverBrowse
	}
	params := url.Values{"fmt": {"json"}, "inc": {"artist-credits recordings release-groups"}}
	reqURL := baseURL + "/release/" + id.String() + "?" + params.Encode()
	return readDiscoverBrowse(ctx, c, reqURL, discoverTracklistMaxBytes, entityLookupTTL, func(ctx context.Context) ([]byte, error) {
		return c.fetchDiscoverTracklist(ctx, reqURL)
	}, func(body []byte) (*DiscoverEditionTracklist, error) {
		var row discoverReleaseProviderRow
		if json.Unmarshal(body, &row) != nil || row.ID != id.String() {
			return nil, errInvalidDiscoverResponse
		}
		return c.discoverTracklist(row)
	})
}

// The small interactive page ceiling is too low for some box sets. Keep the
// same paced HTTP transport, with one attempt and a separate wire ceiling.
// A merged release is not the exact requested edition; don't follow redirects.
func (c *Client) fetchDiscoverTracklist(ctx context.Context, reqURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/json")
	client := *c.httpClient
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := doPacedRequestWithClient(req, client)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("MusicBrainz tracklist returned status %d", resp.StatusCode)
	}
	if resp.ContentLength > discoverTracklistMaxBytes {
		return nil, fmt.Errorf("MusicBrainz tracklist exceeds body budget")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, discoverTracklistMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > discoverTracklistMaxBytes {
		return nil, fmt.Errorf("MusicBrainz tracklist exceeds body budget")
	}
	return body, nil
}

func (c *Client) discoverEditionRow(row discoverReleaseProviderRow) (DiscoverEdition, error) {
	if !validDiscoverID(row.ID) || !validDiscoverID(row.ReleaseGroup.ID) || row.Title == "" || row.Media == nil || len(row.Media) > discoverTracklistMaxMedia {
		return DiscoverEdition{}, errInvalidDiscoverResponse
	}
	formats := make([]string, 0, len(row.Media))
	for _, medium := range row.Media {
		if medium.Format != "" && !slices.Contains(formats, medium.Format) {
			formats = append(formats, medium.Format)
		}
	}
	artist, credits, truncated := projectDiscoverCredits(row.ArtistCredit)
	return DiscoverEdition{
		ReleaseMBID: row.ID, ReleaseGroupMBID: row.ReleaseGroup.ID, Title: row.Title,
		Artist: artist, ArtistCredits: credits, ArtistCreditsTruncated: truncated, Date: row.Date, Country: row.Country,
		Status: row.Status, Disambiguation: row.Disambiguation, DiscCount: len(row.Media), Formats: formats,
		CoverArtURL: c.GetCoverArtURL(row.ID),
	}, nil
}

func (c *Client) discoverTracklist(row discoverReleaseProviderRow) (*DiscoverEditionTracklist, error) {
	edition, err := c.discoverEditionRow(row)
	if err != nil {
		return nil, err
	}
	out := &DiscoverEditionTracklist{DiscoverEdition: edition, Tracks: make([]DiscoverEditionTrack, 0)}
	mediaPositions := make(map[int]bool, len(row.Media))
	trackIDs := make(map[string]bool)
	for _, medium := range row.Media {
		// Omitted/null fields are not evidence of an empty medium. An explicit
		// zero count and empty audio array are valid (pregap/data are separate).
		// MusicBrainz's track-offset describes where loaded tracks start, not
		// whether their positions are contiguous (and a pregap forces offset 0).
		if medium.Position < 1 || medium.Position > len(row.Media) || mediaPositions[medium.Position] || medium.TrackOffset != 0 ||
			medium.TrackCount == nil || medium.Tracks == nil || *medium.TrackCount != len(medium.Tracks) {
			return nil, errInvalidDiscoverResponse
		}
		mediaPositions[medium.Position] = true
		// Audio and data together occupy positions 1..N; only the pregap is 0.
		positiveTrackCount := len(medium.Tracks) + len(medium.DataTracks)
		rowCount := positiveTrackCount
		if medium.Pregap != nil {
			rowCount++
		}
		if rowCount > discoverTracklistMaxTracks-len(out.Tracks) {
			return nil, errInvalidDiscoverResponse
		}
		trackPositions := make(map[int]bool, rowCount)
		appendTrack := func(track discoverProviderTrack, kind string) error {
			if track.Position == nil || (*track.Position < 1 && !(kind == "pregap" && *track.Position == 0)) ||
				(kind == "pregap" && *track.Position != 0) || *track.Position > positiveTrackCount || trackPositions[*track.Position] ||
				!validDiscoverID(track.ID) || trackIDs[track.ID] ||
				(!validDiscoverID(track.Recording.ID) && !(kind == "data" && track.Recording.ID == "")) ||
				(track.Length != nil && *track.Length < 0) {
				return errInvalidDiscoverResponse
			}
			title := track.Title
			if title == "" {
				title = track.Recording.Title
			}
			if title == "" {
				return errInvalidDiscoverResponse
			}
			credits := track.ArtistCredit
			if len(credits) == 0 {
				credits = track.Recording.ArtistCredit
			}
			artist, artistCredits, truncated := projectDiscoverCredits(credits)
			trackPositions[*track.Position], trackIDs[track.ID] = true, true
			out.Tracks = append(out.Tracks, DiscoverEditionTrack{
				TrackMBID: track.ID, RecordingMBID: track.Recording.ID, DiscPosition: medium.Position,
				TrackPosition: *track.Position, Number: track.Number, Kind: kind, Title: title, Duration: track.Length,
				Artist: artist, ArtistCredits: artistCredits, ArtistCreditsTruncated: truncated,
			})
			return nil
		}
		if medium.Pregap != nil {
			if err := appendTrack(*medium.Pregap, "pregap"); err != nil {
				return nil, err
			}
		}
		for _, tracks := range []struct {
			kind string
			rows []discoverProviderTrack
		}{{"track", medium.Tracks}, {"data", medium.DataTracks}} {
			for _, track := range tracks.rows {
				if err := appendTrack(track, tracks.kind); err != nil {
					return nil, err
				}
			}
		}
	}
	slices.SortFunc(out.Tracks, func(a, b DiscoverEditionTrack) int {
		if n := cmp.Compare(a.DiscPosition, b.DiscPosition); n != 0 {
			return n
		}
		return cmp.Compare(a.TrackPosition, b.TrackPosition)
	})
	out.TrackCount = len(out.Tracks)
	return out, nil
}
