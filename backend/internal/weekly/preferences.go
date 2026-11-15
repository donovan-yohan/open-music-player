package weekly

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

func validID(s string) bool {
	id, e := uuid.Parse(s)
	return e == nil && id != uuid.Nil && id.String() == s
}
func invalid(detail string) error { return &Refusal{400, "VALIDATION_ERROR", detail} }
func conflict(st *State, code string, current any) error {
	return &Conflict{code, "state changed; read current state before new intent", current, st.Epoch, st.Revision, st.FilterRevision}
}

// The repository owns pre-write metadata for a byte-limit rollback. The
// callback supplies only its captured pre-write resource, never speculative ack
// state or an unlocked read of a possibly newer account version.
func limitCurrent(err error, current any) error {
	var c *Conflict
	if errors.As(err, &c) && c.Code == "RESOURCE_LIMIT" {
		c.Current = current
	}
	return err
}
func neutral(id string, epoch int64) Feedback {
	return Feedback{RecordingMbid: id, Vote: "none", ProfileEpoch: epoch}
}
func currentFeedback(st *State, id string) Feedback {
	if f, ok := st.Feedback[id]; ok {
		return f.Feedback
	}
	return neutral(id, st.Epoch)
}
func bump(st *State) { st.Revision++; st.FilterRevision++ }
func payload(kind, target string, v any) string {
	b, _ := json.Marshal(v)
	return kind + ":" + target + ":" + string(b)
}
func replay(st *State, id, payload string, out any) (bool, error) {
	for _, r := range st.Replays {
		if r.ID == id {
			if r.Payload != payload {
				return false, conflict(st, "MUTATION_CONFLICT", nil)
			}
			return true, json.Unmarshal(r.Ack, out)
		}
	}
	return false, nil
}
func remember(st *State, id, payload, kind string, v any) {
	b, _ := json.Marshal(v)
	st.Replays = append(st.Replays, Replay{id, payload, kind, b})
	if len(st.Replays) > MaxReplays {
		st.Replays = st.Replays[len(st.Replays)-MaxReplays:]
	}
}
func validateWrite(id string, revision, epoch int64) error {
	if !validID(id) || revision < 0 || epoch < 0 {
		return invalid("valid mutationId, revision and epoch required")
	}
	return nil
}
func batchItem(st *State, id string, batch *string) (Item, bool) {
	for _, p := range st.Batches {
		if batch != nil && (p.BatchID == nil || *p.BatchID != *batch) {
			continue
		}
		for _, i := range p.Items {
			if i.RecordingMbid == id {
				return i, true
			}
		}
	}
	return Item{}, false
}
func (s *Service) Feedback(ctx context.Context, user uuid.UUID, id string) (Feedback, error) {
	var out Feedback
	if !validID(id) {
		return out, invalid("invalid recordingMbid")
	}
	e := s.store.Update(ctx, user, func(st *State) error {
		if _, ok := st.Feedback[id]; !ok {
			if _, ok = batchItem(st, id, nil); !ok {
				return &Refusal{404, "NOT_FOUND", "recording provenance unavailable"}
			}
		}
		out = currentFeedback(st, id)
		return nil
	})
	return out, e
}
func (s *Service) WriteFeedback(ctx context.Context, user uuid.UUID, id string, w FeedbackWrite, now time.Time) (FeedbackAck, error) {
	var out FeedbackAck
	if !validID(id) || (w.Vote != "up" && w.Vote != "down" && w.Vote != "none") || (w.BatchID != nil && !validID(*w.BatchID)) {
		return out, invalid("invalid feedback")
	}
	if e := validateWrite(w.MutationID, w.ExpectedRevision, w.ProfileEpoch); e != nil {
		return out, e
	}
	p := payload("feedback", id, w)
	var current Feedback
	e := s.store.Update(ctx, user, func(st *State) error {
		if yes, e := replay(st, w.MutationID, p, &out); e != nil {
			return e
		} else if yes {
			out.Replayed = true
			return nil
		}
		current = currentFeedback(st, id)
		if st.Epoch != w.ProfileEpoch {
			return conflict(st, "EPOCH_CONFLICT", current)
		}
		entry, exists := st.Feedback[id]
		item, member := batchItem(st, id, w.BatchID)
		if (w.BatchID != nil && !member) || (!exists && !member) {
			return &Refusal{404, "NOT_FOUND", "recording provenance unavailable"}
		}
		if current.Revision != w.ExpectedRevision {
			return conflict(st, "REVISION_CONFLICT", current)
		}
		if !exists {
			if len(st.Feedback) >= MaxFeedback {
				return &Conflict{"RESOURCE_LIMIT", "feedback resource limit reached", current, st.Epoch, st.Revision, st.FilterRevision}
			}
			entry = FeedbackEntry{Title: item.Title, Artist: item.Artist, ArtistMbids: item.ArtistMbids, PrimaryArtistMbid: item.PrimaryArtistMbid}
		}
		stamp := now.UTC()
		mutation := w.MutationID
		entry.Feedback = Feedback{id, w.Vote, current.Revision + 1, st.Epoch, &stamp, &mutation}
		st.Feedback[id] = entry
		bump(st)
		out = FeedbackAck{ContractVersion, entry.Feedback, st.Revision, st.FilterRevision, false}
		remember(st, w.MutationID, p, "feedback", out)
		return nil
	})
	return out, limitCurrent(e, current)
}
func (s *Service) WritePreference(ctx context.Context, user uuid.UUID, w PreferenceWrite, now time.Time) (PreferenceAck, error) {
	var out PreferenceAck
	if e := validateWrite(w.MutationID, w.ExpectedRevision, w.ProfileEpoch); e != nil {
		return out, e
	}
	if w.Resource == "permission" {
		if w.Permission == nil || w.Enabled == nil || w.ArtistMbid != nil || w.Interested != nil || w.Blocked != nil {
			return out, invalid("permission variant requires only permission and enabled")
		}
		switch *w.Permission {
		case "learningFromServerHistory", "externalCatalogQueries", "similarArtistQueries":
		default:
			return out, invalid("unknown permission")
		}
	} else if w.Resource == "artist" {
		if w.ArtistMbid == nil || !validID(*w.ArtistMbid) || w.Interested == nil || w.Blocked == nil || w.Permission != nil || w.Enabled != nil {
			return out, invalid("artist variant requires artistMbid, interested and blocked")
		}
	} else {
		return out, invalid("unknown preference resource")
	}
	p := payload("preference", "", w)
	var current any
	e := s.store.Update(ctx, user, func(st *State) error {
		if yes, e := replay(st, w.MutationID, p, &out); e != nil {
			return e
		} else if yes {
			out.Replayed = true
			return nil
		}
		out = PreferenceAck{ContractVersion: ContractVersion, ProfileEpoch: st.Epoch}
		var rev int64
		if w.Resource == "permission" {
			v := st.Permissions[*w.Permission]
			rev = v.Revision
			current = PermissionResource{*w.Permission, v.Enabled, v.Revision}
		} else {
			v := st.Artists[*w.ArtistMbid]
			if v.ArtistMbid == "" {
				v.ArtistMbid = *w.ArtistMbid
			}
			rev = v.Revision
			current = v
		}
		if st.Epoch != w.ProfileEpoch {
			return conflict(st, "EPOCH_CONFLICT", current)
		}
		if rev != w.ExpectedRevision {
			return conflict(st, "REVISION_CONFLICT", current)
		}
		if w.Resource == "permission" {
			name := *w.Permission
			v := st.Permissions[name]
			changed := v.Enabled != *w.Enabled
			v.Enabled = *w.Enabled
			v.Revision++
			st.Permissions[name] = v
			if changed {
				st.PermissionGeneration++
				st.Batches = []Page{}
			}
			out.Permission = &PermissionResource{name, v.Enabled, v.Revision}
			out.ResourceRevision = v.Revision
		} else {
			id := *w.ArtistMbid
			v, exists := st.Artists[id]
			if !exists {
				if len(st.Artists) >= MaxArtists {
					return &Conflict{"RESOURCE_LIMIT", "artist resource limit reached", current, st.Epoch, st.Revision, st.FilterRevision}
				}
				name, e := s.store.ArtistEvidence(ctx, user, id)
				if e != nil {
					return e
				}
				if name == "" {
					for _, b := range st.Batches {
						for _, i := range b.Items {
							if i.PrimaryArtistMbid == id {
								name = i.Artist
							}
						}
					}
				}
				if name == "" {
					for _, f := range st.Feedback {
						if f.PrimaryArtistMbid == id {
							name = f.Artist
						}
					}
				}
				if name == "" {
					return &Refusal{404, "ARTIST_EVIDENCE_UNAVAILABLE", "canonical artist evidence unavailable"}
				}
				v = Artist{ArtistMbid: id, Name: name}
			}
			v.Revision++
			v.Interested = *w.Interested
			v.Blocked = *w.Blocked
			st.Artists[id] = v
			out.Artist = &v
			out.ResourceRevision = v.Revision
		}
		bump(st)
		out.PreferenceRevision = st.Revision
		out.FilterRevision = st.FilterRevision
		remember(st, w.MutationID, p, "preference", out)
		return nil
	})
	return out, limitCurrent(e, current)
}
func (s *Service) Reset(ctx context.Context, user uuid.UUID, w ResetWrite) (ResetAck, error) {
	var out ResetAck
	if w.Scope != "discovery_preferences" {
		return out, invalid("invalid reset scope")
	}
	if e := validateWrite(w.MutationID, w.ExpectedRevision, w.ProfileEpoch); e != nil {
		return out, e
	}
	p := payload("reset", "", w)
	e := s.store.Update(ctx, user, func(st *State) error {
		if yes, e := replay(st, w.MutationID, p, &out); e != nil {
			return e
		} else if yes {
			out.Replayed = true
			return nil
		}
		if st.Epoch != w.ProfileEpoch {
			return conflict(st, "EPOCH_CONFLICT", nil)
		}
		if st.Revision != w.ExpectedRevision {
			return conflict(st, "REVISION_CONFLICT", nil)
		}
		st.Epoch++
		st.PermissionGeneration++
		bump(st)
		st.Feedback = map[string]FeedbackEntry{}
		st.Artists = map[string]Artist{}
		st.Batches = []Page{}
		st.Replays = []Replay{}
		h := st.Permissions["learningFromServerHistory"]
		h.Enabled = false
		h.Revision++
		st.Permissions["learningFromServerHistory"] = h
		out = ResetAck{ContractVersion, st.Epoch, st.Revision, st.FilterRevision, false}
		remember(st, w.MutationID, p, "reset", out)
		return nil
	})
	return out, e
}
func affinities(st *State) []Affinity {
	m := map[string]*Affinity{}
	for _, f := range st.Feedback {
		if f.Vote == "none" {
			continue
		}
		sign := 1
		if f.Vote == "down" {
			sign = -1
		}
		for _, id := range f.ArtistMbids {
			a := m[id]
			if a == nil {
				a = &Affinity{ArtistMbid: id, ReasonCodes: []string{"current_recording_votes"}}
				m[id] = a
			}
			// Labels can differ across accepted generations. Pick a stable
			// evidenced primary label, independent of feedback map iteration.
			if id == f.PrimaryArtistMbid && (a.Name == "" || f.Artist < a.Name) {
				a.Name = f.Artist
			}
			a.Affinity += sign
			a.ContributingCount++
		}
	}
	out := []Affinity{}
	for _, a := range m {
		a.Affinity = max(-3, min(3, a.Affinity))
		out = append(out, *a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ArtistMbid < out[j].ArtistMbid })
	return out
}

