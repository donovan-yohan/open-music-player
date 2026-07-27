package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/testutil"
)

func TestNewAnalysisResponsePreservesUpdatedAtPrecision(t *testing.T) {
	updatedAt := time.Date(2026, 7, 10, 12, 0, 0, 123456000, time.FixedZone("offset", 3600))
	response := newAnalysisResponse(&db.TrackAnalysis{
		TrackID:     42,
		Status:      db.AnalysisStatusAnalyzed,
		RequestedAt: time.Date(2026, 7, 10, 10, 0, 0, 0, time.UTC),
		UpdatedAt:   updatedAt,
		Error:       sql.NullString{},
	})

	if got, want := response.UpdatedAt, "2026-07-10T11:00:00.123456Z"; got != want {
		t.Fatalf("updated_at = %q, want %q", got, want)
	}
}

func TestNewAnalysisResponseKeepsDetailArraysInArtifactsOnly(t *testing.T) {
	response := newAnalysisResponse(&db.TrackAnalysis{
		TrackID: 42,
		Status:  db.AnalysisStatusAnalyzed,
		SummaryJSON: json.RawMessage(`{
			"waveform":{
				"sample_count":3,
				"channels":{
					"channel_set":"bands3-v1",
					"values":{"low":{"artifact_ref":"channels.detail.low"}}
				}
			}
		}`),
		ArtifactsJSON: json.RawMessage(`{
			"waveforms":{"detail":{"minima":[-0.8,-0.2,-0.5],"maxima":[0.7,0.3,0.6]}},
			"channels":{"detail":{"low":[0.2,0.5,0.3]}}
		}`),
		RequestedAt: time.Date(2026, 7, 24, 10, 0, 0, 0, time.UTC),
		UpdatedAt:   time.Date(2026, 7, 24, 10, 1, 0, 0, time.UTC),
	})

	if strings.Contains(string(response.Summary), `"minima"`) ||
		strings.Contains(string(response.Summary), `"[0.2,0.5,0.3]"`) {
		t.Fatalf("summary contains detail arrays: %s", response.Summary)
	}
	if !strings.Contains(string(response.Artifacts), `"minima"`) ||
		!strings.Contains(string(response.Artifacts), `"low":[0.2,0.5,0.3]`) {
		t.Fatalf("detail artifacts missing arrays: %s", response.Artifacts)
	}
}

func TestDecodeAnalysisOverridesRequestAcceptsCompactBody(t *testing.T) {
	req := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/tracks/42/analysis/overrides",
		strings.NewReader(`{"overrides":{"bpm":{"value":124}}}`),
	)
	w := httptest.NewRecorder()

	decoded, err := decodeAnalysisOverridesRequest(w, req)
	if err != nil {
		t.Fatalf("decode compact overrides: %v", err)
	}
	if len(decoded.Overrides) == 0 {
		t.Fatal("expected overrides payload")
	}
}

func TestDecodeAnalysisOverridesRequestRejectsOversizedBody(t *testing.T) {
	body := `{"overrides":{"padding":"` +
		strings.Repeat("a", maxAnalysisOverridesRequestBytes) +
		`"}}`
	req := httptest.NewRequest(
		http.MethodPatch,
		"/api/v1/tracks/42/analysis/overrides",
		strings.NewReader(body),
	)
	w := httptest.NewRecorder()

	if _, err := decodeAnalysisOverridesRequest(w, req); err == nil {
		t.Fatal("expected oversized overrides body to fail")
	}
}

