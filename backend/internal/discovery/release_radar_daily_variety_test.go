package discovery

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/radartest"
)

func varietyDailyService(t *testing.T, f *varietyCatalog) (*RadarService, *dailyClock) {
	t.Helper()
	store := dailyFixtureStore(t)
	c := newDailyClock()
	store.now = c.now
	s := NewDailyRadarService(f, f, f, store.database)
	s.daily = store
	return s, c
}
func varietyDailyRead(t *testing.T, s *RadarService, u uuid.UUID, c *dailyClock, policy string) RadarPage {
	t.Helper()
	p, e := s.ReadWithOrdering(context.Background(), u, c.now(), policy)
	if e != nil {
		t.Fatal(e)
	}
	return p
}
func dailyRowIdentity(t *testing.T, s *RadarService, u uuid.UUID) string {
	t.Helper()
	var raw string
	if e := s.daily.database.QueryRow(`SELECT row_to_json(d)::text FROM release_radar_daily d WHERE user_id=$1 AND source=$2`, u, radarDailyNamespace).Scan(&raw); e != nil {
		t.Fatal(e)
	}
	return raw
}
func TestRadarDailyVarietyLegacySnapshotsMembershipAndRestartKeepQuota(t *testing.T) {
	for _, enriched := range []bool{false, true} {
		t.Run(map[bool]string{false: "unenriched", true: "enriched"}[enriched], func(t *testing.T) {
			rows := varietyRows("A1/A/X/1", "A2/A/X/2", "B1/B/Y/3", "C1/C/Z/4")
			if !enriched {
				for i := range rows {
					rows[i].ReleaseGroupMBID = ""
					rows[i].ReleaseID = ""
				}
			}
			f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: rows}}
			s, c := varietyDailyService(t, f)
			u := radartest.RadarAccount(t, s.daily.database)
			first := varietyDailyRead(t, s, u, c, RadarPolicy)
			before := dailyRowIdentity(t, s, u)
			store := peerDailyStore(t, s)
			peer := NewDailyRadarService(f, f, f, store.database)
			peer.daily = store
			c.advance(23 * time.Hour)
			p := varietyDailyRead(t, peer, u, c, RadarVarietyPolicy)
			if !reflect.DeepEqual(varietyTitles(p), []string{"A1", "B1", "C1", "A2"}) || !p.GeneratedAt.Equal(first.GeneratedAt) || p.EffectiveWindows != first.EffectiveWindows {
				t.Fatalf("bad warm projection %+v", p)
			}
			if dailyRowIdentity(t, peer, u) != before || f.count() != 1 || peer.daily.namespace != radarDailyNamespace {
				t.Fatal("v2 changed durable admission or attempted enrichment")
			}
			f.owned = map[uuid.UUID]map[uuid.UUID]bool{u: {uuid.MustParse(rows[0].MBID): true}}
			owned := varietyDailyRead(t, peer, u, c, RadarVarietyPolicy)
			if !reflect.DeepEqual(varietyTitles(owned), []string{"A2", "B1", "C1"}) || *owned.Coverage.OwnedExcluded != 1 {
				t.Fatal("owned representative left phantom exposure")
			}
			f.owned[u] = map[uuid.UUID]bool{uuid.MustParse(rows[1].MBID): true}
			removed := varietyDailyRead(t, peer, u, c, RadarVarietyPolicy)
			if !reflect.DeepEqual(varietyTitles(removed), []string{"A1", "B1", "C1"}) {
				t.Fatal("warm remove/add ignored")
			}
			f.owned[u] = map[uuid.UUID]bool{}
			legacy := varietyDailyRead(t, peer, u, c, RadarPolicy)
			if !reflect.DeepEqual(varietyTitles(legacy), []string{"A1", "A2", "B1", "C1"}) || legacy.PolicyVersion != RadarPolicy {
				t.Fatal("v2 mutated raw legacy order")
			}
			f.membershipFail = true
			unavailable := varietyDailyRead(t, peer, u, c, RadarVarietyPolicy)
			if len(unavailable.Items) != 0 || !containsRadar(unavailable.Coverage.Reasons, "membership_unavailable") {
				t.Fatal("unknown membership admitted candidates")
			}
			if f.count() != 1 || dailyRowIdentity(t, s, u) != before {
				t.Fatal("membership projection spent quota or rewrote cache")
			}
		})
	}
}
func TestRadarDailyVarietyPendingFailureCancellationAndRecovery(t *testing.T) {
	f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: varietyRows("A1/A/X", "A2/A/X", "B1/B/Y")}}
	s, c := varietyDailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	first := varietyDailyRead(t, s, u, c, RadarVarietyPolicy)
	good := dailyStoredData(t, s, u)
	c.advance(24 * time.Hour)
	entered, release := make(chan struct{}, 1), make(chan struct{})
	f.block = release
	f.entered = entered
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, e := s.ReadWithOrdering(ctx, u, c.now(), RadarVarietyPolicy); done <- e }()
	released := false
	defer func() {
		if !released {
			close(release)
			<-done
		}
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("refresh never reached provider")
	}
	store := peerDailyStore(t, s)
	peer := NewDailyRadarService(f, f, f, store.database)
	peer.daily = store
	for _, policy := range []string{RadarPolicy, RadarVarietyPolicy} {
		p := varietyDailyRead(t, peer, u, c, policy)
		if !p.GeneratedAt.Equal(first.GeneratedAt) || len(p.Items) != 3 || f.count() != 2 {
			t.Fatal("pending response refreshed or relabelled last-good")
		}
	}
	cancel()
	close(release)
	released = true
	if e := <-done; e == nil {
		t.Fatal("canceled v2 publisher succeeded")
	}
	for _, policy := range []string{RadarPolicy, RadarVarietyPolicy} {
		if _, e := peer.ReadWithOrdering(context.Background(), u, c.now(), policy); e == nil {
			t.Fatal("failed attempt hidden or retried")
		}
	}
	if f.count() != 2 || dailyStoredData(t, s, u) != good {
		t.Fatal("failed v2 attempt lost last-good or retried")
	}
	c.advance(24 * time.Hour)
	f.block = nil
	f.entered = nil
	recovered := varietyDailyRead(t, peer, u, c, RadarVarietyPolicy)
	if f.count() != 3 || !recovered.GeneratedAt.Equal(c.now()) {
		t.Fatal("natural next admission cannot recover")
	}
}
func TestRadarDailyVarietyTwoHundredMetadataCandidatesWithinBound(t *testing.T) {
	rows := dailyRows(200)
	for i := range rows {
		rows[i].Title = strings.Repeat("T", 240)
		rows[i].Artist = strings.Repeat("A", 240)
		rows[i].ReleaseGroupMBID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
		rows[i].ReleaseID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
		rows[i].ArtistCredits = nil
		for _, a := range []byte{'A', 'B', 'C', 'D', 'E'} {
			rows[i].ArtistCredits = append(rows[i].ArtistCredits, musicbrainz.ArtistCredit{MBID: varietyArtist(a).String()})
		}
	}
	f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: rows}}
	s, c := varietyDailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	p := varietyDailyRead(t, s, u, c, RadarVarietyPolicy)
	raw := dailyStoredData(t, s, u)
	var stored RadarPage
	if json.Unmarshal([]byte(raw), &stored) != nil || stored.PolicyVersion != RadarPolicy || len(stored.Items) != 200 || len(raw) > radarCacheBytes || len(p.Items) != 20 || f.count() != 2 {
		t.Fatalf("metadata pool bound/retention failure size=%d count=%d calls=%d", len(raw), len(stored.Items), f.count())
	}
	t.Logf("stored 200 metadata candidates with five seed credits and 240-byte title/artist: %d bytes", len(raw))
	before := dailyRowIdentity(t, s, u)
	varietyDailyRead(t, s, u, c, RadarPolicy)
	if before != dailyRowIdentity(t, s, u) || f.count() != 2 {
		t.Fatal("legacy warm visit changed v2-admitted raw cache")
	}
	// JSON escaping can exceed the byte budget despite valid 240-byte strings.
	// Refuse the whole refresh safely, preserving all last-good candidates and
	// consuming only its naturally admitted attempt, not dropping metadata/rows.
	c.advance(24 * time.Hour)
	for i := range f.rows {
		f.rows[i].Title = strings.Repeat("<", 240)
		f.rows[i].Artist = strings.Repeat("&", 240)
	}
	if _, e := s.ReadWithOrdering(context.Background(), u, c.now(), RadarVarietyPolicy); e == nil {
		t.Fatal("oversized 200-pool publication accepted")
	}
	if f.count() != 4 || dailyStoredData(t, s, u) != raw {
		t.Fatal("oversized publication lost last-good")
	}
	if _, e := s.ReadWithOrdering(context.Background(), u, c.now(), RadarPolicy); e == nil || f.count() != 4 {
		t.Fatal("size refusal bypassed quota")
	}
}

func TestRadarDailyRejectsReorderedLegacyRawBeforeWire(t *testing.T) {
	f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: varietyRows("A1/A/X", "A2/A/X", "B1/B/Y")}}
	s, c := varietyDailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	varietyDailyRead(t, s, u, c, RadarPolicy)
	var raw RadarPage
	if e := json.Unmarshal([]byte(dailyStoredData(t, s, u)), &raw); e != nil {
		t.Fatal(e)
	}
	raw.Items[0], raw.Items[1] = raw.Items[1], raw.Items[0]
	b, e := json.Marshal(raw)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.daily.database.Exec(`UPDATE release_radar_daily SET candidates=$3 WHERE user_id=$1 AND source=$2`, u, radarDailyNamespace, string(b)); e != nil {
		t.Fatal(e)
	}
	before := dailyRowIdentity(t, s, u)
	for _, policy := range []string{RadarPolicy, RadarVarietyPolicy} {
		if _, e = s.ReadWithOrdering(context.Background(), u, c.now(), policy); e == nil {
			t.Fatalf("reordered v1 raw admitted to %s producer", policy)
		}
	}
	if f.count() != 1 || dailyRowIdentity(t, s, u) != before {
		t.Fatal("bad cache caused provider retry or rewrite")
	}
}
