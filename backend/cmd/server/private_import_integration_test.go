package main

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

var privateImportFixtureDSN = regexp.MustCompile(`^postgres://(pif_[0-9a-f]{24}):[0-9a-f]{64}@127\.0\.0\.1:[1-9][0-9]{0,4}/(pif_[0-9a-f]{24})\?sslmode=disable&connect_timeout=3$`)
var privateImportFixtureMarker = regexp.MustCompile(`^[0-9a-f]{64}$`)

func openPrivateImportFixtureDB(t *testing.T, ctx context.Context) *db.DB {
	t.Helper()
	dsn, token := os.Getenv("OMP_PRIVATE_FENCE_TEST_DSN"), os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER")
	if dsn == "" {
		t.Skip("requires an independently attested disposable private-import fixture")
	}
	parts := privateImportFixtureDSN.FindStringSubmatch(dsn)
	if len(parts) != 3 || parts[1] != parts[2] || !privateImportFixtureMarker.MatchString(token) || os.Getenv(db.AllowProtectedDBTestsEnv) != "" {
		t.Fatal("refusing non-disposable fixture DSN")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	pool, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open private import fixture")
	}
	t.Cleanup(func() { _ = pool.Close() })
	database := &db.DB{DB: pool}
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal(err)
	}
	var name, role, comment string
	if err := pool.QueryRowContext(ctx, `SELECT current_database(), current_user, COALESCE(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = current_database()`).Scan(&name, &role, &comment); err != nil || name != parts[1] || role != name || comment != "private-fence-fixture:"+token {
		t.Fatal("fixture database attestation mismatch")
	}
	return database
}

func seedPrivateImportUser(t *testing.T, database *db.DB, ctx context.Context) uuid.UUID {
	t.Helper()
	user := uuid.New()
	if _, err := database.ExecContext(ctx, `INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'fixture','fixture')`, user, user.String()+"@fixture.invalid"); err != nil {
		t.Fatal(err)
	}
	return user
}

func TestPrivateImportNotInGlobalMaintenanceCandidates(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	database := openPrivateImportFixtureDB(t, ctx)
	if err := database.Migrate(); err != nil {
		t.Fatal(err)
	}
	owner := seedPrivateImportUser(t, database, ctx)
	var private, shared int64
	if err := database.QueryRowContext(ctx, `INSERT INTO tracks (identity_hash,title,private_owner_id,source_file_hash,file_size_bytes,storage_key) VALUES($1,'Private fixture',$2,$3,8,'fixture.mp3') RETURNING id`, uuid.NewString(), owner, "sha256:"+strings.Repeat("d", 64)).Scan(&private); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRowContext(ctx, `INSERT INTO tracks (identity_hash,title,storage_key) VALUES($1,'Shared fixture','shared.mp3') RETURNING id`, uuid.NewString()).Scan(&shared); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := database.Exec(`DELETE FROM tracks WHERE id IN ($1,$2)`, private, shared); err != nil {
			t.Error(err)
		}
	})
	tracks := db.NewTrackRepository(database)
	candidates, err := tracks.GetMaintenanceCandidates(ctx, true, true, 0, 200)
	if err != nil {
		t.Fatal(err)
	}
	foundShared := false
	for _, track := range candidates {
		if track.ID == private {
			t.Fatal("private track leaked into global maintenance candidates")
		}
		foundShared = foundShared || track.ID == shared
	}
	if !foundShared {
		t.Fatal("ordinary shared maintenance candidate was lost")
	}
}

type privateProviderFixture func(*http.Request) (*http.Response, error)

func (f privateProviderFixture) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestPrivateImportNumericMatcherRefusesPrivateLikeUnknown(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	database := openPrivateImportFixtureDB(t, ctx)
	if err := database.Migrate(); err != nil {
		t.Fatal(err)
	}
	owner, other := seedPrivateImportUser(t, database, ctx), seedPrivateImportUser(t, database, ctx)
	var id int64
	if err := database.QueryRowContext(ctx, `INSERT INTO tracks (identity_hash,title,private_owner_id,source_file_hash,file_size_bytes,storage_key) VALUES($1,'Private fixture',$2,$3,8,'fixture.mp3') RETURNING id`, uuid.NewString(), owner, "sha256:"+strings.Repeat("e", 64)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	tracks := db.NewTrackRepository(database)
	public := &db.Track{Title: "Shared Fixture", IdentityHash: uuid.NewString()}
	if err := tracks.Create(ctx, public); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := database.Exec(`DELETE FROM tracks WHERE id IN ($1,$2)`, id, public.ID); err != nil {
			t.Error(err)
		}
	})
	mbid := uuid.NewString()
	calls := 0
	transport := http.DefaultTransport
	http.DefaultTransport = privateProviderFixture(func(req *http.Request) (*http.Response, error) {
		calls++
		if req.URL.Hostname() != "musicbrainz.org" {
			return nil, fmt.Errorf("fixture refused arbitrary outbound request")
		}
		body := `{"count":0,"recordings":[]}`
		if strings.HasSuffix(req.URL.Path, mbid) {
			body = fmt.Sprintf(`{"id":%q,"title":"Shared Fixture"}`, mbid)
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = transport })
	secret := uuid.NewString() + uuid.NewString()
	sessions := auth.NewService(nil, nil, secret)
	router := api.NewRouterWithConfig(&api.RouterConfig{
		AuthService: sessions, AuthHandlers: auth.NewHandlers(sessions),
		MatcherHandlers: matcher.NewHandler(matcher.NewMatcher(musicbrainz.NewClient(nil)), tracks),
	})
	request := func(user uuid.UUID, track int64, action, body string) *httptest.ResponseRecorder {
		t.Helper()
		credential, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/api/v1/tracks/%d/%s", track, action), strings.NewReader(body)).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+credential)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w
	}
	for _, probe := range []struct{ action, body string }{
		{"match", `{}`}, {"confirm-match", fmt.Sprintf(`{"recordingMbid":%q}`, mbid)}, {"link-mb", fmt.Sprintf(`{"mb_recording_id":%q}`, mbid)},
	} {
		for _, user := range []uuid.UUID{owner, other} {
			unknown := request(user, 1<<60, probe.action, probe.body)
			private := request(user, id, probe.action, probe.body)
			if unknown.Code != http.StatusNotFound || private.Code != unknown.Code || private.Body.String() != unknown.Body.String() || calls != 0 {
				t.Fatalf("%s private=%d unknown=%d provider_calls=%d", probe.action, private.Code, unknown.Code, calls)
			}
		}
	}
	for _, probe := range []struct{ action, body string }{
		{"match", `{}`}, {"confirm-match", fmt.Sprintf(`{"recordingMbid":%q}`, mbid)}, {"link-mb", fmt.Sprintf(`{"mb_recording_id":%q}`, mbid)},
	} {
		if shared := request(owner, public.ID, probe.action, probe.body); shared.Code != http.StatusOK {
			t.Fatalf("shared %s: %d %s", probe.action, shared.Code, shared.Body)
		}
	}
	if calls < 2 {
		t.Fatalf("shared provider controls did not traverse controlled transport: %d", calls)
	}
}
