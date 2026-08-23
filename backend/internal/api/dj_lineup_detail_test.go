package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

func TestDJLineupOnRepeatDetailSumsRecentPlays(t *testing.T) {
	tracks := []db.DJLineupTrack{
		{ID: 1, Energy: 0.5, RecentPlayCount: 12},
		{ID: 2, Energy: 0.6, RecentPlayCount: 8},
	}
	response := requestDJLineupDetail(t, tracks, "on-repeat")
	if got, want := response.Blocks[0].Detail, "20 plays in the last 90 days"; got != want {
		t.Fatalf("on-repeat detail = %q, want %q", got, want)
	}
}

func TestDJLineupOnRepeatDetailCapsAt999(t *testing.T) {
	tracks := []db.DJLineupTrack{
		{ID: 1, Energy: 0.5, RecentPlayCount: 600},
		{ID: 2, Energy: 0.6, RecentPlayCount: 500},
	}
	response := requestDJLineupDetail(t, tracks, "on-repeat")
	if got := response.Blocks[0].Detail; got != "999+ plays in the last 90 days" {
		t.Fatalf("on-repeat detail = %q, want capped 999+", got)
	}
}

func TestDJLineupFlashbackDetailUsesLatestPriorPlay(t *testing.T) {
	tracks := []db.DJLineupTrack{
		{
			ID:                   1,
			Energy:               0.5,
			HistoricalPlayCount:  3,
			MidWindowPlayCount:   2,
			LastHistoricalPlayed: time.Date(2026, time.March, 14, 12, 0, 0, 0, time.UTC),
		},
		{
			ID:                   2,
			Energy:               0.4,
			HistoricalPlayCount:  1,
			MidWindowPlayCount:   4,
			LastHistoricalPlayed: time.Date(2025, time.November, 2, 8, 0, 0, 0, time.UTC),
		},
	}
	response := requestDJLineupDetail(t, tracks, "flashback")
	if got, want := response.Blocks[0].Detail, "Last played March 2026"; got != want {
		t.Fatalf("flashback detail = %q, want %q", got, want)
	}
}

func TestDJLineupFreshFindsDetailCountsUnplayed(t *testing.T) {
	tracks := []db.DJLineupTrack{
		{ID: 1, Energy: 0.5},
		{ID: 2, Energy: 0.7},
		{ID: 3, Energy: 0.9, TotalPlayCount: 4}, // played: excluded from fresh-finds
	}
	response := requestDJLineupDetail(t, tracks, "fresh-finds")
	if got, want := response.Blocks[0].Detail, "2 unplayed tracks waiting"; got != want {
		t.Fatalf("fresh-finds detail = %q, want %q", got, want)
	}
}

func TestDJLineupDetailsOmittedWhenDataAbsent(t *testing.T) {
	// No plays at all: on-repeat has no candidates (no block), flashback has no
	// prior timestamps, fresh-finds counts zero-play tracks that do exist here.
	unplayed := []db.DJLineupTrack{{ID: 1, Title: "Fresh", Energy: 0.5}}
	freshResponse := requestDJLineupDetail(t, unplayed, "fresh-finds")
	if got := freshResponse.Blocks[0].Detail; got != "1 unplayed tracks waiting" {
		t.Fatalf("fresh-finds detail = %q", got)
	}

	// Empty library: every block either disappears or omits detail entirely.
	response := requestDJLineupDetail(t, nil, "")
	for _, block := range response.Blocks {
		if block.Detail != "" {
			t.Fatalf("block %q detail = %q with empty library, want omitted", block.ID, block.Detail)
		}
	}

	// Flashback candidates without any pre-recent play timestamp omit detail.
	flashbackNoTimestamps := []db.DJLineupTrack{
		{ID: 2, Energy: 0.5, HistoricalPlayCount: 1, MidWindowPlayCount: 1},
	}
	flashbackResponse := requestDJLineupDetail(t, flashbackNoTimestamps, "flashback")
	if len(flashbackResponse.Blocks) != 1 || flashbackResponse.Blocks[0].Detail != "" {
		t.Fatalf("flashback detail = %#v, want one block with omitted detail", flashbackResponse.Blocks)
	}

	// On-repeat candidates always carry a recent play count, so an empty sum is
	// unreachable there; verify via raw computation instead.
	if got := djLineupOnRepeatDetail(nil); got != "" {
		t.Fatalf("on-repeat detail without data = %q, want empty", got)
	}
	if got := djLineupFlashbackDetail(nil); got != "" {
		t.Fatalf("flashback detail without data = %q, want empty", got)
	}
	if got := djLineupFreshFindsDetail(nil); got != "" {
		t.Fatalf("fresh-finds detail without candidates = %q, want empty", got)
	}
}

// requestDJLineupDetail fetches a single-block lineup and asserts the block is
// present before returning the parsed response.
func requestDJLineupDetail(t *testing.T, tracks []db.DJLineupTrack, block string) DJLineupResponse {
	t.Helper()
	handler := NewDJLineupHandlers(&fakeDJLineupStore{tracks: tracks})
	rawURL := "/api/v1/dj/lineup?perBlock=10"
	if block != "" {
		rawURL += "&block=" + block
	}
	req := httptest.NewRequest(http.MethodGet, rawURL, nil)
	rec := httptest.NewRecorder()
	handler.GetLineup(rec, withUser(req, uuid.New()))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET lineup status = %d (body=%s)", rec.Code, rec.Body.String())
	}
	var response DJLineupResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if block != "" && len(response.Blocks) != 1 {
		t.Fatalf("blocks = %d for block=%s, want 1 (body=%s)", len(response.Blocks), block, rec.Body.String())
	}
	return response
}

