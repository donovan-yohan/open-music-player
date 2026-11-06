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
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type membershipFixture struct {
	database  *db.DB
	router    *Router
	user      uuid.UUID
	recording uuid.UUID
	track     int64
	token     func(uuid.UUID) string
}

func newMembershipFixture(t *testing.T) *membershipFixture {
	t.Helper()
	database, _ := newPlaylistMixTestDB(t)
	user := seedMixUser(t, database, "member@example.test")
	recording := uuid.New()
	var track int64
	if err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified,metadata_json,metadata_provenance) VALUES ('membership','Membership',$1,true,'{}','{}') RETURNING id`, recording).Scan(&track); err != nil {
		t.Fatal(err)
	}
	secret := uuid.NewString() + uuid.NewString()
	service := auth.NewService(nil, nil, secret)
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, LibraryHandlers: NewLibraryHandlers(db.NewTrackRepository(database), db.NewLibraryRepository(database))})
	token := func(u uuid.UUID) string {
		s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: u.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour))}}).SignedString([]byte(secret))
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	return &membershipFixture{database, router, user, recording, track, token}
}
func (f *membershipFixture) request(ctx context.Context, recording, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/catalog/recordings/"+recording+"/membership", strings.NewReader(body)).WithContext(ctx)
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, r)
	return w
}
func (f *membershipFixture) add() *httptest.ResponseRecorder {
	return f.request(context.Background(), f.recording.String(), fmt.Sprintf(`{"trackId":%d}`, f.track), f.token(f.user))
}
func TestCatalogMembershipStored(t *testing.T) {
	f := newMembershipFixture(t)
	w := f.add()
	if w.Code != 200 {
		t.Fatalf("authenticated stored membership status=%d want=200 body=%s", w.Code, w.Body.String())
	}
	var wire map[string]json.RawMessage
	if err := json.Unmarshal(w.Body.Bytes(), &wire); err != nil || len(wire) != 5 {
		t.Fatalf("unexpected acknowledgement projection: %s", w.Body.String())
	}
	if w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal("membership may be cached")
	}
	var body struct {
		UserID    uuid.UUID `json:"userId"`
		Recording string    `json:"recordingMbid"`
		Track     int64     `json:"trackId"`
		Status    string    `json:"status"`
		AddedAt   time.Time `json:"addedAt"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.UserID != f.user || body.Recording != f.recording.String() || body.Track != f.track || body.Status != "member" || body.AddedAt.IsZero() {
		t.Fatalf("wrong acknowledgement %s", w.Body.String())
	}
	var added time.Time
	if err := f.database.QueryRow(`SELECT added_at FROM user_library WHERE user_id=$1 AND track_id=$2`, f.user, f.track).Scan(&added); err != nil || !added.Equal(body.AddedAt) {
		t.Fatalf("exact membership readback: %v %v", added, err)
	}
}

