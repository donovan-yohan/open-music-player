package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// Deliberately not the ordinary shared integration DSN. The external fixture
// provisioner must generate fresh credentials and attest the database before
// the test is allowed to migrate or seed any private rows.
var privateFenceDSNPattern = regexp.MustCompile(`^postgres://(pif_[0-9a-f]{24}):[0-9a-f]{64}@127\.0\.0\.1:([1-9][0-9]{0,4})/(pif_[0-9a-f]{24})\?sslmode=disable&connect_timeout=3$`)
var privateFenceMarkerPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

const privateFenceSQLTimeout = 8 * time.Second

func privateFenceTestDB(t *testing.T) *db.DB {
	t.Helper()
	dsn := os.Getenv("OMP_PRIVATE_FENCE_TEST_DSN")
	if dsn == "" {
		t.Skip("requires an explicitly provisioned private-fence disposable PostgreSQL fixture")
	}
	attestation := os.Getenv("OMP_PRIVATE_FENCE_TEST_MARKER")
	parts := privateFenceDSNPattern.FindStringSubmatch(dsn)
	if len(parts) != 4 || parts[1] != parts[3] || !privateFenceMarkerPattern.MatchString(attestation) || os.Getenv(db.AllowProtectedDBTestsEnv) != "" {
		t.Fatal("refusing non-disposable private-fence test database")
	}
	port, _ := strconv.Atoi(parts[2])
	if port > 65535 {
		t.Fatal("invalid fixture loopback port")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open private-fence fixture")
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &db.DB{DB: raw}
	ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
	defer cancel()
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal(err)
	}
	var name, role, marker string
	if err := database.QueryRowContext(ctx, `SELECT current_database(), current_user, COALESCE(shobj_description(oid,'pg_database'),'') FROM pg_database WHERE datname=current_database()`).Scan(&name, &role, &marker); err != nil || name != parts[3] || role != parts[1] || marker != "private-fence-fixture:"+attestation {
		t.Fatal("private-fence fixture attestation missing or mismatched")
	}
	cancel()
	if err := database.Migrate(); err != nil {
		t.Fatal(err)
	}
	postMigrationCtx, cancelPostMigration := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
	defer cancelPostMigration()
	if err := database.CheckDatabaseNotProtected(postMigrationCtx); err != nil {
		t.Fatal(err)
	}
	return database
}

