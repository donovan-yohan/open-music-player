package discovery

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/download"
)

func TestURLResolverNormalizesSupportedURLs(t *testing.T) {
	resolver := NewURLResolver(nil)
	cases := []struct {
		name          string
		url           string
		wantProvider  string
		wantSourceID  string
		wantSourceURL string
		wantTitle     string
	}{
		{
			name:          "youtube watch",
			url:           "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantProvider:  "youtube",
			wantSourceID:  "dQw4w9WgXcQ",
			wantSourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantTitle:     "dQw4w9WgXcQ",
		},
		{
			name:          "youtu.be short link is canonicalized",
			url:           "https://youtu.be/dQw4w9WgXcQ",
			wantProvider:  "youtube",
			wantSourceID:  "dQw4w9WgXcQ",
			wantSourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantTitle:     "dQw4w9WgXcQ",
		},
		{
			name:          "youtube music host",
			url:           "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
			wantProvider:  "youtube",
			wantSourceID:  "dQw4w9WgXcQ",
			wantSourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantTitle:     "dQw4w9WgXcQ",
		},
		{
			name:          "soundcloud track slug becomes a readable title",
			url:           "https://soundcloud.com/porter-robinson/live-shelter-version",
			wantProvider:  "soundcloud",
			wantSourceID:  "porter-robinson/live-shelter-version",
			wantSourceURL: "https://soundcloud.com/porter-robinson/live-shelter-version",
			wantTitle:     "live shelter version",
		},
		{
			name:          "soundcloud playlist",
			url:           "https://soundcloud.com/porter-robinson/sets/nurture",
			wantProvider:  "soundcloud",
			wantSourceID:  "porter-robinson/sets/nurture",
			wantSourceURL: "https://soundcloud.com/porter-robinson/sets/nurture",
			wantTitle:     "nurture",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			candidate, err := resolver.Resolve(tc.url)
			if err != nil {
				t.Fatalf("Resolve(%q) returned error: %v", tc.url, err)
			}
			if candidate.Provider != tc.wantProvider {
				t.Fatalf("provider = %q, want %q", candidate.Provider, tc.wantProvider)
			}
			if candidate.SourceID != tc.wantSourceID {
				t.Fatalf("sourceId = %q, want %q", candidate.SourceID, tc.wantSourceID)
			}
			if candidate.SourceURL != tc.wantSourceURL {
				t.Fatalf("sourceUrl = %q, want %q", candidate.SourceURL, tc.wantSourceURL)
			}
			if candidate.Title != tc.wantTitle {
				t.Fatalf("title = %q, want %q", candidate.Title, tc.wantTitle)
			}
			if candidate.CandidateID != tc.wantProvider+":"+tc.wantSourceID {
				t.Fatalf("candidateId = %q, want %q", candidate.CandidateID, tc.wantProvider+":"+tc.wantSourceID)
			}
			if !candidate.Downloadable {
				t.Fatalf("candidate must be downloadable")
			}
			if candidate.Playable {
				t.Fatalf("candidate must not be playable until downloaded")
			}
			if candidate.Metadata["resolvedFrom"] != "direct_url" {
				t.Fatalf("metadata.resolvedFrom = %v, want direct_url", candidate.Metadata["resolvedFrom"])
			}
			if candidate.Metadata["titleResolved"] != false {
				t.Fatalf("metadata.titleResolved = %v, want false", candidate.Metadata["titleResolved"])
			}
			quality, ok := candidate.Metadata[SourceQualityMetadataKey].(SourceQuality)
			if !ok {
				t.Fatalf("metadata.%s missing or wrong type: %#v", SourceQualityMetadataKey, candidate.Metadata[SourceQualityMetadataKey])
			}
			if quality.Classification != SourceQualityDirectURL || quality.Recommendation != SourceQualityReview {
				t.Fatalf("direct URL source quality = %#v, want review direct_url", quality)
			}
			// The candidate must satisfy the same gate POST /api/v1/queue/items
			// applies, so it is queueable without changing queue semantics.
			if candidate.Provider == "" || candidate.SourceURL == "" || candidate.Title == "" {
				t.Fatalf("candidate missing queue-required field: %#v", candidate)
			}
			if err := download.ValidateUserFacingURL(candidate.SourceURL); err != nil {
				t.Fatalf("resolved sourceUrl %q is not queueable: %v", candidate.SourceURL, err)
			}
		})
	}
}

func TestURLResolverRejectsBadURLsWithTypedErrors(t *testing.T) {
	resolver := NewURLResolver(nil)
	cases := []struct {
		name     string
		url      string
		wantCode string
	}{
		{name: "blank", url: "   ", wantCode: ErrResolveURLRequired},
		{name: "missing scheme", url: "youtube.com/watch?v=dQw4w9WgXcQ", wantCode: ErrResolveInvalidURL},
		{name: "non-http scheme", url: "ftp://example.com/song", wantCode: ErrResolveInvalidURL},
		{name: "file scheme", url: "file:///etc/passwd", wantCode: ErrResolveInvalidURL},
		{name: "protocol relative", url: "//soundcloud.com/artist/track", wantCode: ErrResolveInvalidURL},
		{name: "relative", url: "/watch?v=dQw4w9WgXcQ", wantCode: ErrResolveInvalidURL},
		{name: "unsupported host", url: "https://example.com/song", wantCode: ErrResolveUnsupportedURL},
		{name: "youtube without video id", url: "https://www.youtube.com/feed/subscriptions", wantCode: ErrResolveUnsupportedURL},
		{name: "soundcloud reserved page", url: "https://soundcloud.com/discover", wantCode: ErrResolveUnsupportedURL},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			candidate, err := resolver.Resolve(tc.url)
			if err == nil {
				t.Fatalf("Resolve(%q) succeeded, want error", tc.url)
			}
			// A rejected URL must never yield an enqueueable candidate.
			if candidate.Provider != "" || candidate.SourceURL != "" || candidate.Downloadable {
				t.Fatalf("Resolve(%q) returned an enqueueable candidate on failure: %#v", tc.url, candidate)
			}
			var resolveErr *ResolveError
			if !errors.As(err, &resolveErr) {
				t.Fatalf("error %v is not a *ResolveError", err)
			}
			if resolveErr.Code != tc.wantCode {
				t.Fatalf("error code = %q, want %q", resolveErr.Code, tc.wantCode)
			}
		})
	}
}

