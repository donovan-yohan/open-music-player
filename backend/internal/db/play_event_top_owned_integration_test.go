package db

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestOwnedTopTracksMembershipSnapshotAgainstPostgres(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	tracks := NewTrackRepository(database)
	repo := NewPlayEventRepository(database)
	owner := seedPlayUser(t, database, "snapshot-top@example.test")
	a := seedPlayTrack(t, tracks, ctx, "Snapshot artist", "Before")
	b := seedPlayTrack(t, tracks, ctx, "Snapshot artist", "After")
	at := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)
	insertPlayAt(t, database, owner, a, at)
	insertPlayAt(t, database, owner, b, at)
	if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, owner, a); err != nil {
		t.Fatal(err)
	}
	tx, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, owner, a); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, owner, b); err != nil {
		t.Fatal(err)
	}
	// A separate pool connection reads while the membership writer is open.
	// Uncommitted removal/addition cannot split eligibility from projection.
	check := func(want int64) {
		t.Helper()
		readCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		rows, err := repo.OwnedTopTracks(readCtx, owner, 30, 25)
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) != 1 || rows[0].ID != want || !rows[0].InLibrary || rows[0].PlayCount != 1 || !rows[0].LastPlayedAt.Equal(at) {
			t.Fatalf("snapshot rows=%v, want only owned id %d with its unchanged listen", topTrackSummary(rows), want)
		}
	}
	check(a)
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	check(b)
}

func TestOwnedTopTracksAgainstPostgres(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	tracks := NewTrackRepository(database)
	repo := NewPlayEventRepository(database)
	owner := seedPlayUser(t, database, "owned-top@example.test")
	other := seedPlayUser(t, database, "other-top@example.test")
	at := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Hour)
	owned := make([]int64, 30)
	counts := make(map[int64]int)
	times := make(map[int64]time.Time)
	var firstRemoved int64
	for i := 0; i < 150; i++ {
		id := seedPlayTrack(t, tracks, ctx, "Top artist", fmt.Sprintf("Top %03d", i))
		member, count, last := other, 4, at
		if i == 0 {
			firstRemoved = id
		}
		if i >= 120 {
			j := i - 120
			member, count = owner, 1
			owned[j] = id
			switch j {
			case 0:
				count, last = 3, at.Add(-48*time.Hour)
			case 1:
				count, last = 2, at.Add(time.Hour)
			case 2:
				count = 2
			}
			counts[id], times[id] = count, last
		}
		if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, member, id); err != nil {
			t.Fatal(err)
		}
		for n := 0; n < count; n++ {
			insertPlayAt(t, database, owner, id, last)
		}
	}
	// None of these current memberships has an eligible owner listen.
	for _, kind := range []string{"old", "skip", "never", "foreign"} {
		id := seedPlayTrack(t, tracks, ctx, "Top artist", kind)
		if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, owner, id); err != nil {
			t.Fatal(err)
		}
		switch kind {
		case "old":
			insertPlayAt(t, database, owner, id, at.Add(-31*24*time.Hour))
		case "skip":
			insertSkipAt(t, database, owner, id, at.Add(time.Hour))
		case "foreign":
			insertPlayAt(t, database, other, id, at.Add(time.Hour))
		}
	}
	insertSkipAt(t, database, owner, owned[29], at.Add(time.Hour))
	for n := 0; n < 10; n++ {
		insertPlayAt(t, database, other, owned[29], at.Add(time.Hour))
	}
	insertPlayAt(t, database, other, firstRemoved, at)
	events := func() string {
		t.Helper()
		var snapshot string
		if err := database.QueryRowContext(ctx, `SELECT COALESCE(jsonb_agg(to_jsonb(pe) ORDER BY id), '[]')::text FROM play_events pe`).Scan(&snapshot); err != nil {
			t.Fatal(err)
		}
		return snapshot
	}
	before := events()
	want := []int64{owned[0], owned[1], owned[2]}
	for i := 29; i >= 3; i-- {
		want = append(want, owned[i])
	}
	check := func(rows []TopTrack, ids []int64) {
		t.Helper()
		if len(rows) != len(ids) {
			t.Fatalf("owned rows = %d, want %d (removed tracks must not consume quota)", len(rows), len(ids))
		}
		for i, row := range rows {
			id := ids[i]
			if row.ID != id || !row.InLibrary || row.PlayCount != counts[id] || !row.LastPlayedAt.Equal(times[id]) {
				t.Fatalf("owned row[%d] = id %d count %d inLibrary %v at %s, want id %d count %d at %s", i, row.ID, row.PlayCount, row.InLibrary, row.LastPlayedAt, id, counts[id], times[id])
			}
		}
	}
	rows, err := repo.OwnedTopTracks(ctx, owner, 30, 25)
	if err != nil {
		t.Fatal(err)
	}
	check(rows, want[:25])
	rows, err = repo.OwnedTopTracks(ctx, owner, 30, 100)
	if err != nil {
		t.Fatal(err)
	}
	check(rows, want) // fewer than the requested quota, no filler
	rows, err = repo.OwnedTopTracks(ctx, owner, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	check(rows, want[:20])
	rows, err = repo.OwnedTopTracks(ctx, owner, 1, 100)
	if err != nil {
		t.Fatal(err)
	}
	check(rows, want[1:])
	rows, err = repo.TopTracks(ctx, owner, 30, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 100 {
		t.Fatalf("legacy maximum rows = %d, want 100", len(rows))
	}
	for _, row := range rows {
		if row.InLibrary || row.PlayCount != 4 {
			t.Fatalf("legacy history lost higher-ranked removed track: %+v", row)
		}
	}
	rows, err = repo.OwnedTopTracks(ctx, other, 30, 25)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != firstRemoved || rows[0].PlayCount != 1 || !rows[0].InLibrary {
		t.Fatalf("other account = %v, want its own single owned listen", topTrackSummary(rows))
	}
	// Current membership, not ownership at play time or a cached earlier read.
	library := NewLibraryRepository(database)
	if err := library.RemoveTrackFromLibrary(ctx, owner, owned[0]); err != nil {
		t.Fatal(err)
	}
	rows, err = repo.OwnedTopTracks(ctx, owner, 30, 25)
	if err != nil {
		t.Fatal(err)
	}
	check(rows, want[1:26])
	if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, owner, owned[0]); err != nil {
		t.Fatal(err)
	}
	rows, err = repo.OwnedTopTracks(ctx, owner, 30, 25)
	if err != nil {
		t.Fatal(err)
	}
	check(rows, want[:25])
	if after := events(); after != before {
		t.Fatal("Top reads or membership changes mutated factual play events")
	}

	// The existing hard maximum applies to the eligible set as well.
	for i := 0; i < 100; i++ {
		id := seedPlayTrack(t, tracks, ctx, "Top artist", fmt.Sprintf("Additional %03d", i))
		if _, err := database.ExecContext(ctx, `INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, owner, id); err != nil {
			t.Fatal(err)
		}
		insertPlayAt(t, database, owner, id, at.Add(-time.Minute))
	}
	rows, err = repo.OwnedTopTracks(ctx, owner, 30, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 100 {
		t.Fatalf("owned maximum rows = %d, want 100 from 130 eligible", len(rows))
	}
	seen := make(map[int64]bool)
	for _, row := range rows {
		if !row.InLibrary || seen[row.ID] {
			t.Fatalf("ineligible or duplicate owned row %d", row.ID)
		}
		seen[row.ID] = true
	}
}
