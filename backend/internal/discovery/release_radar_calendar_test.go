package discovery

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

func TestRadarPartialMonthMustBePastNotMerelyEndingToday(t *testing.T) {
	f := &radarMatrix{pages: map[int][]musicbrainz.TrackResult{0: {radarRecording("22222222-2222-4222-8222-222222222222", "2026-10"), radarRecording("33333333-3333-4333-8333-333333333333", "2026-09"), radarRecording("44444444-4444-4444-8444-444444444444", "2026-10-31")}}, total: 3}
	p, err := NewRadarService(f, f, f).Read(context.Background(), uuid.New(), time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC))
	if err != nil || len(p.Items) != 2 || p.Items[0].FirstRelease.Raw != "2026-10-31" || p.Items[1].FirstRelease.Raw != "2026-09" || !containsRadar(p.Coverage.Reasons, "date_omissions") {
		t.Fatalf("unelapsed partial interval admitted %+v %v", p, err)
	}
}
