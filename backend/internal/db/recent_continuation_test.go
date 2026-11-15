package db

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
)

type recentPager interface {
	RecentPage(context.Context, uuid.UUID, int, int, string) ([]RecentlyPlayedTrack, string, bool, error)
}

func TestRecentContinuationCanonicalTraversalAndMutation(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	user := seedPlayUser(t, database, "recent-page@example.test")
	other := seedPlayUser(t, database, "recent-other@example.test")
	tracks := NewTrackRepository(database)
	repo := NewPlayEventRepository(database)
	pager, ok := interface{}(repo).(recentPager)
	if !ok {
		t.Fatal("recent repository does not expose revision-checked continuation")
	}
	at := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	ids := make([]int64, 0, 23)
	for i := 0; i < 23; i++ {
		// Numeric identity, not title equality, owns recency. A repeated listen is not a new slot.
		id := seedPlayTrack(t, tracks, ctx, fmt.Sprintf("Artist %d", i), "Same title")
		ids = append(ids, id)
		insertPlayAt(t, database, user, id, at.Add(time.Duration(i)*time.Minute))
		insertPlayAt(t, database, user, id, at.Add(-time.Hour))
	}
	skip := seedPlayTrack(t, tracks, ctx, "Skip only", "Same title")
	insertSkipAt(t, database, user, skip, at.Add(time.Hour))
	insertPlayAt(t, database, other, skip, at.Add(time.Hour))
	first, revision, more, err := pager.RecentPage(ctx, user, 20, 0, "")
	if err != nil || len(first) != 20 || len(revision) != 64 || !more {
		t.Fatalf("first rows=%d rev=%q more=%t err=%v", len(first), revision, more, err)
	}
	next, same, more, err := pager.RecentPage(ctx, user, 20, 20, revision)
	if err != nil || len(next) != 3 || same != revision || more {
		t.Fatalf("next rows=%d more=%t err=%v", len(next), more, err)
	}
	all := append(first, next...)
	for i, row := range all {
		if row.ID != ids[len(ids)-1-i] {
			t.Fatalf("row %d=%d", i, row.ID)
		}
	}
	// Another user's listen and our skip do not invalidate the canonical non-skip corpus.
	insertPlayAt(t, database, other, ids[0], at.Add(3*time.Hour))
	insertSkipAt(t, database, user, ids[0], at.Add(3*time.Hour))
	if _, _, _, err = pager.RecentPage(ctx, user, 20, 20, revision); err != nil {
		t.Fatal(err)
	}
	// New listen moves an old row ahead of the offset. Dedupe alone would omit its successor.
	insertPlayAt(t, database, user, ids[0], at.Add(4*time.Hour))
	if rows, _, _, err := pager.RecentPage(ctx, user, 20, 20, revision); !errors.Is(err, ErrRecentChanged) || len(rows) != 0 {
		t.Fatalf("mutation admitted rows=%d err=%v", len(rows), err)
	}
	_, newRevision, _, err := pager.RecentPage(ctx, user, 20, 0, "")
	if err != nil || newRevision == revision {
		t.Fatal("fresh read must replace revision", err)
	}
	// Deleting historical rows (including cascade) also changes the fingerprint.
	if _, err = database.ExecContext(ctx, `DELETE FROM play_events WHERE user_id=$1 AND track_id=$2`, user, ids[1]); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err = pager.RecentPage(ctx, user, 20, 20, newRevision); !errors.Is(err, ErrRecentChanged) {
		t.Fatal("deletion was not detected", err)
	}
}
