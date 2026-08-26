package discovery

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/aiassist"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// fakeAcousticBrainzHintSource is a cache stand-in. It records every batched
// lookup so tests can prove one call per response and an exact deduplicated
// argument set.
type fakeAcousticBrainzHintSource struct {
	entries   map[uuid.UUID]db.AcousticBrainzEntry
	err       error
	hitAny    bool
	calls     int
	lastBatch []uuid.UUID
}

func (s *fakeAcousticBrainzHintSource) GetAcousticBrainzByRecordingIDs(
	ctx context.Context,
	recordingMBIDs []uuid.UUID,
) (map[uuid.UUID]db.AcousticBrainzEntry, error) {
	s.calls++
	s.lastBatch = append([]uuid.UUID(nil), recordingMBIDs...)
	// database/sql refuses a query on an expired context; mirror that so the
	// deadline/cancellation cases exercise the real failure shape.
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if s.err != nil {
		return nil, s.err
	}
	if s.hitAny {
		result := make(map[uuid.UUID]db.AcousticBrainzEntry, len(recordingMBIDs))
		for _, id := range recordingMBIDs {
			result[id] = fullAcousticBrainzEntry(id)
		}
		return result, nil
	}
	result := make(map[uuid.UUID]db.AcousticBrainzEntry, len(recordingMBIDs))
	for _, id := range recordingMBIDs {
		if entry, ok := s.entries[id]; ok {
			result[id] = entry
		}
	}
	return result, nil
}

const (
	hintRecordingMBID      = "3fa85f64-5717-4562-b3fc-2c963f66afa6"
	hintOtherRecordingMBID = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
	hintThirdRecordingMBID = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
)

var hintRetrievedAt = time.Date(2024, 3, 11, 9, 30, 0, 0, time.UTC)

// fullAcousticBrainzEntry mirrors a complete stored row: BPM, key, scale,
// Camelot, dump revision, and retrieval time.
func fullAcousticBrainzEntry(recordingID uuid.UUID) db.AcousticBrainzEntry {
	bpm := 128.0
	return db.AcousticBrainzEntry{
		RecordingMBID: recordingID,
		BPM:           &bpm,
		Key:           sql.NullString{String: "A", Valid: true},
		KeyScale:      sql.NullString{String: "minor", Valid: true},
		Camelot:       sql.NullString{String: "8A", Valid: true},
		DumpRevision:  "acousticbrainz-dump-2022-06",
		RetrievedAt:   sql.NullTime{Time: hintRetrievedAt, Valid: true},
	}
}

// bpmOnlyAcousticBrainzEntry is the minimum the table's payload CHECK allows on
// the rhythm-only side: BPM present, no tonal columns.
func bpmOnlyAcousticBrainzEntry(recordingID uuid.UUID) db.AcousticBrainzEntry {
	bpm := 174.0
	return db.AcousticBrainzEntry{
		RecordingMBID: recordingID,
		BPM:           &bpm,
		DumpRevision:  "acousticbrainz-dump-2022-06",
		RetrievedAt:   sql.NullTime{Time: hintRetrievedAt, Valid: true},
	}
}

// hintCandidate builds a fresh candidate each call so repeated runs over the
// same fixture cannot share metadata maps.
func hintCandidate(candidateID, mbIDKey, mbIDValue string) Candidate {
	metadata := map[string]interface{}{"track": "Song", "artist": "Artist"}
	if mbIDKey != "" {
		metadata[mbIDKey] = mbIDValue
	}
	return Candidate{
		CandidateID:  "youtube:" + candidateID,
		Provider:     "youtube",
		SourceID:     candidateID,
		SourceURL:    "https://www.youtube.com/watch?v=" + candidateID,
		Title:        "Song",
		Artist:       "Artist",
		DurationMs:   201000,
		Downloadable: true,
		Metadata:     metadata,
	}
}