func membershipSnapshot(t *testing.T, database *db.DB) map[string]string {
	t.Helper()
	rows, err := database.Query(`SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename<>'user_library' ORDER BY tablename`)
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
		var value string
		if err := database.QueryRow(`SELECT COALESCE(jsonb_agg(v ORDER BY v::text),'[]'::jsonb)::text FROM (SELECT to_jsonb(t) v FROM ` + pq.QuoteIdentifier(name) + ` t) q`).Scan(&value); err != nil {
			t.Fatal(err)
		}
		result[name] = value
	}
	return result
}
func TestCatalogMembershipRetryAccountsAndNoSideEffects(t *testing.T) {
	f := newMembershipFixture(t)
	other := seedMixUser(t, f.database, "independent@example.test")
	before := membershipSnapshot(t, f.database)
	// Actual HTTP server commits the write, then discards its acknowledgement by
	// hijacking/closing the connection. The client sees transport failure, not 200.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := httptest.NewRecorder()
		f.router.ServeHTTP(recorder, r)
		if recorder.Code != 200 {
			t.Errorf("lost-ACK producer status %d", recorder.Code)
		}
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		_ = conn.Close()
	}))
	defer server.Close()
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, server.URL+"/api/v1/catalog/recordings/"+f.recording.String()+"/membership", strings.NewReader(fmt.Sprintf(`{"trackId":%d}`, f.track)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+f.token(f.user))
	req.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(req)
	if err == nil {
		response.Body.Close()
		t.Fatal("expected lost HTTP acknowledgement")
	}
	// Reconcile exact identity/account through existing authenticated resolver.
	read := httptest.NewRequest(http.MethodGet, "/api/v1/catalog/recordings/"+f.recording.String()+"/resolution", nil)
	read.Header.Set("Authorization", "Bearer "+f.token(f.user))
	rw := httptest.NewRecorder()
	f.router.ServeHTTP(rw, read)
	var resolved CatalogResolutionResponse
	if err := json.Unmarshal(rw.Body.Bytes(), &resolved); err != nil {
		t.Fatal(err)
	}
	if rw.Code != 200 || resolved.UserID != f.user || resolved.RecordingMBID != f.recording.String() || resolved.Status != "owned" || len(resolved.Candidates) != 1 || resolved.Candidates[0].TrackID != f.track || !resolved.Candidates[0].InLibrary || !resolved.Candidates[0].MBVerified {
		t.Fatalf("exact resolver readback: %s", rw.Body.String())
	}
	var original time.Time
	if err := f.database.QueryRow(`SELECT added_at FROM user_library WHERE user_id=$1 AND track_id=$2`, f.user, f.track).Scan(&original); err != nil {
		t.Fatal(err)
	}
	results := make(chan *httptest.ResponseRecorder, 12)
	for i := 0; i < 12; i++ {
		go func() { results <- f.add() }()
	}
	for i := 0; i < 12; i++ {
		w := <-results
		var got db.CatalogMembership
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if w.Code != 200 || !got.AddedAt.Equal(original) || got.UserID != f.user || got.TrackID != f.track || got.RecordingMBID != f.recording.String() {
			t.Fatalf("retry changed membership: %s", w.Body.String())
		}
	}
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("duplicate/other-owner mutation %d %v", count, err)
	}
	w := f.request(context.Background(), f.recording.String(), fmt.Sprintf(`{"trackId":%d}`, f.track), f.token(other))
	var otherResult db.CatalogMembership
	if err := json.Unmarshal(w.Body.Bytes(), &otherResult); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || otherResult.UserID != other {
		t.Fatalf("independent account %s", w.Body.String())
	}
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 2 {
		t.Fatal("independent membership missing", err)
	}
	var unchanged time.Time
	if err := f.database.QueryRow(`SELECT added_at FROM user_library WHERE user_id=$1 AND track_id=$2`, f.user, f.track).Scan(&unchanged); err != nil || !unchanged.Equal(original) {
		t.Fatal("other owner mutated")
	}
	if !reflect.DeepEqual(before, membershipSnapshot(t, f.database)) {
		t.Fatal("metadata/jobs/other public tables changed")
	}
	// The ordinary existing Library reader also returns the same canonical identity.
	read = httptest.NewRequest(http.MethodGet, "/api/v1/library", nil)
	read.Header.Set("Authorization", "Bearer "+f.token(f.user))
	rw = httptest.NewRecorder()
	f.router.ServeHTTP(rw, read)
	var library LibraryListResponse
	if err := json.Unmarshal(rw.Body.Bytes(), &library); err != nil {
		t.Fatal(err)
	}
	if rw.Code != 200 || len(library.Tracks) != 1 || library.Tracks[0].ID != f.track || library.Tracks[0].MBRecordingID == nil || *library.Tracks[0].MBRecordingID != f.recording {
		t.Fatalf("Library readback: %s", rw.Body.String())
	}
}
func TestCatalogMembershipRefusals(t *testing.T) {
	f := newMembershipFixture(t)
	before := membershipSnapshot(t, f.database)
	body := fmt.Sprintf(`{"trackId":%d}`, f.track)
	cases := []struct {
		name, recording, body, token string
		code                         int
	}{
		{"missing_auth", f.recording.String(), body, "", 401},
		{"bad_auth", f.recording.String(), body, "invalid", 401},
		{"nil_auth", f.recording.String(), body, f.token(uuid.Nil), 401},
		{"nil_recording", uuid.Nil.String(), body, f.token(f.user), 400},
		{"uppercase", strings.ToUpper(f.recording.String()), body, f.token(f.user), 400},
		{"compact", strings.ReplaceAll(f.recording.String(), "-", ""), body, f.token(f.user), 400},
	}
	for _, bad := range []string{`{}`, `null`, `[]`, `{"trackId":null}`, `{"trackId":0}`, `{"trackId":-1}`, `{"trackId":9223372036854775808}`, `{"trackId":"1"}`, `{"trackId":1.0}`, `{"trackId":1,"trackId":1}`, `{"TrackId":1}`, `{"trackId":1,"userId":"override"}`, `{"trackId":1} {}`, `{"trackId":1,"padding":"` + strings.Repeat("x", 2000) + `"}`} {
		cases = append(cases, struct {
			name, recording, body, token string
			code                         int
		}{"bad_body", f.recording.String(), bad, f.token(f.user), 400})
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := f.request(context.Background(), c.recording, c.body, c.token)
			if w.Code != c.code {
				t.Fatalf("status %d want %d: %s", w.Code, c.code, w.Body.String())
			}
		})
	}
	for _, query := range []string{"?userId=" + uuid.NewString(), "?trackId=2"} {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/catalog/recordings/"+f.recording.String()+"/membership"+query, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+f.token(f.user))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		f.router.ServeHTTP(w, req)
		if w.Code != 400 {
			t.Fatalf("query override accepted %d", w.Code)
		}
	}
	if !reflect.DeepEqual(before, membershipSnapshot(t, f.database)) {
		t.Fatal("refusals changed public tables")
	}
	check := func(recording uuid.UUID, track int64, want int, code string) {
		t.Helper()
		w := f.request(context.Background(), recording.String(), fmt.Sprintf(`{"trackId":%d}`, track), f.token(f.user))
		var e map[string]string
		json.Unmarshal(w.Body.Bytes(), &e)
		if w.Code != want || e["code"] != code {
			t.Fatalf("refusal status=%d body=%s", w.Code, w.Body.String())
		}
	}
	check(f.recording, f.track+1000, 404, "TARGET_UNAVAILABLE")
	check(uuid.New(), f.track, 409, "TARGET_MISMATCH")
	if _, err := f.database.Exec(`UPDATE tracks SET mb_verified=false WHERE id=$1`, f.track); err != nil {
		t.Fatal(err)
	}
	check(f.recording, f.track, 409, "NEEDS_REVIEW")
	if _, err := f.database.Exec(`UPDATE tracks SET mb_verified=true WHERE id=$1`, f.track); err != nil {
		t.Fatal(err)
	}
	if _, err := f.database.Exec(`INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified) VALUES ('ambiguous','same',$1,false)`, f.recording); err != nil {
		t.Fatal(err)
	}
	check(f.recording, f.track, 409, "NEEDS_REVIEW")
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 0 {
		t.Fatal("refusal wrote membership", err)
	}
	// Unwired capability refuses valid work, while input/owner guards still precede DB admission.
	f.router.libraryHandlers = nil
	f.router = NewRouterWithConfig(&RouterConfig{AuthHandlers: f.router.authHandlers, AuthService: f.router.authService})
	if w := f.add(); w.Code != 503 {
		t.Fatalf("unsupported %d", w.Code)
	}
	if w := f.request(context.Background(), f.recording.String(), `{"trackId":1,"owner":"bad"}`, f.token(f.user)); w.Code != 400 {
		t.Fatal("owner validation after unavailable")
	}
}