type PageQuery struct {
	Limit              int
	FeedbackCursor     string
	ArtistCursor       string
	PreferenceRevision *int64
}

func cursor(kind string, st *State, offset int) string {
	return base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("%s:%d:%d:%d", kind, st.Epoch, st.Revision, offset)))
}
func offset(raw, kind string, st *State, revision *int64) (int, error) {
	if raw == "" {
		return 0, nil
	}
	if revision == nil || *revision != st.Revision {
		return 0, conflict(st, "PAGINATION_CONFLICT", nil)
	}
	b, e := base64.RawURLEncoding.DecodeString(raw)
	if e != nil {
		return 0, invalid("malformed cursor")
	}
	parts := strings.Split(string(b), ":")
	if len(parts) != 4 || parts[0] != kind {
		return 0, invalid("malformed cursor")
	}
	epoch, e1 := strconv.ParseInt(parts[1], 10, 64)
	rev, e2 := strconv.ParseInt(parts[2], 10, 64)
	n, e3 := strconv.Atoi(parts[3])
	if e1 != nil || e2 != nil || e3 != nil || n < 0 {
		return 0, invalid("malformed cursor")
	}
	if epoch != st.Epoch || rev != st.Revision {
		return 0, conflict(st, "PAGINATION_CONFLICT", nil)
	}
	return n, nil
}
func (s *Service) Preferences(ctx context.Context, user uuid.UUID, q PageQuery, now time.Time) (PreferencesPage, error) {
	var out PreferencesPage
	if q.Limit == 0 {
		q.Limit = 50
	}
	if q.Limit < 1 || q.Limit > 50 {
		return out, invalid("limit must be between 1 and 50")
	}
	e := s.store.Update(ctx, user, func(st *State) error {
		fo, e := offset(q.FeedbackCursor, "feedback", st, q.PreferenceRevision)
		if e != nil {
			return e
		}
		ao, e := offset(q.ArtistCursor, "artist", st, q.PreferenceRevision)
		if e != nil {
			return e
		}
		if q.PreferenceRevision != nil && *q.PreferenceRevision != st.Revision {
			return conflict(st, "PAGINATION_CONFLICT", nil)
		}
		out = PreferencesPage{ContractVersion: ContractVersion, ProfileEpoch: st.Epoch, PreferenceRevision: st.Revision, FilterRevision: st.FilterRevision, PermissionsVersion: PermissionsVersion, RankingVersion: RankingVersion, PermissionRevisions: map[string]int64{}, InterestedArtists: []Artist{}, BlockedArtists: []Artist{}, RecordingFeedback: []FeedbackEntry{}, DerivedArtistAffinities: affinities(st), HistoryCoverage: HistoryCoverage{Status: "not_permitted", ShortDays: 30, LongDays: 90}}
		out.LearningFromServerHistory = st.Permissions["learningFromServerHistory"].Enabled
		out.ExternalCatalogQueries = st.Permissions["externalCatalogQueries"].Enabled
		out.SimilarArtistQueries = st.Permissions["similarArtistQueries"].Enabled
		for k, v := range st.Permissions {
			out.PermissionRevisions[k] = v.Revision
		}
		if len(out.DerivedArtistAffinities) > 50 {
			out.DerivedArtistAffinities = out.DerivedArtistAffinities[:50]
		}
		if len(out.DerivedArtistAffinities) > 0 {
			stamp := now.UTC()
			out.DerivedBuiltAt = &stamp
		}
		if out.LearningFromServerHistory {
			h, e := s.store.History(ctx, user, now)
			if e != nil {
				return e
			}
			out.HistoryCoverage = HistoryCoverage{"identified_server_events", 30, 90, len(h.Short), len(h.Long)}
			if h.Unresolved > 0 {
				out.HistoryCoverage.Status = "identity_limited"
			}
		}
		feedback := []FeedbackEntry{}
		for _, f := range st.Feedback {
			if f.Vote != "none" {
				feedback = append(feedback, f)
			}
		}
		sort.Slice(feedback, func(i, j int) bool { return feedback[i].RecordingMbid < feedback[j].RecordingMbid })
		artists := []Artist{}
		for _, a := range st.Artists {
			artists = append(artists, a)
		}
		sort.Slice(artists, func(i, j int) bool { return artists[i].ArtistMbid < artists[j].ArtistMbid })
		if fo > len(feedback) || ao > len(artists) {
			return invalid("cursor outside resource set")
		}
		end := min(fo+q.Limit, len(feedback))
		out.RecordingFeedback = append(out.RecordingFeedback, feedback[fo:end]...)
		if end < len(feedback) {
			v := cursor("feedback", st, end)
			out.FeedbackCursor = &v
		}
		end = min(ao+q.Limit, len(artists))
		for _, a := range artists[ao:end] { // Neutral artist tombstones remain inspectable in interestedArtists with interested=false.
			if a.Interested || !a.Blocked {
				out.InterestedArtists = append(out.InterestedArtists, a)
			}
			if a.Blocked {
				out.BlockedArtists = append(out.BlockedArtists, a)
			}
		}
		if end < len(artists) {
			v := cursor("artist", st, end)
			out.ArtistCursor = &v
		}
		// Preserve the complete canonical page and cursor envelope first. Only
		// the reconstructable summary may consume the remaining HTTP JSON bytes.
		summary := out.DerivedArtistAffinities
		out.DerivedArtistAffinities = []Affinity{}
		encoded, err := json.Marshal(out)
		if err != nil {
			return err
		}
		size := len(encoded)
		for n, a := range summary {
			encoded, err = json.Marshal(a)
			if err != nil {
				return err
			}
			cost := len(encoded)
			if n > 0 {
				cost++ // comma inside the already-counted array brackets
			}
			if size+cost > MaxResponseBytes {
				break
			}
			out.DerivedArtistAffinities = append(out.DerivedArtistAffinities, a)
			size += cost
		}
		return nil
	})
	return out, e
}

