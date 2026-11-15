package api

import (
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
)

func TestWeeklyMalformedQueryRefusesInsteadOfDefaulting(t *testing.T) {
	f := newWeeklyFixture(t)
	for _, query := range []string{"feedbackCursor=%ZZ&preferenceRevision=0", "limit=1;feedbackCursor=bad"} {
		request := f.rawRequest("GET", "preferences", nil)
		request.URL.RawQuery = query
		w := httptest.NewRecorder()
		f.router.ServeHTTP(w, request)
		if w.Code != 400 {
			t.Fatalf("malformed cursor query defaulted to a successful initial page: %q %d %s", query, w.Code, w.Body.String())
		}
	}
}

func TestWeeklyUnresolvedHistoryDisclosedWithoutProvider(t *testing.T) {
	f := newWeeklyFixture(t)
	var track int64
	if e := f.database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist) VALUES($1,'Synthetic unidentified history','Unknown') RETURNING id`, uuid.NewString()).Scan(&track); e != nil {
		t.Fatal(e)
	}
	f.sql(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,$3)`, f.user, track, f.now)
	f.permission("learningFromServerHistory", true)
	f.permission("externalCatalogQueries", true)
	p := f.ok("GET", "weekly", nil, "weekly-identity-limited")
	found := false
	for _, v := range p["coverage"].(map[string]any)["reasonCodes"].([]any) {
		if v == "unresolved_history_identity" {
			found = true
		}
	}
	if p["status"] != "needs_preferences" || !found || f.calls.Load() != 0 {
		t.Fatal("unresolved factual history hidden as ordinary empty seeds")
	}
	prefs := f.ok("GET", "preferences", nil, "preferences-identity-limited")
	if prefs["historyCoverage"].(map[string]any)["status"] != "identity_limited" {
		t.Fatal("history coverage invented completeness")
	}
}