func hintService(source AcousticBrainzHintSource, items ...Candidate) *Service {
	return NewService(ServiceConfig{
		Providers:           []Provider{fakeProvider{name: "youtube", items: items}},
		DefaultProviders:    []string{"youtube"},
		AcousticBrainzHints: source,
	})
}

func acousticBrainzHintKeys() []string {
	return []string{
		AcousticBrainzHintBPMKey,
		AcousticBrainzHintKeyKey,
		AcousticBrainzHintKeyScaleKey,
		AcousticBrainzHintCamelotKey,
		AcousticBrainzHintSourceKey,
		AcousticBrainzHintDumpRevisionKey,
		AcousticBrainzHintRetrievedAtKey,
	}
}

func assertNoAcousticBrainzHints(t *testing.T, where string, metadata map[string]interface{}) {
	t.Helper()
	for _, key := range acousticBrainzHintKeys() {
		if _, ok := metadata[key]; ok {
			t.Fatalf("%s carried AcousticBrainz hint %q on a path that must have none: %#v", where, key, metadata)
		}
	}
}

// hintEnvelopeJSON marshals a search envelope for byte-identity comparison with
// the wall-clock-derived provider timings zeroed. ProviderSummary.ElapsedMs is
// time.Since(start).Milliseconds() measured around the provider goroutine, so
// two otherwise identical responses can differ by a millisecond under scheduler
// or GC noise. Nothing about the AcousticBrainz hint contract depends on it, and
// comparing it makes a no-behavioral-change assertion flake as if hints had
// leaked. Every other field, including the whole candidate payload, is compared
// verbatim.
func hintEnvelopeJSON(t *testing.T, resp SearchResponse) string {
	t.Helper()
	normalized := resp
	normalized.Providers = append([]ProviderSummary(nil), resp.Providers...)
	for index := range normalized.Providers {
		normalized.Providers[index].ElapsedMs = 0
	}
	encoded, err := json.Marshal(normalized)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

// TestSearchAttachesAcousticBrainzCandidateHintsOnCacheHit pins the whole
// metadata contract: every key, its Go type, the provenance constant, and the
// atomic block behavior for a partially populated row.
func TestSearchAttachesAcousticBrainzCandidateHintsOnCacheHit(t *testing.T) {
	recordingID := uuid.MustParse(hintRecordingMBID)
	otherID := uuid.MustParse(hintOtherRecordingMBID)
	source := &fakeAcousticBrainzHintSource{entries: map[uuid.UUID]db.AcousticBrainzEntry{
		recordingID: fullAcousticBrainzEntry(recordingID),
		otherID:     bpmOnlyAcousticBrainzEntry(otherID),
	}}
	svc := hintService(source,
		hintCandidate("full", "mbRecordingId", hintRecordingMBID),
		hintCandidate("bpmonly", "mb_recording_id", hintOtherRecordingMBID),
	)

	resp := svc.Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
	if len(resp.Results) != 2 {
		t.Fatalf("results = %#v, want two candidates", resp.Results)
	}

	full := resp.Results[0].Metadata
	if full["track"] != "Song" || full["mbRecordingId"] != hintRecordingMBID {
		t.Fatalf("hint attach dropped pre-existing metadata: %#v", full)
	}
	bpm, ok := full[AcousticBrainzHintBPMKey].(float64)
	if !ok || bpm != 128.0 {
		t.Fatalf("%s = %#v, want float64 128", AcousticBrainzHintBPMKey, full[AcousticBrainzHintBPMKey])
	}
	if value, ok := full[AcousticBrainzHintKeyKey].(string); !ok || value != "A" {
		t.Fatalf("%s = %#v, want string \"A\"", AcousticBrainzHintKeyKey, full[AcousticBrainzHintKeyKey])
	}
	if value, ok := full[AcousticBrainzHintKeyScaleKey].(string); !ok || value != "minor" {
		t.Fatalf("%s = %#v, want string \"minor\"", AcousticBrainzHintKeyScaleKey, full[AcousticBrainzHintKeyScaleKey])
	}
	if value, ok := full[AcousticBrainzHintCamelotKey].(string); !ok || value != "8A" {
		t.Fatalf("%s = %#v, want string \"8A\"", AcousticBrainzHintCamelotKey, full[AcousticBrainzHintCamelotKey])
	}
	if value, ok := full[AcousticBrainzHintSourceKey].(string); !ok || value != db.AcousticBrainzSource {
		t.Fatalf("%s = %#v, want %q", AcousticBrainzHintSourceKey, full[AcousticBrainzHintSourceKey], db.AcousticBrainzSource)
	}
	if value, ok := full[AcousticBrainzHintDumpRevisionKey].(string); !ok || value != "acousticbrainz-dump-2022-06" {
		t.Fatalf("%s = %#v, want the pinned dump revision", AcousticBrainzHintDumpRevisionKey, full[AcousticBrainzHintDumpRevisionKey])
	}
	retrievedAt, ok := full[AcousticBrainzHintRetrievedAtKey].(string)
	if !ok {
		t.Fatalf("%s = %#v, want an RFC3339 string", AcousticBrainzHintRetrievedAtKey, full[AcousticBrainzHintRetrievedAtKey])
	}
	parsed, err := time.Parse(time.RFC3339, retrievedAt)
	if err != nil || !parsed.Equal(hintRetrievedAt) {
		t.Fatalf("%s = %q parsed=%v err=%v, want RFC3339 UTC %v", AcousticBrainzHintRetrievedAtKey, retrievedAt, parsed, err, hintRetrievedAt)
	}

	// The block is atomic but hit-only per column: a BPM-only row yields BPM plus
	// provenance and never invents a key or Camelot value.
	partial := resp.Results[1].Metadata
	if partial[AcousticBrainzHintBPMKey] != 174.0 || partial[AcousticBrainzHintSourceKey] != db.AcousticBrainzSource {
		t.Fatalf("bpm-only hint block = %#v, want bpm plus provenance", partial)
	}
	for _, key := range []string{AcousticBrainzHintKeyKey, AcousticBrainzHintKeyScaleKey, AcousticBrainzHintCamelotKey} {
		if _, ok := partial[key]; ok {
			t.Fatalf("bpm-only row invented %q: %#v", key, partial)
		}
	}

	// The published wire contract, witnessed by hardcoded strings instead of by
	// the constants themselves. Every other assertion in this package indexes
	// metadata through the AcousticBrainzHint*Key constants, which makes them
	// self-referential: renaming all seven literals would leave the suite green
	// while silently invalidating docs/ACOUSTICBRAINZ_IMPORT.md, any client
	// reading ab_bpm, and every selection snapshot already persisted with the old
	// keys. The literal db.AcousticBrainzSource value is pinned here for the same
	// reason. This loop is the one place that must be edited deliberately when
	// the published key names change.
	for key, want := range map[string]interface{}{
		"ab_bpm":           128.0,
		"ab_key":           "A",
		"ab_key_scale":     "minor",
		"ab_camelot":       "8A",
		"ab_source":        "acousticbrainz",
		"ab_dump_revision": "acousticbrainz-dump-2022-06",
		"ab_retrieved_at":  hintRetrievedAt.Format(time.RFC3339),
	} {
		if full[key] != want {
			t.Fatalf("published metadata key %q = %#v, want %#v (full block: %#v)", key, full[key], want, full)
		}
	}

	// Sections carry the same candidate metadata as the flat result list.
	if len(resp.Sections) != 1 || len(resp.Sections[0].Items) != 2 {
		t.Fatalf("sections = %#v, want one section with both candidates", resp.Sections)
	}
	if resp.Sections[0].Items[0].Candidate.Metadata[AcousticBrainzHintCamelotKey] != "8A" {
		t.Fatalf("section candidate lost the hint block: %#v", resp.Sections[0].Items[0].Candidate.Metadata)
	}

	block, err := json.Marshal(map[string]interface{}{
		AcousticBrainzHintBPMKey:          full[AcousticBrainzHintBPMKey],
		AcousticBrainzHintKeyKey:          full[AcousticBrainzHintKeyKey],
		AcousticBrainzHintKeyScaleKey:     full[AcousticBrainzHintKeyScaleKey],
		AcousticBrainzHintCamelotKey:      full[AcousticBrainzHintCamelotKey],
		AcousticBrainzHintSourceKey:       full[AcousticBrainzHintSourceKey],
		AcousticBrainzHintDumpRevisionKey: full[AcousticBrainzHintDumpRevisionKey],
		AcousticBrainzHintRetrievedAtKey:  full[AcousticBrainzHintRetrievedAtKey],
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("ab_* metadata block for a full row: %s", block)
}

// TestSearchOmitsAcousticBrainzCandidateHintsOnCacheMiss proves a miss writes no
// key at all: never provenance without a value.
func TestSearchOmitsAcousticBrainzCandidateHintsOnCacheMiss(t *testing.T) {
	source := &fakeAcousticBrainzHintSource{entries: map[uuid.UUID]db.AcousticBrainzEntry{}}
	svc := hintService(source, hintCandidate("miss", "mbRecordingId", hintRecordingMBID))

	resp := svc.Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
	if len(resp.Results) != 1 {
		t.Fatalf("results = %#v, want one candidate", resp.Results)
	}
	if source.calls != 1 {
		t.Fatalf("lookup calls = %d, want exactly one batched cache read", source.calls)
	}
	assertNoAcousticBrainzHints(t, "cache-miss candidate", resp.Results[0].Metadata)

	// A row that somehow carries no usable value is treated as a miss too.
	valueless := uuid.MustParse(hintRecordingMBID)
	emptySource := &fakeAcousticBrainzHintSource{entries: map[uuid.UUID]db.AcousticBrainzEntry{
		valueless: {RecordingMBID: valueless, DumpRevision: "acousticbrainz-dump-2022-06", RetrievedAt: sql.NullTime{Time: hintRetrievedAt, Valid: true}},
	}}
	emptyResp := hintService(emptySource, hintCandidate("valueless", "mbRecordingId", hintRecordingMBID)).
		Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
	assertNoAcousticBrainzHints(t, "valueless cache row", emptyResp.Results[0].Metadata)
}

// TestSearchSkipsAcousticBrainzLookupWhenNoCandidateCarriesRecordingMBID proves
// the resolver never errors and never triggers a lookup for unusable values.
func TestSearchSkipsAcousticBrainzLookupWhenNoCandidateCarriesRecordingMBID(t *testing.T) {
	cases := []struct {
		name     string
		metadata map[string]interface{}
	}{
		{name: "nil metadata", metadata: nil},
		{name: "absent key", metadata: map[string]interface{}{"track": "Song"}},
		{name: "empty string", metadata: map[string]interface{}{"mbRecordingId": ""}},
		{name: "whitespace only", metadata: map[string]interface{}{"mb_recording_id": "   "}},
		{name: "not a uuid", metadata: map[string]interface{}{"mbRecordingId": "not-a-uuid"}},
		{name: "non string", metadata: map[string]interface{}{"mbRecordingId": 123}},
		{name: "explicit nil", metadata: map[string]interface{}{"mbRecordingId": nil}},
		{name: "nil uuid", metadata: map[string]interface{}{"mbRecordingId": uuid.Nil.String()}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got, ok := candidateRecordingMBID(tc.metadata); ok || got != uuid.Nil {
				t.Fatalf("candidateRecordingMBID = %v, %v; want uuid.Nil, false", got, ok)
			}
			source := &fakeAcousticBrainzHintSource{hitAny: true}
			candidate := hintCandidate("skip", "", "")
			candidate.Metadata = tc.metadata
			resp := hintService(source, candidate).Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
			if source.calls != 0 {
				t.Fatalf("lookup calls = %d, want 0 when no candidate carries a recording MBID", source.calls)
			}
			if len(resp.Results) != 1 {
				t.Fatalf("results = %#v, want one candidate", resp.Results)
			}
			assertNoAcousticBrainzHints(t, tc.name, resp.Results[0].Metadata)
		})
	}
}

// TestSearchBatchesOneAcousticBrainzLookupPerCandidateResponse proves the batch
// is deduplicated and issued exactly once per response, never per candidate.
func TestSearchBatchesOneAcousticBrainzLookupPerCandidateResponse(t *testing.T) {
	source := &fakeAcousticBrainzHintSource{hitAny: true}
	svc := hintService(source,
		hintCandidate("one", "mbRecordingId", hintRecordingMBID),
		hintCandidate("two", "mbRecordingId", hintOtherRecordingMBID),
		hintCandidate("three", "mb_recording_id", hintRecordingMBID),
		hintCandidate("four", "mbRecordingId", hintThirdRecordingMBID),
		hintCandidate("five", "mbRecordingId", hintOtherRecordingMBID),
	)

	resp := svc.Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
	if len(resp.Results) != 5 {
		t.Fatalf("results = %#v, want five candidates", resp.Results)
	}
	if source.calls != 1 {
		t.Fatalf("lookup calls = %d, want exactly 1 batched call for the whole response", source.calls)
	}
	if len(source.lastBatch) != 3 {
		t.Fatalf("batch = %v, want three deduplicated MBIDs", source.lastBatch)
	}
	unique := map[uuid.UUID]struct{}{}
	for _, id := range source.lastBatch {
		unique[id] = struct{}{}
	}
	for _, want := range []string{hintRecordingMBID, hintOtherRecordingMBID, hintThirdRecordingMBID} {
		if _, ok := unique[uuid.MustParse(want)]; !ok {
			t.Fatalf("batch %v missing %s", source.lastBatch, want)
		}
	}
	if len(unique) != 3 {
		t.Fatalf("batch %v contains duplicates", source.lastBatch)
	}
	for index := range resp.Results {
		if resp.Results[index].Metadata[AcousticBrainzHintSourceKey] != db.AcousticBrainzSource {
			t.Fatalf("candidate %d lost the hint block: %#v", index, resp.Results[index].Metadata)
		}
	}
}

// TestSearchAcousticBrainzCandidateHintLookupFailureIsNonFatal proves a failing
// or expired lookup degrades to exactly the no-hint-source response.
func TestSearchAcousticBrainzCandidateHintLookupFailureIsNonFatal(t *testing.T) {
	baseline := hintService(nil, hintCandidate("one", "mbRecordingId", hintRecordingMBID)).
		Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
	baselineJSON := hintEnvelopeJSON(t, baseline)

	t.Run("lookup error", func(t *testing.T) {
		source := &fakeAcousticBrainzHintSource{err: errors.New("boom")}
		resp := hintService(source, hintCandidate("one", "mbRecordingId", hintRecordingMBID)).
			Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
		if source.calls != 1 {
			t.Fatalf("lookup calls = %d, want one attempted call", source.calls)
		}
		if len(resp.Results) != len(baseline.Results) || len(resp.Providers) != len(baseline.Providers) {
			t.Fatalf("failed lookup changed the envelope: %#v", resp)
		}
		if got := hintEnvelopeJSON(t, resp); got != baselineJSON {
			t.Fatalf("failed lookup response =\n%s\nwant nil-source response =\n%s", got, baselineJSON)
		}
	})

	t.Run("cancelled parent context", func(t *testing.T) {
		source := &fakeAcousticBrainzHintSource{hitAny: true}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		resp := hintService(source, hintCandidate("one", "mbRecordingId", hintRecordingMBID)).
			Search(ctx, "Artist Song", []string{"youtube"}, 10)
		for index := range resp.Results {
			assertNoAcousticBrainzHints(t, "cancelled-context candidate", resp.Results[index].Metadata)
		}
	})
}

// TestSearchCandidatePayloadIsIdenticalWhenAcousticBrainzTableIsEmpty is the
// no-op guarantee: an empty cache table produces a byte-identical envelope to
// having no hint source at all.
func TestSearchCandidatePayloadIsIdenticalWhenAcousticBrainzTableIsEmpty(t *testing.T) {
	fixtures := func() []Candidate {
		return []Candidate{
			hintCandidate("one", "mbRecordingId", hintRecordingMBID),
			hintCandidate("two", "", ""),
		}
	}

	disabled := hintEnvelopeJSON(t, hintService(nil, fixtures()...).Search(context.Background(), "Artist Song", []string{"youtube"}, 10))
	// An empty table is exactly what the real repository returns: an empty,
	// non-nil map and a nil error.
	emptyTable := &fakeAcousticBrainzHintSource{entries: map[uuid.UUID]db.AcousticBrainzEntry{}}
	enabled := hintEnvelopeJSON(t, hintService(emptyTable, fixtures()...).Search(context.Background(), "Artist Song", []string{"youtube"}, 10))
	if enabled != disabled {
		t.Fatalf("empty-table response =\n%s\nwant byte-identical to nil-source response =\n%s", enabled, disabled)
	}
	if emptyTable.calls != 1 {
		t.Fatalf("lookup calls = %d, want one batched read even against an empty table", emptyTable.calls)
	}
}

// TestSearchHandlerPersistsAcousticBrainzCandidateHintsInSelectionSnapshot
// proves the untrusted discovery selection snapshot carries the hints forward,
// and that an empty table leaves the snapshot byte-identical.
func TestSearchHandlerPersistsAcousticBrainzCandidateHintsInSelectionSnapshot(t *testing.T) {
	fixtures := func() []Candidate {
		return []Candidate{hintCandidate("one", "mbRecordingId", hintRecordingMBID)}
	}
	searchRequest := func() *http.Request {
		request := httptest.NewRequest(http.MethodGet, "/api/v1/discovery/search?q=first", nil)
		return request.WithContext(context.WithValue(request.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.New()}))
	}

	hitStore := &captureSelectionStore{}
	hitHandlers := NewHandlersWithAssistAndSelectionStore(hintService(&fakeAcousticBrainzHintSource{hitAny: true}, fixtures()...), nil, hitStore)
	recorder := httptest.NewRecorder()
	hitHandlers.Search(recorder, searchRequest())
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", recorder.Code, recorder.Body.String())
	}
	if hitStore.session == nil || len(hitStore.session.Candidates) == 0 {
		t.Fatalf("persisted session = %#v", hitStore.session)
	}
	var persisted []Candidate
	if err := json.Unmarshal(hitStore.session.Candidates, &persisted); err != nil {
		t.Fatal(err)
	}
	if len(persisted) != 1 {
		t.Fatalf("persisted candidates = %#v, want one", persisted)
	}
	for _, key := range acousticBrainzHintKeys() {
		if _, ok := persisted[0].Metadata[key]; !ok {
			t.Fatalf("selection snapshot dropped %q: %s", key, hitStore.session.Candidates)
		}
	}
	if persisted[0].Metadata[AcousticBrainzHintSourceKey] != db.AcousticBrainzSource {
		t.Fatalf("selection snapshot provenance = %#v", persisted[0].Metadata[AcousticBrainzHintSourceKey])
	}

	disabledStore := &captureSelectionStore{}
	disabledHandlers := NewHandlersWithAssistAndSelectionStore(hintService(nil, fixtures()...), nil, disabledStore)
	disabledRecorder := httptest.NewRecorder()
	disabledHandlers.Search(disabledRecorder, searchRequest())
	emptyStore := &captureSelectionStore{}
	emptyHandlers := NewHandlersWithAssistAndSelectionStore(
		hintService(&fakeAcousticBrainzHintSource{entries: map[uuid.UUID]db.AcousticBrainzEntry{}}, fixtures()...),
		nil,
		emptyStore,
	)
	emptyRecorder := httptest.NewRecorder()
	emptyHandlers.Search(emptyRecorder, searchRequest())
	if disabledStore.session == nil || emptyStore.session == nil {
		t.Fatalf("sessions = %#v / %#v", disabledStore.session, emptyStore.session)
	}
	if string(emptyStore.session.Candidates) != string(disabledStore.session.Candidates) {
		t.Fatalf("empty-table snapshot =\n%s\nwant byte-identical to nil-source snapshot =\n%s", emptyStore.session.Candidates, disabledStore.session.Candidates)
	}
}