func TestUpdateTrackAnalysisOverridesRevisionContractAgainstPostgres(t *testing.T) {
	database := newAnalysisHandlerTestDB(t)
	ctx := context.Background()
	userID := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		userID, "analysis-override@example.test", "analysis-override", "x",
	); err != nil {
		t.Fatalf("seed analysis user: %v", err)
	}

	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Analysis Override Contract",
		"",
		120000,
		db.WithStorage("tracks/fixture/analysis-override-contract.wav", 1024),
		db.WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatalf("seed analysis track: %v", err)
	}
	if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, track.ID); err != nil {
		t.Fatalf("add analysis track to library: %v", err)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, db.AnalysisResult{
		SummaryJSON: json.RawMessage(`{"bpm":{"value":119},"beat_grid":{"beats_ms":[0,504,1008]}}`),
	}); err != nil {
		t.Fatalf("seed generated analysis: %v", err)
	}

	handler := NewAnalysisHandlers(analysisRepo, libraryRepo)
	update := func(body string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(
			http.MethodPatch,
			"/api/v1/tracks/"+strconv.FormatInt(track.ID, 10)+"/analysis/overrides",
			strings.NewReader(body),
		)
		req.SetPathValue("track_id", strconv.FormatInt(track.ID, 10))
		req = req.WithContext(context.WithValue(
			req.Context(),
			auth.UserContextKey,
			&auth.UserContext{UserID: userID, Email: "analysis-override@example.test"},
		))
		recorder := httptest.NewRecorder()
		handler.UpdateTrackAnalysisOverrides(recorder, req)
		return recorder
	}

	success := update(`{
		"overrides":{"manual_timing_override":{"bpm":120,"beat_anchor_ms":0}},
		"expected_revision":0
	}`)
	if success.Code != http.StatusOK {
		t.Fatalf("initial update status = %d, body = %s", success.Code, success.Body.String())
	}
	var response AnalysisResponse
	if err := json.NewDecoder(success.Body).Decode(&response); err != nil {
		t.Fatalf("decode initial update response: %v", err)
	}
	if response.OverrideRevision != 1 {
		t.Fatalf("initial update override_revision = %d, want 1", response.OverrideRevision)
	}
	var responseOverrides map[string]any
	if err := json.Unmarshal(response.Overrides, &responseOverrides); err != nil {
		t.Fatalf("decode projected overrides: %v", err)
	}
	if _, present := responseOverrides["manual_timing_override"]; present {
		t.Fatal("response dual-emitted provisional manual_timing_override")
	}
	if got := responseOverrides["manual_timing_v2"].(map[string]any)["schema_version"]; got != float64(2) {
		t.Fatalf("response manual timing schema = %#v, want 2", got)
	}
	var effectiveTiming map[string]any
	if err := json.Unmarshal(response.EffectiveTiming, &effectiveTiming); err != nil {
		t.Fatalf("decode effective timing: %v", err)
	}
	if got := effectiveTiming["bpm"].(map[string]any)["value"]; got != float64(120) {
		t.Fatalf("effective BPM = %#v, want 120", got)
	}

	stale := update(`{
		"overrides":{"manual_timing_override":{"bpm":122}},
		"expected_revision":0
	}`)
	assertAnalysisOverrideError(t, stale, http.StatusConflict, "ANALYSIS_OVERRIDE_CONFLICT")

	negative := update(`{"overrides":{},"expected_revision":-1}`)
	assertAnalysisOverrideError(t, negative, http.StatusBadRequest, "INVALID_REQUEST")

	stored, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatalf("read analysis after rejected updates: %v", err)
	}
	if stored.ManualOverrideRevision != 1 {
		t.Fatalf("rejected updates changed override revision to %d", stored.ManualOverrideRevision)
	}
}

func newAnalysisHandlerTestDB(t *testing.T) *db.DB {
	t.Helper()
	dsn := testutil.PostgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run analysis handler integration tests")
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open analysis handler Postgres: %v", err)
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &db.DB{DB: raw}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping analysis handler Postgres: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate analysis handler Postgres: %v", err)
	}
	if _, err := database.Exec(`TRUNCATE TABLE users, tracks RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate analysis handler tables: %v", err)
	}
	return database
}

func assertAnalysisOverrideError(t *testing.T, recorder *httptest.ResponseRecorder, wantStatus int, wantCode string) {
	t.Helper()
	if recorder.Code != wantStatus {
		t.Fatalf("update status = %d, want %d; body = %s", recorder.Code, wantStatus, recorder.Body.String())
	}
	var response LibraryErrorResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode update error response: %v", err)
	}
	if response.Code != wantCode {
		t.Fatalf("update error code = %q, want %q", response.Code, wantCode)
	}
}

func TestNormalizeAnalysisOverridesMarksManualTimingCorrectionsTrusted(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"value":124,"confidence":0.2,"provenance":"analyzer"},
		"beat_grid":{"bpm":124,"beats_ms":[120,604,1088]},
		"downbeats":{"positions_ms":[120,2056],"confidence":0.419}
	}`))
	if err != nil {
		t.Fatalf("normalize analysis overrides: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized overrides: %v", err)
	}
	for _, field := range []string{"bpm", "beat_grid", "downbeats"} {
		if got := overrides[field]["confidence"]; got != float64(1) {
			t.Fatalf("%s confidence = %#v, want 1", field, got)
		}
		if got := overrides[field]["provenance"]; got != manualAnalysisOverrideProvenance {
			t.Fatalf("%s provenance = %#v, want %q", field, got, manualAnalysisOverrideProvenance)
		}
	}
}

