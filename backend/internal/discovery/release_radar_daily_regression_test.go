package discovery

import (
	"context"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/radartest"
	"testing"
	"time"
)

// Same visit/assertion body as preserved RED; only fixture admission/account
// setup gained the real durable-store prerequisite. No provider I/O is mocked
// inside the service or admission owner.
func TestRadarDailyRepeatedVisitDoesNotRefresh(t *testing.T) {
	f := &radarMatrix{pages: map[int][]musicbrainz.TrackResult{0: {radarRecording("22222222-2222-4222-8222-222222222222", "2026-11-12")}}, total: 1}
	s := NewRadarService(f, f, f)
	configureDailyRegression(t, s)
	user := radartest.RadarAccount(t, s.daily.database)
	for i := 0; i < 2; i++ {
		p, err := s.Read(context.Background(), user, radarNow)
		if err != nil || len(p.Items) != 1 {
			t.Fatalf("visit %d: %+v %v", i, p, err)
		}
	}
	if len(f.queries) != 1 {
		t.Fatalf("repeated visit refreshed provider: got %d calls, want 1", len(f.queries))
	}
}
func configureDailyRegression(t *testing.T, s *RadarService) {
	t.Helper()
	s.daily = dailyFixtureStore(t)
}
func dailyFixtureStore(t *testing.T) *radarDailyStore {
	t.Helper()
	return &radarDailyStore{database: radartest.RadarDatabase(t), namespace: radarDailyNamespace, now: func() time.Time { return radarNow }}
}