// TestAssistSearchCandidatesCarryAcousticBrainzHints proves SearchRanked shares
// the single attach site, so the assist envelope carries the same block.
func TestAssistSearchCandidatesCarryAcousticBrainzHints(t *testing.T) {
	source := &fakeAcousticBrainzHintSource{hitAny: true}
	svc := NewAssistService(AssistConfig{
		Client: &fakeAssistClient{intent: &aiassist.Intent{Kind: aiassist.KindSearch, SearchQuery: "Artist Song", Providers: []string{"youtube"}}},
		Search: hintService(source, hintCandidate("one", "mbRecordingId", hintRecordingMBID)),
	})

	resp := svc.Assist(context.Background(), "find Artist Song", 0)
	if resp.Search == nil || len(resp.Search.Results) != 1 {
		t.Fatalf("assist search envelope = %#v", resp.Search)
	}
	metadata := resp.Search.Results[0].Metadata
	for _, key := range acousticBrainzHintKeys() {
		if _, ok := metadata[key]; !ok {
			t.Fatalf("assist candidate missing %q: %#v", key, metadata)
		}
	}
	if source.calls != 1 {
		t.Fatalf("lookup calls = %d, want one batched read shared with the ranked search path", source.calls)
	}
}

// TestResolveURLCandidateNeverCarriesAcousticBrainzHints pins the structural
// fact that the direct-URL path cannot carry a recording MBID: the resolver
// writes only resolvedFrom/mediaType/titleResolved plus sourceQuality, so a hint
// source that would hit on any MBID is never even consulted.
func TestResolveURLCandidateNeverCarriesAcousticBrainzHints(t *testing.T) {
	source := &fakeAcousticBrainzHintSource{hitAny: true}
	h := NewHandlersWithAssistAndSelectionStore(hintService(source), nil, &captureSelectionStore{})

	recorder := httptest.NewRecorder()
	h.ResolveURL(recorder, httptest.NewRequest(
		http.MethodPost,
		"/api/v1/discovery/resolve-url",
		strings.NewReader(`{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}`),
	))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", recorder.Code, recorder.Body.String())
	}
	var response ResolveURLResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Candidate.Metadata["resolvedFrom"] != "direct_url" {
		t.Fatalf("resolved candidate metadata = %#v", response.Candidate.Metadata)
	}
	assertNoAcousticBrainzHints(t, "resolve-url candidate", response.Candidate.Metadata)
	if source.calls != 0 {
		t.Fatalf("lookup calls = %d, want 0 on the direct-URL path", source.calls)
	}

	// The assist direct-URL branch shares the same resolver and is equally inert.
	assistResp := NewAssistService(AssistConfig{Search: hintService(source)}).
		Assist(context.Background(), "queue https://www.youtube.com/watch?v=dQw4w9WgXcQ", 0)
	if len(assistResp.Candidates) != 1 {
		t.Fatalf("assist direct-url candidates = %#v", assistResp.Candidates)
	}
	assertNoAcousticBrainzHints(t, "assist direct-url candidate", assistResp.Candidates[0].Metadata)
	if source.calls != 0 {
		t.Fatalf("lookup calls = %d after assist direct-url, want 0", source.calls)
	}
}

