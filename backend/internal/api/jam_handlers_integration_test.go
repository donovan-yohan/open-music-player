package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/jam"
	"github.com/redis/go-redis/v9"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestJamIntegrationFixtureProtection(t *testing.T) {
	assertFixtureProtection(t, func(t *testing.T) { jamIntegration(t) }, "JAM_TEST_DSN", "JAM_TEST_REDIS")
}

func jamIntegration(t *testing.T) (*jam.Repository, jam.Owner, jam.Proof, *http.ServeMux) {
	t.Helper()
	dsn := os.Getenv("JAM_TEST_DSN")
	addr := os.Getenv("JAM_TEST_REDIS")
	if dsn == "" || addr == "" {
		t.Skip("disposable JAM_TEST_DSN/JAM_TEST_REDIS required")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	admin, e := sql.Open("postgres", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { admin.Close() })
	// Read the original database marker before creating the isolated schema.
	if err := (&db.DB{DB: admin}).CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatal(err)
	}
	schema := "jam_http_" + uuid.NewString()[:8]
	if _, e = admin.Exec(`CREATE SCHEMA ` + schema); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { admin.Exec(`DROP SCHEMA ` + schema + ` CASCADE`) })
	db, e := sql.Open("postgres", dsn+"&search_path="+schema)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	_, e = db.Exec(`CREATE TABLE users(id uuid PRIMARY KEY,connect_auth_generation bigint NOT NULL DEFAULT 0); CREATE TABLE tracks(id bigint PRIMARY KEY,title text,artist text,duration_ms integer);CREATE TABLE user_library(user_id uuid REFERENCES users(id),track_id bigint REFERENCES tracks(id),PRIMARY KEY(user_id,track_id));CREATE TABLE jams(id uuid PRIMARY KEY,owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,owner_auth_generation bigint NOT NULL,created_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,closed_at timestamptz,version bigint NOT NULL CHECK(version>=1),state jsonb NOT NULL CHECK(octet_length(state::text)<=65536));CREATE INDEX jams_owner_idx ON jams(owner_user_id);`)
	if e != nil {
		t.Fatal(e)
	}
	o := jam.Owner{UserID: uuid.New()}
	p := jam.Proof{HostDeviceID: uuid.New(), LeaseID: uuid.New(), WriterSecret: jam.NewSecret()}
	if _, e = db.Exec(`INSERT INTO users(id) VALUES($1)`, o.UserID); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(`INSERT INTO tracks VALUES(1,'<script>not executable</script>','Local fixture',180000)`); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(`INSERT INTO user_library VALUES($1,1)`, o.UserID); e != nil {
		t.Fatal(e)
	}
	c := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { c.Close() })
	l := jam.NewRedisLimiter(c)
	l.Prefix = "jam-http-test:" + uuid.NewString()
	repo := jam.NewRepository(db)
	// Synthetic local fixture resolver. Production MUST use account middleware +
	// current generation and actual Connect lease validation, never this fixture.
	h := NewJamHandlers(repo, l, func(r *http.Request) (jam.Owner, error) {
		if r.Header.Get("X-Test-Owner") != o.UserID.String() {
			return jam.Owner{}, jam.ErrDenied
		}
		return o, nil
	}, func(_ context.Context, owner jam.Owner, proof jam.Proof) error {
		if owner != o || proof != p {
			return jam.ErrDenied
		}
		return nil
	})
	m := http.NewServeMux()
	h.RegisterGuestRoutes(m)
	h.RegisterHostRoutes(m)
	h.RegisterGuestWebRoutes(m)
	return repo, o, p, m
}
func jamHTTP(t *testing.T, c *http.Client, method, url, token string, body any) (int, []byte, http.Header) {
	t.Helper()
	var b bytes.Buffer
	if body != nil {
		if e := json.NewEncoder(&b).Encode(body); e != nil {
			t.Fatal(e)
		}
	}
	r, e := http.NewRequest(method, url, &b)
	if e != nil {
		t.Fatal(e)
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	r.Header.Set("Content-Type", "application/json")
	res, e := c.Do(r)
	if e != nil {
		t.Fatal(e)
	}
	defer res.Body.Close()
	var out bytes.Buffer
	out.ReadFrom(res.Body)
	return res.StatusCode, out.Bytes(), res.Header
}
func TestJamHostMutationRequiresDesignatedWriter(t *testing.T) {
	repo, o, p, m := jamIntegration(t)
	ctx := context.Background()
	id := uuid.New()
	if _, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}}); e != nil {
		t.Fatal(e)
	}
	wrong := p
	wrong.WriterSecret = jam.NewSecret()
	body, _ := json.Marshal(jam.HeartbeatInput{Proof: wrong, HostSequence: 1})
	r := httptest.NewRequest("PUT", "/api/v1/jams/"+id.String()+"/host", bytes.NewReader(body))
	r.Header.Set("X-Test-Owner", o.UserID.String())
	w := httptest.NewRecorder()
	m.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("viewer writer=%d %s", w.Code, w.Body.String())
	}
	view, e := repo.HostSnapshot(ctx, o, id)
	if e != nil || view.Version != 1 {
		t.Fatalf("denied mutation=%+v %v", view, e)
	}
}
func TestJamHTTPRealLocalFlow(t *testing.T) {
	repo, o, p, m := jamIntegration(t)
	ctx := context.Background()
	id := uuid.New()
	if _, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}}); e != nil {
		t.Fatal(e)
	}
	invite, e := repo.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(m)
	defer server.Close()
	base := server.URL + "/api/v1/guest/jams/" + id.String()
	secret := jam.NewSecret()
	in := jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Local listener", MemberSecret: secret}
	status, b, h := jamHTTP(t, server.Client(), "POST", base+"/members", "", in)
	if status != 201 {
		t.Fatalf("join %d %s", status, b)
	}
	if h.Get("Cache-Control") != "no-store" {
		t.Fatal("cache")
	}
	var joined jam.JoinResult
	if e = json.Unmarshal(b, &joined); e != nil {
		t.Fatal(e)
	}
	q := jam.RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[0].CatalogItemID, ExpectedVersion: joined.Snapshot.Version}
	status, b, _ = jamHTTP(t, server.Client(), "POST", base+"/requests", secret, q)
	if status != 201 {
		t.Fatalf("request %d %s", status, b)
	}
	view, e := repo.HostSnapshot(ctx, o, id)
	if e != nil {
		t.Fatal(e)
	}
	if len(view.HostRequests) != 1 || view.HostRequests[0].Status != "pending" {
		t.Fatal("must require explicit approval")
	}
	if _, e = repo.Decide(ctx, o, id, p, q.RequestID, jam.DecisionInput{ExpectedVersion: view.Version, Status: "uncertain"}); e != nil {
		t.Fatal(e)
	}
	status, b, _ = jamHTTP(t, server.Client(), "GET", base, secret, nil)
	if status != 200 || !strings.Contains(string(b), `"status":"uncertain"`) {
		t.Fatalf("readback %d %s", status, b)
	}
	for _, path := range []string{"/api/v1/jams/" + id.String(), "/api/v1/library", "/api/v1/tracks/1/playback"} {
		status, _, _ = jamHTTP(t, server.Client(), "GET", server.URL+path, secret, nil)
		if status == 200 {
			t.Fatalf("guest crossed scope %s", path)
		}
	}
	status, b, h = jamHTTP(t, server.Client(), "GET", server.URL+"/join", "", nil)
	if status != 200 || !strings.Contains(string(b), "Playback is on the host") || !strings.Contains(h.Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatalf("guest page=%d", status)
	}
	status, b, _ = jamHTTP(t, server.Client(), "GET", server.URL+"/join/app.js", "", nil)
	if status != 200 || strings.Contains(string(b), "innerHTML") || strings.Contains(string(b), "localStorage") {
		t.Fatal("unsafe asset")
	}
	t.Log("real loopback HTTP join -> pending request -> explicit uncertain decision -> guest readback PASS; no audio admission claimed")
}

