package jam

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"github.com/openmusicplayer/backend/internal/db"
)

func TestJamRepositoryFixtureProtection(t *testing.T) {
	assertFixtureProtection(t, func(t *testing.T) { testRepository(t) }, "JAM_TEST_DSN", "")
}

// assertFixtureProtection runs the real helper in a child process because its
// expected t.Fatal must not fail this parent test. The marker case makes all
// child transactions read-only: a misplaced guard cannot create a schema first.
func assertFixtureProtection(t *testing.T, fixture func(*testing.T), dsnEnv, redisEnv string) {
	t.Helper()
	if os.Getenv("OMP_FIXTURE_PROTECTION_CHILD") == "1" {
		fixture(t)
		t.Fatal("fixture accepted a protected database")
	}
	run := func(t *testing.T, dsn, marker string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		// Select only the top-level test in the child, not this subtest suffix.
		name := strings.Split(t.Name(), "/")[0]
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^"+name+"$", "-test.v")
		cmd.Env = append(os.Environ(), "OMP_FIXTURE_PROTECTION_CHILD=1", dsnEnv+"="+dsn)
		if redisEnv != "" {
			cmd.Env = append(cmd.Env, redisEnv+"=127.0.0.1:1")
		}
		output, err := cmd.CombinedOutput()
		if ctx.Err() != nil {
			t.Fatal("fixture protection child timed out")
		}
		if err == nil || !strings.Contains(string(output), db.ErrProtectedDatabase.Error()) || !strings.Contains(string(output), marker) {
			t.Fatalf("fixture did not refuse at the protection guard: %v\n%s", err, output)
		}
	}
	t.Run("protected_port_before_connection", func(t *testing.T) {
		// Malformed key/value syntax makes sql.Open itself fail without dialing.
		// The port guard must refuse first, even before that parse error.
		run(t, "host=192.0.2.1 port="+db.ProtectedDSNPorts()[0]+" invalid", "protected host port")
	})
	t.Run("root_marker_before_schema", func(t *testing.T) {
		dsn := os.Getenv(dsnEnv)
		if dsn == "" {
			t.Skip("disposable PostgreSQL DSN required")
		}
		if err := db.CheckDSNNotProtected(dsn); err != nil {
			t.Fatal(err)
		}
		raw, err := sql.Open("postgres", dsn)
		if err != nil {
			t.Fatal("open protection fixture database")
		}
		defer raw.Close()
		if err := (&db.DB{DB: raw}).CheckDatabaseNotProtected(context.Background()); err != nil {
			t.Fatal(err)
		}
		// The existing DSN's search path owns the real marker seen by the
		// helper's root connection. Its new private schema must not mask it.
		schema := "fixture_protection_" + strings.ReplaceAll(uuid.NewString(), "-", "")
		if _, err := raw.Exec(`CREATE SCHEMA ` + schema); err != nil {
			t.Fatal(err)
		}
		defer func() {
			if _, err := raw.Exec(`DROP SCHEMA ` + schema + ` CASCADE`); err != nil {
				t.Error(err)
			}
		}()
		if _, err := raw.Exec(`CREATE TABLE ` + schema + `.omp_environment(id integer PRIMARY KEY, name text NOT NULL, protected boolean NOT NULL, updated_at timestamptz NOT NULL); INSERT INTO ` + schema + `.omp_environment VALUES(1,'fixture-protection-test',true,NOW())`); err != nil {
			t.Fatal(err)
		}
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatal("protection fixture requires a URL DSN")
		}
		q := u.Query()
		q.Set("search_path", schema+",public")
		q.Set("default_transaction_read_only", "on")
		u.RawQuery = q.Encode()
		// Read-only startup prevents any CREATE SCHEMA from succeeding. The
		// required marker refusal (rather than a read-only SQL error) proves
		// the check happens before the first attempted schema mutation.
		run(t, u.String(), "fixture-protection-test")
		var protected bool
		if err := raw.QueryRow(`SELECT protected FROM ` + schema + `.omp_environment WHERE id=1`).Scan(&protected); err != nil || !protected {
			t.Fatalf("refused helper changed root marker: protected=%v err=%v", protected, err)
		}
	})
}