// failingRoundTripper fails the test if the hint path ever reaches the network.
type failingRoundTripper struct{ t *testing.T }

func (rt failingRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	rt.t.Fatalf("AcousticBrainz hint path performed an HTTP request: %s", req.URL)
	return nil, errors.New("unreachable")
}

// TestAcousticBrainzCandidateHintSourceIsCacheOnlyByConstruction encodes the
// policy that AcousticBrainz is a dump-loaded cache only: no runtime
// AcousticBrainz network client exists in this repository, and none may be added
// behind the hint seam. Submissions to AcousticBrainz ended in 2022 and the
// dump is frozen, so a live fetch would be both useless and a new external
// dependency on a read path that must stay cheap and non-blocking.
func TestAcousticBrainzCandidateHintSourceIsCacheOnlyByConstruction(t *testing.T) {
	t.Run("seam shape", func(t *testing.T) {
		seam := reflect.TypeOf((*AcousticBrainzHintSource)(nil)).Elem()
		if seam.NumMethod() != 1 {
			names := make([]string, 0, seam.NumMethod())
			for index := 0; index < seam.NumMethod(); index++ {
				names = append(names, seam.Method(index).Name)
			}
			t.Fatalf("AcousticBrainzHintSource methods = %v, want exactly one cache read", names)
		}
		if got := seam.Method(0).Name; got != "GetAcousticBrainzByRecordingIDs" {
			t.Fatalf("AcousticBrainzHintSource method = %q, want GetAcousticBrainzByRecordingIDs", got)
		}
	})

	t.Run("production hint source carries no HTTP transport", func(t *testing.T) {
		assertNoHTTPTypes(t, reflect.TypeOf(db.AnalysisRepository{}), 2, nil)
	})

	t.Run("runtime guard", func(t *testing.T) {
		original := http.DefaultTransport
		http.DefaultTransport = failingRoundTripper{t: t}
		defer func() { http.DefaultTransport = original }()

		source := &fakeAcousticBrainzHintSource{hitAny: true}
		resp := hintService(source, hintCandidate("one", "mbRecordingId", hintRecordingMBID)).
			Search(context.Background(), "Artist Song", []string{"youtube"}, 10)
		if len(resp.Results) != 1 || resp.Results[0].Metadata[AcousticBrainzHintSourceKey] != db.AcousticBrainzSource {
			t.Fatalf("hints did not attach under the no-network guard: %#v", resp.Results)
		}
	})
}

// assertNoHTTPTypes walks a struct type to a bounded depth and fails on any HTTP
// client or transport field. It stops at database/sql types, which are the
// intended terminal shape of the production hint source.
func assertNoHTTPTypes(t *testing.T, typ reflect.Type, depth int, path []string) {
	t.Helper()
	for typ.Kind() == reflect.Pointer {
		typ = typ.Elem()
	}
	if typ.PkgPath() == "database/sql" || typ.Kind() != reflect.Struct || depth < 0 {
		return
	}
	for index := 0; index < typ.NumField(); index++ {
		field := typ.Field(index)
		fieldType := field.Type
		for fieldType.Kind() == reflect.Pointer {
			fieldType = fieldType.Elem()
		}
		where := append(append([]string(nil), path...), typ.Name()+"."+field.Name)
		switch {
		case fieldType.PkgPath() == "net/http",
			fieldType == reflect.TypeOf(url.URL{}),
			field.Type == reflect.TypeOf((*http.RoundTripper)(nil)).Elem():
			t.Fatalf("hint source field %s has HTTP-shaped type %s; AcousticBrainz must stay cache-only", strings.Join(where, " -> "), field.Type)
		}
		assertNoHTTPTypes(t, fieldType, depth-1, where)
	}
}
