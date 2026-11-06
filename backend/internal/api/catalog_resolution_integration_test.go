package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/search"
)

func TestCatalogResolutionMatrix(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	repo := db.NewTrackRepository(database)
	a := seedMixUser(t, database, "a@example.test")
	b := seedMixUser(t, database, "b@example.test")
	seed := func(recording uuid.UUID, verified, owned bool) int64 {
		t.Helper()
		var id int64
		err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified,storage_key,source_url,metadata_json,metadata_provenance) VALUES ($1,'Identical title',$2,$3,'private-key','https://private.invalid/source','{"private":"hidden"}','{}') RETURNING id`, uuid.NewString(), recording, verified).Scan(&id)
		if err != nil {
			t.Fatal(err)
		}
		if owned {
			if _, err := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, a, id); err != nil {
				t.Fatal(err)
			}
		}
		return id
	}
	owned, unowned, missing, review, ambiguous, mixed, large := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	ownedID := seed(owned, true, true)
	unownedID := seed(unowned, true, false)
	reviewID := seed(review, false, true)
	ambiguousIDs := []int64{seed(ambiguous, true, true), seed(ambiguous, true, false)}
	seed(mixed, true, true)
	seed(mixed, false, false)
	for i := 0; i < 25; i++ {
		seed(large, true, i%2 == 0)
	}
	// Same title/duration without an exact MBID is never a fallback.
	seed(uuid.New(), true, true)
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	service := auth.NewService(nil, nil, hex.EncodeToString(secret))
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, SearchHandlers: search.NewHandlers(repo), LibraryHandlers: NewLibraryHandlers(repo, db.NewLibraryRepository(database))})
	token := func(user uuid.UUID) string {
		t.Helper()
		s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(hex.EncodeToString(secret)))
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	request := func(path, bearer, method string) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	path := func(id string) string { return "/api/v1/catalog/recordings/" + id + "/resolution" }
	// Snapshot every public table, not only membership counts.
	snapshot := func() map[string]string {
		t.Helper()
		rows, err := database.Query(`SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename`)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var names []string
		for rows.Next() {
			var s string
			if err := rows.Scan(&s); err != nil {
				t.Fatal(err)
			}
			names = append(names, s)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}

		result := map[string]string{}
		for _, name := range names {
			var s string
			err := database.QueryRow(`SELECT COALESCE(jsonb_agg(v ORDER BY v::text),'[]'::jsonb)::text FROM (SELECT to_jsonb(t) v FROM ` + pq.QuoteIdentifier(name) + ` t) q`).Scan(&s)
			if err != nil {
				t.Fatal(err)
			}
			result[name] = s
		}
		return result
	}
	before := snapshot()
	// Every production request must also succeed under PostgreSQL read-only admission.
	database.SetMaxOpenConns(1)
	if _, err := database.Exec(`SET default_transaction_read_only=on`); err != nil {
		t.Fatal(err)
	}
	defer database.Exec(`SET default_transaction_read_only=off`)
	cases := []struct {
		name      string
		id        uuid.UUID
		user      uuid.UUID
		status    string
		ids       []int64
		verified  bool
		member    bool
		truncated bool
	}{
		{"owned", owned, a, "owned", []int64{ownedID}, true, true, false},
		{"different_account", owned, b, "stored_unowned", []int64{ownedID}, true, false, false},
		{"stored_unowned", unowned, a, "stored_unowned", []int64{unownedID}, true, false, false},
		{"missing", missing, a, "missing", nil, false, false, false},
		{"unverified_owned", review, a, "needs_review", []int64{reviewID}, false, true, false},
		{"unverified_other_account", review, b, "needs_review", []int64{reviewID}, false, false, false},
		{"verified_ambiguity", ambiguous, a, "ambiguous", ambiguousIDs, true, false, false},
		{"mixed_evidence", mixed, a, "ambiguous", nil, false, false, false},
		{"bounded", large, a, "ambiguous", nil, true, false, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := request(path(c.id.String()), token(c.user), http.MethodGet)
			if w.Code != 200 {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("personalized response may be cached")
			}
			var body CatalogResolutionResponse
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.UserID != c.user || body.RecordingMBID != c.id.String() || body.Status != c.status || body.Truncated != c.truncated || body.Limit != 20 {
				t.Fatalf("wrong body: %s", w.Body.String())
			}
			if body.Candidates == nil || len(body.Candidates) > 20 {
				t.Fatalf("unbounded/null candidates: %s", w.Body.String())
			}
			if c.ids != nil {
				if len(body.Candidates) != len(c.ids) {
					t.Fatal("candidate count")
				}
				for i, id := range c.ids {
					if body.Candidates[i].TrackID != id {
						t.Fatal("wrong numeric identity/order")
					}
				}
			}
			if len(body.Candidates) == 1 && (body.Candidates[0].MBVerified != c.verified || body.Candidates[0].InLibrary != c.member) {
				t.Fatal("wrong identity/membership evidence")
			}
			if c.truncated && len(body.Candidates) != 20 {
				t.Fatal("limit not filled")
			}
			var wire map[string]json.RawMessage
			json.Unmarshal(w.Body.Bytes(), &wire)
			if len(wire) != 6 {
				t.Fatal("unexpected response fields")
			}
			var candidates []map[string]json.RawMessage
			json.Unmarshal(wire["candidates"], &candidates)
			for _, candidate := range candidates {
				if len(candidate) != 3 {
					t.Fatal("private candidate fields disclosed")
				}
			}
			for _, private := range []string{"private-key", "private.invalid", "hidden", "playback", "storage", "source"} {
				if strings.Contains(w.Body.String(), private) {
					t.Fatal("private/grant data disclosed")
				}
			}
			direct, truncated, err := repo.ResolveCatalogRecording(ctx, c.id, c.user)
			if err != nil || truncated != body.Truncated || !reflect.DeepEqual(direct, body.Candidates) {
				t.Fatalf("repository/route mismatch: %v", err)
			}
		})
	}
	for _, bad := range []string{"not-a-uuid", uuid.Nil.String(), strings.ReplaceAll(owned.String(), "-", ""), strings.ToUpper(owned.String()), "urn:uuid:" + owned.String(), "%20" + owned.String(), strings.Repeat("a", 1000)} {
		if w := request(path(bad), token(a), http.MethodGet); w.Code != 400 {
			t.Fatalf("malformed %q status=%d", bad, w.Code)
		}
	}
	if w := request(path(owned.String())+"?userId="+b.String(), token(a), http.MethodGet); w.Code != 400 {
		t.Fatal("query owner override accepted")
	}
	for _, bearer := range []string{"", "invalid", token(uuid.Nil)} {
		if w := request(path(owned.String()), bearer, http.MethodGet); w.Code != 401 {
			t.Fatalf("unauthorized status=%d", w.Code)
		}
	}
	if w := request(path(owned.String()), token(a), http.MethodPost); w.Code != 405 {
		t.Fatal("mutation method admitted")
	}
	if _, _, err := repo.ResolveCatalogRecording(context.Background(), uuid.Nil, a); err == nil {
		t.Fatal("nil recording accepted")
	}
	if _, _, err := repo.ResolveCatalogRecording(context.Background(), owned, uuid.Nil); err == nil {
		t.Fatal("nil user accepted")
	}
	// Existing authenticated global search already discloses unowned numeric identity.
	searchResponse := request("/api/v1/search/recordings?q=Identical&limit=100", token(b), http.MethodGet)
	if searchResponse.Code != 200 {
		_, _, searchErr := repo.SearchRecordings(ctx, "Identical", 100, 0)
		t.Fatalf("search disclosure control failed: %d repository error: %v", searchResponse.Code, searchErr)
	}
	var searchBody struct {
		Data []struct {
			ID int64 `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(searchResponse.Body.Bytes(), &searchBody); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, track := range searchBody.Data {
		if track.ID == unownedID {
			found = true
		}
	}
	if !found {
		t.Fatal("unowned identity absent from existing search policy")
	}
	// A disabled repository makes pre-lookup rejection observable without a DB mock.
	disabled := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service})
	for _, check := range []struct {
		id   string
		want int
	}{{"not-a-uuid", 400}, {uuid.Nil.String(), 400}, {owned.String(), 503}} {
		req := httptest.NewRequest(http.MethodGet, path(check.id), nil)
		req.Header.Set("Authorization", "Bearer "+token(a))
		w := httptest.NewRecorder()
		disabled.ServeHTTP(w, req)
		if w.Code != check.want {
			t.Fatalf("pre-lookup/disabled status=%d want=%d", w.Code, check.want)
		}
	}
	if after := snapshot(); !reflect.DeepEqual(before, after) {
		t.Fatal("resolver changed database contents")
	}
}