// Each run owns only a fresh schema in an explicitly supplied disposable DB.
func testRepository(t *testing.T) (*Repository, Owner, Proof) {
	t.Helper()
	dsn := os.Getenv("JAM_TEST_DSN")
	if dsn == "" {
		t.Skip("JAM_TEST_DSN required (disposable PostgreSQL only)")
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
	schema := "jam_test_" + uuid.NewString()[:8]
	if _, e = admin.Exec(`CREATE SCHEMA ` + schema); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { admin.Exec(`DROP SCHEMA ` + schema + ` CASCADE`) })
	db, e := sql.Open("postgres", dsn+"&search_path="+schema)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	_, e = db.Exec(`CREATE TABLE users(id uuid PRIMARY KEY,connect_auth_generation bigint NOT NULL DEFAULT 0); CREATE TABLE tracks(id bigint PRIMARY KEY,title text,artist text,duration_ms integer); CREATE TABLE user_library(user_id uuid REFERENCES users(id),track_id bigint REFERENCES tracks(id),PRIMARY KEY(user_id,track_id));` + testJamSchema)
	if e != nil {
		t.Fatal(e)
	}
	o := Owner{UserID: uuid.New(), Generation: 0}
	p := Proof{HostDeviceID: uuid.New(), LeaseID: uuid.New(), WriterSecret: NewSecret()}
	if _, e = db.Exec(`INSERT INTO users(id) VALUES($1);`, o.UserID); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(`INSERT INTO tracks VALUES(1,'Selected track','Fixture artist',180000),(2,'Not owned','Other',1000)`); e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(`INSERT INTO user_library VALUES($1,1)`, o.UserID); e != nil {
		t.Fatal(e)
	}
	return NewRepository(db), o, p
}
func createFixture(t *testing.T, r *Repository, o Owner, p Proof) uuid.UUID {
	t.Helper()
	id := uuid.New()
	_, e := r.Create(context.Background(), o, CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}})
	if e != nil {
		t.Fatal(e)
	}
	return id
}
func TestPostgresCreateIsOwnedBoundedAndIdempotent(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	id := uuid.New()
	in := CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}}
	first, e := r.Create(ctx, o, in)
	if e != nil {
		t.Fatal(e)
	}
	again, e := r.Create(ctx, o, in)
	if e != nil || again.Version != first.Version {
		t.Fatalf("retry=%+v %v", again, e)
	}
	if _, e = r.Create(ctx, o, CreateInput{JamID: uuid.New(), Proof: p, TrackIDs: []int64{1}}); e != ErrConflict {
		t.Fatalf("one live: %v", e)
	}
	if len(first.Catalog) != 1 || first.Catalog[0].CatalogItemID == uuid.Nil {
		t.Fatal("opaque catalog missing")
	}
	if _, e = r.DB.Exec(`UPDATE users SET connect_auth_generation=1 WHERE id=$1`, o.UserID); e != nil {
		t.Fatal(e)
	}
	if _, e = r.HostSnapshot(ctx, o, id); e != ErrDenied {
		t.Fatalf("old generation=%v", e)
	}
	if _, e = r.Create(ctx, Owner{UserID: o.UserID, Generation: 1}, CreateInput{JamID: uuid.New(), Proof: p, TrackIDs: []int64{2}}); e != ErrDenied {
		t.Fatalf("unowned=%v", e)
	}
	_ = fmt.Sprint(time.Second)
}

