package discovery

import (
	"context"
	"fmt"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"strings"
	"testing"
	"time"
)

type radarMatrix struct {
	pages         map[int][]musicbrainz.TrackResult
	total         int
	queries       []string
	membershipErr error
	providerErr   error
}

func (f *radarMatrix) RecentArtistSeeds(context.Context, uuid.UUID, time.Time, time.Time, int) (db.RadarSeeds, error) {
	return db.RadarSeeds{Artists: []uuid.UUID{radarArtist}, Available: 1, Events: 50}, nil
}
func (f *radarMatrix) OwnedRecordingIDs(context.Context, uuid.UUID, []uuid.UUID) (map[uuid.UUID]bool, error) {
	return map[uuid.UUID]bool{}, f.membershipErr
}
func (f *radarMatrix) SearchTracks(ctx context.Context, q string, limit, offset int, skip bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	f.queries = append(f.queries, q)
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Results: f.pages[offset], Total: f.total, Limit: limit, Offset: offset}, f.providerErr
}

var radarNow = time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)

func TestRadarDatesCreditsAndIdentityAreEvidenceNotEditionOrName(t *testing.T) {
	dates := []string{"2026-11-12", "2026-10", "2026", "2026-08", "2026-11", "2026-11-15", "2026-02-30", "", "2001-01-01"}
	rows := []musicbrainz.TrackResult{}
	for n, date := range dates {
		row := radarRecording(fmt.Sprintf("%08d-2222-4222-8222-222222222222", n+1), date)
		row.ReleaseDate = "2026-11-13"
		rows = append(rows, row)
	}
	rows[0].ArtistCredits = append([]musicbrainz.ArtistCredit{{MBID: uuid.NewString(), Name: "Fixture artist"}}, rows[0].ArtistCredits...)
	foreign := radarRecording("99999999-2222-4222-8222-222222222222", "2026-11-13")
	foreign.ArtistCredits = []musicbrainz.ArtistCredit{{MBID: uuid.NewString(), Name: "Fixture artist"}}
	rows = append(rows, foreign)
	f := &radarMatrix{pages: map[int][]musicbrainz.TrackResult{0: rows}, total: len(rows)}
	p, err := NewRadarService(f, f, f).Read(context.Background(), uuid.New(), radarNow)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Items) != 2 || p.Items[0].FirstRelease.Raw != "2026-11-12" || p.Items[1].FirstRelease.Raw != "2026-10" || p.Items[1].FirstRelease.Precision != "month" {
		t.Fatalf("false newness %+v", p.Items)
	}
	if p.Coverage.DateRejected != 7 || p.Coverage.IdentityRejected != 1 || !p.Coverage.Partial {
		t.Fatalf("missing omissions %+v", p.Coverage)
	}
	if len(f.queries) != 1 || !strings.Contains(f.queries[0], "arid:"+radarArtist.String()) || !strings.Contains(f.queries[0], "firstreleasedate:[2026-08-16 TO 2026-11-14]") {
		t.Fatalf("unbounded/non-ID query %v", f.queries)
	}
}
func TestRadarMembershipFailureIsUnknownNotUnowned(t *testing.T) {
	f := &radarMatrix{pages: map[int][]musicbrainz.TrackResult{0: {radarRecording("22222222-2222-4222-8222-222222222222", "2026-11-12")}}, total: 1, membershipErr: fmt.Errorf("synthetic DB failure")}
	p, err := NewRadarService(f, f, f).Read(context.Background(), uuid.New(), radarNow)
	if err != nil || len(p.Items) != 0 || !containsRadar(p.Coverage.Reasons, "membership_unavailable") {
		t.Fatalf("unknown ownership admitted %+v %v", p, err)
	}
}
func TestRadarTwoPagesTotalAndTwentyDisplayed(t *testing.T) {
	f := &radarMatrix{pages: map[int][]musicbrainz.TrackResult{}, total: 1000}
	for offset := 0; offset < 200; offset += 100 {
		for n := 0; n < 100; n++ {
			f.pages[offset] = append(f.pages[offset], radarRecording(fmt.Sprintf("%08d-2222-4222-8222-222222222222", offset+n+1), "2026-11-12"))
		}
	}
	p, err := NewRadarService(f, f, f).Read(context.Background(), uuid.New(), radarNow)
	if err != nil || len(p.Items) != 20 || len(f.queries) != 2 || p.Coverage.Retrieved != 200 || !containsRadar(p.Coverage.Reasons, "catalog_budget") || !containsRadar(p.Coverage.Reasons, "result_limit") {
		t.Fatalf("budget violated %+v %v", p, err)
	}
	for i := 1; i < len(p.Items); i++ {
		if p.Items[i-1].RecordingMbid >= p.Items[i].RecordingMbid {
			t.Fatal("non deterministic tie order")
		}
	}
}
func TestRadarProviderFailureAndCanceledDeadlineRemainPartial(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		if canceled {
			cancel()
		}
		f := &radarMatrix{providerErr: fmt.Errorf("synthetic provider failure")}
		p, err := NewRadarService(f, f, f).Read(ctx, uuid.New(), radarNow)
		cancel()
		if err != nil || len(p.Items) != 0 || !p.Coverage.Partial || p.Coverage.KnownTotal != nil {
			t.Fatalf("failure became empty success %+v %v", p, err)
		}
	}
}