func TestNormalizeAnalysisOverridesCanonicalizesLegacyTimingAliases(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"nativeBpm":124},
		"beat_grid":{"offsetMs":12,"beatsMs":[0,484]},
		"downbeats":{"positionsMs":[0,1936]}
	}`))
	if err != nil {
		t.Fatalf("normalize aliases: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized aliases: %v", err)
	}
	bpm := overrides["bpm"]
	if got := bpm["value"]; got != float64(124) {
		t.Fatalf("canonical BPM value = %#v, want 124", got)
	}
	if _, ok := bpm["nativeBpm"]; ok {
		t.Fatal("legacy BPM alias survived normalization")
	}
	beatGrid := overrides["beat_grid"]
	if got := beatGrid["offset_ms"]; got != float64(12) {
		t.Fatalf("canonical beat-grid offset = %#v, want 12", got)
	}
	if got := beatGrid["beats_ms"]; !sameJSONNumbers(got, []float64{0, 484}) {
		t.Fatalf("canonical beat-grid markers = %#v", got)
	}
	if _, ok := beatGrid["offsetMs"]; ok {
		t.Fatal("legacy offset alias survived normalization")
	}
	if _, ok := beatGrid["beatsMs"]; ok {
		t.Fatal("legacy beats alias survived normalization")
	}
	downbeats := overrides["downbeats"]
	if got := downbeats["positions_ms"]; !sameJSONNumbers(got, []float64{0, 1936}) {
		t.Fatalf("canonical downbeats = %#v", got)
	}
	if _, ok := downbeats["positionsMs"]; ok {
		t.Fatal("legacy downbeat alias survived normalization")
	}
}

func TestNormalizeAnalysisOverridesPrefersCanonicalTimingFields(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"value":124,"nativeBpm":126},
		"beat_grid":{"offset_ms":12,"offsetMs":24,"beats_ms":[0,484],"beatsMs":[1,485]},
		"downbeats":{"positions_ms":[0,1936],"positionsMs":[1,1937]}
	}`))
	if err != nil {
		t.Fatalf("normalize mixed aliases: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized mixed aliases: %v", err)
	}
	if got := overrides["bpm"]["value"]; got != float64(124) {
		t.Fatalf("canonical BPM value = %#v, want 124", got)
	}
	if got := overrides["beat_grid"]["offset_ms"]; got != float64(12) {
		t.Fatalf("canonical grid offset = %#v, want 12", got)
	}
	if got := overrides["downbeats"]["positions_ms"]; !sameJSONNumbers(got, []float64{0, 1936}) {
		t.Fatalf("canonical downbeats = %#v", got)
	}
}

