package discovery

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type varietyCatalog struct{ dailyCatalog }

func varietyArtist(letter byte) uuid.UUID {
	return uuid.MustParse(fmt.Sprintf("%08d-1111-4111-8111-111111111111", letter-'A'+1))
}
func (f *varietyCatalog) RecentArtistSeeds(context.Context, uuid.UUID, time.Time, time.Time, int) (db.RadarSeeds, error) {
	return db.RadarSeeds{Artists: []uuid.UUID{varietyArtist('A'), varietyArtist('B'), varietyArtist('C'), varietyArtist('D'), varietyArtist('E')}, Available: 5, Events: 30}, nil
}

// A spec is label/seed credits/group/edition. Empty optional identities stay
// empty. IDs and display titles are deliberately separate dimensions.
func varietyRows(specs ...string) []musicbrainz.TrackResult {
	rows := dailyRows(len(specs))
	for i, spec := range specs {
		parts := strings.Split(spec, "/")
		rows[i].Title = parts[0]
		rows[i].Artist = "Synthetic " + parts[1]
		rows[i].ArtistCredits = nil
		for _, a := range strings.Split(parts[1], "+") {
			rows[i].ArtistCredits = append(rows[i].ArtistCredits, musicbrainz.ArtistCredit{MBID: varietyArtist(a[0]).String()})
		}
		if len(parts) > 2 && parts[2] != "" {
			rows[i].ReleaseGroupMBID = fmt.Sprintf("%08d-aaaa-4aaa-8aaa-aaaaaaaaaaaa", parts[2][0])
		}
		if len(parts) > 3 && parts[3] != "" {
			rows[i].ReleaseID = fmt.Sprintf("%08d-bbbb-4bbb-8bbb-bbbbbbbbbbbb", parts[3][0])
		}
	}
	return rows
}
func varietyTitles(p RadarPage) []string {
	titles := []string{}
	for _, s := range p.Items {
		titles = append(titles, s.Title)
	}
	return titles
}
func TestRadarVarietyResearchExamplesThroughService(t *testing.T) {
	cases := []struct {
		name  string
		specs []string
		want  []string
	}{
		{"album flood", []string{"A1/A/X", "A2/A/X", "A3/A/X", "B1/B/Y", "C1/C/Z", "D1/D/W", "E1/E/V"}, []string{"A1", "B1", "C1", "D1", "E1", "A2", "A3"}},
		{"two albums same artist", []string{"A1/A/X", "A2/A/Q", "B1/B/Y", "C1/C/Z"}, []string{"A1", "B1", "C1", "A2"}},
		{"one album fills", []string{"A1/A/X", "A2/A/X", "A3/A/X"}, []string{"A1", "A2", "A3"}},
		{"unknown albums are unique", []string{"A1/A", "A2/A", "B1/B", "C1/C"}, []string{"A1", "B1", "C1", "A2"}},
		{"same group distinct editions", []string{"A1/A/X/1", "A2/A/X/2", "B1/B/Y/3"}, []string{"A1", "B1", "A2"}},
		{"edition fallback", []string{"A1/A//1", "A2/A//1", "B1/B//2"}, []string{"A1", "B1", "A2"}},
		{"collaboration maximum exposure", []string{"AB/A+B/X", "B1/B/Y", "C1/C/Z"}, []string{"AB", "C1", "B1"}},
		// Research's future exact-recording preference is intentionally unavailable.
		// A provider search score is not that signal. Current policy stays date/ID.
		{"future preference not fabricated", []string{"A1/A/X", "A2/A/X", "A3/A/X", "B1/B/Y", "C1/C/Z", "D1/D/W", "E1/E/V"}, []string{"A1", "B1", "C1", "D1", "E1", "A2", "A3"}},
		{"later sibling has no invented preference", []string{"A1/A/X", "A2/A/X", "A3/A/X", "B1/B/Y", "C1/C/Z", "D1/D/W", "E1/E/V"}, []string{"A1", "B1", "C1", "D1", "E1", "A2", "A3"}},
		{"ownership removed before exposures", []string{"A1/A/X", "A2/A/X", "B1/B/Y", "C1/C/Z"}, []string{"A2", "B1", "C1"}},
		{"empty", nil, []string{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rows := varietyRows(tc.specs...)
			for i := range rows {
				rows[i].Score = 100 - i
				if rows[i].Title == "A3" {
					rows[i].Score = 9999
				}
			}
			f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: rows}}
			user := uuid.New()
			if tc.name == "ownership removed before exposures" {
				f.owned = map[uuid.UUID]map[uuid.UUID]bool{user: {uuid.MustParse(rows[0].MBID): true}}
			}
			for iteration := 0; iteration < 10; iteration++ {
				// Reverse provider order repeatedly. Candidate map iteration also varies.
				for a, b := 0, len(f.rows)-1; a < b; a, b = a+1, b-1 {
					f.rows[a], f.rows[b] = f.rows[b], f.rows[a]
				}
				p, err := NewRadarService(f, f, f).ReadWithOrdering(context.Background(), user, radarNow, RadarVarietyPolicy)
				if err != nil || !reflect.DeepEqual(varietyTitles(p), tc.want) {
					t.Fatalf("got %v want %v error %v", varietyTitles(p), tc.want, err)
				}
				if p.PolicyVersion != RadarVarietyPolicy {
					t.Fatal("wrong projection policy")
				}
			}
		})
	}
}
func TestRadarVarietyAlbumIdentityAndExposurePrecedence(t *testing.T) {
	cases := []struct {
		name        string
		specs, want []string
	}{
		{"group before edition or artist novelty", []string{"A1/A/X/1", "B1/B/X/2", "A2/A/Y/3"}, []string{"A1", "A2", "B1"}},
		{"edition without group still groups", []string{"A1/A//1", "B1/B//1", "A2/A//2"}, []string{"A1", "A2", "B1"}},
		{"unknown recordings are independent of known albums", []string{"A1/A", "B1/B", "A2/A/X"}, []string{"A1", "B1", "A2"}},
		{"maximum not sum of credited exposures", []string{"AB/A+B/X", "AB2/A+B/Y", "A1/A/Z"}, []string{"AB", "AB2", "A1"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: varietyRows(tc.specs...)}}
			p, e := NewRadarService(f, f, f).ReadWithOrdering(context.Background(), uuid.New(), radarNow, RadarVarietyPolicy)
			if e != nil || !reflect.DeepEqual(varietyTitles(p), tc.want) {
				t.Fatalf("got %v want %v error %v", varietyTitles(p), tc.want, e)
			}
		})
	}
}

