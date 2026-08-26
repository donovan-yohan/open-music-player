// Package listenbrainz implements a minimal client for the ListenBrainz labs
// similar-artists endpoint (https://labs.api.listenbrainz.org). The
// integration pins ONE similarity algorithm by name on the REQUEST, records
// that pinned name on every response and cache row, and rejects any per-entry
// algorithm that contradicts it. Every failure mode returns a typed error;
// degrading to an empty candidate expansion is the caller's job (see
// ExpansionService.Expand), never a silent nil-result-nil-error here.
package listenbrainz

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
)

// PinnedAlgorithm is the ONE similarity algorithm this integration requests.
// It is sent as the `algorithm` query parameter and recorded verbatim on every
// response and cache row (issue #392). Upstream validates the name against a
// strict enum and answers HTTP 400 for an unknown one, so an upstream enum
// rename surfaces as a deterministic ErrUpstreamStatus in the logs rather than
// silent drift to whatever default the service would otherwise pick. The
// `limit_100` segment also fixes the page size upstream returns.
const PinnedAlgorithm = "session_based_days_7500_session_300_contribution_3_threshold_10_limit_100_filter_True_skip_30"

const (
	defaultBaseURL = "https://labs.api.listenbrainz.org"
	// defaultTimeout bounds ONE HTTP attempt.
	defaultTimeout = 10 * time.Second
	// maxResponseBytes bounds the decoded body read so a hostile upstream
	// cannot exhaust memory through this client.
	maxResponseBytes = 4 << 20
)

var (
	// ErrRateLimited reports an HTTP 429 from upstream after every retry was
	// exhausted. Callers degrade to empty candidate expansion (or stale
	// cache); it is never surfaced to API users.
	ErrRateLimited = errors.New("listenbrainz rate limited")
	// ErrBadPayload reports a malformed or wrong-algorithm upstream payload.
	// Unknown JSON fields are NOT malformed: the labs API adds descriptive
	// fields (comment, type, gender, ...) that this client tolerates.
	ErrBadPayload = errors.New("listenbrainz malformed payload")
	// ErrUpstreamStatus reports a non-200, non-429 HTTP status. The status
	// code is in the message so an upstream algorithm-enum rename (HTTP 400)
	// is visible in logs instead of looking like a generic outage.
	ErrUpstreamStatus = errors.New("listenbrainz unexpected status")
	// ErrUnreachable reports a transport failure, a per-attempt timeout, or a
	// cancelled caller context. It wraps the cause.
	ErrUnreachable = errors.New("listenbrainz unreachable")
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

// similarArtistRaw models only the fields this integration depends on. The
// decoder is deliberately tolerant of extra fields: the live labs payload also
// carries comment/type/gender per entry, and rejecting unknown fields would
// reject every real production response.
type similarArtistRaw struct {
	ArtistMBID    string `json:"artist_mbid"`
	Name          string `json:"name"`
	Score         int    `json:"score"`
	ReferenceMBID string `json:"reference_mbid"`
	// Algorithm is absent from the real payload. When upstream does supply it,
	// it must match the pinned request value — defense in depth, not the
	// primary provenance mechanism.
	Algorithm string `json:"algorithm,omitempty"`
}

// SimilarArtist is one validated entry of a similar-artists response.
type SimilarArtist struct {
	ArtistMBID uuid.UUID
	Name       string
	Score      int
}

// Response is a parsed upstream payload with its retrieval provenance.
// Algorithm is the algorithm pinned on the REQUEST (the payload does not echo
// one per entry); it travels with every response into callers and cache rows
// so a reader can always tell which upstream view produced the candidate set.
type Response struct {
	ArtistMBID  uuid.UUID
	Algorithm   string
	Similar     []SimilarArtist
	RetrievedAt time.Time
}

// SimilarArtists fetches similar artists for one reference artist MBID under
// the pinned algorithm.
//
// It returns a typed error for EVERY failure mode and never returns a nil
// response with a nil error, except for a uuid.Nil input which is a no-op:
//   - ErrRateLimited  — HTTP 429 after every retry was exhausted.
//   - ErrUpstreamStatus — any other non-200 status (the code is in the message).
//   - ErrBadPayload   — body is not a valid array of similar-artist entries,
//     carries an unparseable MBID / negative score, or names an algorithm
//     other than the pinned one.
//   - ErrUnreachable  — transport error, per-attempt timeout, or a cancelled
//     caller context.
//
// Degrading to an empty candidate expansion is ExpansionService.Expand's job.
func (c *Client) SimilarArtists(ctx context.Context, artistMBID uuid.UUID, count int) (*Response, error) {
	if artistMBID == uuid.Nil {
		return nil, nil
	}
	endpoint := c.baseURL + "/similar-artists/json?" + url.Values{
		"algorithm":    []string{PinnedAlgorithm},
		"artist_mbids": []string{artistMBID.String()},
	}.Encode()

	for attempt := 0; ; attempt++ {
		payload, status, err := c.fetch(ctx, endpoint)
		if err == nil {
			return parsePayload(artistMBID, payload)
		}
		if errors.Is(err, ErrUpstreamStatus) {
			if status != http.StatusTooManyRequests {
				return nil, err
			}
			if attempt >= c.maxRetries {
				return nil, fmt.Errorf("%w after %d attempt(s)", ErrRateLimited, attempt+1)
			}
			time.Sleep(c.retryBackoff(attempt))
			continue
		}
		// Transport error, per-attempt timeout, cancelled context, or a body
		// read that failed part-way: no retry can distinguish these cheaply.
		return nil, fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
}

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
		return nil, resp.StatusCode, fmt.Errorf("%w: %d", ErrUpstreamStatus, resp.StatusCode)
	}
	return body, resp.StatusCode, nil
}

// parsePayload validates the upstream document deterministically: it must be a
// JSON array whose entries carry parseable MBIDs and non-negative scores, and
// whose optional per-entry algorithm (absent from the real payload) matches the
// pinned request value. Unknown fields are ignored — the live payload carries
// comment/type/gender that this integration has no use for. Any violation
// rejects the whole payload rather than silently dropping entries.
//
// Response.Algorithm is the pinned REQUEST value, not something echoed by
// upstream: the labs API validates the name against its enum and answers 400
// for an unknown one, so a successful 200 is itself the confirmation that the
// pinned algorithm produced this body.
func parsePayload(reference uuid.UUID, raw []byte) (*Response, error) {
	var entries []similarArtistRaw
	if err := json.Unmarshal(raw, &entries); err != nil {
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
		if e.Score < 0 {
			return nil, fmt.Errorf("%w: bad score %d", ErrBadPayload, e.Score)
		}
		response.Similar = append(response.Similar, SimilarArtist{ArtistMBID: mbid, Name: e.Name, Score: e.Score})
	}
	return response, nil
}
