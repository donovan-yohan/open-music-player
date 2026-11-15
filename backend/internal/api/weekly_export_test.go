package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/weekly"
)

// A transactionally cloned collaborator, not PostgreSQL or a provider. It
// enforces the production encoded-state ceiling; all canonical writes below
// enter the production service. Only accepted-batch metadata is synthetic.
type weeklyExportStore struct {
	mu         sync.Mutex
	state      *weekly.State
	artistName string
}

func (s *weeklyExportStore) Update(_ context.Context, _ uuid.UUID, fn func(*weekly.State) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, err := json.Marshal(s.state)
	if err != nil {
		return err
	}
	var next weekly.State
	if err = json.Unmarshal(raw, &next); err != nil {
		return err
	}
	if err = fn(&next); err != nil {
		return err
	}
	raw, err = json.Marshal(&next)
	if err != nil {
		return err
	}
	if len(raw) > 1800000 {
		return &weekly.Conflict{Code: "RESOURCE_LIMIT", ProfileEpoch: s.state.Epoch, PreferenceRevision: s.state.Revision, FilterRevision: s.state.FilterRevision}
	}
	s.state = &next
	return nil
}
func (s *weeklyExportStore) ArtistEvidence(context.Context, uuid.UUID, string) (string, error) {
	if s.artistName != "" {
		return s.artistName, nil
	}
	return "Synthetic verified Library artist", nil
}
func (s *weeklyExportStore) History(context.Context, uuid.UUID, time.Time) (weekly.History, error) {
	return weekly.History{}, nil
}
func (s *weeklyExportStore) Eligibility(context.Context, uuid.UUID, []string, time.Time) (weekly.Eligibility, error) {
	return weekly.Eligibility{}, nil
}

func weeklyExportID(n int, role int) string {
	return fmt.Sprintf("%08x-0000-4000-8000-%012x", n+1, role)
}
func weeklyExportVote(t *testing.T, store *weeklyExportStore, service *weekly.Service, user uuid.UUID, n int, title, artist, vote string, primaryFirst bool, creditCount int) {
	t.Helper()
	id, batch := weeklyExportID(n, 1), weeklyExportID(n, 3)
	credits := []string{}
	for a := 0; a < creditCount; a++ {
		number := n*16 + a
		if primaryFirst {
			number += 10000
			if a == 0 {
				number = n
			}
		}
		credits = append(credits, weeklyExportID(number, 2))
	}
	store.state.Batches = append(store.state.Batches, weekly.Page{BatchID: &batch, Items: []weekly.Item{{RecordingMbid: id, Title: title, Artist: artist, ArtistMbids: credits, PrimaryArtistMbid: credits[0]}}})
	if len(store.state.Batches) > 2 {
		store.state.Batches = store.state.Batches[1:]
	}
	_, err := service.WriteFeedback(context.Background(), user, id, weekly.FeedbackWrite{Vote: vote, MutationID: weeklyExportID(n, 4), BatchID: &batch}, time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("production WriteFeedback %d: %v", n, err)
	}
}

func weeklyExportRouter(t *testing.T, store *weeklyExportStore, user uuid.UUID) (http.Handler, string) {
	t.Helper()
	const key = "synthetic-export-regression-only"
	authService := auth.NewService(nil, nil, key)
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(authService), AuthService: authService, WeeklyHandlers: NewWeeklyHandlers(store, nil)})
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, authWeeklyClaims(user)).SignedString([]byte(key))
	if err != nil {
		t.Fatal(err)
	}
	return router, token
}

