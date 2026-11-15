package db

import (
	"github.com/google/uuid"
	"testing"
	"time"
)

func TestRadarAccountWindowSeedsAndAnyLinkedMembership(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	a := seedPlayUser(t, database, "radar-a@example.test")
	b := seedPlayUser(t, database, "radar-b@example.test")
	now := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	since := now.AddDate(0, 0, -90)
	artist := func(n int) uuid.UUID {
		return uuid.MustParse([]string{"11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555", "66666666-6666-4666-8666-666666666666"}[n])
	}
	seed := func(ar *uuid.UUID, recording *uuid.UUID, verified bool) int64 {
		t.Helper()
		var id int64
		err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES ($1,'same title','not identity',$2,$3,$4) RETURNING id`, uuid.NewString(), ar, recording, verified).Scan(&id)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	ids := []int64{}
	for n := 0; n < 6; n++ {
		ar := artist(n)
		id := seed(&ar, nil, true)
		ids = append(ids, id)
		insertPlayAt(t, database, a, id, now.Add(-time.Duration(n+1)*time.Hour))
	}
	// More than Home's first 20 events for one artist must not hide older artist seeds.
	for i := 0; i < 30; i++ {
		insertPlayAt(t, database, a, ids[0], now.Add(-time.Duration(i)*time.Minute))
	}
	// Equal latest listens resolve by canonical artist ID, not track/title order.
	insertPlayAt(t, database, a, ids[1], now)
	unresolved := seed(nil, nil, false)
	insertPlayAt(t, database, a, unresolved, now.Add(-time.Hour))
	unverified := artist(5)
	id := seed(&unverified, nil, false)
	insertPlayAt(t, database, a, id, now.Add(-time.Minute))
	foreign := uuid.New()
	fid := seed(&foreign, nil, true)
	insertPlayAt(t, database, b, fid, now)
	insertSkipAt(t, database, a, fid, now)
	insertPlayAt(t, database, a, fid, since.Add(-time.Second))
	insertPlayAt(t, database, a, fid, now.Add(time.Second))
	recording := uuid.New()
	other := uuid.New()
	copy1 := seed(nil, &recording, false)
	copy2 := seed(nil, &recording, true)
	foreignCopy := seed(nil, &other, true)
	for _, pair := range []struct {
		user uuid.UUID
		id   int64
	}{{a, copy1}, {b, copy2}, {b, foreignCopy}, {a, unresolved}} {
		if _, err := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, pair.user, pair.id); err != nil {
			t.Fatal(err)
		}
	}
	database.SetMaxOpenConns(1)
	if _, err := database.Exec(`SET default_transaction_read_only=on`); err != nil {
		t.Fatal(err)
	}
	defer database.Exec(`SET default_transaction_read_only=off`)
	seeds, err := NewPlayEventRepository(database).RecentArtistSeeds(ctx, a, since, now, 5)
	if err != nil {
		t.Fatal(err)
	}
	if seeds.Available != 6 || len(seeds.Artists) != 5 || seeds.UnresolvedTracks != 2 || seeds.Events != 39 || seeds.UnlinkedLibraryTracks != 1 {
		t.Fatalf("wrong full-window projection %+v", seeds)
	}
	for n, id := range seeds.Artists {
		if id != artist(n) {
			t.Fatalf("wrong deterministic recency seeds %v", seeds.Artists)
		}
	}
	owned, err := NewLibraryRepository(database).OwnedRecordingIDs(ctx, a, []uuid.UUID{recording, other})
	if err != nil {
		t.Fatal(err)
	}
	if !owned[recording] || owned[other] || len(owned) != 1 {
		t.Fatalf("wrong private ANY membership %v", owned)
	}
	foreignOwned, err := NewLibraryRepository(database).OwnedRecordingIDs(ctx, b, []uuid.UUID{recording, other})
	if err != nil || len(foreignOwned) != 2 {
		t.Fatalf("wrong foreign account projection %v %v", foreignOwned, err)
	}
}
