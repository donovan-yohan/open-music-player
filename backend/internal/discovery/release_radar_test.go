package discovery

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type radarFixture struct {
	pages   map[int][]musicbrainz.TrackResult
	owned   map[uuid.UUID]bool
	offsets []int
}

var radarArtist = uuid.MustParse("11111111-1111-4111-8111-111111111111")

func (f *radarFixture) RecentArtistSeeds(context.Context, uuid.UUID, time.Time, time.Time, int) (db.RadarSeeds, error) {
	return db.RadarSeeds{Artists: []uuid.UUID{radarArtist}, Available: 1, Events: 30}, nil
}
func (f *radarFixture) OwnedRecordingIDs(context.Context, uuid.UUID, []uuid.UUID) (map[uuid.UUID]bool, error) {
	return f.owned, nil
}
func (f *radarFixture) SearchTracks(ctx context.Context, q string, limit, offset int, skip bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	f.offsets = append(f.offsets, offset)
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Results: f.pages[offset], Total: 101, Limit: limit, Offset: offset}, nil
}
func radarRecording(id, date string) musicbrainz.TrackResult {
	return musicbrainz.TrackResult{MBID: id, Title: "Fixture song", Artist: "Fixture artist", FirstReleaseDate: date, ArtistCredits: []musicbrainz.ArtistCredit{{MBID: radarArtist.String(), Name: "Fixture artist"}}}
}
func TestRadarLaterPageNewestAndOwnedExclusion(t *testing.T) {
	old := "22222222-2222-4222-8222-222222222222"
	newest := "33333333-3333-4333-8333-333333333333"
	owned := "44444444-4444-4444-8444-444444444444"
	first := make([]musicbrainz.TrackResult, 100)
	for i := range first {
		first[i] = radarRecording(old, "2026-10-01")
	}
	first[1] = radarRecording(owned, "2026-11-13")
	f := &radarFixture{pages: map[int][]musicbrainz.TrackResult{0: first, 100: {radarRecording(newest, "2026-11-12")}}, owned: map[uuid.UUID]bool{uuid.MustParse(owned): true}}
	page, err := NewRadarService(f, f, f).Read(context.Background(), uuid.New(), time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 2 || page.Items[0].RecordingMbid != newest || page.Items[1].RecordingMbid != old {
		t.Fatalf("wrong eligible order: %+v", page.Items)
	}
	if len(f.offsets) != 2 || page.Coverage.OwnedExcluded == nil || *page.Coverage.OwnedExcluded != 1 || page.Coverage.Retrieved != 101 {
		t.Fatalf("wrong bounded coverage %+v offsets %v", page.Coverage, f.offsets)
	}
}