func weeklyAssertExport(t *testing.T, store *weeklyExportStore, user uuid.UUID, name string) weekly.Export {
	t.Helper()
	before, err := json.Marshal(store.state)
	if err != nil {
		t.Fatal(err)
	}
	router, token := weeklyExportRouter(t, store, user)
	var first []byte
	var out weekly.Export
	for attempt := 0; attempt < 8; attempt++ {
		req := httptest.NewRequest("GET", weeklyRoot+"preferences/export", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		if attempt == 0 {
			if dir := os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR"); dir != "" {
				if err = os.WriteFile(filepath.Join(dir, "export-"+name+".json"), w.Body.Bytes(), 0600); err != nil {
					t.Fatal(err)
				}
			}
			t.Logf("authenticated GET preferences/export stateBytes=%d responseBytes=%d status=%d", len(before), w.Body.Len(), w.Code)
		}
		if w.Code != 200 || w.Body.Len() > 1800000 {
			t.Fatalf("valid admitted state cannot be exported: HTTP %d, %d bytes", w.Code, w.Body.Len())
		}
		if w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Content-Type") != "application/json" {
			t.Fatal("lost private JSON response headers")
		}
		if err = json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if len(out.DerivedArtistAffinities) > 50 || out.Truncated || out.HistoryIncluded {
			t.Fatalf("not a bounded derived summary with complete canonical state: affinities=%d truncated=%v history=%v", len(out.DerivedArtistAffinities), out.Truncated, out.HistoryIncluded)
		}
		if attempt == 0 {
			first = append([]byte{}, w.Body.Bytes()...)
		} else if !bytes.Equal(first, w.Body.Bytes()) {
			t.Fatal("repeated export changed serialized bytes")
		}
	}
	after, _ := json.Marshal(store.state)
	if !bytes.Equal(before, after) {
		t.Fatal("export mutated permissions, feedback, revisions, replay or attempt state")
	}
	if out.ContractVersion != weekly.ContractVersion || out.ProfileEpoch != store.state.Epoch || out.PreferenceRevision != store.state.Revision || out.FilterRevision != store.state.FilterRevision || len(out.Permissions) != len(store.state.Permissions) {
		t.Fatal("export lost account revision or permission authority")
	}
	for k, p := range store.state.Permissions {
		if out.Permissions[k] != (weekly.PermissionResource{Permission: k, Enabled: p.Enabled, Revision: p.Revision}) {
			t.Fatal("export changed permission", k)
		}
	}
	feedback := map[string]weekly.FeedbackEntry{}
	for i, f := range out.RecordingFeedback {
		if i > 0 && out.RecordingFeedback[i-1].RecordingMbid >= f.RecordingMbid {
			t.Fatal("feedback not in unique canonical order")
		}
		feedback[f.RecordingMbid] = f
	}
	artists := map[string]weekly.Artist{}
	for i, a := range out.Artists {
		if i > 0 && out.Artists[i-1].ArtistMbid >= a.ArtistMbid {
			t.Fatal("artists not in unique canonical order")
		}
		artists[a.ArtistMbid] = a
	}
	if !reflect.DeepEqual(feedback, store.state.Feedback) || !reflect.DeepEqual(artists, store.state.Artists) {
		t.Fatal("canonical feedback/choices (including neutral tombstones) were lost or changed")
	}
	for i, a := range out.DerivedArtistAffinities {
		if a.Affinity < -3 || a.Affinity > 3 || (i > 0 && out.DerivedArtistAffinities[i-1].ArtistMbid >= a.ArtistMbid) {
			t.Fatal("invalid summary value/order")
		}
	}
	page, err := weekly.NewService(store, nil).Preferences(context.Background(), user, weekly.PageQuery{Limit: 1}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(out.DerivedArtistAffinities, page.DerivedArtistAffinities[:len(out.DerivedArtistAffinities)]) {
		t.Fatal("export is not a prefix of the existing Preferences summary")
	}
	if len(out.DerivedArtistAffinities) < len(page.DerivedArtistAffinities) {
		out.DerivedArtistAffinities = append(out.DerivedArtistAffinities, page.DerivedArtistAffinities[len(out.DerivedArtistAffinities)])
		next, err := json.Marshal(out)
		if err != nil || len(next) <= 1800000 {
			t.Fatal("summary omitted an entry that fits the actual serialized ceiling")
		}
		out.DerivedArtistAffinities = out.DerivedArtistAffinities[:len(out.DerivedArtistAffinities)-1]
	}
	t.Logf("canonicalFeedback=%d canonicalArtists=%d summary=%d repeatedIdentical=8 stateUnchanged=true", len(feedback), len(artists), len(out.DerivedArtistAffinities))
	return out
}

func TestWeeklyExportBoundedCanonicalFeedback(t *testing.T) {
	for _, count := range []int{1, 126, 700} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			store := &weeklyExportStore{state: weekly.NewState()}
			service, user := weekly.NewService(store, nil), uuid.New()
			for n := 0; n < count; n++ {
				weeklyExportVote(t, store, service, user, n, "Synthetic recording", "Synthetic artist", "up", false, 16)
			}
			out := weeklyAssertExport(t, store, user, fmt.Sprint(count))
			if len(out.DerivedArtistAffinities) != min(50, count*16) {
				t.Fatal("summary policy differs from Preferences")
			}
		})
	}
}