func TestNormalizeAnalysisOverridesKeepsOffsetOnlyGridUntrusted(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"beat_grid":{"offset_ms":87,"confidence":1,"provenance":"manual_override"}
	}`))
	if err != nil {
		t.Fatalf("normalize offset-only override: %v", err)
	}

	var overrides map[string]map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatalf("decode normalized offset-only override: %v", err)
	}
	grid := overrides["beat_grid"]
	if got := grid["offset_ms"]; got != float64(87) {
		t.Fatalf("offset = %#v, want 87", got)
	}
	if _, ok := grid["confidence"]; ok {
		t.Fatal("offset-only override retained grid-wide confidence")
	}
	if _, ok := grid["provenance"]; ok {
		t.Fatal("offset-only override retained grid-wide provenance")
	}
}

func TestNormalizeAnalysisOverridesCanonicalManualTimingIsIndependent(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"value":121},
		"beat_grid":{"bpm":121,"beats_ms":[0,496,992]},
		"downbeats":{"positions_ms":[0]},
		"manual_timing_override":{
			"bpm":120,"beat_anchor_ms":12,"beats_per_bar":4,
			"downbeat_phase_index":1,"phrase_length_bars":8,
			"revision":99,"updated_at":"client-forged"
		}
	}`))
	if err != nil {
		t.Fatalf("normalize canonical timing: %v", err)
	}
	var overrides map[string]any
	if err := json.Unmarshal(normalized, &overrides); err != nil {
		t.Fatal(err)
	}
	if overrides["bpm"].(map[string]any)["value"] != float64(121) {
		t.Fatalf("legacy BPM fallback changed: %#v", overrides["bpm"])
	}
	if got := overrides["beat_grid"].(map[string]any)["beats_ms"].([]any); len(got) != 3 || got[1] != float64(496) {
		t.Fatalf("legacy beat-grid fallback changed: %#v", got)
	}
	if got := overrides["downbeats"].(map[string]any)["positions_ms"].([]any); len(got) != 1 || got[0] != float64(0) {
		t.Fatalf("legacy downbeat fallback changed: %#v", got)
	}
	timing := overrides["manual_timing_v2"].(map[string]any)
	if timing["schema_version"] != float64(2) {
		t.Fatalf("manual timing schema = %#v, want 2", timing["schema_version"])
	}
	if timing["confidence"] != float64(1) || timing["provenance"] != manualAnalysisOverrideProvenance {
		t.Fatalf("manual timing trust = %#v", timing)
	}
	if _, present := timing["revision"]; present {
		t.Fatal("client-supplied revision survived normalization")
	}
	if _, present := timing["updated_at"]; present {
		t.Fatal("client-supplied updated_at survived normalization")
	}
}

func TestNormalizeAnalysisOverridesCanonicalManualTimingRejectsAmbiguousPhase(t *testing.T) {
	for name, input := range map[string]string{
		"nonpositive bpm":       `{"manual_timing_override":{"bpm":0}}`,
		"BPM below floor":       `{"manual_timing_override":{"bpm":29.9}}`,
		"BPM above ceiling":     `{"manual_timing_override":{"bpm":300.1}}`,
		"negative anchor":       `{"manual_timing_override":{"beat_anchor_ms":-1}}`,
		"phase without meter":   `{"manual_timing_override":{"downbeat_phase_index":0}}`,
		"phase outside meter":   `{"manual_timing_override":{"beats_per_bar":4,"downbeat_phase_index":4}}`,
		"meter above ceiling":   `{"manual_timing_override":{"beats_per_bar":33}}`,
		"phrase is not spacing": `{"manual_timing_override":{"phrase_length_bars":0}}`,
		"phrase above ceiling":  `{"manual_timing_override":{"phrase_length_bars":129}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := normalizeAnalysisOverrides(json.RawMessage(input)); err == nil {
				t.Fatal("expected invalid manual timing override")
			}
		})
	}
}

func TestNormalizeAnalysisOverridesCanonicalWriteDoesNotRewriteLegacyFallback(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"bpm":{"nativeBpm":"legacy-unknown"},
		"beat_grid":{"offsetMs":12,"beatsMs":[0,"legacy-gap",1000]},
		"downbeats":{"positionsMs":[0,2000]},
		"manual_timing_override":{"bpm":120,"beat_anchor_ms":12}
	}`))
	if err != nil {
		t.Fatalf("canonical write rejected retained legacy fallback: %v", err)
	}
	var document map[string]any
	if err := json.Unmarshal(normalized, &document); err != nil {
		t.Fatal(err)
	}
	legacyBPM := document["bpm"].(map[string]any)
	if legacyBPM["nativeBpm"] != "legacy-unknown" {
		t.Fatalf("legacy BPM was rewritten: %#v", legacyBPM)
	}
	legacyGrid := document["beat_grid"].(map[string]any)
	if _, canonicalized := legacyGrid["beats_ms"]; canonicalized {
		t.Fatalf("legacy beat grid was canonicalized: %#v", legacyGrid)
	}
	if got := legacyGrid["beatsMs"].([]any)[1]; got != "legacy-gap" {
		t.Fatalf("legacy beat intent changed: %#v", legacyGrid)
	}
}

