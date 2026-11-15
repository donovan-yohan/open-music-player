package api

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestWeeklyPendingConcurrentFirstReadAndNoRefill(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.permission("externalCatalogQueries", true)
	f.onProvider = func() {
		f.onProvider = nil
		p := f.ok("GET", "weekly", nil, "weekly-pending")
		if p["status"] != "pending" || p["batchId"] != nil || f.calls.Load() != 1 {
			t.Fatal("concurrent read admitted a second provider attempt")
		}
	}
	p := f.ok("GET", "weekly", nil, "")
	batch := p["batchId"]
	f.vote(weeklyRecordingA, "down", batch, "")
	filtered := f.ok("GET", "weekly", nil, "weekly-filtered")
	ids := weeklyIDs(filtered)
	if len(ids) != 2 || ids[0] != weeklyRecordingB || ids[1] != weeklyRecordingA2 || f.calls.Load() != 1 {
		t.Fatal("hard filter reranked/refilled", ids)
	}
	f.vote(weeklyRecordingA, "none", batch, "")
	restored := f.ok("GET", "weekly", nil, "weekly-restored")
	if strings.Join(weeklyIDs(restored), ",") != strings.Join(weeklyIDs(p), ",") || restored["batchId"] != batch {
		t.Fatal("clear did not restore original positions")
	}
}
func TestWeeklyLiveOwnedRecentBlockAndForeignOwnership(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.permission("externalCatalogQueries", true)
	base := f.ok("GET", "weekly", nil, "")
	foreign := uuid.New()
	f.sql(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'synthetic foreign','x')`, foreign, foreign.String()+"@example.test")
	var track int64
	if e := f.database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_recording_id) VALUES($1,'Synthetic alternate edition','Artist A',$2) RETURNING id`, uuid.NewString(), weeklyRecordingA).Scan(&track); e != nil {
		t.Fatal(e)
	}
	f.sql(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, foreign, track)
	if p := f.ok("GET", "weekly", nil, ""); len(weeklyIDs(p)) != 3 {
		t.Fatal("foreign ownership excluded current account")
	}
	f.sql(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, f.user, track)
	p := f.ok("GET", "weekly", nil, "weekly-owned-filtered")
	if len(weeklyIDs(p)) != 2 || weeklyIDs(p)[0] != weeklyRecordingB {
		t.Fatal("unverified alternate edition not excluded")
	}
	f.sql(`DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, f.user, track)
	f.sql(`INSERT INTO play_events(user_id,track_id,played_at,skipped) VALUES($1,$2,$3,false)`, f.user, track, f.now.Add(-time.Hour))
	p = f.ok("GET", "weekly", nil, "weekly-recent-filtered")
	if len(weeklyIDs(p)) != 2 {
		t.Fatal("recent factual recording ignored")
	}
	f.sql(`DELETE FROM play_events WHERE user_id=$1`, f.user)
	prefs := f.ok("GET", "preferences", nil, "")
	f.ok("PUT", "preferences", map[string]any{"resource": "artist", "artistMbid": weeklyArtistA, "interested": true, "blocked": true, "expectedRevision": 1, "profileEpoch": prefs["profileEpoch"], "mutationId": uuid.NewString()}, "artist-block")
	p = f.ok("GET", "weekly", nil, "weekly-block-filtered")
	if len(weeklyIDs(p)) != 1 || weeklyIDs(p)[0] != weeklyRecordingB || p["batchId"] != base["batchId"] {
		t.Fatal("artist block did not remove all original rows")
	}
	f.ok("PUT", "preferences", map[string]any{"resource": "artist", "artistMbid": weeklyArtistA, "interested": true, "blocked": false, "expectedRevision": 2, "profileEpoch": prefs["profileEpoch"], "mutationId": uuid.NewString()}, "artist-unblock")
	p = f.ok("GET", "weekly", nil, "")
	if len(weeklyIDs(p)) != 3 || f.calls.Load() != 1 {
		t.Fatal("unblock did not restore exact original base")
	}
}
func TestWeeklyTruthfulEmptyPartialAndProviderBudgets(t *testing.T) {
	for _, scenario := range []string{"empty", "partial", "oversize", "malformed"} {
		t.Run(scenario, func(t *testing.T) {
			f := newWeeklyFixture(t)
			f.artist(weeklyArtistA)
			f.permission("externalCatalogQueries", true)
			switch scenario {
			case "empty":
				f.body = `{"count":0,"recordings":[]}`
			case "partial":
				f.sql(`INSERT INTO tracks(identity_hash,title) VALUES($1,'Synthetic unresolved owned')`, uuid.NewString())
				f.sql(`INSERT INTO user_library(user_id,track_id) SELECT $1,id FROM tracks WHERE title='Synthetic unresolved owned'`, f.user)
			case "oversize":
				f.body = `{"padding":"` + strings.Repeat("x", 1048576) + `","count":0,"recordings":[]}`
			case "malformed":
				f.body = `{`
			}
			p := f.ok("GET", "weekly", nil, "weekly-"+scenario)
			want := scenario
			if scenario == "oversize" || scenario == "malformed" {
				want = "unavailable"
			}
			if p["status"] != want {
				t.Fatal("status", p["status"], "want", want)
			}
			if f.calls.Load() > 2 {
				t.Fatal("unbounded retry")
			}
			if p["coverage"].(map[string]any)["providerRequests"].(float64) != float64(f.calls.Load()) {
				t.Fatal("real request budget counter wrong")
			}
		})
	}
}
func TestWeeklyHistoryPermissionTimeSplitAndNoFutureLeak(t *testing.T) {
	f := newWeeklyFixture(t)
	f.permission("externalCatalogQueries", true)
	var seedA, seedB int64
	if e := f.database.QueryRow(`SELECT t.id FROM tracks t JOIN user_library ul ON ul.track_id=t.id WHERE ul.user_id=$1 AND mb_artist_id=$2`, f.user, weeklyArtistA).Scan(&seedA); e != nil {
		t.Fatal(e)
	}
	if e := f.database.QueryRow(`SELECT t.id FROM tracks t JOIN user_library ul ON ul.track_id=t.id WHERE ul.user_id=$1 AND mb_artist_id=$2`, f.user, weeklyArtistB).Scan(&seedB); e != nil {
		t.Fatal(e)
	}
	f.sql(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,$3),($1,$4,$5)`, f.user, seedA, f.now.AddDate(0, 0, -45), seedB, f.now.Add(time.Hour))
	p := f.ok("GET", "weekly", nil, "")
	if p["status"] != "needs_preferences" || f.calls.Load() != 0 {
		t.Fatal("history used without permission")
	}
	f.permission("learningFromServerHistory", true)
	p = f.ok("GET", "weekly", nil, "weekly-history")
	if weeklyIDs(p)[0] != weeklyRecordingA {
		t.Fatal("future event leaked into rank")
	}
	coverage := f.ok("GET", "preferences", nil, "preferences-history")["historyCoverage"].(map[string]any)
	if coverage["longArtists"] != float64(1) || coverage["shortArtists"] != float64(0) {
		t.Fatal("short/long/future projections mixed", coverage)
	}
	f.permission("learningFromServerHistory", false)
	p = f.ok("GET", "weekly", nil, "")
	if p["batchId"] != nil || f.calls.Load() != 1 {
		t.Fatal("history revocation retained output or minted provider quota")
	}
}
func TestWeeklyPaginationFeedbackAndArtistRevisionIndependence(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.permission("externalCatalogQueries", true)
	p := f.ok("GET", "weekly", nil, "")
	// Each new resource still expects zero despite unrelated global revisions.
	f.vote(weeklyRecordingA, "up", p["batchId"], "")
	f.vote(weeklyRecordingB, "up", p["batchId"], "")
	first := f.ok("GET", "preferences?limit=1", nil, "")
	path := fmt.Sprintf("preferences?limit=1&feedbackCursor=%s&preferenceRevision=%.0f", first["feedbackCursor"], first["preferenceRevision"])
	second := f.ok("GET", path, nil, "")
	if len(second["recordingFeedback"].([]any)) != 1 || second["feedbackCursor"] != nil {
		t.Fatal("feedback continuation incorrect")
	}
}