func TestWeeklyExportNearStorageCeilingEscapedMetadata(t *testing.T) {
	for _, name := range []string{"recording-metadata", "artist-metadata"} {
		t.Run(name, func(t *testing.T) { weeklyExportNearCeiling(t, name) })
	}
}

func weeklyExportNearCeiling(t *testing.T, name string) {
	store := &weeklyExportStore{state: weekly.NewState()}
	if name == "artist-metadata" {
		store.artistName = strings.Repeat("\x01<&>\"\\", 83) + "界é"
	}
	service, user := weekly.NewService(store, nil), uuid.New()
	// Both strings meet generate's actual 2,000-byte metadata bound. JSON HTML,
	// control, quote and backslash escaping must count, not source string bytes.
	metadata := strings.Repeat("\x01<&>\"\\", 332) + "é界ABC"
	for n := 0; n < 65; n++ {
		vote := "up"
		if n%11 == 0 {
			vote = "none"
		}
		weeklyExportVote(t, store, service, user, n, metadata, metadata, vote, true, 16)
	}
	// Retire provenance through the collaborator, as a later accepted generation
	// can do. Fill via canonical artist writes with actual <=500-character labels.
	store.state.Batches = []weekly.Page{}
	for n := 0; n < weekly.MaxArtists; n++ {
		id := weeklyExportID(n+50000, 2)
		interested, blocked := n%3 == 0, n%3 == 1
		_, err := service.WritePreference(context.Background(), user, weekly.PreferenceWrite{Resource: "artist", MutationID: weeklyExportID(n+50000, 4), ArtistMbid: &id, Interested: &interested, Blocked: &blocked}, time.Time{})
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(store.state)
		if len(raw) > 1750000 {
			break
		}
	}
	// Approach the encoded ceiling using legal canonical metadata, not an
	// invalid padding field. Use small records for the final few KiB so the
	// fixture itself never exceeds the admission ceiling.
	for n := 65; ; n++ {
		raw, _ := json.Marshal(store.state)
		if len(raw) >= 1797500 {
			break
		}
		title, artist, credits := metadata, metadata, 16
		if len(raw) > 1760000 {
			title, artist = "T", "A"
			credits = 1
		}
		weeklyExportVote(t, store, service, user, n, title, artist, "up", true, credits)
		store.state.Batches = []weekly.Page{}
	}
	out := weeklyAssertExport(t, store, user, "near-ceiling-"+name)
	if len(out.DerivedArtistAffinities) >= 50 {
		t.Fatal("fixture did not exercise the serialized-byte summary bound")
	}
}

func TestWeeklyExportMaximumCanonicalCounts(t *testing.T) {
	store := &weeklyExportStore{state: weekly.NewState()}
	service, user := weekly.NewService(store, nil), uuid.New()
	for n := 0; n < weekly.MaxFeedback; n++ {
		vote := []string{"up", "down", "none"}[n%3]
		weeklyExportVote(t, store, service, user, n, "T", "A", vote, false, 1)
	}
	for n := 0; n < weekly.MaxArtists; n++ {
		id, interested, blocked := weeklyExportID(n+50000, 2), n%3 == 0, n%3 == 1
		if _, err := service.WritePreference(context.Background(), user, weekly.PreferenceWrite{Resource: "artist", MutationID: weeklyExportID(n+50000, 4), ArtistMbid: &id, Interested: &interested, Blocked: &blocked}, time.Time{}); err != nil {
			t.Fatal(err)
		}
	}
	out := weeklyAssertExport(t, store, user, "maximum-counts")
	if len(out.Artists) != weekly.MaxArtists || len(out.RecordingFeedback) != weekly.MaxFeedback {
		t.Fatal("max-count fixture lost canonical entries")
	}
}

