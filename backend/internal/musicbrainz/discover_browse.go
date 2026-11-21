package musicbrainz

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

const (
	DiscoverBrowseDefaultLimit = 20
	DiscoverBrowseMaxLimit     = 25
	DiscoverBrowseMaxOffset    = 10000
	discoverBrowseMaxBytes     = 1 << 20 // shared interactive public-read policy
	discoverBrowseTimeout      = 5 * time.Second
)

var ErrInvalidDiscoverBrowse = errors.New("invalid catalog browse parameters")
var errInvalidDiscoverResponse = errors.New("invalid MusicBrainz catalog browse response")

type DiscographyType string

const (
	DiscographyAlbum     DiscographyType = "album"
	DiscographySingle    DiscographyType = "single"
	DiscographyEP        DiscographyType = "ep"
	DiscographyBroadcast DiscographyType = "broadcast"
	DiscographyOther     DiscographyType = "other"
)

// DiscoverBrowsePage uses provider offsets, not offsets into a local sort.
// NextOffset follows the number of source rows actually returned, which can be
// less than the requested limit even when the provider has more results.
type DiscoverBrowsePage[T any] struct {
	Results    []T  `json:"results"`
	Total      int  `json:"total"`
	Limit      int  `json:"limit"`
	Offset     int  `json:"offset"`
	HasMore    bool `json:"hasMore"`
	NextOffset *int `json:"nextOffset,omitempty"`
	Truncated  bool `json:"truncated,omitempty"` // provider has more past our offset cap
}

type DiscoverReleaseGroup struct {
	ReleaseGroupMBID       string         `json:"releaseGroupMbid"`
	Title                  string         `json:"title"`
	Artist                 string         `json:"artist,omitempty"`
	ArtistCredits          []ArtistCredit `json:"artistCredits,omitempty"`
	ArtistCreditsTruncated bool           `json:"artistCreditsTruncated,omitempty"`
	PrimaryType            string         `json:"primaryType,omitempty"`
	SecondaryTypes         []string       `json:"secondaryTypes,omitempty"`
	FirstReleaseDate       string         `json:"firstReleaseDate,omitempty"`
	Disambiguation         string         `json:"disambiguation,omitempty"`
	CoverArtURL            string         `json:"coverArtUrl"`
}

// BrowseArtistDiscography returns release groups, never concrete editions.
// The optional type is applied upstream before paging.
func (c *Client) BrowseArtistDiscography(ctx context.Context, id uuid.UUID, kind DiscographyType, limit, offset int) (*DiscoverBrowsePage[DiscoverReleaseGroup], error) {
	switch kind {
	case "", DiscographyAlbum, DiscographySingle, DiscographyEP, DiscographyBroadcast, DiscographyOther:
	default:
		return nil, ErrInvalidDiscoverBrowse
	}
	if !validDiscoverPage(id, limit, offset) {
		return nil, ErrInvalidDiscoverBrowse
	}
	params := url.Values{"artist": {id.String()}, "inc": {"artist-credits"}}
	if kind != "" {
		params.Set("type", string(kind))
	}
	return readDiscoverPage(ctx, c, "/release-group", params, "release-group-count", "release-group-offset", "release-groups", limit, offset, 0, func(row discoverGroupProviderRow) (DiscoverReleaseGroup, error) {
		// Check the provider's full credit list before its display projection is capped.
		if !discoverHasCredit(row.ArtistCredit, id) || (kind != "" && !strings.EqualFold(row.PrimaryType, string(kind))) {
			return DiscoverReleaseGroup{}, errInvalidDiscoverResponse
		}
		return c.discoverGroupRow(row)
	})
}