// Gate only fixture destination INSERTs, not production control flow. PostgreSQL
// exposes both the destination advisory wait and the competing UPDATE row wait.
func membershipInsertGate(t *testing.T, f *membershipFixture) func() {
	t.Helper()
	conn, err := f.database.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = conn.ExecContext(context.Background(), `SELECT pg_advisory_lock(782391)`); err != nil {
		t.Fatal(err)
	}
	if _, err = f.database.Exec(`CREATE OR REPLACE FUNCTION membership_test_gate() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_advisory_xact_lock(782391); RETURN NEW; END $$; CREATE TRIGGER membership_test_gate BEFORE INSERT ON user_library FOR EACH ROW EXECUTE FUNCTION membership_test_gate()`); err != nil {
		t.Fatal(err)
	}
	released := false
	release := func() {
		if !released {
			released = true
			_, err := conn.ExecContext(context.Background(), `SELECT pg_advisory_unlock(782391)`)
			if err != nil {
				t.Error(err)
			}
			conn.Close()
		}
	}
	t.Cleanup(func() {
		release()
		if _, err := f.database.Exec(`DROP TRIGGER IF EXISTS membership_test_gate ON user_library; DROP FUNCTION IF EXISTS membership_test_gate()`); err != nil {
			t.Error(err)
		}
	})
	return release
}
func waitMembershipInsert(t *testing.T, f *membershipFixture) int {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		var pid int
		err := f.database.QueryRow(`SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND query LIKE 'INSERT INTO user_library(user_id,track_id)%' AND wait_event_type='Lock' AND wait_event='advisory' LIMIT 1`).Scan(&pid)
		if err == nil {
			t.Logf("destination INSERT pid=%d positively waiting on PostgreSQL advisory lock", pid)
			return pid
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("destination INSERT did not reach observed lock wait")
	return 0
}
func TestCatalogMembershipRelinkFence(t *testing.T) {
	for _, mutation := range []string{`mb_recording_id='11111111-1111-4111-8111-111111111111'`, `mb_verified=false`} {
		t.Run(mutation, func(t *testing.T) {
			f := newMembershipFixture(t)
			release := membershipInsertGate(t, f)
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- f.add() }()
			insertPID := waitMembershipInsert(t, f)
			conn, err := f.database.Conn(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			var updatePID int
			if err := conn.QueryRowContext(context.Background(), `SELECT pg_backend_pid()`).Scan(&updatePID); err != nil {
				t.Fatal(err)
			}
			updated := make(chan error, 1)
			go func() {
				_, err := conn.ExecContext(context.Background(), `UPDATE tracks SET `+mutation+` WHERE id=$1`, f.track)
				updated <- err
			}()
			deadline := time.Now().Add(4 * time.Second)
			blocked := false
			for time.Now().Before(deadline) {
				select {
				case err := <-updated:
					t.Fatalf("identity UPDATE escaped selected-track fence before membership commit: %v", err)
				default:
				}
				var waits bool
				if err := f.database.QueryRow(`SELECT $1=ANY(pg_blocking_pids($2))`, insertPID, updatePID).Scan(&waits); err != nil {
					t.Fatal(err)
				}
				if waits {
					blocked = true
					t.Logf("competing identity UPDATE pid=%d blocked by membership transaction pid=%d", updatePID, insertPID)
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if !blocked {
				t.Fatal("no PostgreSQL selected-track UPDATE conflict observed")
			}
			release()
			select {
			case w := <-done:
				if w.Code != 200 {
					t.Fatalf("commit status %d: %s", w.Code, w.Body.String())
				}
			case <-time.After(4 * time.Second):
				t.Fatal("membership did not complete")
			}
			select {
			case err := <-updated:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(4 * time.Second):
				t.Fatal("identity UPDATE did not resume after commit")
			}
			if w := f.add(); w.Code != 409 {
				t.Fatalf("changed evidence retry acknowledged: %s", w.Body.String())
			}
		})
	}
}
func TestCatalogMembershipCancellationRollsBack(t *testing.T) {
	f := newMembershipFixture(t)
	release := membershipInsertGate(t, f)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		done <- f.request(ctx, f.recording.String(), fmt.Sprintf(`{"trackId":%d}`, f.track), f.token(f.user))
	}()
	waitMembershipInsert(t, f)
	cancel()
	select {
	case w := <-done:
		if w.Code == 200 {
			t.Fatal("canceled transaction acknowledged")
		}
	case <-time.After(4 * time.Second):
		t.Fatal("cancel did not retire write")
	}
	release()
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 0 {
		t.Fatal("canceled membership persisted", err)
	}
	if _, err := f.database.Exec(`UPDATE tracks SET mb_verified=false WHERE id=$1`, f.track); err != nil {
		t.Fatal("canceled transaction retained track lock", err)
	}
}
func TestCatalogMembershipPreAdmissionRelink(t *testing.T) {
	f := newMembershipFixture(t)
	tx, err := f.database.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE tracks SET mb_recording_id=$1 WHERE id=$2`, uuid.New(), f.track); err != nil {
		t.Fatal(err)
	}
	var pid int
	if err := tx.QueryRow(`SELECT pg_backend_pid()`).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- f.add() }()
	deadline := time.Now().Add(4 * time.Second)
	waited := false
	for time.Now().Before(deadline) {
		var yes bool
		if err := f.database.QueryRow(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE query LIKE 'SELECT mb_recording_id, mb_verified FROM tracks%' AND $1=ANY(pg_blocking_pids(pid)))`, pid).Scan(&yes); err != nil {
			t.Fatal(err)
		}
		if yes {
			waited = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !waited {
		t.Fatal("no pre-admission selected-track wait observed")
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case w := <-done:
		if w.Code != 409 || !strings.Contains(w.Body.String(), "TARGET_MISMATCH") {
			t.Fatalf("relinked candidate accepted %s", w.Body.String())
		}
	case <-time.After(4 * time.Second):
		t.Fatal("request did not complete")
	}
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 0 {
		t.Fatal("pre-admission relink wrote membership", err)
	}
}

func TestCatalogMembershipConcurrentEvidenceSnapshot(t *testing.T) {
	f := newMembershipFixture(t)
	release := membershipInsertGate(t, f)
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- f.add() }()
	waitMembershipInsert(t, f)
	// The uniqueness/admission snapshot already ran. No global predicate lock is
	// claimed: independent track writes still proceed while this INSERT is held.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := f.database.ExecContext(ctx, `INSERT INTO tracks(identity_hash,title,mb_recording_id,mb_verified) VALUES ('later-evidence','later',$1,true)`, f.recording); err != nil {
		t.Fatal("independent track write blocked", err)
	}
	release()
	select {
	case w := <-done:
		if w.Code != 200 {
			t.Fatalf("admission snapshot changed %s", w.Body.String())
		}
	case <-time.After(4 * time.Second):
		t.Fatal("membership stalled")
	}
	// A later read is deliberately truthful about the newer ambiguous state; it
	// must not choose the already-owned candidate or pretend membership is a grant.
	candidates, _, err := db.NewTrackRepository(f.database).ResolveCatalogRecording(context.Background(), f.recording, f.user)
	if err != nil || len(candidates) != 2 || !candidates[0].InLibrary || candidates[1].InLibrary {
		t.Fatal("new evidence readback", candidates, err)
	}
	if w := f.add(); w.Code != 409 || !strings.Contains(w.Body.String(), "NEEDS_REVIEW") {
		t.Fatalf("ambiguity preferred owned %s", w.Body.String())
	}
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 1 {
		t.Fatal("ambiguity changed membership", err)
	}
}
func TestCatalogMembershipBoundedBodyAndRepositoryValidation(t *testing.T) {
	f := newMembershipFixture(t)
	w := f.request(context.Background(), f.recording.String(), fmt.Sprintf(`{"trackId":%d}`, f.track)+strings.Repeat(" ", 1100), f.token(f.user))
	if w.Code != 400 {
		t.Fatal("valid JSON with oversized trailing whitespace admitted", w.Code)
	}
	for _, c := range []struct {
		user, recording uuid.UUID
		track           int64
	}{{uuid.Nil, f.recording, f.track}, {f.user, uuid.Nil, f.track}, {f.user, f.recording, 0}, {f.user, f.recording, -1}} {
		// Nil repository positively proves validation happens before DB admission.
		var repo *db.LibraryRepository
		if _, err := repo.AddCatalogMembership(context.Background(), c.user, c.recording, c.track); err == nil {
			t.Fatal("invalid repository input admitted")
		}
	}
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library`).Scan(&count); err != nil || count != 0 {
		t.Fatal("oversize body wrote membership", err)
	}
}
