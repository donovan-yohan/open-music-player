package discovery

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/radartest"
)

func TestRadarDailyWarmRetirementKeepsLastGoodAndConsumesAttempt(t *testing.T) {
	for _, mode := range []string{"cancel", "lease", "publication-pool-loss"} {
		t.Run(mode, func(t *testing.T) {
			f := &dailyCatalog{rows: dailyRows(2)}
			s, c := dailyService(t, f)
			u := radartest.RadarAccount(t, s.daily.database)
			f.owned = map[uuid.UUID]map[uuid.UUID]bool{u: {}}
			old := dailyRead(t, s, u, c)
			before := dailyStoredData(t, s, u)
			c.advance(radarDailyInterval)
			entered, release := make(chan struct{}, 1), make(chan struct{})
			f.entered, f.block = entered, release
			original := s.daily
			if mode == "publication-pool-loss" {
				s.daily = peerDailyStore(t, s)
			}
			peer := NewDailyRadarService(f, f, f, original.database)
			peer.daily = original
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { _, e := s.Read(ctx, u, c.now()); done <- e }()
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				close(release)
				<-done
				t.Fatal("provider not entered")
			}
			f.mu.Lock()
			f.owned[u][uuid.MustParse(f.rows[0].MBID)] = true
			f.mu.Unlock()
			pending, e := peer.Read(context.Background(), u, c.now())
			if e != nil || len(pending.Items) != 1 || !pending.GeneratedAt.Equal(old.GeneratedAt) || pending.EffectiveWindows != old.EffectiveWindows {
				close(release)
				<-done
				t.Fatal("live pending warm membership/date control failed", e)
			}
			switch mode {
			case "cancel":
				cancel()
			case "lease":
				c.advance(radarPublicationLease)
			case "publication-pool-loss":
				s.daily.database.Close()
			}
			close(release)
			if e := <-done; e == nil {
				t.Fatal("retired leader succeeded")
			}
			s.daily = original
			if mode == "cancel" {
				var phase string
				if e := original.database.QueryRow(`SELECT phase FROM release_radar_daily WHERE user_id=$1 AND source=$2`, u, original.namespace).Scan(&phase); e != nil || phase != "failed" {
					t.Fatal("known canceled attempt was not safely recorded", phase, e)
				}
				if _, e := peer.Read(context.Background(), u, c.now()); e == nil {
					t.Fatal("recorded cancellation replayed inside lease")
				}
			}
			c.advance(radarPublicationLease)
			if _, e := peer.Read(context.Background(), u, c.now()); e == nil {
				t.Error("retired warm attempt bypassed failure owner")
			}
			if dailyStoredData(t, s, u) != before || f.count() != 2 {
				t.Fatal("retirement changed last-good or retried provider")
			}
		})
	}
}

func TestRadarDailyWarmLeaseExactBoundaryAndRequestClock(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	old := dailyRead(t, s, u, c)
	before := dailyStoredData(t, s, u)
	c.advance(radarDailyInterval)
	state, e := s.daily.begin(context.Background(), u)
	if e != nil || !state.admitted {
		t.Fatal("warm attempt not admitted", e)
	}
	peer := NewDailyRadarService(f, f, f, s.daily.database)
	peer.daily = peerDailyStore(t, s)
	c.advance(radarPublicationLease - time.Millisecond)
	p, e := peer.Read(context.Background(), u, c.now().Add(72*time.Hour))
	if e != nil || !p.GeneratedAt.Equal(old.GeneratedAt) || p.EffectiveWindows != old.EffectiveWindows {
		t.Fatal("live lease refused using request clock", e)
	}
	c.advance(time.Millisecond)
	if _, e := peer.Read(context.Background(), u, old.GeneratedAt); e == nil {
		t.Error("exact lease boundary served success using stale request clock")
	}
	if e := s.daily.finish(context.Background(), u, state.token, "ready", before); e == nil {
		t.Error("exact lease boundary published")
	}
	if dailyStoredData(t, s, u) != before || f.count() != 1 {
		t.Fatal("boundary mutated last-good or retried")
	}
}

func TestRadarDailyFailureFinalizationRetainsExactAuthority(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	dailyRead(t, s, u, c)
	before := dailyStoredData(t, s, u)
	c.advance(radarDailyInterval)
	old, e := s.daily.begin(context.Background(), u)
	if e != nil || !old.admitted {
		t.Fatal("old attempt missing", e)
	}
	c.advance(radarDailyInterval)
	next, e := s.daily.begin(context.Background(), u)
	if e != nil || !next.admitted {
		t.Fatal("successor attempt missing", e)
	}
	wrongSource := *s.daily
	wrongSource.namespace += ":other"
	for _, tc := range []struct {
		name        string
		store       *radarDailyStore
		user, token uuid.UUID
	}{
		{"superseded", s.daily, u, old.token},
		{"token", s.daily, u, uuid.New()},
		{"account", s.daily, radartest.RadarAccount(t, s.daily.database), next.token},
		{"source", &wrongSource, u, next.token},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if e := tc.store.finish(context.Background(), tc.user, tc.token, "failed", ""); e == nil {
				t.Fatal("foreign failure finalization accepted")
			}
		})
	}
	state, e := s.daily.begin(context.Background(), u)
	if e != nil || state.admitted || state.phase != "pending" || state.data != before {
		t.Fatal("stale finalization altered successor", e)
	}
	if e := s.daily.finish(context.Background(), u, next.token, "ready", before); e != nil {
		t.Fatal("current owner cannot publish", e)
	}
	if e := s.daily.finish(context.Background(), u, next.token, "failed", ""); e == nil {
		t.Fatal("terminal phase overwritten")
	}
	if p := dailyRead(t, s, u, c); len(p.Items) != 1 || dailyStoredData(t, s, u) != before || f.count() != 1 {
		t.Fatal("ready control damaged")
	}
}