// This test requires the explicitly selected disposable OMP_POSTGRES_TEST_DSN.
func TestCatalogResolutionOwned(t *testing.T) {
	database, _ := newPlaylistMixTestDB(t)
	user := seedMixUser(t, database, "resolver@example.test")
	recording := uuid.New()
	var trackID int64
	if err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified,storage_key,source_url) VALUES ('resolver-owned','Same title',$1,true,'private-key','https://private.invalid/source') RETURNING id`, recording).Scan(&trackID); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, user, trackID); err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	service := auth.NewService(nil, nil, hex.EncodeToString(secret))
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, LibraryHandlers: NewLibraryHandlers(db.NewTrackRepository(database), db.NewLibraryRepository(database))})
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(hex.EncodeToString(secret)))
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/api/v1/catalog/recordings/"+recording.String()+"/resolution", nil)
	request.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("resolution status = %d, want 200; body=%s", response.Code, response.Body.String())
	}
	var body struct {
		RecordingMBID string `json:"recordingMbid"`
		UserID        string `json:"userId"`
		Status        string `json:"status"`
		Candidates    []struct {
			TrackID    int64 `json:"trackId"`
			MBVerified bool  `json:"mbVerified"`
			InLibrary  bool  `json:"inLibrary"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.RecordingMBID != recording.String() || body.UserID != user.String() || body.Status != "owned" || len(body.Candidates) != 1 || body.Candidates[0].TrackID != trackID || !body.Candidates[0].MBVerified || !body.Candidates[0].InLibrary {
		t.Fatalf("incorrect resolution: %s", response.Body.String())
	}
}
