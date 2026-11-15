package weekly

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

func weekStart(now time.Time) time.Time {
	now = now.UTC()
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return day.AddDate(0, 0, -(int(day.Weekday())+6)%7)
}
func emptyPage(now time.Time, st *State, status string) Page {
	start := weekStart(now)
	return Page{ContractVersion: ContractVersion, Status: status, WeekStart: start, WeekEndExclusive: start.AddDate(0, 0, 7), CalendarZone: "UTC", RankingVersion: RankingVersion, ProviderPolicyVersion: ProviderPolicyVersion, ProfileEpoch: st.Epoch, PreferenceRevisionAtGeneration: st.Revision, FilterRevision: st.FilterRevision, Items: []Item{}, Coverage: Coverage{IdentityScope: "identified_server_library", ProviderStatus: "not_requested", ReasonCodes: []string{}}}
}
func cloneState(st *State) State { // snapshot is detached from later transactional reads.
	out := *st
	out.Artists = map[string]Artist{}
	for k, v := range st.Artists {
		out.Artists[k] = v
	}
	out.Feedback = map[string]FeedbackEntry{}
	for k, v := range st.Feedback {
		out.Feedback[k] = v
	}
	out.Permissions = map[string]PermissionState{}
	for k, v := range st.Permissions {
		out.Permissions[k] = v
	}
	return out
}
func (s *Service) Read(ctx context.Context, user uuid.UUID, clock func() time.Time) (Page, error) {
	ctx, cancelRead := context.WithTimeout(ctx, 15*time.Second)
	defer cancelRead()
	now := clock().UTC()
	var page Page
	var snap State
	var hist History
	token := ""
	var seeds []string
	e := s.store.Update(ctx, user, func(st *State) error {
		snap = cloneState(st)
		page = emptyPage(now, st, "needs_preferences")
		if !st.Permissions["externalCatalogQueries"].Enabled {
			page.Status = "consent_required"
			return nil
		}
		for _, p := range st.Batches {
			if p.WeekStart.Equal(page.WeekStart) && p.ProfileEpoch == st.Epoch {
				page = p
				return nil
			}
		}
		if st.Permissions["learningFromServerHistory"].Enabled {
			var e error
			hist, e = s.store.History(ctx, user, now)
			if e != nil {
				return e
			}
		}
		if hist.Unresolved > 0 {
			page.Coverage.ReasonCodes = append(page.Coverage.ReasonCodes, "unresolved_history_identity")
		}
		seeds = selectSeeds(st, hist)
		if len(seeds) == 0 {
			return nil
		}
		if a := st.Attempt; a != nil {
			if a.Phase == "pending" {
				if now.Before(a.LeaseUntil) {
					page.Status = "pending"
					page.RetryAfter = &a.LeaseUntil
					return nil
				}
				a.Phase = "failed"
			}
			if a.Week.Equal(page.WeekStart) || now.Before(a.RetryAfter) {
				page.Status = "unavailable"
				page.RetryAfter = &a.RetryAfter
				page.Coverage.ProviderStatus = "cooldown"
				page.Coverage.ReasonCodes = []string{"attempt_entitlement_consumed"}
				return nil
			}
		}
		if s.catalog == nil {
			page.Status = "unavailable"
			page.Coverage.ProviderStatus = "unavailable"
			return nil
		}
		token = uuid.NewString()
		retry := now.Add(24 * time.Hour)
		if page.WeekEndExclusive.After(retry) {
			retry = page.WeekEndExclusive
		}
		st.Attempt = &Attempt{Week: page.WeekStart, Token: token, LeaseUntil: now.Add(15 * time.Second), RetryAfter: retry, Epoch: st.Epoch, PermissionGeneration: st.PermissionGeneration, Phase: "pending"}
		return nil
	})
	if e != nil {
		return Page{}, e
	}
	if token == "" {
		if page.BatchID != nil {
			return s.filter(ctx, user, page, clock())
		}
		return page, nil
	}
	work, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	produced, produceErr := s.generate(work, user, &snap, hist, seeds, now)
	// Publication uses a new bounded transaction even if the request was canceled,
	// solely to retire the already consumed attempt. Never detach provider work.
	publish, cancelPublish := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancelPublish()
	e = s.store.Update(publish, user, func(st *State) error {
		a := st.Attempt
		at := clock().UTC()
		if a == nil || a.Token != token || a.Epoch != st.Epoch || a.PermissionGeneration != st.PermissionGeneration || !st.Permissions["externalCatalogQueries"].Enabled || !at.Before(a.LeaseUntil) || ctx.Err() != nil {
			page = emptyPage(at, st, "stale")
			reason := "publication_retired"
			page.StaleReason = &reason
			page.Coverage = produced.Coverage
			page.Coverage.ProviderStatus = "retired"
			page.Coverage.ReasonCodes = append(page.Coverage.ReasonCodes, reason)
			if errors.Is(ctx.Err(), context.DeadlineExceeded) && a != nil && a.Epoch == st.Epoch && a.PermissionGeneration == st.PermissionGeneration {
				page.Status = "unavailable"
				page.Coverage.ProviderStatus = "timeout"
			}
			if a != nil && a.Token == token {
				a.Phase = "failed"
				page.RetryAfter = &a.RetryAfter
			}
			return nil
		}
		if produceErr != nil {
			a.Phase = "failed"
			page = emptyPage(at, st, "unavailable")
			page.Coverage = produced.Coverage
			page.Coverage.ProviderStatus = "failed"
			page.Coverage.ReasonCodes = append(page.Coverage.ReasonCodes, "provider_generation_failed")
			page.RetryAfter = &a.RetryAfter
			return nil
		}
		a.Phase = "ready"
		page = produced
		st.Batches = append(st.Batches, page)
		if len(st.Batches) > 2 {
			st.Batches = st.Batches[len(st.Batches)-2:]
		}
		return nil
	})
	if e != nil {
		return Page{}, e
	}
	if page.BatchID != nil {
		return s.filter(ctx, user, page, clock())
	}
	return page, nil
}
func selectSeeds(st *State, h History) []string {
	scores := map[string]int{}
	for id, a := range st.Artists {
		if a.Interested && !a.Blocked {
			scores[id] = 10
		}
	}
	for _, a := range affinities(st) {
		if !st.Artists[a.ArtistMbid].Blocked {
			scores[a.ArtistMbid] += a.Affinity
			if scores[a.ArtistMbid] == 0 {
				scores[a.ArtistMbid] = 0
			}
		}
	}
	for id := range h.Long {
		if !st.Artists[id].Blocked {
			scores[id]++
		}
	}
	ids := []string{}
	for id := range scores {
		if !st.Artists[id].Blocked {
			ids = append(ids, id)
		}
	}
	sort.Slice(ids, func(i, j int) bool {
		if scores[ids[i]] != scores[ids[j]] {
			return scores[ids[i]] > scores[ids[j]]
		}
		return ids[i] < ids[j]
	})
	if len(ids) > 5 {
		ids = ids[:5]
	}
	sort.Strings(ids)
	return ids
}
func (s *Service) generate(ctx context.Context, user uuid.UUID, st *State, h History, seeds []string, now time.Time) (p Page, resultErr error) {
	p = emptyPage(now, st, "empty")
	p.Coverage.ProviderStatus = "ok"
	p.Coverage.SeedsConsidered = len(seeds)
	if h.Unresolved > 0 {
		p.Coverage.ReasonCodes = append(p.Coverage.ReasonCodes, "unresolved_history_identity")
	}
	terms := []string{}
	for _, id := range seeds {
		terms = append(terms, "arid:"+id)
	}
	query := "(" + strings.Join(terms, " OR ") + ")"
	ctx, usage := musicbrainz.WithWeeklyReadBudget(ctx)
	defer func() { p.Coverage.ProviderRequests, p.Coverage.ProviderBodyBytes = usage.Usage() }()
	candidates := map[string]Item{}
	conflicting := map[string]bool{}
	for offset := 0; offset < 200; offset += 100 {
		if e := ctx.Err(); e != nil {
			return p, e
		}
		resp, e := s.catalog.SearchTracks(ctx, query, 100, offset, false)
		p.Coverage.PagesFetched++
		if e != nil || resp == nil {
			if e == nil {
				e = fmt.Errorf("missing catalog response")
			}
			return p, e
		}
		if len(resp.Results) > 100 {
			return p, fmt.Errorf("provider page exceeded bound")
		}
		for _, r := range resp.Results {
			p.Coverage.CandidatesConsidered++
			if !validID(r.MBID) || r.Title == "" || !utf8.ValidString(r.Title) || len(r.Title) > 2000 || r.Artist == "" || len(r.Artist) > 2000 || len(r.ArtistCredits) == 0 || len(r.ArtistCredits) > 16 {
				continue
			}
			credits := []string{}
			seen := map[string]bool{}
			valid := true
			for _, a := range r.ArtistCredits {
				if !validID(a.MBID) {
					valid = false
					break
				}
				if !seen[a.MBID] {
					credits = append(credits, a.MBID)
					seen[a.MBID] = true
				}
			}
			if !valid || len(credits) == 0 {
				continue
			}
			item := Item{RecordingMbid: r.MBID, Title: r.Title, Artist: r.Artist, ArtistMbids: credits, PrimaryArtistMbid: credits[0], ReasonCodes: []string{}, Components: []Component{}, Provenance: []Provenance{{Provider: "musicbrainz", RetrievedAt: now}}, Feedback: neutral(r.MBID, st.Epoch)}
			if old, ok := candidates[r.MBID]; ok {
				p.Coverage.Excluded.Duplicate++
				if old.Title != item.Title || old.PrimaryArtistMbid != item.PrimaryArtistMbid || strings.Join(old.ArtistMbids, ",") != strings.Join(item.ArtistMbids, ",") {
					conflicting[r.MBID] = true
				}
				continue
			}
			candidates[r.MBID] = item
		}
		if offset+len(resp.Results) >= resp.Total || len(resp.Results) < 100 {
			break
		}
	}
	items := []Item{}
	for id, i := range candidates {
		if !conflicting[id] {
			items = append(items, i)
		}
	}
	ids := []string{}
	for _, i := range items {
		ids = append(ids, i.RecordingMbid)
	}
	elig, e := s.store.Eligibility(ctx, user, ids, now)
	if e != nil {
		return p, e
	}
	items = hardFilter(items, st, elig, &p.Coverage.Excluded)
	if elig.UnresolvedOwned > 0 {
		p.Coverage.ReasonCodes = append(p.Coverage.ReasonCodes, "unresolved_library_identity")
	}
	p.Items = rank(items, st, h)
	for n := range p.Items {
		p.Items[n].OriginalRank = n + 1
	}
	if len(p.Items) > 0 {
		p.Status = "ready"
	}
	if len(p.Coverage.ReasonCodes) > 0 {
		p.Status = "partial"
	}
	batch := uuid.NewString()
	p.BatchID = &batch
	p.GeneratedAt = &now
	return p, nil
}
func rank(items []Item, st *State, h History) []Item {
	affinity := map[string]int{}
	for _, a := range affinities(st) {
		affinity[a.ArtistMbid] = a.Affinity
	}
	scores := map[string]float64{}
	for n := range items {
		i := &items[n]
		id := i.PrimaryArtistMbid
		interest := 0.
		if st.Artists[id].Interested {
			interest = 1
		}
		vote := float64(affinity[id])
		history := 0.
		if _, ok := h.Long[id]; ok {
			history = .25
		}
		if _, ok := h.Short[id]; ok {
			history = .5
		}
		i.Components = []Component{{"explicit_artist_interest", interest, true}, {"current_recording_vote_affinity", vote, true}, {"server_history_affinity", history, st.Permissions["learningFromServerHistory"].Enabled}, {"audio_similarity", 0, false}}
		i.ReasonCodes = []string{}
		if interest > 0 {
			i.ReasonCodes = append(i.ReasonCodes, "explicit_artist_interest")
		}
		if vote != 0 {
			i.ReasonCodes = append(i.ReasonCodes, "current_recording_vote_affinity")
		}
		if history > 0 {
			i.ReasonCodes = append(i.ReasonCodes, "server_history_affinity")
		}
		scores[i.RecordingMbid] = interest + vote + history
	}
	sort.Slice(items, func(i, j int) bool {
		a, b := items[i].RecordingMbid, items[j].RecordingMbid
		if scores[a] != scores[b] {
			return scores[a] > scores[b]
		}
		return a < b
	})
	out := []Item{}
	counts := map[string]int{}
	last := ""
	for len(out) < 20 {
		chosen := -1
		for n, i := range items {
			if counts[i.PrimaryArtistMbid] < 2 {
				if chosen < 0 {
					chosen = n
				}
				if i.PrimaryArtistMbid != last {
					chosen = n
					break
				}
			}
		}
		if chosen < 0 {
			break
		}
		i := items[chosen]
		out = append(out, i)
		counts[i.PrimaryArtistMbid]++
		last = i.PrimaryArtistMbid
		items = append(items[:chosen], items[chosen+1:]...)
	}
	return out
}
func hardFilter(items []Item, st *State, e Eligibility, c *Excluded) []Item {
	out := []Item{}
	for _, i := range items {
		if e.Owned[i.RecordingMbid] {
			c.Owned++
			continue
		}
		if e.Recent[i.RecordingMbid] {
			c.Recent++
			continue
		}
		if st.Feedback[i.RecordingMbid].Vote == "down" {
			c.Downvoted++
			continue
		}
		blocked := false
		for _, id := range i.ArtistMbids {
			if st.Artists[id].Blocked {
				blocked = true
			}
		}
		if blocked {
			c.Blocked++
			continue
		}
		i.Feedback = currentFeedback(st, i.RecordingMbid)
		out = append(out, i)
	}
	return out
}
func (s *Service) filter(ctx context.Context, user uuid.UUID, p Page, now time.Time) (Page, error) {
	ids := []string{}
	for _, i := range p.Items {
		ids = append(ids, i.RecordingMbid)
	}
	elig, e := s.store.Eligibility(ctx, user, ids, now)
	if e != nil {
		return Page{}, e
	}
	e = s.store.Update(ctx, user, func(st *State) error {
		authorized := false
		for _, batch := range st.Batches {
			if p.BatchID != nil && batch.BatchID != nil && *p.BatchID == *batch.BatchID {
				authorized = true
			}
		}
		if !authorized || st.Epoch != p.ProfileEpoch || !st.Permissions["externalCatalogQueries"].Enabled {
			p = emptyPage(now, st, "stale")
			v := "profile_retired"
			p.StaleReason = &v
			return nil
		}
		// Only the frozen base is filtered. Never call rank or refill here.
		p.FilterRevision = st.FilterRevision
		p.Items = hardFilter(p.Items, st, elig, &p.Coverage.Excluded)
		if elig.UnresolvedOwned > 0 && !contains(p.Coverage.ReasonCodes, "unresolved_library_identity") {
			p.Coverage.ReasonCodes = append(p.Coverage.ReasonCodes, "unresolved_library_identity")
		}
		if len(p.Items) == 0 {
			p.Status = "empty"
		} else if len(p.Coverage.ReasonCodes) > 0 {
			p.Status = "partial"
		}
		return nil
	})
	return p, e
}
func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}