// Optional local-only executable preview, no deployment, account credentials or
// public URL. It serves actual SQL/Redis handlers and expires automatically.
func TestJamLocalGuestBrowser(t *testing.T) {
	if os.Getenv("JAM_DEMO") != "1" {
		t.Skip("set JAM_DEMO=1 for bounded loopback preview")
	}
	repo, o, p, m := jamIntegration(t)
	ctx := context.Background()
	id := uuid.New()
	if _, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}}); e != nil {
		t.Fatal(e)
	}
	invite, e := repo.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(m)
	defer server.Close()
	artifact := filepath.Join(os.Getenv("TMPDIR"), "soundq-jam-local-preview.json")
	url := server.URL + "/join#jamId=" + id.String() + "&invite=" + invite.JoinToken
	b, _ := json.Marshal(map[string]string{"url": url, "origin": server.URL, "jamId": id.String(), "stopFile": artifact + ".stop"})
	if e = os.WriteFile(artifact, b, 0600); e != nil {
		t.Fatal(e)
	}
	t.Logf("loopback preview manifest: %s (contains disposable invitation; mode0600)", artifact)
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	end := time.After(12 * time.Minute)
	sequence := int64(0)
	for {
		select {
		case <-end:
			return
		case <-ticker.C:
			if _, err := os.Stat(artifact + ".stop"); err == nil {
				os.Remove(artifact + ".stop")
				return
			}
			sequence++
			if _, e = repo.Heartbeat(ctx, o, id, jam.HeartbeatInput{Proof: p, HostSequence: sequence, NowPlaying: &jam.NowPlaying{Title: "Local fixture — host only", Artist: "No audio is running", DurationMS: 180000}}); e != nil {
				t.Fatal(fmt.Errorf("preview heartbeat: %w", e))
			}
		}
	}
}
