package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

func TestCatalogPrivateScope(t *testing.T) {
	// Use the predecessor's guarded, independently attested fixture. This test
	// must never seed a private row through the ordinary integration DSN.
	database := privateFenceTestDB(t)
	owner := seedMixUser(t, database, uuid.NewString()+"@example.test")
	other := seedMixUser(t, database, uuid.NewString()+"@example.test")
	accounts := []struct {
		name string
		id   uuid.UUID
	}{{"owner", owner}, {"foreign", other}}
	tracks, library := db.NewTrackRepository(database), db.NewLibraryRepository(database)
	secret := uuid.NewString() + uuid.NewString()
	service := auth.NewService(nil, nil, secret)
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, LibraryHandlers: NewLibraryHandlers(tracks, library)})
	tokens := make(map[uuid.UUID]string)
	for _, account := range accounts {
		token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: account.id.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
		if err != nil {
			t.Fatal(err)
		}
		tokens[account.id] = token
	}
	request := func(t *testing.T, user uuid.UUID, method, path, body string) *httptest.ResponseRecorder {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		r := httptest.NewRequest(method, path, strings.NewReader(body)).WithContext(ctx)
		r.Header.Set("Authorization", "Bearer "+tokens[user])
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	path := func(recording uuid.UUID) string { return "/api/v1/catalog/recordings/" + recording.String() }
	seedShared := func(t *testing.T, recording uuid.UUID, verified bool) int64 {
		t.Helper()
		var id int64
		if err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified) VALUES ($1,'Catalog shared fixture',$2,$3) RETURNING id`, uuid.NewString(), recording, verified).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	const title = "Catalog private fixture"
	seedPrivate := func(t *testing.T, recording uuid.UUID, verified bool) int64 {
		t.Helper()
		var id int64
		err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified,private_owner_id,storage_key,source_file_hash,file_size_bytes)
			VALUES ($1,$2,$3,$4,$5,$6,$7,128) RETURNING id`, uuid.NewString(), title, recording, verified, owner, uuid.NewString(), "sha256:"+strings.ReplaceAll(uuid.NewString()+uuid.NewString(), "-", "")).Scan(&id)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	exec := func(t *testing.T, sql string, args ...any) {
		t.Helper()
		if _, err := database.Exec(sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	verified := func(id int64, member bool) db.CatalogTrackCandidate {
		return db.CatalogTrackCandidate{TrackID: id, MBVerified: true, InLibrary: member}
	}
	read := func(t *testing.T, user, recording uuid.UUID, status string, truncated bool, candidates []db.CatalogTrackCandidate) *httptest.ResponseRecorder {
		t.Helper()
		w := request(t, user, http.MethodGet, path(recording)+"/resolution", "")
		want := CatalogResolutionResponse{RecordingMBID: recording.String(), UserID: user, Status: status, Candidates: candidates, Limit: db.CatalogResolutionLimit, Truncated: truncated}
		payload, err := json.Marshal(want)
		if err != nil {
			t.Fatal(err)
		}
		if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Content-Type") != "application/json" || w.Body.String() != string(payload)+"\n" {
			t.Errorf("resolution want %s, got %d %s", payload, w.Code, w.Body)
		}
		return w
	}
	add := func(t *testing.T, user, recording uuid.UUID, id int64) *httptest.ResponseRecorder {
		t.Helper()
		return request(t, user, http.MethodPost, path(recording)+"/membership", fmt.Sprintf(`{"trackId":%d}`, id))
	}
	refused := func(t *testing.T, w *httptest.ResponseRecorder, status int, code string) {
		t.Helper()
		if w.Code != status || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Content-Type") != "application/json" || w.Body.String() != fmt.Sprintf("{\"code\":%q}\n", code) {
			t.Errorf("membership want %d %s, got %d %s", status, code, w.Code, w.Body)
		}
	}
	members := func(t *testing.T, id int64) string {
		t.Helper()
		var rows string
		if err := database.QueryRow(`SELECT COALESCE(jsonb_agg(to_jsonb(ul) ORDER BY user_id),'[]') FROM user_library ul WHERE track_id=$1`, id).Scan(&rows); err != nil {
			t.Fatal(err)
		}
		return rows
	}

	t.Run("private_only_is_absent_but_owned_library_is_unchanged", func(t *testing.T) {
		recording := uuid.New()
		empty := []db.CatalogTrackCandidate{}
		before := make(map[uuid.UUID]string)
		for _, a := range accounts {
			before[a.id] = read(t, a.id, recording, "missing", false, empty).Body.String()
		}
		id := seedPrivate(t, recording, true)
		exec(t, `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, owner, id)
		for _, a := range accounts {
			t.Run(a.name, func(t *testing.T) {
				if after := read(t, a.id, recording, "missing", false, empty); after.Body.String() != before[a.id] {
					t.Error("private-only recording changed the no-row response")
				}
				w := request(t, a.id, http.MethodGet, "/api/v1/library?fields=id,title,mb_recording_id", "")
				var page LibraryListResponse
				if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || w.Code != http.StatusOK {
					t.Fatalf("Library read failed: %d %s", w.Code, w.Body)
				}
				if a.id == owner {
					if page.Total != 1 || len(page.Tracks) != 1 || page.Tracks[0].ID != id || page.Tracks[0].Title != title || page.Tracks[0].MBRecordingID == nil || *page.Tracks[0].MBRecordingID != recording {
						t.Fatalf("owned private row missing from Library: %s", w.Body)
					}
				} else if page.Total != 0 || len(page.Tracks) != 0 {
					t.Fatalf("foreign Library unexpectedly contains fixture: %s", w.Body)
				}
			})
		}
	})

	t.Run("selected_private_numeric_id_matches_missing", func(t *testing.T) {
		recording, existingRecording := uuid.New(), uuid.New()
		fresh, existing := seedPrivate(t, recording, true), seedPrivate(t, existingRecording, true)
		exec(t, `INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, owner, existing)
		original := members(t, existing)
		for _, a := range accounts {
			t.Run(a.name, func(t *testing.T) {
				for _, target := range []struct {
					recording uuid.UUID
					id        int64
				}{{recording, fresh}, {existingRecording, existing}, {recording, existing}} {
					unknown := add(t, a.id, target.recording, 1<<62)
					refused(t, unknown, http.StatusNotFound, "TARGET_UNAVAILABLE")
					result := add(t, a.id, target.recording, target.id)
					refused(t, result, http.StatusNotFound, "TARGET_UNAVAILABLE")
					if result.Body.String() != unknown.Body.String() {
						t.Errorf("private numeric target %d differed from unknown", target.id)
					}
				}
			})
		}
		if got := members(t, fresh); got != "[]" {
			t.Errorf("private Catalog Add created a membership: %s", got)
		}
		if got := members(t, existing); got != original {
			t.Errorf("private Catalog Add modified an existing membership: %s", got)
		}
	})

	t.Run("private_sibling_is_not_competing_evidence", func(t *testing.T) {
		recording := uuid.New()
		shared := seedShared(t, recording, true)
		expected := []db.CatalogTrackCandidate{verified(shared, false)}
		before := make(map[uuid.UUID]string)
		for _, a := range accounts {
			before[a.id] = read(t, a.id, recording, "stored_unowned", false, expected).Body.String()
		}
		private := seedPrivate(t, recording, true)
		for _, a := range accounts {
			t.Run(a.name, func(t *testing.T) {
				if w := read(t, a.id, recording, "stored_unowned", false, expected); w.Body.String() != before[a.id] {
					t.Error("private sibling changed unique resolution")
				}
				w := add(t, a.id, recording, shared)
				var ack db.CatalogMembership
				if err := json.Unmarshal(w.Body.Bytes(), &ack); err != nil || w.Code != http.StatusOK || ack.TrackID != shared || ack.UserID != a.id || ack.RecordingMBID != recording.String() || ack.Status != "member" || ack.AddedAt.IsZero() {
					t.Fatalf("private sibling blocked/altered shared Add: %d %s", w.Code, w.Body)
				}
				var added time.Time
				if err := database.QueryRow(`SELECT added_at FROM user_library WHERE user_id=$1 AND track_id=$2`, a.id, shared).Scan(&added); err != nil || !added.Equal(ack.AddedAt) {
					t.Fatalf("shared membership not persisted with acknowledged time: %v %v", added, err)
				}
				if again := add(t, a.id, recording, shared); again.Code != http.StatusOK || again.Body.String() != w.Body.String() {
					t.Errorf("shared replay changed acknowledgement: %d %s", again.Code, again.Body)
				}
				read(t, a.id, recording, "owned", false, []db.CatalogTrackCandidate{verified(shared, true)})
			})
		}
		if got := members(t, private); got != "[]" {
			t.Errorf("shared Add attached private sibling: %s", got)
		}
		competitor := seedShared(t, recording, false)
		for _, a := range accounts {
			read(t, a.id, recording, "ambiguous", false, []db.CatalogTrackCandidate{verified(shared, true), {TrackID: competitor}})
			refused(t, add(t, a.id, recording, shared), http.StatusConflict, "NEEDS_REVIEW")
		}
	})

	t.Run("older_private_rows_do_not_consume_limit_or_truncation", func(t *testing.T) {
		recording, unrelated := uuid.New(), uuid.New()
		// Insert private rows first so a post-LIMIT filter (even one probing one
		// extra row) cannot return the actual eligible window.
		for i := 0; i <= db.CatalogResolutionLimit; i++ {
			seedPrivate(t, unrelated, i%2 == 0)
		}
		want := make([]db.CatalogTrackCandidate, 0, db.CatalogResolutionLimit)
		for i := 0; i < db.CatalogResolutionLimit; i++ {
			want = append(want, verified(seedShared(t, recording, true), false))
		}
		before := make(map[uuid.UUID]string)
		for _, a := range accounts {
			before[a.id] = read(t, a.id, recording, "ambiguous", false, want).Body.String()
		}
		exec(t, `UPDATE tracks SET mb_recording_id=$1 WHERE mb_recording_id=$2`, recording, unrelated)
		for _, a := range accounts {
			if after := read(t, a.id, recording, "ambiguous", false, want); after.Body.String() != before[a.id] {
				t.Errorf("private rows displaced shared candidates for %s", a.name)
			}
		}
		seedShared(t, recording, true)
		for _, a := range accounts {
			read(t, a.id, recording, "ambiguous", true, want)
		}
		// Check the repository window as well as its HTTP status and projection.
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		got, truncated, err := tracks.ResolveCatalogRecording(ctx, recording, owner)
		if err != nil || !truncated || !reflect.DeepEqual(got, want) {
			t.Errorf("repository candidate window: got %v truncated=%v err=%v; want %v", got, truncated, err, want)
		}
	})
}
