package listenbrainz

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

// testClient returns a client pointed at baseURL with test-fast retry knobs.
func testClient(baseURL string) *Client {
	c := NewClientWithBaseURL(baseURL)
	c.maxRetries = 0
	c.retryBackoff = func(int) time.Duration { return time.Millisecond }
	return c
}

// TestClientBadPayloadIsTyped pins that a malformed body surfaces
// ErrBadPayload instead of the old silent (nil, nil) degrade.
func TestClientBadPayloadIsTyped(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"error":"nope"}`))
	}))
	defer server.Close()

	resp, err := testClient(server.URL).SimilarArtists(context.Background(), testSeedMBID)
	if resp != nil {
		t.Fatalf("malformed body returned a response: %+v", resp)
	}
	if !errors.Is(err, ErrBadPayload) {
		t.Fatalf("err = %v, want ErrBadPayload", err)
	}
}

// TestClientUpstreamStatusIsTypedAndCarriesCode pins that non-200/non-429
// statuses (notably the 400 upstream answers for an unknown algorithm name)
// surface with the status code visible.
func TestClientUpstreamStatusIsTypedAndCarriesCode(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusInternalServerError} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(status)
		}))
		resp, err := testClient(server.URL).SimilarArtists(context.Background(), testSeedMBID)
		server.Close()
		if resp != nil {
			t.Fatalf("status %d returned a response: %+v", status, resp)
		}
		if !errors.Is(err, ErrUpstreamStatus) {
			t.Fatalf("status %d: err = %v, want ErrUpstreamStatus", status, err)
		}
		if !strings.Contains(err.Error(), strconv.Itoa(status)) {
			t.Fatalf("status %d not visible in error %q", status, err)
		}
	}
}

// TestClientUnreachableIsTyped pins that a dead endpoint surfaces
// ErrUnreachable wrapping the transport cause.
func TestClientUnreachableIsTyped(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := server.URL
	server.Close() // nothing is listening any more

	resp, err := testClient(url).SimilarArtists(context.Background(), testSeedMBID)
	if resp != nil {
		t.Fatalf("closed server returned a response: %+v", resp)
	}
	if !errors.Is(err, ErrUnreachable) {
		t.Fatalf("err = %v, want ErrUnreachable", err)
	}
}

// TestClientRateLimitExhaustionIsTyped pins ErrRateLimited after retries.
func TestClientRateLimitExhaustionIsTyped(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	client := testClient(server.URL)
	client.maxRetries = 1
	resp, err := client.SimilarArtists(context.Background(), testSeedMBID)
	if resp != nil {
		t.Fatalf("429 exhaustion returned a response: %+v", resp)
	}
	if !errors.Is(err, ErrRateLimited) {
		t.Fatalf("err = %v, want ErrRateLimited", err)
	}
}

// TestClientNilMBIDIsANoOp keeps the one documented (nil, nil) case.
func TestClientNilMBIDIsANoOp(t *testing.T) {
	resp, err := testClient("http://127.0.0.1:1").SimilarArtists(context.Background(), uuid.Nil)
	if resp != nil || err != nil {
		t.Fatalf("nil MBID = %v, %v; want nil, nil", resp, err)
	}
}

// TestClientRequestBudgetBoundsStackedRetries is the finding-3 regression: a
// 5s backoff must not be paid once the whole-call budget is spent. Exactly one
// upstream attempt happens and the call returns well inside a second.
func TestClientRequestBudgetBoundsStackedRetries(t *testing.T) {
	var hits atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	client := NewClientWithBaseURL(server.URL)
	client.maxRetries = 2
	client.retryBackoff = func(int) time.Duration { return 5 * time.Second }
	client.requestBudget = 50 * time.Millisecond

	start := time.Now()
	resp, err := client.SimilarArtists(context.Background(), testSeedMBID)
	elapsed := time.Since(start)

	if resp != nil {
		t.Fatalf("budget exhaustion returned a response: %+v", resp)
	}
	if !errors.Is(err, ErrUnreachable) {
		t.Fatalf("err = %v, want ErrUnreachable on exhausted request budget", err)
	}
	if elapsed >= time.Second {
		t.Fatalf("call took %v, want well under 1s (backoff must be ctx-aware)", elapsed)
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits = %d, want exactly 1", hits.Load())
	}
}

// TestClientCancelledParentContextIsUnreachable pins that a caller cancelling
// mid-backoff gets a typed error rather than a stuck goroutine.
func TestClientCancelledParentContextIsUnreachable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	client := NewClientWithBaseURL(server.URL)
	client.maxRetries = 2
	client.retryBackoff = func(int) time.Duration { return 5 * time.Second }

	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(10*time.Millisecond, cancel)
	defer cancel()

	start := time.Now()
	_, err := client.SimilarArtists(ctx, testSeedMBID)
	if !errors.Is(err, ErrUnreachable) {
		t.Fatalf("err = %v, want ErrUnreachable on cancelled context", err)
	}
	if elapsed := time.Since(start); elapsed >= time.Second {
		t.Fatalf("cancelled call took %v, want well under 1s", elapsed)
	}
}