func TestPostgresGuestFlowRetriesAndReceipts(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	id := createFixture(t, r, o, p)
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	in := JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Guest", MemberSecret: NewSecret()}
	joined, e := r.Join(ctx, id, in)
	if e != nil {
		t.Fatal(e)
	}
	again, e := r.Join(ctx, id, in)
	if e != nil || again.MemberID != joined.MemberID || !again.MemberExpiresAt.Equal(joined.MemberExpiresAt) {
		t.Fatalf("join retry: %+v %v", again, e)
	}
	req := RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[0].CatalogItemID, ExpectedVersion: joined.Snapshot.Version}
	q, e := r.AddRequest(ctx, id, in.MemberSecret, req)
	if e != nil || q.Status != "pending" {
		t.Fatalf("request=%+v %v", q, e)
	}
	q2, e := r.AddRequest(ctx, id, in.MemberSecret, req)
	if e != nil || q2 != q {
		t.Fatalf("request retry=%+v %v", q2, e)
	}
	view, e := r.HostSnapshot(ctx, o, id)
	if e != nil {
		t.Fatal(e)
	}
	decision := DecisionInput{ExpectedVersion: view.Version, Status: "queued"}
	if _, e = r.Decide(ctx, o, id, p, req.RequestID, decision); e != ErrInvalid {
		t.Fatalf("queued without local receipt=%v", e)
	}
	decision.Receipt = &AdmissionReceipt{RequestID: req.RequestID, SessionID: "local-session", OccurrenceID: "local-occurrence"}
	if _, e = r.Decide(ctx, o, id, p, req.RequestID, decision); e != nil {
		t.Fatal(e)
	}
	pub, e := r.GuestSnapshot(ctx, id, in.MemberSecret)
	if e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(pub)
	if strings.Contains(string(b), "trackId") || strings.Contains(string(b), "Hash") || strings.Contains(string(b), o.UserID.String()) || strings.Contains(string(b), in.MemberSecret) {
		t.Fatalf("leaked public projection=%s", b)
	}
	if pub.Requests[0].Status != "queued" {
		t.Fatal("receipt not visible")
	}
	if e = r.Close(ctx, o, id); e != nil {
		t.Fatal(e)
	}
	if _, e = r.GuestSnapshot(ctx, id, in.MemberSecret); e != ErrDenied {
		t.Fatalf("closed capability=%v", e)
	}
}
func TestPostgresConcurrentLastMemberSlot(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	id := createFixture(t, r, o, p)
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	for i := 0; i < 15; i++ {
		if _, e = r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Guest", MemberSecret: NewSecret()}); e != nil {
			t.Fatal(e)
		}
	}
	start := make(chan struct{})
	results := make(chan error, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, e := r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Guest", MemberSecret: NewSecret()})
			results <- e
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	accepted := 0
	for e := range results {
		if e == nil {
			accepted++
		} else if e != ErrCapacity {
			t.Fatal(e)
		}
	}
	if accepted != 1 {
		t.Fatalf("last member accepted=%d", accepted)
	}
	v, e := r.HostSnapshot(ctx, o, id)
	if e != nil || v.MemberCount != 16 {
		t.Fatalf("member cap=%d %v", v.MemberCount, e)
	}
}
func TestPostgresSequencesExpiryAndGeneration(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	now := time.Now().UTC()
	r.Now = func() time.Time { return now }
	id := createFixture(t, r, o, p)
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	secret := NewSecret()
	joined, e := r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "A", MemberSecret: secret})
	if e != nil {
		t.Fatal(e)
	}
	hb := HeartbeatInput{Proof: p, HostSequence: 1}
	if _, e = r.Heartbeat(ctx, o, id, hb); e != nil {
		t.Fatal(e)
	}
	expiry, e := r.MemberHeartbeat(ctx, id, secret, 1)
	if e != nil {
		t.Fatal(e)
	}
	now = now.Add(20 * time.Second)
	expiry2, e := r.MemberHeartbeat(ctx, id, secret, 1)
	if e != nil || !expiry.Equal(expiry2) {
		t.Fatalf("duplicate member renewed: %v", e)
	}
	before, _ := r.HostSnapshot(ctx, o, id)
	if _, e = r.Heartbeat(ctx, o, id, hb); e != nil {
		t.Fatal(e)
	}
	after, _ := r.HostSnapshot(ctx, o, id)
	if !before.HostSeenAt.Equal(after.HostSeenAt) {
		t.Fatal("duplicate host renewed")
	}
	now = now.Add(11 * time.Second)
	snap, e := r.GuestSnapshot(ctx, id, secret)
	if e != nil || snap.State != "hostOffline" {
		t.Fatalf("offline=%+v %v", snap, e)
	}
	if _, e = r.AddRequest(ctx, id, secret, RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[0].CatalogItemID, ExpectedVersion: 1}); e != ErrDenied {
		t.Fatalf("offline request=%v", e)
	}
	hb.HostSequence = 2
	if _, e = r.Heartbeat(ctx, o, id, hb); e != nil {
		t.Fatal(e)
	}
	if _, e = r.DB.Exec(`UPDATE users SET connect_auth_generation=1 WHERE id=$1`, o.UserID); e != nil {
		t.Fatal(e)
	}
	if _, e = r.GuestSnapshot(ctx, id, secret); e != ErrDenied {
		t.Fatalf("logout guest=%v", e)
	}
}
func TestPostgresRequestRacesAndLifetimeCap(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	id := createFixture(t, r, o, p)
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	secret := NewSecret()
	joined, e := r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "A", MemberSecret: secret})
	if e != nil {
		t.Fatal(e)
	}
	in := RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[0].CatalogItemID, ExpectedVersion: 1}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	start := make(chan struct{})
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; _, e := r.AddRequest(ctx, id, secret, in); results <- e }()
	}
	close(start)
	wg.Wait()
	close(results)
	for e := range results {
		if e != nil {
			t.Fatal(e)
		}
	}
	snap, e := r.GuestSnapshot(ctx, id, secret)
	if e != nil || len(snap.Requests) != 1 || snap.Version != 2 {
		t.Fatalf("duplicate raced: %+v %v", snap, e)
	}
	for len(snap.Requests) < 49 {
		in.RequestID = uuid.New()
		in.ExpectedVersion = snap.Version
		if _, e = r.AddRequest(ctx, id, secret, in); e != nil {
			t.Fatal(e)
		}
		snap, e = r.GuestSnapshot(ctx, id, secret)
		if e != nil {
			t.Fatal(e)
		}
	}
	results = make(chan error, 2)
	start = make(chan struct{})
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			q := RequestInput{RequestID: uuid.New(), CatalogItemID: in.CatalogItemID, ExpectedVersion: snap.Version}
			_, e := r.AddRequest(ctx, id, secret, q)
			results <- e
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	ok, conflict := 0, 0
	for e := range results {
		if e == nil {
			ok++
		} else if e == ErrConflict {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if ok != 1 || conflict != 1 {
		t.Fatalf("last request %d %d", ok, conflict)
	}
	snap, e = r.GuestSnapshot(ctx, id, secret)
	if e != nil || len(snap.Requests) != 50 {
		t.Fatal("lifetime cap")
	}
	in.RequestID = uuid.New()
	in.ExpectedVersion = snap.Version
	if _, e = r.AddRequest(ctx, id, secret, in); e != ErrCapacity {
		t.Fatalf("request 51=%v", e)
	}
}

func TestPostgresLogoutLockSerializesGuestWrites(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	id := createFixture(t, r, o, p)
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	in := JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "A", MemberSecret: NewSecret()}
	tx, e := r.DB.BeginTx(ctx, nil)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`UPDATE users SET connect_auth_generation=1 WHERE id=$1`, o.UserID); e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() { _, e := r.Join(ctx, id, in); done <- e }()
	select {
	case e := <-done:
		t.Fatalf("guest did not wait for owner lock: %v", e)
	case <-time.After(80 * time.Millisecond):
	}
	if e = tx.Commit(); e != nil {
		t.Fatal(e)
	}
	if e = <-done; e != ErrDenied {
		t.Fatalf("generation race=%v", e)
	}
	var count int
	if e = r.DB.QueryRow(`SELECT jsonb_array_length(state->'members') FROM jams WHERE id=$1`, id).Scan(&count); e != nil || count != 0 {
		t.Fatalf("revoked write persisted=%d %v", count, e)
	}
}
func TestPostgresOwnershipRevokedAndTokenHashesOnly(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	id := createFixture(t, r, o, p)
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	secret := NewSecret()
	joined, e := r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "A", MemberSecret: secret})
	if e != nil {
		t.Fatal(e)
	}
	q := RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[0].CatalogItemID, ExpectedVersion: 1}
	if _, e = r.AddRequest(ctx, id, secret, q); e != nil {
		t.Fatal(e)
	}
	var stored string
	if e = r.DB.QueryRow(`SELECT state::text FROM jams WHERE id=$1`, id).Scan(&stored); e != nil {
		t.Fatal(e)
	}
	for _, s := range []string{invite.JoinToken, secret, p.WriterSecret} {
		if strings.Contains(stored, s) {
			t.Fatal("plaintext token at rest")
		}
	}
	if _, e = r.DB.Exec(`DELETE FROM user_library WHERE user_id=$1`, o.UserID); e != nil {
		t.Fatal(e)
	}
	if _, e = r.Decide(ctx, o, id, p, q.RequestID, DecisionInput{ExpectedVersion: 2, Status: "queued", Receipt: &AdmissionReceipt{RequestID: q.RequestID, SessionID: "s", OccurrenceID: "o"}}); e != ErrDenied {
		t.Fatalf("removed ownership=%v", e)
	}
	view, e := r.HostSnapshot(ctx, o, id)
	if e != nil || view.Requests[0].Status != "pending" {
		t.Fatal("failed approval mutated")
	}
	if _, e = r.DB.Exec(`UPDATE jams SET expires_at=now()-interval '1 second' WHERE id=$1`, id); e != nil {
		t.Fatal(e)
	}
	if _, e = r.Heartbeat(ctx, o, id, HeartbeatInput{Proof: p, HostSequence: 100}); e != ErrDenied {
		t.Fatalf("expired revive=%v", e)
	}
	if _, e = r.GuestSnapshot(ctx, id, secret); e != ErrDenied {
		t.Fatalf("expired guest=%v", e)
	}
}
func TestPostgresConcurrentCreateAndJoinHistoryBound(t *testing.T) {
	r, o, p := testRepository(t)
	ctx := context.Background()
	results := make(chan error, 2)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, e := r.Create(ctx, o, CreateInput{JamID: uuid.New(), Proof: p, TrackIDs: []int64{1}})
			results <- e
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	accepted := 0
	for e := range results {
		if e == nil {
			accepted++
		} else if e != ErrConflict {
			t.Fatal(e)
		}
	}
	if accepted != 1 {
		t.Fatalf("live create=%d", accepted)
	}
	var id uuid.UUID
	if e := r.DB.QueryRow(`SELECT id FROM jams`).Scan(&id); e != nil {
		t.Fatal(e)
	}
	invite, e := r.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	for i := 0; i < MaxJoins; i++ {
		secret := NewSecret()
		if _, e = r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "A", MemberSecret: secret}); e != nil {
			t.Fatal(e)
		}
		if e = r.Leave(ctx, id, secret); e != nil {
			t.Fatal(e)
		}
	}
	if _, e = r.Join(ctx, id, JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "A", MemberSecret: NewSecret()}); e != ErrCapacity {
		t.Fatalf("join tombstone bound=%v", e)
	}
}

func TestPostgresPurgeOnlyRetiredAfterRetention(t *testing.T) {
	r, o, p := testRepository(t)
	id := createFixture(t, r, o, p)
	ctx := context.Background()
	if n, e := r.PurgeRetired(ctx); e != nil || n != 0 {
		t.Fatalf("purged live=%d %v", n, e)
	}
	if _, e := r.DB.Exec(`UPDATE jams SET expires_at=now()-interval '25 hours' WHERE id=$1`, id); e != nil {
		t.Fatal(e)
	}
	if n, e := r.PurgeRetired(ctx); e != nil || n != 1 {
		t.Fatalf("purge expired=%d %v", n, e)
	}
}

// This is an isolated test helper, NOT another migration runner. Parent copies
// the authoritative schema into internal/db/db.go exactly once.
const testJamSchema = `CREATE TABLE jams (
 id uuid PRIMARY KEY,owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 owner_auth_generation bigint NOT NULL,created_at timestamptz NOT NULL,
 expires_at timestamptz NOT NULL,closed_at timestamptz,
 version bigint NOT NULL CHECK(version>=1),state jsonb NOT NULL CHECK(octet_length(state::text)<=65536));
 CREATE INDEX jams_owner_idx ON jams(owner_user_id);`