func TestRadarVarietyBeforeTwentyCapAndOriginalDateTieBreak(t *testing.T) {
	specs := []string{}
	for i := 0; i < 25; i++ {
		specs = append(specs, fmt.Sprintf("A%d/A/X", i+1))
	}
	specs = append(specs, "B1/B/Y", "C1/C/Z", "D1/D/W", "E1/E/V")
	rows := varietyRows(specs...)
	for i := 25; i < len(rows); i++ {
		rows[i].FirstReleaseDate = "2026-10-01"
	}
	f := &varietyCatalog{dailyCatalog: dailyCatalog{rows: rows}}
	s := NewRadarService(f, f, f)
	p, err := s.ReadWithOrdering(context.Background(), uuid.New(), radarNow, RadarVarietyPolicy)
	if err != nil || len(p.Items) != 20 || !reflect.DeepEqual(varietyTitles(p)[:5], []string{"A1", "B1", "C1", "D1", "E1"}) {
		t.Fatalf("truncated before variety: %v %v", varietyTitles(p), err)
	}
	if !containsRadar(p.Coverage.Reasons, "result_limit") || p.Coverage.Retrieved != 29 {
		t.Fatalf("wrong coverage %+v", p.Coverage)
	}
	raw, err := s.candidates(context.Background(), uuid.New(), radarNow)
	if err != nil || len(raw.Items) != 29 || raw.PolicyVersion != RadarPolicy || raw.Items[1].Title != "A2" {
		t.Fatal("raw pool reranked/truncated")
	}
	legacy, err := s.Read(context.Background(), uuid.New(), radarNow)
	if err != nil || legacy.PolicyVersion != RadarPolicy || legacy.Items[1].Title != "A2" {
		t.Fatal("legacy order changed")
	}
}

func TestRadarPreservesOptionalCanonicalAssociation(t *testing.T) {
	rows := dailyRows(3)
	group := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	release := "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	rows[0].ReleaseGroupMBID, rows[0].ReleaseID = group, release
	rows[0].ReleaseDate = "2000-01-01" // edition date must not replace recording evidence
	rows[1].ReleaseGroupMBID, rows[1].ReleaseID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "invalid"
	rows[2].AlbumMBID = group // legacy ambiguous field is not the explicit association
	f := &dailyCatalog{rows: rows}
	p, err := NewRadarService(f, f, f).Read(context.Background(), uuid.New(), radarNow)
	if err != nil || len(p.Items) != 3 {
		t.Fatalf("eligible songs lost: %+v %v", p, err)
	}
	b, err := json.Marshal(p.Items)
	if err != nil {
		t.Fatal(err)
	}
	var items []map[string]any
	if err := json.Unmarshal(b, &items); err != nil {
		t.Fatal(err)
	}
	if items[0]["releaseGroupMbid"] != group || items[0]["releaseMbid"] != release || p.Items[0].FirstRelease.Raw != "2026-11-12" {
		t.Fatalf("association lost: %s", b)
	}
	for _, item := range items[1:] {
		if _, ok := item["releaseGroupMbid"]; ok {
			t.Fatalf("invalid/invented association: %s", b)
		}
		if _, ok := item["releaseMbid"]; ok {
			t.Fatalf("invalid association: %s", b)
		}
	}
	if f.count() != 1 {
		t.Fatal("metadata caused enrichment requests")
	}
}