func TestNormalizeAnalysisOverridesAcceptsResetMetadataEnvelope(t *testing.T) {
	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"manual_timing_override":{"revision":4,"updated_at":"2026-07-26T00:00:00Z","confidence":1,"provenance":"manual_override"}
	}`))
	if err != nil {
		t.Fatalf("normalize reset metadata: %v", err)
	}
	var document map[string]any
	if err := json.Unmarshal(normalized, &document); err != nil {
		t.Fatal(err)
	}
	timing := document["manual_timing_v2"].(map[string]any)
	if _, present := timing["revision"]; present {
		t.Fatal("client revision survived reset normalization")
	}
	if timing["confidence"] != float64(1) || timing["provenance"] != manualAnalysisOverrideProvenance {
		t.Fatalf("reset manual trust = %#v", timing)
	}
}

func TestNormalizeAnalysisOverridesRequiresExactV2Schema(t *testing.T) {
	for name, input := range map[string]string{
		"missing": `{"manual_timing_v2":{"bpm":120}}`,
		"old":     `{"manual_timing_v2":{"schema_version":1,"bpm":120}}`,
		"future":  `{"manual_timing_v2":{"schema_version":3,"bpm":120}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := normalizeAnalysisOverrides(json.RawMessage(input)); err == nil {
				t.Fatal("expected schema validation error")
			}
		})
	}

	normalized, err := normalizeAnalysisOverrides(json.RawMessage(`{
		"manual_timing_v2":{
			"schema_version":2,
			"bpm":123,
			"revision":77,
			"updated_at":"forged",
			"confidence":0.1,
			"provenance":"forged"
		}
	}`))
	if err != nil {
		t.Fatalf("normalize v2: %v", err)
	}
	var document map[string]any
	if err := json.Unmarshal(normalized, &document); err != nil {
		t.Fatal(err)
	}
	timing := document["manual_timing_v2"].(map[string]any)
	if timing["schema_version"] != float64(2) ||
		timing["confidence"] != float64(1) ||
		timing["provenance"] != manualAnalysisOverrideProvenance {
		t.Fatalf("normalized v2 trust = %#v", timing)
	}
	if _, present := timing["revision"]; present {
		t.Fatal("forged v2 revision survived")
	}
	if _, present := timing["updated_at"]; present {
		t.Fatal("forged v2 timestamp survived")
	}
}

func TestNormalizeAnalysisOverridesCanonicalizesBareAndEmptyDownbeats(t *testing.T) {
	for name, input := range map[string]string{
		"bare markers":   `{"downbeats":[120,2056]}`,
		"explicit clear": `{"downbeats":[]}`,
	} {
		t.Run(name, func(t *testing.T) {
			normalized, err := normalizeAnalysisOverrides(json.RawMessage(input))
			if err != nil {
				t.Fatalf("normalize downbeats: %v", err)
			}
			var overrides map[string]map[string]any
			if err := json.Unmarshal(normalized, &overrides); err != nil {
				t.Fatalf("decode normalized downbeats: %v", err)
			}
			downbeats := overrides["downbeats"]
			if _, ok := downbeats["positions_ms"]; !ok {
				t.Fatal("canonical positions_ms is missing")
			}
			if got := downbeats["confidence"]; got != float64(1) {
				t.Fatalf("downbeat confidence = %#v, want 1", got)
			}
			if got := downbeats["provenance"]; got != manualAnalysisOverrideProvenance {
				t.Fatalf("downbeat provenance = %#v", got)
			}
		})
	}
}

func TestNormalizeAnalysisOverridesRejectsMalformedTimingValues(t *testing.T) {
	for name, input := range map[string]string{
		"BPM alias is text":             `{"bpm":{"nativeBpm":"fast"}}`,
		"grid is not an object":         `{"beat_grid":[120]}`,
		"grid offset is fractional":     `{"beat_grid":{"offsetMs":1.5}}`,
		"grid markers are malformed":    `{"beat_grid":{"beatsMs":[0,"bad"]}}`,
		"downbeats positions are text":  `{"downbeats":{"positionsMs":"bad"}}`,
		"bare downbeats are fractional": `{"downbeats":[0,1.5]}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := normalizeAnalysisOverrides(json.RawMessage(input)); err == nil {
				t.Fatal("expected malformed timing override to fail")
			}
		})
	}
}

func sameJSONNumbers(value any, want []float64) bool {
	values, ok := value.([]any)
	if !ok || len(values) != len(want) {
		return false
	}
	for index, expected := range want {
		if values[index] != expected {
			return false
		}
	}
	return true
}