func TestDJPinRoutesEndToEnd(t *testing.T) {
	store := newFakeDJPinStore()
	lineupStore := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "Peak", Energy: 0.8, GenreHints: []string{"Techno"}, RecentPlayCount: 4},
		{ID: 2, Title: "Calm", Energy: 0.3, GenreHints: []string{"Ambient"}, RecentPlayCount: 2},
	}}
	secret := "dj-pin-route-test-secret"
	userID := uuid.New()
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:     auth.NewHandlers(nil),
		AuthService:      auth.NewService(nil, nil, secret),
		DJLineupHandlers: NewDJLineupHandlersWithPinStore(lineupStore, store),
		DJPinHandlers:    NewDJPinHandlers(store, lineupStore),
	})
	server := httptest.NewServer(router)
	defer server.Close()

	client := server.Client()
	authed := func(method, path, body string) *http.Request {
		var reader *strings.Reader
		if body == "" {
			reader = strings.NewReader("")
		} else {
			reader = strings.NewReader(body)
		}
		req, err := http.NewRequestWithContext(t.Context(), method, server.URL+path, reader)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer "+signedDJLineupToken(t, secret, userID))
		return req
	}

	// GET before any pin: 404 NOT_FOUND envelope.
	res, err := client.Do(authed(http.MethodGet, "/api/v1/dj/pin", ""))
	if err != nil {
		t.Fatalf("GET pin: %v", err)
	}
	body := readAllBody(t, res)
	if res.StatusCode != http.StatusNotFound || !strings.Contains(body, "NOT_FOUND") {
		t.Fatalf("initial GET pin = %d %s, want 404 NOT_FOUND", res.StatusCode, body)
	}

	// POST pins the current vibe of on-repeat.
	res, err = client.Do(authed(http.MethodPost, "/api/v1/dj/pin", `{"blockId":"on-repeat"}`))
	if err != nil {
		t.Fatalf("POST pin: %v", err)
	}
	body = readAllBody(t, res)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("POST pin = %d %s, want 200", res.StatusCode, body)
	}
	var created DJPinResponse
	if err := json.Unmarshal([]byte(body), &created); err != nil {
		t.Fatalf("decode create: %v", err)
	}
	if created.BlockID != "on-repeat" {
		t.Fatalf("created pin block = %q, want on-repeat", created.BlockID)
	}

	// Invalid block IDs are rejected with INVALID_REQUEST.
	res, err = client.Do(authed(http.MethodPost, "/api/v1/dj/pin", `{"blockId":"bangers"}`))
	if err != nil {
		t.Fatalf("POST invalid pin: %v", err)
	}
	body = readAllBody(t, res)
	if res.StatusCode != http.StatusBadRequest || !strings.Contains(body, "INVALID_REQUEST") {
		t.Fatalf("POST invalid pin = %d %s, want 400 INVALID_REQUEST", res.StatusCode, body)
	}

	// GET returns the stored pin...
	res, err = client.Do(authed(http.MethodGet, "/api/v1/dj/pin", ""))
	if err != nil {
		t.Fatalf("GET pin: %v", err)
	}
	body = readAllBody(t, res)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET pin = %d %s, want 200", res.StatusCode, body)
	}

	// ...and lineup responses now carry the pinned marker plus filtered tracks.
	res, err = client.Do(authed(http.MethodGet, "/api/v1/dj/lineup?perBlock=10", ""))
	if err != nil {
		t.Fatalf("GET lineup: %v", err)
	}
	var lineup DJLineupResponse
	if err := json.NewDecoder(res.Body).Decode(&lineup); err != nil {
		t.Fatalf("decode lineup: %v", err)
	}
	res.Body.Close()
	if lineup.Pinned == nil || lineup.Pinned.BlockID != "on-repeat" {
		t.Fatalf("lineup pinned marker = %+v, want on-repeat", lineup.Pinned)
	}
	for _, block := range lineup.Blocks {
		for _, track := range block.Tracks {
			if track.ID == 2 { // energy 0.3 outside the pinned envelope
				t.Fatalf("track 2 leaked through pinned filter: %+v", lineup)
			}
		}
	}

	// DELETE clears the pin and subsequent GETs 404 again.
	res, err = client.Do(authed(http.MethodDelete, "/api/v1/dj/pin", ""))
	if err != nil {
		t.Fatalf("DELETE pin: %v", err)
	}
	readAllBody(t, res)
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE pin = %d, want 204", res.StatusCode)
	}
	res, err = client.Do(authed(http.MethodGet, "/api/v1/dj/pin", ""))
	if err != nil {
		t.Fatalf("GET pin after delete: %v", err)
	}
	readAllBody(t, res)
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("GET pin after delete = %d, want 404", res.StatusCode)
	}
}

func readAllBody(t *testing.T, res *http.Response) string {
	t.Helper()
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(raw)
}
