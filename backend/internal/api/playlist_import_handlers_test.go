package api

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

func playlistImportRequest(body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/playlist-imports", strings.NewReader(body))
	return req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111"),
	}))
}

// TestCreateImportLogsUnknownFields is why this handler was folded into the
// shared decoder. It already accepted unknown keys, but silently: a client typo
// here did nothing at all and left no trace. Acceptance is unchanged; the trace
// is the new part.
//
// A nil service is enough because StartImport validates the URL before it
// touches any of its own state, so the request fails after decoding.
func TestCreateImportLogsUnknownFields(t *testing.T) {
	handlers := NewPlaylistImportHandlers(nil)

	var logged bytes.Buffer
	previousWriter, previousFlags := log.Writer(), log.Flags()
	log.SetOutput(&logged)
	log.SetFlags(0)
	rec := httptest.NewRecorder()
	handlers.CreateImport(rec, playlistImportRequest(`{"url":"not-a-playlist-url","playlistID":1,"maxTracks":5}`))
	log.SetOutput(previousWriter)
	log.SetFlags(previousFlags)

	want := "Warning: ignoring unknown JSON fields in request body for /api/v1/playlist-imports: maxTracks\n"
	if logged.String() != want {
		t.Fatalf("log = %q, want %q", logged.String(), want)
	}
}

// TestCreateImportRejectsUnparseableBodies covers the guard this handler gained
// when it moved onto the shared decoder: it used to read the first JSON value
// and ignore whatever followed, which is now a 400 like everywhere else.
// A source-resolution failure must be retryable. Before this, a provider
// failure surfaced as a generic INTERNAL_ERROR/500 even though nothing local
// was created and the same request could simply be retried.
func TestCreateImportReportsSourceResolutionFailureAsRetryable(t *testing.T) {
	tests := []struct {
		name     string
		err      error
		wantCode string
	}{
		{name: "provider resolve failure", err: fmt.Errorf("%w: resolve playlist source: %w", playlistimport.ErrSourceResolution, errors.New("boom")), wantCode: "SOURCE_RESOLUTION_FAILED"},
		{name: "incomplete snapshot", err: fmt.Errorf("%w: validate playlist source snapshot: %w", playlistimport.ErrSourceResolution, errors.New("incomplete")), wantCode: "SOURCE_RESOLUTION_FAILED"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			handlePlaylistImportError(rec, tt.err)

			if rec.Code != http.StatusBadGateway {
				t.Fatalf("status = %d, want %d; body = %s", rec.Code, http.StatusBadGateway, rec.Body.String())
			}
			if got := decodePlaylistError(t, rec).Code; got != tt.wantCode {
				t.Fatalf("error code = %q, want %q", got, tt.wantCode)
			}
			if !strings.Contains(rec.Body.String(), "retry") {
				t.Fatalf("body = %s, want an actionable retry message", rec.Body.String())
			}
		})
	}
}

// The limit contract must survive the reordering: an oversized playlist is a
// request-level rejection, not a source-resolution failure.
func TestCreateImportKeepsLimitExceededAsRequestRejection(t *testing.T) {
	rec := httptest.NewRecorder()
	handlePlaylistImportError(rec, fmt.Errorf("wrapped: %w", playlistimport.ErrLimitExceeded))

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusRequestEntityTooLarge)
	}
	if got := decodePlaylistError(t, rec).Code; got != "PLAYLIST_TOO_LARGE" {
		t.Fatalf("error code = %q, want PLAYLIST_TOO_LARGE", got)
	}
}

func TestCreateImportRejectsUnparseableBodies(t *testing.T) {
	for name, body := range map[string]string{
		"malformed json":       `{"url":`,
		"multiple json values": `{"url":"https://example.test/list"} {}`,
		"wrong type":           `{"url":7}`,
	} {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			NewPlaylistImportHandlers(nil).CreateImport(rec, playlistImportRequest(body))
			if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "INVALID_REQUEST") {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}
