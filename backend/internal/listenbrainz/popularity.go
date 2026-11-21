package listenbrainz

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

const (
	popularityMaxBytes = 512 << 10
	popularityLimit    = 10
	popularityTTL      = 12 * time.Hour
	// The v1 cache did not establish credit evidence for empty results.
	popularityCachePrefix = "lb:artist-popularity:v2:"
)

var errPopularityUnconfigured = errors.New("listenbrainz popularity is not configured")

type PopularTrack struct {
	RecordingMBID string `json:"recordingMbid"`
	Title         string `json:"title"`
	Artist        string `json:"artist,omitempty"`
	Duration      int    `json:"duration,omitempty"`
	ListenCount   int64  `json:"listenCount"`
}

type PopularityCache interface {
	Get(context.Context, string) (string, bool)
	Set(context.Context, string, string, time.Duration) error
}

// PopularityService holds a small optional shelf apart from discography and
// similar-artist expansion. Cache hits do not acquire upstream admission.
// Overlapping reads for one artist share the active attempt; other cold reads
// fail fast rather than queuing a backlog for an optional shelf.
type PopularityService struct {
	baseURL string
	token   string
	client  *http.Client
	cache   PopularityCache
	mu      sync.Mutex
	active  *popularityRead
	next    time.Time
}

type popularityRead struct {
	artist uuid.UUID
	done   chan struct{}
	tracks []PopularTrack
	err    error
}

// NewPopularityService takes an operator-supplied ListenBrainz token, never an
// incoming API credential. An empty token disables the shelf, including cache reads.
func NewPopularityService(cache PopularityCache, token string) *PopularityService {
	return &PopularityService{baseURL: "https://api.listenbrainz.org", token: token, cache: cache,
		client: &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (s *PopularityService) TopTracks(ctx context.Context, artist uuid.UUID) ([]PopularTrack, error) {
	if artist == uuid.Nil {
		return nil, ErrBadPayload
	}
	if s.token == "" {
		return nil, errPopularityUnconfigured
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	key := popularityCachePrefix + artist.String()
	if s.cache != nil {
		if data, ok := s.cache.Get(ctx, key); ok && len(data) <= popularityMaxBytes {
			var rows []PopularTrack
			if json.Unmarshal([]byte(data), &rows) == nil && validCachedPopularity(rows) {
				return rows, nil
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	if active := s.active; active != nil && active.artist == artist {
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-active.done:
			return slices.Clone(active.tracks), active.err
		}
	}
	if s.active != nil || time.Now().Before(s.next) {
		s.mu.Unlock()
		return nil, ErrRateLimited
	}
	read := &popularityRead{artist: artist, done: make(chan struct{})}
	s.active = read
	s.mu.Unlock()
	read.tracks, read.err = s.fetchTopTracks(ctx, artist)
	if read.err == nil && s.cache != nil {
		if data, err := json.Marshal(read.tracks); err == nil {
			_ = s.cache.Set(ctx, key, string(data), popularityTTL)
		}
	}
	s.mu.Lock()
	s.active = nil
	cooldown := time.Second
	if errors.Is(read.err, ErrRateLimited) {
		cooldown = time.Minute
	}
	s.next = time.Now().Add(cooldown)
	close(read.done)
	s.mu.Unlock()
	return slices.Clone(read.tracks), read.err
}

func validCachedPopularity(rows []PopularTrack) bool {
	if rows == nil || len(rows) > popularityLimit {
		return false
	}
	for _, row := range rows {
		if !validPopularityMBID(row.RecordingMBID) || strings.TrimSpace(row.Title) == "" || row.ListenCount <= 0 || row.Duration < 0 {
			return false
		}
	}
	return true
}

func validPopularityMBID(raw string) bool {
	id, err := uuid.Parse(raw)
	return err == nil && id != uuid.Nil && raw == id.String()
}

// Keep errors.Is classification without exposing upstream-controlled error
// text (for example, a malformed Location that reflects the auth header).
type popularityIOError struct{ cause error }

func (e popularityIOError) Error() string { return ErrUnreachable.Error() }
func (e popularityIOError) Is(target error) bool {
	return target == ErrUnreachable || errors.Is(e.cause, target)
}

func (s *PopularityService) fetchTopTracks(ctx context.Context, artist uuid.UUID) ([]PopularTrack, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.baseURL+"/1/popularity/top-recordings-for-artist/"+artist.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("build ListenBrainz popularity request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "SoundQ (https://github.com/donovan-yohan/open-music-player)")
	req.Header.Set("Authorization", "Token "+s.token)
	response, err := s.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("send ListenBrainz popularity request: %w", popularityIOError{cause: err})
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusTooManyRequests {
		return nil, ErrRateLimited
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: %d", ErrUpstreamStatus, response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, popularityMaxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read ListenBrainz popularity response: %w", popularityIOError{cause: err})
	}
	// Keep the literal IDs until validated; UUID unmarshalling accepts aliases.
	var rows []struct {
		Recording string   `json:"recording_mbid"`
		Credits   []string `json:"artist_mbids"`
		Title     string   `json:"recording_name"`
		Artist    string   `json:"artist_name"`
		Duration  int      `json:"length"`
		Count     int64    `json:"total_listen_count"`
	}
	if len(data) > popularityMaxBytes || json.Unmarshal(data, &rows) != nil || rows == nil {
		return nil, ErrBadPayload
	}
	// A nonempty upstream list can establish an empty shelf only if every row
	// has explicit artist evidence. Validate before sorting and before the
	// result cap, so a malformed lower-ranked row cannot warm the cache either.
	for _, row := range rows {
		if !validPopularityMBID(row.Recording) || strings.TrimSpace(row.Title) == "" || row.Count <= 0 || len(row.Credits) == 0 {
			return nil, ErrBadPayload
		}
		for _, credit := range row.Credits {
			if !validPopularityMBID(credit) {
				return nil, ErrBadPayload
			}
		}
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Count > rows[j].Count })
	artistID := artist.String()
	seen := make(map[string]bool, popularityLimit)
	tracks := make([]PopularTrack, 0, popularityLimit)
	for _, row := range rows {
		if seen[row.Recording] || !slices.Contains(row.Credits, artistID) {
			continue
		}
		seen[row.Recording] = true
		tracks = append(tracks, PopularTrack{RecordingMBID: row.Recording, Title: strings.TrimSpace(row.Title), Artist: row.Artist, Duration: max(0, row.Duration), ListenCount: row.Count})
		if len(tracks) == popularityLimit {
			break
		}
	}
	return tracks, nil
}
