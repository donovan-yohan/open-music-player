// Package listenbrainz implements a minimal client for the ListenBrainz labs
// similar-artists endpoint (https://labs.api.listenbrainz.org). The
// integration pins ONE similarity algorithm by name: responses record the
// algorithm verbatim, cached rows are keyed to it, and any upstream answer
// that does not carry the pinned name is rejected rather than accepted as
// whatever default the service happens to return.
package listenbrainz

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// PinnedAlgorithm is the ONE similarity algorithm this integration accepts.
// It is recorded verbatim in every response and cache row (issue #392). The
// labs API validates algorithm names against a strict enum; pinning by exact
// string means upstream enum changes surface as deterministic rejections, not
// silent drift to whatever default the service returns.
const PinnedAlgorithm = "session_based_days_7500_session_300_contribution_3_threshold_10_limit_100_filter_True_skip_30"

const (
	defaultBaseURL = "https://labs.api.listenbrainz.org"
	defaultTimeout = 10 * time.Second
	// maxResponseBytes bounds the decoded body read so a hostile upstream
	// cannot exhaust memory through this client.
	maxResponseBytes = 4 << 20
)

var (
	// ErrRateLimited reports an HTTP 429 from upstream after retries. Callers
	// degrade to empty candidate expansion; it is never surfaced to API users.
	ErrRateLimited = errors.New("listenbrainz rate limited")
	// ErrBadPayload reports a malformed or wrong-algorithm upstream payload.
	ErrBadPayload = errors.New("listenbrainz malformed payload")
)

// Client queries the labs similar-artists endpoint. baseURL is injectable for
// httptest fixture servers; a nil httpClient gets the default timeout client.
type Client struct {
	baseURL    string
	httpClient *http.Client
	// Backoff knobs, overridable in tests. Retries apply only to 429s per
	// issue #392's rate-limit/backoff requirement.
	maxRetries   int
	retryBackoff func(attempt int) time.Duration
}

func NewClient() *Client {
	return newClient(defaultBaseURL)
}

// NewClientWithBaseURL targets a custom endpoint (fixture tests only).
func NewClientWithBaseURL(baseURL string) *Client {
	return newClient(baseURL)
}

func newClient(baseURL string) *Client {
	return &Client{
		baseURL:      strings.TrimRight(baseURL, "/"),
		httpClient:   &http.Client{Timeout: defaultTimeout},
		maxRetries:   2,
		retryBackoff: defaultRetryBackoff,
	}
}

// defaultRetryBackoff is a small capped exponential: 250ms then 500ms. The cap
// keeps worst-case handler latency bounded even when upstream stays throttled.
func defaultRetryBackoff(attempt int) time.Duration {
	d := 250 * time.Millisecond
	for i := 0; i < attempt && d < time.Second; i++ {
		d *= 2
	}
	if d > time.Second {
		return time.Second
	}
	return d
}

type similarArtistRaw struct {
	ArtistMBID    string `json:"artist_mbid"`
	Name          string `json:"name"`
	Score         int    `json:"score"`
	ReferenceMBID string `json:"reference_mbid"`
	Algorithm     string `json:"algorithm,omitempty"`
}

// SimilarArtist is one validated entry of a similar-artists response.
type SimilarArtist struct {
	ArtistMBID uuid.UUID
	Name       string
	Score      int
}

// Response is a parsed upstream payload with its retrieval provenance. The
// pinned algorithm name travels with every response into callers and cache
// rows, per issue #392.
type Response struct {
	ArtistMBID  uuid.UUID
	Algorithm   string
	Similar     []SimilarArtist
	RetrievedAt time.Time
}

// SimilarArtists fetches similar artists for one reference artist MBID. On
// timeout/unreachable/429/malformed upstream it degrades to a nil result plus
// nil error — empty candidate expansion, never a caller-facing failure —
// except that ErrRateLimited is returned when every retry was exhausted on
// 429s so callers can log throttling distinctly if they choose.
func (c *Client) SimilarArtists(ctx context.Context, artistMBID uuid.UUID, count int) (*Response, error) {
	if artistMBID == uuid.Nil {
		return nil, nil
	}
	endpoint := c.baseURL + "/similar-artists/json?" + url.Values{
		"algorithm":    []string{PinnedAlgorithm},
		"artist_mbids": []string{artistMBID.String()},
	}.Encode()

	var lastErr error
	for attempt := 0; ; attempt++ {
		payload, status, err := c.fetch(ctx, endpoint)
		if err == nil {
			resp, perr := parsePayload(artistMBID, payload)
			if perr != nil {
				// Malformed upstream payload degrades deterministically to
				// empty expansion; no retry can fix a bad body.
				return nil, nil
			}
			return resp, nil
		}
		if errors.Is(err, errStatus) && status == http.StatusTooManyRequests {
			lastErr = ErrRateLimited
			if attempt < c.maxRetries {
				time.Sleep(c.retryBackoff(attempt))
				continue
			}
			return nil, lastErr
		}
		// Timeout, connection refused, 5xx: unreachable upstream. Empty
		// candidate expansion without surfacing an error to callers.
		return nil, nil
	}
}

var errStatus = errors.New("listenbrainz unexpected status")

func (c *Client) fetch(ctx context.Context, endpoint string) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, 0, err
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode, fmt.Errorf("%w: %d", errStatus, resp.StatusCode)
	}
	return body, resp.StatusCode, nil
}

// parsePayload validates the upstream document deterministically: it must be a
// JSON array whose entries all carry the pinned algorithm (when present),
// parseable MBIDs, and non-negative scores. Any violation rejects the whole
// payload rather than silently dropping entries.
func parsePayload(reference uuid.UUID, raw []byte) (*Response, error) {
	var entries []similarArtistRaw
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&entries); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadPayload, err)
	}
	now := time.Now().UTC()
	response := &Response{
		ArtistMBID:  reference,
		Algorithm:   PinnedAlgorithm,
		RetrievedAt: now,
		Similar:     make([]SimilarArtist, 0, len(entries)),
	}
	for _, e := range entries {
		if e.Algorithm != "" && e.Algorithm != PinnedAlgorithm {
			return nil, fmt.Errorf("%w: unexpected algorithm %q", ErrBadPayload, e.Algorithm)
		}
		mbid, err := uuid.Parse(e.ArtistMBID)
		if err != nil || mbid == uuid.Nil {
			return nil, fmt.Errorf("%w: bad artist_mbid %q", ErrBadPayload, e.ArtistMBID)
		}
		if e.Score < 0 || strconv.Itoa(e.Score) == "" {
			return nil, fmt.Errorf("%w: bad score %d", ErrBadPayload, e.Score)
		}
		response.Similar = append(response.Similar, SimilarArtist{ArtistMBID: mbid, Name: e.Name, Score: e.Score})
	}
	return response, nil
}
