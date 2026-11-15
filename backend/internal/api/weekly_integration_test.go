package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const weeklyArtistA = "11111111-1111-4111-8111-111111111111"
const weeklyArtistB = "22222222-2222-4222-8222-222222222222"
const weeklyRecordingA = "33333333-3333-4333-8333-333333333333"
const weeklyRecordingB = "44444444-4444-4444-8444-444444444444"
const weeklyRecordingA2 = "55555555-5555-4555-8555-555555555555"
const weeklyRoot = "/api/v1/me/discovery/"

type weeklyTransport func(*http.Request) (*http.Response, error)

func (f weeklyTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type weeklyFixture struct {
	t              *testing.T
	database       *db.DB
	user           uuid.UUID
	now            time.Time
	calls          atomic.Int32
	router         *Router
	body           string
	onProvider     func()
	fail           bool
	providerBlock  bool
	providerStatus int
}

func newWeeklyFixture(t *testing.T) *weeklyFixture {
	t.Helper()
	dsn := os.Getenv("SOUNDQ_WEEKLY_TEST_DSN")
	if dsn == "" {
		t.Skip("SOUNDQ_WEEKLY_TEST_DSN required: uniquely owned loopback PostgreSQL")
	}
	u, e := url.Parse(dsn)
	if e != nil || u.Hostname() != "127.0.0.1" || u.Port() == "" || u.User == nil || u.User.Username() != "weekly_fixture" || u.Path != "/weekly_fixture" || u.RawQuery != "sslmode=disable" {
		t.Fatal("refusing non-owned weekly target")
	}
	if e = db.CheckDSNNotProtected(dsn); e != nil {
		t.Fatal(e)
	}
	raw, e := sql.Open("postgres", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { raw.Close() })
	database := &db.DB{DB: raw}
	if e = database.CheckDatabaseNotProtected(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e = database.Migrate(); e != nil {
		t.Fatal(e)
	}
	f := &weeklyFixture{t: t, database: database, user: uuid.New(), now: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
	f.sql(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'Synthetic weekly','fixture-only')`, f.user, f.user.String()+"@example.test")
	seedA, seedB := uuid.NewString(), uuid.NewString()
	f.sql(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES($1,'Synthetic owned seed A','Artist A',$2,$3,true),($4,'Synthetic owned seed B','Artist B',$5,$6,true)`, seedA, weeklyArtistA, uuid.New(), seedB, weeklyArtistB, uuid.New())
	f.sql(`INSERT INTO user_library(user_id,track_id) SELECT $1,id FROM tracks WHERE identity_hash IN ($2,$3)`, f.user, seedA, seedB)
	f.body = `{"count":3,"recordings":[{"id":"` + weeklyRecordingA + `","title":"Synthetic A","score":1,"artist-credit":[{"artist":{"id":"` + weeklyArtistA + `","name":"Artist A"}}]},{"id":"` + weeklyRecordingB + `","title":"Synthetic B","score":100,"artist-credit":[{"artist":{"id":"` + weeklyArtistB + `","name":"Artist B"}}]},{"id":"` + weeklyRecordingA2 + `","title":"Synthetic A2","score":100,"artist-credit":[{"artist":{"id":"` + weeklyArtistA + `","name":"Artist A"}}]}]}`
	old := http.DefaultTransport
	http.DefaultTransport = weeklyTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" {
			return nil, fmt.Errorf("unexpected provider target %s", r.URL)
		}
		if strings.Contains(r.URL.RawQuery, "firstreleasedate") || strings.Contains(r.URL.RawQuery, f.user.String()) {
			t.Error("weekly leaked account or inherited radar date policy")
		}
		f.calls.Add(1)
		if f.onProvider != nil {
			f.onProvider()
		}
		if f.providerBlock {
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		if f.fail {
			return nil, fmt.Errorf("synthetic transport failure")
		}
		if dir := os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR"); dir != "" {
			providerDir := filepath.Join(filepath.Dir(dir), "PROVIDER_FIXTURES")
			if e := os.MkdirAll(providerDir, 0700); e != nil {
				t.Fatal(e)
			}
			name := fmt.Sprintf("%s-%d", f.user, f.calls.Load())
			if e := os.WriteFile(filepath.Join(providerDir, name+".response.json"), []byte(f.body), 0600); e != nil {
				t.Fatal(e)
			}
			if e := os.WriteFile(filepath.Join(providerDir, name+".request.txt"), []byte("SYNTHETIC transport collaborator, no provider traffic\n"+r.Method+" "+r.URL.String()+"\n"), 0600); e != nil {
				t.Fatal(e)
			}
		}
		status := f.providerStatus
		if status == 0 {
			status = 200
		}
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(f.body))}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = old })
	f.restart()
	return f
}
func (f *weeklyFixture) sql(q string, args ...any) {
	f.t.Helper()
	if _, e := f.database.Exec(q, args...); e != nil {
		f.t.Fatal(e)
	}
}
func (f *weeklyFixture) restart() {
	s := auth.NewService(nil, nil, "synthetic-weekly-secret")
	h := NewWeeklyHandlers(db.NewWeeklyRepository(f.database), musicbrainz.NewClient(nil))
	h.now = func() time.Time { return f.now }
	f.router = NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(s), AuthService: s, WeeklyHandlers: h})
}
func (f *weeklyFixture) request(method, path string, body any, name string) (int, map[string]any) {
	f.t.Helper()
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	r := httptest.NewRequest(method, weeklyRoot+path, bytes.NewReader(b))
	token, e := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: f.user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte("synthetic-weekly-secret"))
	if e != nil {
		f.t.Fatal(e)
	}
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, r)
	if w.Header().Get("Cache-Control") != "private, no-store" {
		f.t.Errorf("private route cache control missing: %d %s", w.Code, w.Body.String())
	}
	var out map[string]any
	if e = json.Unmarshal(w.Body.Bytes(), &out); e != nil {
		f.t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	if dir := os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR"); dir != "" && name != "" {
		if body != nil {
			if e = os.WriteFile(filepath.Join(dir, name+".request.json"), b, 0600); e != nil {
				f.t.Fatal(e)
			}
		}
		if e = os.WriteFile(filepath.Join(dir, name+".json"), w.Body.Bytes(), 0600); e != nil {
			f.t.Fatal(e)
		}
	}
	f.t.Logf("HTTP %s %s -> %d %s", method, path, w.Code, w.Body.String())
	return w.Code, out
}
func (f *weeklyFixture) ok(method, path string, body any, name string) map[string]any {
	f.t.Helper()
	code, out := f.request(method, path, body, name)
	if code != 200 {
		f.t.Fatalf("want200 got%d %#v", code, out)
	}
	return out
}
func (f *weeklyFixture) permission(name string, enabled bool) {
	p := f.ok("GET", "preferences", nil, "")
	revs := p["permissionRevisions"].(map[string]any)
	f.ok("PUT", "preferences", map[string]any{"resource": "permission", "permission": name, "enabled": enabled, "mutationId": uuid.NewString(), "expectedRevision": revs[name], "profileEpoch": p["profileEpoch"]}, "permission-ack")
}
func (f *weeklyFixture) artist(id string) {
	p := f.ok("GET", "preferences", nil, "")
	f.ok("PUT", "preferences", map[string]any{"resource": "artist", "artistMbid": id, "interested": true, "blocked": false, "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": p["profileEpoch"]}, "artist-ack")
}
func weeklyIDs(p map[string]any) []string {
	out := []string{}
	for _, v := range p["items"].([]any) {
		out = append(out, v.(map[string]any)["recordingMbid"].(string))
	}
	return out
}
func TestWeeklyAuthenticatedDurableTracer(t *testing.T) {
	f := newWeeklyFixture(t)
	p := f.ok("GET", "preferences", nil, "preferences-default")
	if p["externalCatalogQueries"] != false || p["learningFromServerHistory"] != false {
		t.Fatal("permissions default must be false")
	}
	f.artist(weeklyArtistA)
	f.artist(weeklyArtistB)
	f.permission("externalCatalogQueries", true)
	initial := f.ok("GET", "weekly", nil, "weekly-ready")
	ids := weeklyIDs(initial)
	if strings.Join(ids, ",") != strings.Join([]string{weeklyRecordingA, weeklyRecordingB, weeklyRecordingA2}, ",") {
		t.Fatalf("actual generated ordering %v", ids)
	}
	if f.calls.Load() != 1 {
		t.Fatal("real fixture provider not used")
	}
	feedback := map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": initial["profileEpoch"], "batchId": initial["batchId"]}
	ack := f.ok("PUT", "feedback/"+weeklyRecordingB, feedback, "feedback-ack")
	if ack["feedback"].(map[string]any)["vote"] != "up" {
		t.Fatal(ack)
	}
	f.restart()
	current := f.ok("GET", "weekly", nil, "weekly-current-retained")
	if current["batchId"] != initial["batchId"] || strings.Join(weeklyIDs(current), ",") != strings.Join(ids, ",") || f.calls.Load() != 1 {
		t.Fatal("current base changed or refetched")
	}
	f.now = f.now.AddDate(0, 0, 7)
	next := f.ok("GET", "weekly", nil, "weekly-next-up")
	if weeklyIDs(next)[0] != weeklyRecordingB || f.calls.Load() != 2 {
		t.Fatal("durable HTTP feedback did not affect NEXT real ranker order")
	}
}
