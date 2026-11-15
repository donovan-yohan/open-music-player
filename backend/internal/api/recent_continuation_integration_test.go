package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestRecentContinuationRealRepositoryHTTP(t *testing.T) {
	database := newMetadataOverrideAPIDB(t)
	user := seedMetadataOverrideUser(t, database, "recent-http@example.test")
	for i := 1; i <= 23; i++ {
		id := seedMetadataOverrideTrack(t, database, fmt.Sprintf("%064d", i), "Same title", "Artist", "Album")
		if _, err := database.Exec(`INSERT INTO play_events(user_id,track_id,played_at) VALUES ($1,$2,TIMESTAMPTZ '2026-10-01'+$2::bigint*INTERVAL '1 minute')`, user, id); err != nil {
			t.Fatal(err)
		}
		if i%2 == 0 {
			addToMetadataOverrideLibrary(t, database, user, id)
		}
	}
	repo := db.NewPlayEventRepository(database)
	h := NewPlayEventHandlersWithMetadataOverrides(repo, db.NewTrackRepository(database), db.NewTrackMetadataOverrideRepository(database))
	request := func(query string) (int, RecentlyPlayedResponse) {
		t.Helper()
		rr := httptest.NewRecorder()
		h.RecentlyPlayed(rr, withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?continuation=true&limit=20&"+query, nil), user))
		var body RecentlyPlayedResponse
		if rr.Code == 200 {
			if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
		}
		return rr.Code, body
	}
	status, first := request("offset=0")
	if status != 200 || len(first.Tracks) != 20 || first.Revision == "" || first.HasMore == nil || !*first.HasMore {
		t.Fatalf("first status=%d body=%+v", status, first)
	}
	status, last := request("offset=20&revision=" + first.Revision)
	if status != 200 || len(last.Tracks) != 3 || last.HasMore == nil || *last.HasMore || last.Revision != first.Revision {
		t.Fatalf("last status=%d body=%+v", status, last)
	}
	for i, row := range append(first.Tracks, last.Tracks...) {
		want := int64(23 - i)
		if row.ID != want || row.InLibrary != (want%2 == 0) {
			t.Fatalf("row=%+v want ID=%d membership=%t", row, want, want%2 == 0)
		}
	}
	if _, err := database.Exec(`INSERT INTO play_events(user_id,track_id,played_at) VALUES ($1,1,TIMESTAMPTZ '2026-10-02')`, user); err != nil {
		t.Fatal(err)
	}
	status, _ = request("offset=20&revision=" + first.Revision)
	if status != 409 {
		t.Fatalf("mutation status=%d", status)
	}
	status, fresh := request("offset=0")
	if status != 200 || fresh.Tracks[0].ID != 1 || fresh.Revision == first.Revision {
		t.Fatalf("fresh status=%d", status)
	}
}