func TestLibraryPrivateFence(t *testing.T) {
	database := privateFenceTestDB(t)
	exec := func(t *testing.T, query string, args ...any) {
		t.Helper()
		ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
		defer cancel()
		if _, err := database.ExecContext(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	refuse := func(t *testing.T, code string, constraint string, query string, args ...any) {
		t.Helper()
		ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
		defer cancel()
		_, err := database.ExecContext(ctx, query, args...)
		var pgErr *pq.Error
		if !errors.As(err, &pgErr) || string(pgErr.Code) != code || pgErr.Constraint != constraint {
			t.Fatalf("%s: expected SQLSTATE %s / %s, got %v", query, code, constraint, err)
		}
	}
	seedUser := func(t *testing.T) uuid.UUID {
		t.Helper()
		id := uuid.New()
		exec(t, `INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, 'user', 'x')`, id, uuid.NewString()+"@example.test")
		return id
	}
	owner, other := seedUser(t), seedUser(t)
	sharedHash := "sha256:" + strings.Repeat("a", 64)
	// Exercise the existing producer, which must still create a shared row.
	// Give its row and both private rows the same exact-byte evidence.
	tracks := db.NewTrackRepository(database)
	public := &db.Track{IdentityHash: uuid.NewString(), Title: "Public fixture"}
	setupCtx, cancelSetup := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
	defer cancelSetup()
	if err := tracks.Create(setupCtx, public); err != nil {
		t.Fatal(err)
	}
	publicID := public.ID
	exec(t, `UPDATE tracks SET source_file_hash=$1,file_size_bytes=42 WHERE id=$2`, sharedHash, publicID)
	var ownerID, otherID int64
	var publicOwner uuid.NullUUID
	if err := database.QueryRowContext(setupCtx, `SELECT private_owner_id FROM tracks WHERE id=$1`, publicID).Scan(&publicOwner); err != nil || publicOwner.Valid {
		t.Fatalf("legacy shared insert: owner=%v err=%v", publicOwner, err)
	}
	privateInsert := `INSERT INTO tracks(identity_hash,title,private_owner_id,source_file_hash,file_size_bytes,storage_key) VALUES($1,'Private fixture',$2,$3,$4,$5)`
	for _, p := range []struct {
		account uuid.UUID
		id      *int64
	}{
		{owner, &ownerID}, {other, &otherID},
	} {
		if err := database.QueryRowContext(setupCtx, privateInsert+` RETURNING id`, uuid.NewString(), p.account, sharedHash, 42, uuid.NewString()).Scan(p.id); err != nil {
			t.Fatal(err)
		}
	}
	cancelSetup()
	if publicID == ownerID || ownerID == otherID || publicID == otherID {
		t.Fatal("cross-account/public identities were coalesced")
	}

	t.Run("authenticated_numeric_route", func(t *testing.T) {
		secret := uuid.NewString() + uuid.NewString()
		service := auth.NewService(nil, nil, secret)
		router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, LibraryHandlers: NewLibraryHandlers(db.NewTrackRepository(database), db.NewLibraryRepository(database))})
		token := func(u uuid.UUID) string {
			t.Helper()
			s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: u.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
			if err != nil {
				t.Fatal(err)
			}
			return s
		}
		a, b := token(owner), token(other)
		request := func(credential string, id int64) *httptest.ResponseRecorder {
			ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
			defer cancel()
			r := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/api/v1/library/tracks/%d", id), nil).WithContext(ctx)
			if credential != "" {
				r.Header.Set("Authorization", "Bearer "+credential)
			}
			w := httptest.NewRecorder()
			router.ServeHTTP(w, r)
			return w
		}
		for _, probe := range []struct{ method, path string }{
			{http.MethodPost, "/api/v1/library/uploads"},
			{http.MethodGet, "/api/v1/library/uploads/" + uuid.NewString()},
		} {
			r := httptest.NewRequest(probe.method, probe.path, nil)
			r.Header.Set("Authorization", "Bearer "+a)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, r)
			if w.Code != http.StatusNotFound {
				t.Fatalf("upload/status must not be registered: %s %d", probe.method, w.Code)
			}
		}
		if w := request("", ownerID); w.Code != http.StatusUnauthorized {
			t.Fatalf("unauthenticated add: %d %s", w.Code, w.Body)
		}
		missing := request(a, -1)
		if missing.Code != http.StatusNotFound || missing.Body.String() != "{\"code\":\"TRACK_NOT_FOUND\",\"message\":\"track not found\"}\n" {
			t.Fatalf("missing add: %d %s", missing.Code, missing.Body)
		}
		for _, req := range []struct {
			token string
			id    int64
		}{{b, ownerID}, {a, otherID}} {
			if w := request(req.token, req.id); w.Code != missing.Code || w.Body.String() != missing.Body.String() || w.Header().Get("Content-Type") != missing.Header().Get("Content-Type") {
				t.Fatalf("foreign add not missing-equivalent: %d %s", w.Code, w.Body)
			}
		}
		for _, req := range []struct {
			token   string
			account uuid.UUID
			id      int64
		}{{a, owner, ownerID}, {b, other, otherID}, {a, owner, publicID}, {b, other, publicID}} {
			const attempts = 6
			start := make(chan struct{})
			result := make(chan *httptest.ResponseRecorder, attempts)
			for i := 0; i < attempts; i++ {
				go func() { <-start; result <- request(req.token, req.id) }()
			}
			close(start)
			var created, conflicts int
			var ack AddTrackResponse
			for i := 0; i < attempts; i++ {
				w := <-result
				switch w.Code {
				case http.StatusCreated:
					created++
					if err := json.Unmarshal(w.Body.Bytes(), &ack); err != nil || ack.TrackID != req.id || ack.AddedAt == "" {
						t.Errorf("bad success acknowledgement: %s (%v)", w.Body, err)
					}
				case http.StatusConflict:
					if w.Body.String() != "{\"code\":\"ALREADY_IN_LIBRARY\",\"message\":\"track already in library\"}\n" {
						t.Errorf("incorrect duplicate response: %s", w.Body)
					}
					conflicts++
				default:
					t.Errorf("unexpected concurrent status: %d %s", w.Code, w.Body)
				}
			}
			if created != 1 || conflicts != attempts-1 {
				t.Fatalf("want one insert and stable duplicate contract, got created=%d conflicts=%d", created, conflicts)
			}
			var before, after time.Time
			var count int
			readCtx, cancelRead := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
			err := database.QueryRowContext(readCtx, `SELECT count(*),min(added_at) FROM user_library WHERE user_id=$1 AND track_id=$2`, req.account, req.id).Scan(&count, &before)
			cancelRead()
			if err != nil || count != 1 || before.UTC().Format("2006-01-02T15:04:05Z") != ack.AddedAt {
				t.Fatalf("membership readback count=%d added_at=%v ack=%+v err=%v", count, before, ack, err)
			}
			if w := request(req.token, req.id); w.Code != http.StatusConflict {
				t.Fatalf("replay: %d %s", w.Code, w.Body)
			}
			replayCtx, cancelReplay := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
			err = database.QueryRowContext(replayCtx, `SELECT added_at FROM user_library WHERE user_id=$1 AND track_id=$2`, req.account, req.id).Scan(&after)
			cancelReplay()
			if err != nil || !after.Equal(before) {
				t.Fatalf("replay changed existing timestamp: %v -> %v (%v)", before, after, err)
			}
		}
	})

	t.Run("shared_membership_invariant", func(t *testing.T) {
		const denial = "user_library_visible_track"
		refuse(t, "23503", denial, `INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, other, ownerID)
		refuse(t, "23503", denial, `INSERT INTO user_library(user_id,track_id) SELECT $1,id FROM tracks WHERE id=$2 ON CONFLICT DO NOTHING`, owner, otherID)
		// Use a legitimate owner and public membership regardless of route subtest outcome.
		exec(t, `INSERT INTO user_library(user_id,track_id) VALUES($1,$2),($3,$4) ON CONFLICT DO NOTHING`, owner, ownerID, other, publicID)
		refuse(t, "23503", denial, `UPDATE user_library SET user_id=$1 WHERE track_id=$2`, other, ownerID)
		refuse(t, "23503", denial, `UPDATE user_library SET track_id=$1 WHERE user_id=$2 AND track_id=$3`, ownerID, other, publicID)
		refuse(t, "23503", denial, `INSERT INTO user_library(user_id,track_id) VALUES($1,$2) ON CONFLICT (user_id,track_id) DO UPDATE SET track_id=$3`, other, publicID, ownerID)
		var foreign int
		ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
		defer cancel()
		if err := database.QueryRowContext(ctx, `SELECT count(*) FROM user_library ul JOIN tracks t ON t.id=ul.track_id WHERE t.private_owner_id IS NOT NULL AND t.private_owner_id<>ul.user_id`).Scan(&foreign); err != nil || foreign != 0 {
			t.Fatalf("foreign memberships=%d error=%v", foreign, err)
		}
	})

	t.Run("membership_uses_own_schema", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
		defer cancel()
		tx, err := database.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		if _, err := tx.ExecContext(ctx, `CREATE TEMP TABLE tracks(id bigint, private_owner_id uuid)`); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO pg_temp.tracks (id) VALUES ($1)`, ownerID); err != nil {
			t.Fatal(err)
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO public.user_library(user_id,track_id) VALUES($1,$2)`, other, ownerID)
		var pgErr *pq.Error
		if !errors.As(err, &pgErr) || pgErr.Code != "23503" || pgErr.Constraint != "user_library_visible_track" {
			t.Fatalf("same-session shadow bypassed membership scope: %v", err)
		}
	})

	t.Run("scoped_exact_custody", func(t *testing.T) {
		refuse(t, "23505", "idx_tracks_private_exact_source", privateInsert, uuid.NewString(), owner, sharedHash, 42, uuid.NewString())
		exec(t, privateInsert, uuid.NewString(), owner, sharedHash, 43, uuid.NewString())
		exec(t, privateInsert, uuid.NewString(), owner, "sha256:"+strings.Repeat("b", 64), 42, uuid.NewString())
		for _, bad := range []struct {
			owner any
			hash  string
			size  any
			key   any
		}{{uuid.Nil, sharedHash, 42, "fixture"}, {owner, "SHA256:" + strings.Repeat("A", 64), 42, "fixture"}, {owner, "", 42, "fixture"}, {owner, sharedHash + "\n", 42, "fixture"}, {owner, sharedHash, nil, "fixture"}, {owner, sharedHash, 0, "fixture"}, {owner, sharedHash, 42, nil}, {owner, sharedHash, 42, ""}} {
			refuse(t, "23514", "tracks_private_exact_source", privateInsert, uuid.NewString(), bad.owner, bad.hash, bad.size, bad.key)
		}
		refuse(t, "23503", "tracks_private_owner_id_fkey", privateInsert, uuid.NewString(), uuid.New(), sharedHash, 42, "fixture")
		const custody = "tracks_private_custody"
		refuse(t, "23514", custody, `UPDATE tracks SET private_owner_id=$1,storage_key='claimed',file_size_bytes=99 WHERE id=$2`, other, publicID)
		refuse(t, "23514", custody, `UPDATE tracks SET private_owner_id=NULL WHERE id=$1`, ownerID)
		refuse(t, "23514", custody, `UPDATE tracks SET private_owner_id=$1,source_file_hash=$2 WHERE id=$3`, other, "sha256:"+strings.Repeat("c", 64), ownerID)
		for _, change := range []string{"storage_key='replacement'", "source_file_hash='sha256:'||repeat('d',64)", "file_size_bytes=44", "identity_hash='replacement'"} {
			refuse(t, "23514", custody, `UPDATE tracks SET `+change+` WHERE id=$1`, ownerID)
		}
		// Use a private row without membership so the primary/FK relationship
		// cannot be credited for rejecting ID replacement.
		refuse(t, "23514", custody, `UPDATE tracks SET id=-10 WHERE private_owner_id=$1 AND file_size_bytes=43`, owner)
		exec(t, `UPDATE tracks SET title='Nor is this a metadata lock' WHERE id=$1`, ownerID)
	})

	t.Run("repeat_startup_and_account_delete", func(t *testing.T) {
		if err := database.Migrate(); err != nil {
			t.Fatal(err)
		}
		var kept uuid.UUID
		ctx, cancel := context.WithTimeout(t.Context(), privateFenceSQLTimeout)
		defer cancel()
		if err := database.QueryRowContext(ctx, `SELECT private_owner_id FROM tracks WHERE id=$1`, ownerID).Scan(&kept); err != nil || kept != owner {
			t.Fatalf("startup changed private custody: %v %v", kept, err)
		}
		refuse(t, "23503", "tracks_private_owner_id_fkey", `DELETE FROM users WHERE id=$1`, owner)
		legacy := seedUser(t)
		exec(t, `INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, legacy, publicID)
		exec(t, `DELETE FROM users WHERE id=$1`, legacy)
		var libraryCount, trackCount int
		if err := database.QueryRowContext(ctx, `SELECT (SELECT count(*) FROM user_library WHERE user_id=$1), (SELECT count(*) FROM tracks WHERE id=$2 AND private_owner_id IS NULL)`, legacy, publicID).Scan(&libraryCount, &trackCount); err != nil || libraryCount != 0 || trackCount != 1 {
			t.Fatalf("legacy account delete: memberships=%d public track=%d error=%v", libraryCount, trackCount, err)
		}
	})
}
