package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestCatalogMembershipRemovalFence(t *testing.T) {
	f := newMembershipFixture(t)
	original := time.Date(2020, 2, 3, 4, 5, 6, 123000000, time.UTC)
	if _, err := f.database.Exec(`INSERT INTO user_library(user_id,track_id,added_at) VALUES ($1,$2,$3)`, f.user, f.track, original); err != nil {
		t.Fatal(err)
	}
	release := membershipInsertGate(t, f)
	// AFTER STATEMENT fires even for DO NOTHING, after uniqueness processing.
	// It exposes the original two-statement gap without altering production SQL.
	if _, err := f.database.Exec(`DROP TRIGGER membership_test_gate ON user_library; CREATE TRIGGER membership_test_gate AFTER INSERT ON user_library FOR EACH STATEMENT EXECUTE FUNCTION membership_test_gate()`); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	added := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		added <- f.request(ctx, f.recording.String(), fmt.Sprintf(`{"trackId":%d}`, f.track), f.token(f.user))
	}()
	var removed chan error
	// Release and reap before fixture teardown, including on any assertion failure.
	// Cleanup errors are reported, never substituted for the primary assertion.
	defer func() {
		release()
		cancel()
		if added != nil {
			select {
			case <-added:
			case <-time.After(4 * time.Second):
				t.Error("Add cleanup did not finish")
			}
		}
		if removed != nil {
			select {
			case <-removed:
			case <-time.After(4 * time.Second):
				t.Error("Remove cleanup did not finish")
			}
		}
	}()
	insertPID := waitMembershipInsert(t, f)
	removed = make(chan error, 1)
	go func() { removed <- db.NewLibraryRepository(f.database).RemoveTrackFromLibrary(ctx, f.user, f.track) }()
	blocked, escaped := false, false
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case err := <-removed:
			removed = nil
			if err != nil {
				t.Fatal(err)
			}
			escaped = true
			t.Log("ordinary Remove committed while Add was held after uniqueness processing")
		default:
		}
		if escaped {
			break
		}
		if err := f.database.QueryRow(`SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND query LIKE '%DELETE FROM user_library%' AND $1=ANY(pg_blocking_pids(pid)))`, insertPID).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			t.Logf("ordinary Remove positively blocked by Add pid=%d until commit", insertPID)
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !blocked && !escaped {
		t.Fatal("neither removal completion nor PostgreSQL row wait observed")
	}
	release()
	var w *httptest.ResponseRecorder
	select {
	case w = <-added:
		added = nil
	case <-time.After(4 * time.Second):
		t.Fatal("Add did not complete after gate release")
	}
	if escaped {
		t.Fatalf("ordinary removal escaped Add commit fence; Add status=%d body=%s want=200 with stable added_at", w.Code, w.Body.String())
	}
	var ack db.CatalogMembership
	if err := json.Unmarshal(w.Body.Bytes(), &ack); err != nil {
		t.Fatal(err)
	}
	if w.Code != 200 || !ack.AddedAt.Equal(original) || ack.UserID != f.user || ack.TrackID != f.track || ack.RecordingMBID != f.recording.String() {
		t.Fatalf("repeat acknowledgement changed: status=%d body=%s", w.Code, w.Body.String())
	}
	select {
	case err := <-removed:
		removed = nil
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("ordinary Remove did not resume after Add commit")
	}
	var count int
	if err := f.database.QueryRow(`SELECT count(*) FROM user_library WHERE user_id=$1 AND track_id=$2`, f.user, f.track).Scan(&count); err != nil || count != 0 {
		t.Fatalf("acknowledgement became a lease: count=%d err=%v", count, err)
	}
}

func TestCatalogMembershipRepeatPreservesFullRows(t *testing.T) {
	f := newMembershipFixture(t)
	other := seedMixUser(t, f.database, "preserved@example.test")
	if _, err := f.database.Exec(`INSERT INTO user_library(user_id,track_id,added_at) VALUES ($1,$3,'2020-01-02T03:04:05.123456Z'),($2,$3,'2021-02-03T04:05:06.654321Z')`, f.user, other, f.track); err != nil {
		t.Fatal(err)
	}
	snapshot := func() string {
		t.Helper()
		var rows string
		if err := f.database.QueryRow(`SELECT jsonb_agg(to_jsonb(ul) ORDER BY user_id)::text FROM user_library ul`).Scan(&rows); err != nil {
			t.Fatal(err)
		}
		return rows
	}
	before := snapshot()
	for i := 0; i < 3; i++ {
		for _, owner := range []string{f.token(f.user), f.token(other)} {
			w := f.request(context.Background(), f.recording.String(), fmt.Sprintf(`{"trackId":%d}`, f.track), owner)
			if w.Code != 200 {
				t.Fatalf("repeat status=%d body=%s", w.Code, w.Body.String())
			}
			if after := snapshot(); after != before {
				t.Fatalf("repeat changed existing membership fields: before=%s after=%s", before, after)
			}
		}
	}
}
