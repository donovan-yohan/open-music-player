package discovery

import (
	"context"
	"fmt"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const RadarPolicy = "recording-radar-v1"

type RadarDate struct {
	Raw       string `json:"raw"`
	Precision string `json:"precision"`
}
type RadarSong struct {
	RecordingMbid           string    `json:"recordingMbid"`
	Title                   string    `json:"title"`
	Artist                  string    `json:"artist"`
	CreditedSeedArtistMbids []string  `json:"creditedSeedArtistMbids"`
	FirstRelease            RadarDate `json:"firstRelease"`
}
type RadarWindows struct {
	ListenSince  time.Time `json:"listenSince"`
	ReleaseSince string    `json:"releaseSince"`
	Through      string    `json:"through"`
	ListenDays   int       `json:"listenDays"`
	ReleaseDays  int       `json:"releaseDays"`
}
type RadarBounds struct {
	Seeds             int `json:"seeds"`
	Pages             int `json:"pages"`
	PageSize          int `json:"pageSize"`
	RawCandidates     int `json:"rawCandidates"`
	Items             int `json:"items"`
	DeadlineSeconds   int `json:"deadlineSeconds"`
	ProviderPageBytes int `json:"providerPageBytes"`
	ResponseBytes     int `json:"responseBytes"`
	RetriesPerPage    int `json:"retriesPerPage"`
}
type RadarCoverage struct {
	Partial               bool     `json:"partial"`
	Reasons               []string `json:"reasons"`
	ProviderStatus        string   `json:"providerStatus"`
	SeedsAvailable        *int     `json:"seedsAvailable"`
	SeedsSelected         int      `json:"seedsSelected"`
	UnresolvedSeedTracks  *int     `json:"unresolvedSeedTracks"`
	ServerEvents          *int     `json:"serverEvents"`
	UnlinkedLibraryTracks *int     `json:"unlinkedLibraryTracks"`
	PagesFetched          int      `json:"pagesFetched"`
	KnownTotal            *int     `json:"knownTotal"`
	Retrieved             int      `json:"retrieved"`
	Deduped               int      `json:"deduped"`
	DateRejected          int      `json:"dateRejected"`
	IdentityRejected      int      `json:"identityRejected"`
	OwnedExcluded         *int     `json:"ownedExcluded"`
	Returned              int      `json:"returned"`
	IdentityScope         string   `json:"identityScope"`
	DeviceLocalCoverage   string   `json:"deviceLocalCoverage"`
}
type RadarPage struct {
	PolicyVersion       string        `json:"policyVersion"`
	GeneratedAt         time.Time     `json:"generatedAt"`
	CalendarZone        string        `json:"calendarZone"`
	EffectiveWindows    RadarWindows  `json:"effectiveWindows"`
	EffectiveBounds     RadarBounds   `json:"effectiveBounds"`
	SelectedArtistMbids []string      `json:"selectedArtistMbids"`
	Items               []RadarSong   `json:"items"`
	Coverage            RadarCoverage `json:"coverage"`
}
type RadarSeedReader interface {
	RecentArtistSeeds(context.Context, uuid.UUID, time.Time, time.Time, int) (db.RadarSeeds, error)
}
type RadarMembershipReader interface {
	OwnedRecordingIDs(context.Context, uuid.UUID, []uuid.UUID) (map[uuid.UUID]bool, error)
}
type RadarCatalog interface {
	SearchTracks(context.Context, string, int, int, bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error)
}
type RadarService struct {
	seeds      RadarSeedReader
	membership RadarMembershipReader
	catalog    RadarCatalog
	daily      *radarDailyStore
}

// NewRadarService constructs the bounded computation, without automatic daily
// admission. Serving composition must use NewDailyRadarService.
func NewRadarService(seeds RadarSeedReader, membership RadarMembershipReader, catalog RadarCatalog) *RadarService {
	return &RadarService{seeds: seeds, membership: membership, catalog: catalog}
}
func (s *RadarService) Read(ctx context.Context, user uuid.UUID, now time.Time) (RadarPage, error) {
	if user == uuid.Nil {
		return RadarPage{}, fmt.Errorf("radar requires account")
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if s.daily != nil {
		return s.readDaily(ctx, user, now)
	}
	page, err := s.candidates(ctx, user, now)
	if err != nil {
		return page, err
	}
	return s.filterMembership(ctx, user, page)
}

// candidates caches metadata eligibility, never an account ownership verdict.
func (s *RadarService) candidates(ctx context.Context, user uuid.UUID, now time.Time) (RadarPage, error) {
	ctx = musicbrainz.WithRadarReadBudget(ctx)
	now = now.UTC()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	since := today.AddDate(0, 0, -90)
	page := RadarPage{PolicyVersion: RadarPolicy, GeneratedAt: now, CalendarZone: "UTC", EffectiveWindows: RadarWindows{now.AddDate(0, 0, -90), since.Format("2006-01-02"), today.Format("2006-01-02"), 90, 90}, EffectiveBounds: RadarBounds{5, 2, 100, 200, 20, 15, 1048576, 262144, 1}, SelectedArtistMbids: []string{}, Items: []RadarSong{}, Coverage: RadarCoverage{Reasons: []string{}, ProviderStatus: "not_requested", IdentityScope: "identified_server_library", DeviceLocalCoverage: "unresolved"}}
	c := &page.Coverage
	reason := func(code string) {
		c.Partial = true
		for _, v := range c.Reasons {
			if v == code {
				return
			}
		}
		c.Reasons = append(c.Reasons, code)
	}
	seeds, err := s.seeds.RecentArtistSeeds(ctx, user, page.EffectiveWindows.ListenSince, now, 5)
	if err != nil {
		reason("seeds_unavailable")
		return page, nil
	}
	c.SeedsAvailable = &seeds.Available
	c.ServerEvents = &seeds.Events
	c.UnresolvedSeedTracks = &seeds.UnresolvedTracks
	c.UnlinkedLibraryTracks = &seeds.UnlinkedLibraryTracks
	if seeds.UnresolvedTracks > 0 || seeds.UnlinkedLibraryTracks > 0 {
		reason("identity_unresolved")
	}
	if seeds.Available > 5 {
		reason("seed_limit")
	}
	selected := map[string]bool{}
	terms := []string{}
	for _, id := range seeds.Artists {
		if id != uuid.Nil && !selected[id.String()] && len(terms) < 5 {
			selected[id.String()] = true
			terms = append(terms, "arid:"+id.String())
		}
	}
	for id := range selected {
		page.SelectedArtistMbids = append(page.SelectedArtistMbids, id)
	}
	sort.Strings(page.SelectedArtistMbids)
	c.SeedsSelected = len(terms)
	if len(terms) == 0 {
		return page, nil
	}
	query := "(" + strings.Join(terms, " OR ") + ") AND firstreleasedate:[" + since.Format("2006-01-02") + " TO " + today.Format("2006-01-02") + "]"
	candidates := map[string]musicbrainz.TrackResult{}
	conflicts := map[string]bool{}
	for offset := 0; offset < 200; offset += 100 {
		if ctx.Err() != nil {
			c.ProviderStatus = "timeout"
			reason("timeout")
			break
		}
		response, e := s.catalog.SearchTracks(ctx, query, 100, offset, false)
		if e != nil || response == nil {
			c.ProviderStatus = "unavailable"
			if ctx.Err() != nil {
				c.ProviderStatus = "timeout"
				reason("timeout")
			} else {
				reason("provider_unavailable")
			}
			break
		}
		if response.Offset != offset || response.Limit != 100 || response.Total < 0 || len(response.Results) > 100 {
			c.ProviderStatus = "unavailable"
			reason("provider_unavailable")
			break
		}
		c.ProviderStatus = "ok"
		c.PagesFetched++
		total := response.Total
		c.KnownTotal = &total
		for _, row := range response.Results {
			c.Retrieved++
			if !radarID(row.MBID) {
				c.IdentityRejected++
				reason("identity_omissions")
				continue
			}
			if prior, ok := candidates[row.MBID]; ok {
				if prior.FirstReleaseDate != row.FirstReleaseDate {
					conflicts[row.MBID] = true
				}
				continue
			}
			candidates[row.MBID] = row
		}
		if offset+len(response.Results) >= response.Total {
			break
		}
		if len(response.Results) < 100 {
			reason("catalog_budget")
			break
		}
		if offset == 100 {
			reason("catalog_budget")
		}
	}
	c.Deduped = len(candidates)
	type dated struct {
		song  RadarSong
		start time.Time
	}
	eligible := []dated{}
	for id, row := range candidates {
		credits := []string{}
		for _, credit := range row.ArtistCredits {
			if radarID(credit.MBID) && selected[credit.MBID] {
				if !containsRadar(credits, credit.MBID) {
					credits = append(credits, credit.MBID)
				}
			}
		}
		sort.Strings(credits)
		if conflicts[id] || len(credits) == 0 || !radarText(row.Title) || !radarText(row.Artist) {
			c.IdentityRejected++
			reason("identity_omissions")
			continue
		}
		if row.ArtistCreditsTruncated {
			reason("identity_omissions")
		}
		date, start, end, ok := radarDate(row.FirstReleaseDate)
		// A full-day date may be today. A month/year must have fully elapsed,
		// including when this is the interval's final calendar day.
		if !ok || start.Before(since) || end.After(today) || (date.Precision != "day" && !end.Before(today)) {
			c.DateRejected++
			if !ok || end.After(today) || !end.Before(since) {
				reason("date_omissions")
			}
			continue
		}
		eligible = append(eligible, dated{RadarSong{id, row.Title, row.Artist, credits, date}, start})
	}
	sort.Slice(eligible, func(i, j int) bool {
		if !eligible[i].start.Equal(eligible[j].start) {
			return eligible[i].start.After(eligible[j].start)
		}
		return eligible[i].song.RecordingMbid < eligible[j].song.RecordingMbid
	})
	for _, entry := range eligible {
		page.Items = append(page.Items, entry.song)
	}
	return page, nil
}

// Re-run current-account membership on every serve, including a warm cache hit.
// The candidate set retains initially owned songs and rows beyond the first 20,
// allowing imports/removals to change the visible set without a provider read.
func (s *RadarService) filterMembership(ctx context.Context, user uuid.UUID, page RadarPage) (RadarPage, error) {
	candidates := page.Items
	page.Items = []RadarSong{}
	// Never append into a cached coverage slice shared with another projection.
	page.Coverage.Reasons = append([]string{}, page.Coverage.Reasons...)
	c := &page.Coverage
	c.Returned = 0
	if len(candidates) == 0 {
		return page, nil
	}
	ids := make([]uuid.UUID, 0, len(candidates))
	for _, song := range candidates {
		id, err := uuid.Parse(song.RecordingMbid)
		if err != nil || id == uuid.Nil {
			return RadarPage{}, fmt.Errorf("invalid radar cached identity")
		}
		ids = append(ids, id)
	}
	owned, err := s.membership.OwnedRecordingIDs(ctx, user, ids)
	if err != nil || owned == nil {
		c.Partial = true
		c.Reasons = append(c.Reasons, "membership_unavailable")
		return page, nil
	}
	ownedCount := 0
	c.OwnedExcluded = &ownedCount
	for i, song := range candidates {
		if owned[ids[i]] {
			ownedCount++
			continue
		}
		if len(page.Items) == 20 {
			c.Partial = true
			if !containsRadar(c.Reasons, "result_limit") {
				c.Reasons = append(c.Reasons, "result_limit")
			}
			continue
		}
		page.Items = append(page.Items, song)
	}
	c.Returned = len(page.Items)
	return page, nil
}

func containsRadar(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func radarID(raw string) bool {
	id, err := uuid.Parse(raw)
	return err == nil && id != uuid.Nil && id.String() == raw
}
func radarText(raw string) bool {
	return utf8.ValidString(raw) && len(raw) > 0 && len(raw) <= 240 && strings.TrimSpace(raw) != "" && !strings.ContainsFunc(raw, unicode.IsControl)
}
func radarDate(raw string) (RadarDate, time.Time, time.Time, bool) {
	layout, precision := "", ""
	switch len(raw) {
	case 4:
		layout = "2006"
		precision = "year"
	case 7:
		layout = "2006-01"
		precision = "month"
	case 10:
		layout = "2006-01-02"
		precision = "day"
	default:
		return RadarDate{}, time.Time{}, time.Time{}, false
	}
	start, err := time.Parse(layout, raw)
	if err != nil || start.Year() < 1 || start.Format(layout) != raw {
		return RadarDate{}, time.Time{}, time.Time{}, false
	}
	end := start
	if precision == "month" {
		end = start.AddDate(0, 1, -1)
	} else if precision == "year" {
		end = start.AddDate(1, 0, -1)
	}
	return RadarDate{raw, precision}, start, end, true
}