type discoverArtistCredit struct {
	Name       string `json:"name"`
	JoinPhrase string `json:"joinphrase"`
	Artist     struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"artist"`
}

func projectDiscoverCredits(rows []discoverArtistCredit) (string, []ArtistCredit, bool) {
	var display strings.Builder
	credits := make([]ArtistCredit, 0, min(len(rows), maxArtistCredits))
	for i, row := range rows {
		if i == maxArtistCredits {
			break
		}
		name := row.Name
		if name == "" {
			name = row.Artist.Name
		}
		display.WriteString(name)
		if i+1 < len(rows) && i+1 < maxArtistCredits {
			display.WriteString(row.JoinPhrase)
		}
		if validDiscoverID(row.Artist.ID) {
			credits = append(credits, ArtistCredit{MBID: row.Artist.ID, Name: row.Artist.Name})
		}
	}
	return display.String(), credits, len(rows) > maxArtistCredits
}

type discoverGroupProviderRow struct {
	ID               string                 `json:"id"`
	Title            string                 `json:"title"`
	PrimaryType      string                 `json:"primary-type"`
	SecondaryTypes   []string               `json:"secondary-types"`
	FirstReleaseDate string                 `json:"first-release-date"`
	Disambiguation   string                 `json:"disambiguation"`
	ArtistCredit     []discoverArtistCredit `json:"artist-credit"`
}

func (c *Client) discoverGroupRow(row discoverGroupProviderRow) (DiscoverReleaseGroup, error) {
	if !validDiscoverID(row.ID) || strings.TrimSpace(row.Title) == "" {
		return DiscoverReleaseGroup{}, errInvalidDiscoverResponse
	}
	artist, credits, truncated := projectDiscoverCredits(row.ArtistCredit)
	return DiscoverReleaseGroup{
		ReleaseGroupMBID: row.ID, Title: row.Title, PrimaryType: row.PrimaryType,
		SecondaryTypes: row.SecondaryTypes, FirstReleaseDate: row.FirstReleaseDate, Disambiguation: row.Disambiguation,
		Artist: artist, ArtistCredits: credits, ArtistCreditsTruncated: truncated,
		CoverArtURL: c.releaseGroupCoverArtURL(releaseGroupID(row.ID)),
	}, nil
}

func validDiscoverID(raw string) bool {
	id, err := uuid.Parse(raw)
	return err == nil && id != uuid.Nil && id.String() == raw
}

func validDiscoverPage(id uuid.UUID, limit, offset int) bool {
	return id != uuid.Nil && limit >= 1 && limit <= DiscoverBrowseMaxLimit && offset >= 0 && offset <= DiscoverBrowseMaxOffset
}

func readDiscoverPage[P, T any](ctx context.Context, c *Client, path string, params url.Values, countKey, offsetKey, rowsKey string, limit, offset, resultWindow int, project func(P) (T, error)) (*DiscoverBrowsePage[T], error) {
	providerLimit, lastOffset := limit, DiscoverBrowseMaxOffset
	if resultWindow > 0 {
		lastOffset = min(lastOffset, resultWindow-1)
		if offset > lastOffset {
			return nil, ErrInvalidDiscoverBrowse
		}
		providerLimit = min(limit, resultWindow-offset)
	}
	params.Set("fmt", "json")
	params.Set("limit", strconv.Itoa(providerLimit))
	params.Set("offset", strconv.Itoa(offset))
	reqURL := baseURL + path + "?" + params.Encode()
	return readDiscoverBrowse(ctx, c, reqURL, discoverBrowseMaxBytes, searchTTL, func(ctx context.Context) ([]byte, error) {
		// Browse already owns a full fill. Reuse paced transport without
		// joining a doRequest flight with another caller's lifetime.
		return c.requestWithRetry(ctx, reqURL)
	}, func(body []byte) (*DiscoverBrowsePage[T], error) {
		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(body, &envelope); err != nil {
			return nil, errInvalidDiscoverResponse
		}
		var count, returnedOffset *int
		if json.Unmarshal(envelope[countKey], &count) != nil || count == nil || *count < 0 ||
			json.Unmarshal(envelope[offsetKey], &returnedOffset) != nil || returnedOffset == nil || *returnedOffset != offset {
			return nil, errInvalidDiscoverResponse
		}
		rows := json.NewDecoder(bytes.NewReader(envelope[rowsKey]))
		if open, err := rows.Token(); err != nil || open != json.Delim('[') {
			return nil, errInvalidDiscoverResponse
		}
		out := &DiscoverBrowsePage[T]{Results: make([]T, 0, providerLimit), Total: *count, Limit: limit, Offset: offset}
		for rows.More() {
			if len(out.Results) >= providerLimit {
				return nil, errInvalidDiscoverResponse
			}
			var row *P
			if err := rows.Decode(&row); err != nil || row == nil {
				return nil, errInvalidDiscoverResponse
			}
			item, err := project(*row)
			if err != nil {
				return nil, err
			}
			out.Results = append(out.Results, item)
		}
		if close, err := rows.Token(); err != nil || close != json.Delim(']') {
			return nil, errInvalidDiscoverResponse
		}
		next := offset + len(out.Results)
		if (len(out.Results) == 0 && offset < *count) || (len(out.Results) > 0 && next > *count) {
			return nil, errInvalidDiscoverResponse
		}
		if next < *count {
			out.Truncated = next > lastOffset
			out.HasMore = !out.Truncated
			if out.HasMore {
				out.NextOffset = &next
			}
		}
		return out, nil
	})
}

// Cache only complete, validated public responses. Each request decodes its
// own DTO under the same byte and shape rules whether cold or warm.
func readDiscoverBrowse[T any](ctx context.Context, c *Client, reqURL string, maxBytes int, ttl time.Duration, fetch func(context.Context) ([]byte, error), decode func([]byte) (*T, error)) (*T, error) {
	return readDiscoverBrowseWithCache(ctx, c, c, reqURL, maxBytes, ttl, fetch, decode)
}

type discoverBrowseCache interface {
	cacheGet(context.Context, string) (string, bool)
	cacheSet(context.Context, string, string, time.Duration)
}

type discoverBrowseFlightKey struct {
	client   *Client
	url      string
	maxBytes int
}

type discoverBrowseFlight struct {
	done    chan struct{}
	cancel  context.CancelFunc
	callers int // protected by discoverBrowseFlights
	body    []byte
	err     error
}

// Unlike the transport-only doRequest registry, a browse flight owns the cache
// read, provider read, validation and cache write. Retain only active fills,
// partitioned by Client; the underlying provider pacing is still process-wide.
var discoverBrowseFlights = struct {
	sync.Mutex
	active map[discoverBrowseFlightKey]*discoverBrowseFlight
}{active: make(map[discoverBrowseFlightKey]*discoverBrowseFlight)}

func readDiscoverBrowseWithCache[T any](ctx context.Context, c *Client, store discoverBrowseCache, reqURL string, maxBytes int, ttl time.Duration, fetch func(context.Context) ([]byte, error), decode func([]byte) (*T, error)) (*T, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	key := discoverBrowseFlightKey{client: c, url: reqURL, maxBytes: maxBytes}
	var firstValue *T // the first caller alone can use the fill's decoded DTO
	discoverBrowseFlights.Lock()
	flight := discoverBrowseFlights.active[key]
	first := flight == nil
	if first {
		// This is public metadata, so the fill carries the browse policy, not
		// the first caller's deadline, cancellation, values or private budgets.
		fillCtx, cancel := context.WithTimeout(WithInteractiveCatalogRead(context.Background()), discoverBrowseTimeout)
		flight = &discoverBrowseFlight{done: make(chan struct{}), cancel: cancel}
		discoverBrowseFlights.active[key] = flight
		go func() {
			defer cancel()
			cacheKey := c.buildCacheKey("discover-browse-v1", reqURL, 0, 0)
			flight.body, firstValue, flight.err = fillDiscoverBrowse(fillCtx, store, cacheKey, maxBytes, ttl, fetch, decode)
			discoverBrowseFlights.Lock()
			if discoverBrowseFlights.active[key] == flight {
				delete(discoverBrowseFlights.active, key)
			}
			close(flight.done)
			discoverBrowseFlights.Unlock()
		}()
	}
	flight.callers++
	discoverBrowseFlights.Unlock()
	defer leaveDiscoverBrowseFlight(key, flight)

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-flight.done:
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if flight.err != nil || first {
		return firstValue, flight.err
	}
	value, err := decode(flight.body)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return value, err
}

func leaveDiscoverBrowseFlight(key discoverBrowseFlightKey, flight *discoverBrowseFlight) {
	discoverBrowseFlights.Lock()
	defer discoverBrowseFlights.Unlock()
	flight.callers--
	if flight.callers == 0 && discoverBrowseFlights.active[key] == flight {
		// Stop abandoned work and don't make a later caller join its failure.
		flight.cancel()
		delete(discoverBrowseFlights.active, key)
	}
}

func fillDiscoverBrowse[T any](ctx context.Context, store discoverBrowseCache, key string, maxBytes int, ttl time.Duration, fetch func(context.Context) ([]byte, error), decode func([]byte) (*T, error)) ([]byte, *T, error) {
	if cached, ok := store.cacheGet(ctx, key); ok && len(cached) <= maxBytes {
		body := []byte(cached)
		value, err := decode(body)
		if ctx.Err() != nil {
			return nil, nil, ctx.Err()
		}
		if err == nil {
			return body, value, nil
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	body, err := fetch(ctx)
	if ctx.Err() != nil {
		return nil, nil, ctx.Err()
	}
	if err != nil {
		return nil, nil, err
	}
	if len(body) > maxBytes {
		return nil, nil, fmt.Errorf("MusicBrainz catalog browse exceeds body budget")
	}
	value, err := decode(body)
	if ctx.Err() != nil {
		return nil, nil, ctx.Err()
	}
	if err != nil {
		return nil, nil, fmt.Errorf("decode catalog browse: %w", err)
	}
	// A best-effort SET can exhaust the remaining fill budget without
	// invalidating the result. Each caller still checks its own context.
	store.cacheSet(ctx, key, string(body), ttl)
	return body, value, nil
}
