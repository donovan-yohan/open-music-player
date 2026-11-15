package api

import (
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func (f *weeklyFixture) vote(id, vote string, batch any, name string) map[string]any {
	current := f.ok("GET", "feedback/"+id, nil, "")
	return f.ok("PUT", "feedback/"+id, map[string]any{"vote": vote, "mutationId": uuid.NewString(), "expectedRevision": current["revision"], "profileEpoch": current["profileEpoch"], "batchId": batch}, name)
}
func TestWeeklyReplaceReplayClearCausalNextHTTP(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.permission("externalCatalogQueries", true)
	base := f.ok("GET", "weekly", nil, "causal-neutral")
	if weeklyIDs(base)[0] != weeklyRecordingA {
		t.Fatal("neutral control")
	}
	operation := map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": base["profileEpoch"], "batchId": base["batchId"]}
	ack := f.ok("PUT", "feedback/"+weeklyRecordingB, operation, "causal-up")
	replay := f.ok("PUT", "feedback/"+weeklyRecordingB, operation, "feedback-replayed")
	if replay["replayed"] != true || replay["feedback"].(map[string]any)["revision"] != ack["feedback"].(map[string]any)["revision"] {
		t.Fatal("replay multiplied")
	}
	operation["vote"] = "down"
	if code, _ := f.request("PUT", "feedback/"+weeklyRecordingB, operation, "mutation-conflict"); code != 409 {
		t.Fatal("mutation mismatch accepted")
	}
	f.vote(weeklyRecordingB, "up", base["batchId"], "same-vote")
	prefs := f.ok("GET", "preferences", nil, "preferences-up")
	affinities := prefs["derivedArtistAffinities"].([]any)
	if len(affinities) != 1 || affinities[0].(map[string]any)["affinity"] != float64(1) || affinities[0].(map[string]any)["contributingCount"] != float64(1) {
		t.Fatal("repeated writes multiplied strength")
	}
	current := f.ok("GET", "weekly", nil, "")
	if current["batchId"] != base["batchId"] || strings.Join(weeklyIDs(current), ",") != strings.Join(weeklyIDs(base), ",") {
		t.Fatal("current base reranked")
	}
	f.now = f.now.AddDate(0, 0, 7)
	up := f.ok("GET", "weekly", nil, "causal-next-up")
	if weeklyIDs(up)[0] != weeklyRecordingB {
		t.Fatal("up did not reach next HTTP order")
	}
	f.vote(weeklyRecordingB, "down", up["batchId"], "causal-down")
	downNow := f.ok("GET", "weekly", nil, "causal-current-down")
	if strings.Contains(strings.Join(weeklyIDs(downNow), ","), weeklyRecordingB) || downNow["batchId"] != up["batchId"] {
		t.Fatal("down did not filter original")
	}
	f.now = f.now.AddDate(0, 0, 7)
	down := f.ok("GET", "weekly", nil, "causal-next-down")
	if weeklyIDs(down)[0] != weeklyRecordingA {
		t.Fatal("negative not replacing positive")
	}
	// Null batch permits correction of an existing canonical resource after its
	// original provenance batch expires. This is a real HTTP boundary, not a scorer fake.
	f.vote(weeklyRecordingB, "none", nil, "causal-clear")
	f.restart()
	neutral := f.ok("GET", "feedback/"+weeklyRecordingB, nil, "feedback-tombstone")
	if neutral["vote"] != "none" || neutral["revision"] != float64(4) {
		t.Fatal("neutral revision tombstone lost")
	}
	if code, _ := f.request("PUT", "feedback/"+weeklyRecordingB, map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 2, "profileEpoch": base["profileEpoch"], "batchId": nil}, "feedback-stale-revision"); code != 409 {
		t.Fatal("old write resurrected vote")
	}
	f.now = f.now.AddDate(0, 0, 7)
	clear := f.ok("GET", "weekly", nil, "causal-next-clear")
	if strings.Join(weeklyIDs(clear), ",") != strings.Join(weeklyIDs(base), ",") {
		t.Fatal("clear did not restore neutral order")
	}
	p := f.ok("GET", "preferences", nil, "preferences-clear")
	if len(p["derivedArtistAffinities"].([]any)) != 0 {
		t.Fatal("clear retained old contribution")
	}
}
func TestWeeklyResetEpochReplayAndForeignProvenance(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	base := f.ok("GET", "weekly", nil, "")
	f.vote(weeklyRecordingA, "up", base["batchId"], "")
	before := f.ok("GET", "preferences", nil, "")
	exp := f.ok("GET", "preferences/export", nil, "export")
	if exp["historyIncluded"] != false || exp["truncated"] != false {
		t.Fatal("export scope")
	}
	oldUser := f.user
	f.user = uuid.New()
	f.sql(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'other','x')`, f.user, f.user.String()+"@example.test")
	if code, _ := f.request("GET", "feedback/"+weeklyRecordingA, nil, "foreign-feedback"); code != 404 {
		t.Fatal("foreign read leaked")
	}
	if code, _ := f.request("PUT", "feedback/"+weeklyRecordingA, map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": 0, "batchId": base["batchId"]}, "foreign-provenance"); code != 404 {
		t.Fatal("foreign provenance accepted")
	}
	f.user = oldUser
	reset := map[string]any{"mutationId": uuid.NewString(), "expectedRevision": before["preferenceRevision"], "profileEpoch": before["profileEpoch"], "scope": "discovery_preferences"}
	ack := f.ok("POST", "preferences/reset", reset, "reset-ack")
	r := f.ok("POST", "preferences/reset", reset, "reset-replayed")
	if r["replayed"] != true || r["profileEpoch"] != ack["profileEpoch"] {
		t.Fatal("reset replay")
	}
	f.restart()
	after := f.ok("GET", "preferences", nil, "preferences-reset")
	if after["externalCatalogQueries"] != true || after["learningFromServerHistory"] != false || len(after["recordingFeedback"].([]any)) != 0 || len(after["interestedArtists"].([]any)) != 0 {
		t.Fatal("reset wrong scope")
	}
	if code, _ := f.request("PUT", "feedback/"+weeklyRecordingA, map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": base["profileEpoch"], "batchId": nil}, "feedback-stale-epoch"); code != 409 {
		t.Fatal("old epoch accepted")
	}
	f.artist(weeklyArtistA)
	page := f.ok("GET", "weekly", nil, "weekly-entitlement-after-reset")
	if page["status"] != "unavailable" || f.calls.Load() != 1 {
		t.Fatal("reset minted provider entitlement")
	}
	var count int
	if e := f.database.QueryRow(`SELECT COUNT(*) FROM user_library WHERE user_id=$1`, f.user).Scan(&count); e != nil || count != 2 {
		t.Fatal("reset changed library", count, e)
	}
}
func TestWeeklyStatusesPaginationAndValidation(t *testing.T) {
	f := newWeeklyFixture(t)
	if p := f.ok("GET", "weekly", nil, "weekly-consent-required"); p["status"] != "consent_required" || p["batchId"] != nil {
		t.Fatal(p)
	}
	f.permission("externalCatalogQueries", true)
	if p := f.ok("GET", "weekly", nil, "weekly-needs-preferences"); p["status"] != "needs_preferences" || f.calls.Load() != 0 {
		t.Fatal(p)
	}
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	base := f.ok("GET", "weekly", nil, "")
	f.vote(weeklyRecordingA, "up", base["batchId"], "")
	f.vote(weeklyRecordingB, "down", base["batchId"], "")
	first := f.ok("GET", "preferences?limit=1", nil, "preferences-page1")
	if first["feedbackCursor"] == nil || first["artistCursor"] == nil {
		t.Fatal("missing continuation")
	}
	path := fmt.Sprintf("preferences?limit=1&feedbackCursor=%s&artistCursor=%s&preferenceRevision=%.0f", first["feedbackCursor"], first["artistCursor"], first["preferenceRevision"])
	f.ok("GET", path, nil, "preferences-page2")
	f.vote(weeklyRecordingA, "none", base["batchId"], "")
	if code, _ := f.request("GET", path, nil, "pagination-conflict"); code != 409 {
		t.Fatal("mixed revision pagination")
	}
	for _, path := range []string{"weekly?refresh=true", "preferences?limit=51", "preferences?limit=0", "preferences?artistCursor=garbage&preferenceRevision=6", "feedback/00000000-0000-0000-0000-000000000000"} {
		if code, _ := f.request("GET", path, nil, ""); code != 400 && code != 409 {
			t.Fatal("invalid query accepted", path, code)
		}
	}
	if code, _ := f.request("PUT", "preferences", map[string]any{"resource": "artist", "mutationId": uuid.NewString(), "profileEpoch": 0, "expectedRevision": 0, "artistMbid": uuid.NewString(), "interested": true, "blocked": false}, "artist-evidence-unavailable"); code != 404 {
		t.Fatal("invented artist admitted")
	}
	if code, _ := f.request("PUT", "feedback/"+weeklyRecordingA, map[string]any{"vote": "up"}, "validation-error"); code != 400 {
		t.Fatal("missing authority fields accepted")
	}
	r := httptest.NewRequest("GET", weeklyRoot+"weekly", nil)
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, r)
	if w.Code != 401 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal("auth bypass")
	}
	if dir := osWireDir(); dir != "" {
		saveWire(t, dir, "unauthorized", w.Body.Bytes())
	}
}
func osWireDir() string { return os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR") }
func saveWire(t *testing.T, dir, name string, b []byte) {
	t.Helper()
	if e := os.WriteFile(filepath.Join(dir, name+".json"), b, 0600); e != nil {
		t.Fatal(e)
	}
}
func TestWeeklyPermissionRevocationRetiresInflight(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	f.onProvider = func() { f.onProvider = nil; f.permission("externalCatalogQueries", false) }
	p := f.ok("GET", "weekly", nil, "weekly-stale")
	if p["status"] != "stale" || p["batchId"] != nil {
		t.Fatal("revoked publisher accepted")
	}
	f.permission("externalCatalogQueries", true)
	f.restart()
	p = f.ok("GET", "weekly", nil, "weekly-revoked-entitlement")
	if p["status"] != "unavailable" || f.calls.Load() != 1 {
		t.Fatal("consent transition minted entitlement")
	}
}
func TestWeeklyExpiredLeaseAndBoundaryCooldown(t *testing.T) {
	f := newWeeklyFixture(t)
	f.now = time.Date(2026, 11, 22, 23, 59, 0, 0, time.UTC)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	f.onProvider = func() { f.onProvider = nil; f.now = f.now.Add(16 * time.Second) }
	p := f.ok("GET", "weekly", nil, "weekly-expired-lease")
	if p["status"] != "stale" || p["batchId"] != nil {
		t.Fatal("late publisher accepted")
	}
	f.now = f.now.Add(time.Minute)
	f.restart()
	p = f.ok("GET", "weekly", nil, "weekly-boundary-cooldown")
	if p["status"] != "unavailable" || f.calls.Load() != 1 {
		t.Fatal("week boundary bypassed failed attempt cooldown")
	}
	f.now = f.now.Add(25 * time.Hour)
	p = f.ok("GET", "weekly", nil, "weekly-after-cooldown")
	if p["batchId"] == nil || f.calls.Load() != 2 {
		t.Fatal("new week after cooldown refused")
	}
}
func TestWeeklyProviderFailureNeverWarmSuccess(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	f.ok("GET", "weekly", nil, "")
	f.now = f.now.AddDate(0, 0, 7)
	f.fail = true
	p := f.ok("GET", "weekly", nil, "weekly-unavailable")
	if p["status"] != "unavailable" || p["batchId"] != nil || p["generatedAt"] != nil {
		t.Fatal("failed generation replayed old warm success")
	}
	calls := f.calls.Load()
	f.restart()
	p = f.ok("GET", "weekly", nil, "weekly-failure-retained")
	if p["status"] != "unavailable" || f.calls.Load() != calls {
		t.Fatal("failure refetched after restart")
	}
}