type Export struct {
	ContractVersion         string                        `json:"contractVersion"`
	ProfileEpoch            int64                         `json:"profileEpoch"`
	PreferenceRevision      int64                         `json:"preferenceRevision"`
	FilterRevision          int64                         `json:"filterRevision"`
	Permissions             map[string]PermissionResource `json:"permissions"`
	Artists                 []Artist                      `json:"artists"`
	RecordingFeedback       []FeedbackEntry               `json:"recordingFeedback"`
	DerivedArtistAffinities []Affinity                    `json:"derivedArtistAffinities"`
	Truncated               bool                          `json:"truncated"`
	HistoryIncluded         bool                          `json:"historyIncluded"`
}

func (s *Service) Export(ctx context.Context, user uuid.UUID) (Export, error) {
	var out Export
	e := s.store.Update(ctx, user, func(st *State) error {
		out = Export{ContractVersion: ContractVersion, ProfileEpoch: st.Epoch, PreferenceRevision: st.Revision, FilterRevision: st.FilterRevision, Permissions: map[string]PermissionResource{}, Artists: []Artist{}, RecordingFeedback: []FeedbackEntry{}, DerivedArtistAffinities: []Affinity{}}
		for k, v := range st.Permissions {
			out.Permissions[k] = PermissionResource{k, v.Enabled, v.Revision}
		}
		for _, a := range st.Artists {
			out.Artists = append(out.Artists, a)
		}
		for _, f := range st.Feedback {
			out.RecordingFeedback = append(out.RecordingFeedback, f)
		}
		sort.Slice(out.Artists, func(i, j int) bool { return out.Artists[i].ArtistMbid < out.Artists[j].ArtistMbid })
		sort.Slice(out.RecordingFeedback, func(i, j int) bool {
			return out.RecordingFeedback[i].RecordingMbid < out.RecordingFeedback[j].RecordingMbid
		})
		// Canonical choices and feedback, including tombstones, are complete.
		// Derived affinities are only the same ID-ordered summary used by
		// Preferences, further bounded by the remaining serialized byte budget.
		// Marshal with the HTTP encoder so HTML/control/Unicode escaping counts.
		encoded, err := json.Marshal(out)
		if err != nil {
			return err
		}
		size := len(encoded)
		for n, a := range affinities(st) {
			if n == 50 {
				break
			}
			encoded, err = json.Marshal(a)
			if err != nil {
				return err
			}
			cost := len(encoded)
			if n > 0 {
				cost++ // comma inside the already-counted array brackets
			}
			if size+cost > MaxResponseBytes {
				break
			}
			out.DerivedArtistAffinities = append(out.DerivedArtistAffinities, a)
			size += cost
		}
		return nil
	})
	return out, e
}