func TestWeeklyExportDeterministicSharedArtistLabels(t *testing.T) {
	store := &weeklyExportStore{state: weekly.NewState()}
	service, user := weekly.NewService(store, nil), uuid.New()
	artist := weeklyExportID(0, 2)
	for n := 0; n < 12; n++ {
		id, batch := weeklyExportID(n, 1), weeklyExportID(n, 3)
		name := "Zulu"
		if n%2 == 0 {
			name = "Alpha"
		}
		store.state.Batches = []weekly.Page{{BatchID: &batch, Items: []weekly.Item{{RecordingMbid: id, Title: "T", Artist: name, ArtistMbids: []string{artist}, PrimaryArtistMbid: artist}}}}
		if _, err := service.WriteFeedback(context.Background(), user, id, weekly.FeedbackWrite{Vote: "up", MutationID: weeklyExportID(n, 4), BatchID: &batch}, time.Time{}); err != nil {
			t.Fatal(err)
		}
	}
	out := weeklyAssertExport(t, store, user, "shared-labels")
	if len(out.DerivedArtistAffinities) != 1 || out.DerivedArtistAffinities[0].Name != "Alpha" || out.DerivedArtistAffinities[0].Affinity != 3 || out.DerivedArtistAffinities[0].ContributingCount != 12 {
		t.Fatal("label stabilization changed affinity arithmetic")
	}
}

func TestWeeklyExportCanonicalByteHeadroom(t *testing.T) {
	// Serialization proof, not an admission fixture: maximize every canonical
	// metadata field and shared integer width, minimize noncanonical state.
	// An object-map entry costs its fixed UUID key + quotes + colon (39 bytes)
	// more than the same canonical array entry. Past ten resources the saved
	// keys dominate the fixed export envelope/permission expansion. Below ten,
	// even maximal legal metadata is far below the response ceiling.
	const revision = int64(9223372036854775807)
	metadata := strings.Repeat("\x01", 2000)
	stamp := time.Date(9999, 12, 31, 23, 59, 59, 999999999, time.UTC)
	for feedbackCount := 0; feedbackCount <= 10; feedbackCount++ {
		for artistCount := 0; artistCount <= 10; artistCount++ {
			state := weekly.NewState()
			state.Epoch, state.Revision, state.FilterRevision = revision, revision, revision
			for k := range state.Permissions {
				state.Permissions[k] = weekly.PermissionState{Revision: revision}
			}
			for n := 0; n < feedbackCount; n++ {
				id, mutation := weeklyExportID(n, 1), weeklyExportID(n, 4)
				credits := []string{}
				for a := 0; a < 16; a++ {
					credits = append(credits, weeklyExportID(n*16+a, 2))
				}
				state.Feedback[id] = weekly.FeedbackEntry{Feedback: weekly.Feedback{RecordingMbid: id, Vote: "none", Revision: revision, ProfileEpoch: revision, UpdatedAt: &stamp, LastMutationID: &mutation}, Title: metadata, Artist: metadata, ArtistMbids: credits, PrimaryArtistMbid: credits[0]}
			}
			for n := 0; n < artistCount; n++ {
				id := weeklyExportID(n, 2)
				state.Artists[id] = weekly.Artist{ArtistMbid: id, Name: metadata, Revision: revision}
			}
			stored, _ := json.Marshal(state)
			store := &weeklyExportStore{state: state}
			out, err := weekly.NewService(store, nil).Export(context.Background(), uuid.New())
			if err != nil {
				t.Fatal(err)
			}
			canonical, err := json.Marshal(out)
			if err != nil || len(canonical) > 1800000 || (feedbackCount+artistCount >= 10 && len(canonical) > len(stored)) {
				t.Fatalf("canonical envelope proof failed for %d/%d: stored=%d canonical=%d err=%v", feedbackCount, artistCount, len(stored), len(canonical), err)
			}
		}
	}
}

func TestWeeklyExportHTTPByteBoundary(t *testing.T) {
	// Exactly 1,800,000 bytes after encoding, despite far fewer source bytes.
	value := strings.Repeat("\x01", 299999) + "abcd"
	for _, extra := range []string{"", "x"} {
		w := httptest.NewRecorder()
		weeklyResult(w, value+extra, nil)
		if extra == "" {
			if w.Code != 200 || w.Body.Len() != 1800000 {
				t.Fatalf("exact encoded ceiling refused: %d/%d", w.Code, w.Body.Len())
			}
		} else if w.Code != 503 {
			t.Fatal("over-ceiling response was admitted")
		}
	}
}
