package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/weekly"
)

func TestWeeklyPreferencesEscapedSummaryByteBudget(t *testing.T) {
	store := &weeklyExportStore{state: weekly.NewState()}
	service, user := weekly.NewService(store, nil), uuid.New()
	metadata := strings.Repeat("<", 2000) // Actual generation metadata bound; JSON escapes each byte sixfold.
	for n := 0; n < 51; n++ {
		title, artist := metadata, metadata
		if n == 50 {
			title, artist = "T", "A"
		}
		weeklyExportVote(t, store, service, user, n, title, artist, "up", true, 1)
		// A real permission transition retires accepted-batch metadata, not feedback.
		if n%10 == 9 || n == 50 {
			permission := "externalCatalogQueries"
			current := store.state.Permissions[permission]
			enabled := !current.Enabled
			if _, err := service.WritePreference(context.Background(), user, weekly.PreferenceWrite{Resource: "permission", MutationID: weeklyExportID(n+60000, 4), Permission: &permission, Enabled: &enabled, ExpectedRevision: current.Revision}, time.Time{}); err != nil {
				t.Fatal(err)
			}
		}
	}
	for n := 0; n < 51; n++ {
		id, interested, blocked := weeklyExportID(n+50000, 2), true, n%2 == 0
		if _, err := service.WritePreference(context.Background(), user, weekly.PreferenceWrite{Resource: "artist", MutationID: weeklyExportID(n+50000, 4), ArtistMbid: &id, Interested: &interested, Blocked: &blocked}, time.Time{}); err != nil {
			t.Fatal(err)
		}
	}
	before, err := json.Marshal(store.state)
	if err != nil {
		t.Fatal(err)
	}
	if len(before) > weekly.MaxResponseBytes || len(store.state.Batches) != 0 {
		t.Fatal("fixture not admitted/retired")
	}
	router, token := weeklyExportRouter(t, store, user)
	read := func(query string) weekly.PreferencesPage {
		t.Helper()
		req := httptest.NewRequest("GET", weeklyRoot+"preferences"+query, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		page, err := service.Preferences(context.Background(), user, weekly.PageQuery{}, time.Time{})
		encoded, _ := json.Marshal(page)
		t.Logf("admittedStateBytes=%d defaultDomainBytes=%d HTTP=%d responseBytes=%d", len(before), len(encoded), w.Code, w.Body.Len())
		if err != nil || w.Code != 200 || w.Body.Len() > weekly.MaxResponseBytes {
			t.Fatalf("reachable Preferences unavailable: status=%d domainBytes=%d err=%v", w.Code, len(encoded), err)
		}
		var out weekly.PreferencesPage
		if err = json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	page := read("")
	if len(page.RecordingFeedback) != 50 || len(page.InterestedArtists) != 50 || len(page.BlockedArtists) != 25 || page.FeedbackCursor == nil || page.ArtistCursor == nil {
		t.Fatal("canonical default page/pagination changed")
	}
	for _, f := range page.RecordingFeedback {
		if !reflect.DeepEqual(f, store.state.Feedback[f.RecordingMbid]) {
			t.Fatal("feedback changed")
		}
	}
	for _, a := range append(append([]weekly.Artist{}, page.InterestedArtists...), page.BlockedArtists...) {
		if a != store.state.Artists[a.ArtistMbid] {
			t.Fatal("choice changed")
		}
	}
	if page.PreferenceRevision != store.state.Revision || page.FilterRevision != store.state.FilterRevision || page.ProfileEpoch != store.state.Epoch {
		t.Fatal("revision changed")
	}
	small, err := service.Preferences(context.Background(), user, weekly.PageQuery{Limit: 1}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if len(small.DerivedArtistAffinities) != 50 {
		t.Fatal("count cap/ordinary summary changed")
	}
	if len(page.DerivedArtistAffinities) >= 50 || len(page.DerivedArtistAffinities) == 0 || !reflect.DeepEqual(page.DerivedArtistAffinities, small.DerivedArtistAffinities[:len(page.DerivedArtistAffinities)]) {
		t.Fatal("not deterministic summary prefix")
	}
	next := page
	next.DerivedArtistAffinities = append(append([]weekly.Affinity{}, page.DerivedArtistAffinities...), small.DerivedArtistAffinities[len(page.DerivedArtistAffinities)])
	raw, _ := json.Marshal(next)
	if len(raw) <= weekly.MaxResponseBytes {
		t.Fatal("summary prefix not maximal")
	}
	continuation := read("?feedbackCursor=" + *page.FeedbackCursor + "&artistCursor=" + *page.ArtistCursor + "&preferenceRevision=" + strconv.FormatInt(page.PreferenceRevision, 10))
	if len(continuation.RecordingFeedback) != 1 || len(continuation.InterestedArtists) != 1 || len(continuation.BlockedArtists) != 1 || continuation.FeedbackCursor != nil || continuation.ArtistCursor != nil {
		t.Fatal("continuation lost canonical resources")
	}
	after, _ := json.Marshal(store.state)
	if !bytes.Equal(before, after) {
		t.Fatal("Preferences mutated state")
	}
}
