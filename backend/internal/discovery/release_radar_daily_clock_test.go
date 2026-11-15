package discovery

import (
	"context"
	"testing"

	"github.com/openmusicplayer/backend/internal/radartest"
)

// Deterministic SQL fixture scheduling exercises the production shared-clock
// reader. It does not claim that wall-clock time elapsed or use the request time
// to decide whether publication is still possible.
func TestRadarDailyWarmPendingDatabaseClockRefusesExpiredLease(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	old := dailyRead(t, s, u, c)
	before := dailyStoredData(t, s, u)
	s.daily.now = nil
	if _, e := s.daily.database.Exec(`UPDATE release_radar_daily SET attempted_at=clock_timestamp()-INTERVAL '24 hours' WHERE user_id=$1 AND source=$2`, u, s.daily.namespace); e != nil {
		t.Fatal(e)
	}
	state, e := s.daily.begin(context.Background(), u)
	if e != nil || !state.admitted {
		t.Fatal("shared-clock pending attempt missing", e)
	}
	p, e := s.Read(context.Background(), u, c.now())
	if e != nil || !p.GeneratedAt.Equal(old.GeneratedAt) || p.EffectiveWindows != old.EffectiveWindows {
		t.Fatal("production-clock live pending control failed", e)
	}
	for _, stamp := range []string{"clock_timestamp()-INTERVAL '21 seconds'", "clock_timestamp()+INTERVAL '1 hour'"} {
		if _, e := s.daily.database.Exec(`UPDATE release_radar_daily SET attempted_at=`+stamp+` WHERE user_id=$1 AND source=$2`, u, s.daily.namespace); e != nil {
			t.Fatal(e)
		}
		if _, e := s.Read(context.Background(), u, c.now()); e == nil {
			t.Error("nonlive production-clock lease replayed success", stamp)
		}
	}
	if f.count() != 1 || dailyStoredData(t, s, u) != before {
		t.Fatal("shared-clock refusal retried or changed last-good")
	}
}
