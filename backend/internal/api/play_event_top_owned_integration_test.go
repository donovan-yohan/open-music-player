package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

// Exercise the actual handler/store wire, not a handler-side membership filter.
// More than 100 removed tracks outrank all 30 current library tracks.
func TestTopTracksOwnedHTTPAgainstPostgres(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	owner := seedMixUser(t, database, "top-owner@example.test")
	other := seedMixUser(t, database, "top-other@example.test")
	at := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Hour)
	owned := make([]int64, 30)
	for i := 0; i < 150; i++ {
		id := seedMixTrack(t, trackRepo, ctx, fmt.Sprintf("Top %03d", i), 200000)
		member, count := other, 4
		if i >= 120 {
			member, count = owner, 1
			owned[i-120] = id
		}
		if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, member, id); err != nil {
			t.Fatal(err)
		}
		if _, err := database.ExecContext(ctx, `INSERT INTO play_events (user_id, track_id, played_at)
			SELECT $1, $2, $3 FROM generate_series(1, $4::int)`, owner, id, at, count); err != nil {
			t.Fatal(err)
		}
	}
	h := NewPlayEventHandlers(db.NewPlayEventRepository(database), trackRepo)
	read := func(query string) (*httptest.ResponseRecorder, TopTracksResponse, map[string]json.RawMessage) {
		t.Helper()
		rr := httptest.NewRecorder()
		h.TopTracks(rr, withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/top"+query, nil), owner))
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
		}
		var response TopTracksResponse
		var wire map[string]json.RawMessage
		if err := json.Unmarshal(rr.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &wire); err != nil {
			t.Fatal(err)
		}
		return rr, response, wire
	}
	_, response, wire := read("?owned=true&limit=25")
	if len(response.Tracks) != 25 {
		t.Fatalf("owned rows = %d, want 25 behind 120 higher-ranked removed tracks", len(response.Tracks))
	}
	for i, row := range response.Tracks {
		if row.ID != owned[29-i] || !row.InLibrary || row.PlayCount != 1 || !row.LastPlayedAt.Equal(at) {
			t.Fatalf("owned row[%d] = id %d count %d inLibrary %v at %s, want owned id %d count 1 at %s", i, row.ID, row.PlayCount, row.InLibrary, row.LastPlayedAt, owned[29-i], at)
		}
	}
	if string(wire["ownedOnly"]) != "true" || response.Days != 30 || response.Limit != 25 {
		t.Fatalf("owned envelope = %s", wire)
	}
	for _, query := range []string{"?limit=25", "?owned=false&limit=25"} {
		_, legacy, legacyWire := read(query)
		if _, present := legacyWire["ownedOnly"]; present {
			t.Fatalf("legacy response unexpectedly emits ownedOnly for %s", query)
		}
		if len(legacy.Tracks) != 25 || legacy.Tracks[0].InLibrary || legacy.Tracks[0].PlayCount != 4 {
			t.Fatalf("legacy history must preserve removed tracks for %s", query)
		}
	}
}
