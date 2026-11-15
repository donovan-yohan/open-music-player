package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

func (f *weeklyFixture) rawRequest(method, path string, body any) *http.Request {
	b, _ := json.Marshal(body)
	r := httptest.NewRequest(method, weeklyRoot+path, bytes.NewReader(b))
	token, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, authWeeklyClaims(f.user)).SignedString([]byte("synthetic-weekly-secret"))
	r.Header.Set("Authorization", "Bearer "+token)
	return r
}

// Keep the actual normal auth claims type, rather than bypassing middleware.
func authWeeklyClaims(id uuid.UUID) jwt.MapClaims {
	return jwt.MapClaims{"user_id": id.String(), "exp": time.Now().Add(time.Minute).Unix()}
}

type weeklyLostResponse struct {
	header http.Header
	status int
}

func (w *weeklyLostResponse) Header() http.Header         { return w.header }
func (w *weeklyLostResponse) WriteHeader(status int)      { w.status = status }
func (w *weeklyLostResponse) Write(p []byte) (int, error) { return 0, io.ErrClosedPipe }
func TestWeeklyLostResponseReadbackExactReplay(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	page := f.ok("GET", "weekly", nil, "")
	operation := map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": page["profileEpoch"], "batchId": page["batchId"]}
	lost := &weeklyLostResponse{header: make(http.Header)}
	f.router.ServeHTTP(lost, f.rawRequest("PUT", "feedback/"+weeklyRecordingA, operation))
	if lost.status != 200 {
		t.Fatal("write did not commit before response loss", lost.status)
	}
	read := f.ok("GET", "feedback/"+weeklyRecordingA, nil, "response-loss-readback")
	if read["vote"] != "up" || read["lastMutationId"] != operation["mutationId"] || read["revision"] != float64(1) {
		t.Fatal("unknown write readback")
	}
	replay := f.ok("PUT", "feedback/"+weeklyRecordingA, operation, "response-loss-replay")
	if replay["replayed"] != true || replay["feedback"].(map[string]any)["revision"] != float64(1) {
		t.Fatal("response-loss retry multiplied signal")
	}
}
func TestWeeklyConcurrentClaimAndResourceCAS(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan *httptest.ResponseRecorder, 1)
	f.onProvider = func() {
		close(entered)
		select {
		case <-release:
		case <-time.After(10 * time.Second):
			t.Error("fixture provider release deadline")
		}
	}
	go func() {
		w := httptest.NewRecorder()
		f.router.ServeHTTP(w, f.rawRequest("GET", "weekly", nil))
		done <- w
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("provider admission not reached")
	}
	pending := f.ok("GET", "weekly", nil, "weekly-concurrent-pending")
	if pending["status"] != "pending" || f.calls.Load() != 1 {
		close(release)
		t.Fatal("parallel first read minted attempt")
	}
	close(release)
	var generated *httptest.ResponseRecorder
	select {
	case generated = <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("publisher did not settle")
	}
	if generated.Code != 200 {
		t.Fatal(generated.Body.String())
	}
	f.onProvider = nil
	var page map[string]any
	if e := json.Unmarshal(generated.Body.Bytes(), &page); e != nil {
		t.Fatal(e)
	}
	results := make(chan int, 2)
	for _, vote := range []string{"up", "down"} {
		go func(vote string) {
			w := httptest.NewRecorder()
			f.router.ServeHTTP(w, f.rawRequest("PUT", "feedback/"+weeklyRecordingA, map[string]any{"vote": vote, "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": page["profileEpoch"], "batchId": page["batchId"]}))
			results <- w.Code
		}(vote)
	}
	statuses := map[int]int{}
	for n := 0; n < 2; n++ {
		select {
		case c := <-results:
			statuses[c]++
		case <-time.After(5 * time.Second):
			t.Fatal("CAS writes did not settle")
		}
	}
	if statuses[200] != 1 || statuses[409] != 1 {
		t.Fatal("per-resource CAS lost update", statuses)
	}
	state := f.ok("GET", "feedback/"+weeklyRecordingA, nil, "concurrent-cas-readback")
	if state["revision"] != float64(1) {
		t.Fatal("CAS revision")
	}
}
func TestWeeklyReplayPruningStillRejectsOldRevision(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	page := f.ok("GET", "weekly", nil, "")
	old := map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": page["profileEpoch"], "batchId": page["batchId"]}
	f.ok("PUT", "feedback/"+weeklyRecordingA, old, "")
	for n := 0; n < 130; n++ {
		w := httptest.NewRecorder()
		body := map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": n + 1, "profileEpoch": page["profileEpoch"], "batchId": nil}
		f.router.ServeHTTP(w, f.rawRequest("PUT", "feedback/"+weeklyRecordingA, body))
		if w.Code != 200 {
			t.Fatalf("bounded replay setup %d %d %s", n, w.Code, w.Body.String())
		}
	}
	if code, _ := f.request("PUT", "feedback/"+weeklyRecordingA, old, "pruned-operation-conflict"); code != 409 {
		t.Fatal("old pruned operation became new intent")
	}
	var count int
	if e := f.database.QueryRow(`SELECT jsonb_array_length(state->'Replays') FROM weekly_profiles WHERE user_id=$1`, f.user).Scan(&count); e != nil || count != 128 {
		t.Fatal("replay state not bounded", count, e)
	}
	prefs := f.ok("GET", "preferences", nil, "")
	aff := prefs["derivedArtistAffinities"].([]any)[0].(map[string]any)
	if aff["affinity"] != float64(1) || aff["contributingCount"] != float64(1) {
		t.Fatal("repeated fresh same-value writes multiplied affinity")
	}
}
func TestWeeklyResetWhileProviderHeldRetiresPublication(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	f.onProvider = func() {
		f.onProvider = nil
		p := f.ok("GET", "preferences", nil, "")
		f.ok("POST", "preferences/reset", map[string]any{"mutationId": uuid.NewString(), "expectedRevision": p["preferenceRevision"], "profileEpoch": p["profileEpoch"], "scope": "discovery_preferences"}, "")
	}
	p := f.ok("GET", "weekly", nil, "weekly-reset-inflight")
	if p["status"] != "stale" || p["batchId"] != nil || p["profileEpoch"] != float64(1) {
		t.Fatal("old epoch publisher survived reset")
	}
	f.artist(weeklyArtistA)
	f.restart()
	p = f.ok("GET", "weekly", nil, "")
	if p["status"] != "unavailable" || f.calls.Load() != 1 {
		t.Fatal("reset released quota")
	}
}