func TestZeroValueURLResolverFallsBackToDefaultRegistry(t *testing.T) {
	// A var-declared resolver has a nil registry; Resolve must not panic and must
	// behave like a default resolver.
	var resolver URLResolver

	candidate, err := resolver.Resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
	if err != nil {
		t.Fatalf("zero-value Resolve returned error: %v", err)
	}
	if candidate.Provider != "youtube" || candidate.SourceID != "dQw4w9WgXcQ" {
		t.Fatalf("unexpected candidate from zero-value resolver: %#v", candidate)
	}

	if _, err := resolver.Resolve("https://example.com/not-supported"); err == nil {
		t.Fatalf("zero-value Resolve accepted an unsupported URL")
	}
}

func TestResolveURLHandlerRejectsOversizedBody(t *testing.T) {
	handlers := NewHandlers(NewService(ServiceConfig{}))
	// Build a body comfortably larger than the cap.
	body := `{"url":"https://www.youtube.com/watch?v=` + strings.Repeat("a", resolveURLMaxRequestBodyBytes+1) + `"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/resolve-url", strings.NewReader(body))

	handlers.ResolveURL(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 for oversized body; body=%s", rec.Code, rec.Body.String())
	}
	var payload struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if payload.Code != "INVALID_REQUEST" {
		t.Fatalf("error code = %q, want INVALID_REQUEST", payload.Code)
	}
}

func TestResolveURLHandlerReturnsQueueableCandidate(t *testing.T) {
	handlers := NewHandlers(NewService(ServiceConfig{}))
	body := `{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}`
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/resolve-url", strings.NewReader(body))

	handlers.ResolveURL(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var resp ResolveURLResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Candidate.Provider != "youtube" || resp.Candidate.SourceID != "dQw4w9WgXcQ" {
		t.Fatalf("unexpected candidate: %#v", resp.Candidate)
	}
	if !resp.Candidate.Downloadable || resp.Candidate.Playable {
		t.Fatalf("candidate must be downloadable and not playable: %#v", resp.Candidate)
	}
	// The resolver response is a candidate only: no queue item, job, or download
	// is created. Asserting the response carries no job/queue fields guards the
	// "no autonomous download / no queue mutation" boundary at the HTTP layer.
	raw := rec.Body.String()
	for _, forbidden := range []string{"queueItemId", "downloadJobId", "\"job\"", "\"queue\""} {
		if strings.Contains(raw, forbidden) {
			t.Fatalf("resolve response unexpectedly contains %q: %s", forbidden, raw)
		}
	}
}

func TestResolveURLHandlerErrorStatuses(t *testing.T) {
	handlers := NewHandlers(NewService(ServiceConfig{}))
	cases := []struct {
		name       string
		body       string
		wantStatus int
		wantCode   string
	}{
		{name: "missing url", body: `{}`, wantStatus: http.StatusBadRequest, wantCode: ErrResolveURLRequired},
		{name: "invalid json", body: `{`, wantStatus: http.StatusBadRequest, wantCode: "INVALID_REQUEST"},
		{name: "unsupported host", body: `{"url":"https://example.com/x"}`, wantStatus: http.StatusUnprocessableEntity, wantCode: ErrResolveUnsupportedURL},
		{name: "non-http scheme", body: `{"url":"ftp://example.com/x"}`, wantStatus: http.StatusUnprocessableEntity, wantCode: ErrResolveInvalidURL},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/resolve-url", bytes.NewBufferString(tc.body))
			handlers.ResolveURL(rec, req)

			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rec.Code, tc.wantStatus, rec.Body.String())
			}
			var payload struct {
				Code string `json:"code"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
				t.Fatalf("decode error body: %v", err)
			}
			if payload.Code != tc.wantCode {
				t.Fatalf("error code = %q, want %q", payload.Code, tc.wantCode)
			}
		})
	}
}

// TestResolverFailureIsolatedFromSearch proves a resolver rejection on a shared
// Handlers instance does not affect a subsequent discovery search: the two run
// through entirely separate code paths.
func TestResolverFailureIsolatedFromSearch(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{{CandidateID: "youtube:1", Provider: "youtube", SourceURL: "https://example.invalid/1", Title: "one", Downloadable: true}}},
		},
		DefaultProviders: []string{"youtube"},
	})
	handlers := NewHandlers(svc)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/resolve-url", strings.NewReader(`{"url":"https://example.com/not-supported"}`))
	handlers.ResolveURL(rec, req)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("resolve status = %d, want 422", rec.Code)
	}

	resp := svc.Search(context.Background(), "one", nil, 10)
	if len(resp.Results) != 1 {
		t.Fatalf("search after resolver failure returned %d results, want 1", len(resp.Results))
	}
}
