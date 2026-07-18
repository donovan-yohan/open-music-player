package research

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/discovery"
)

type fixtureSearch struct {
	response discovery.SourceSearchResponse
	seen     []string
}

func (f *fixtureSearch) SearchSources(_ context.Context, _ string, providers []string, _ int) discovery.SourceSearchResponse {
	f.seen = append([]string(nil), providers...)
	return f.response
}

func TestBaselineBuilderSortsAndGroundsPayload(t *testing.T) {
	search := &fixtureSearch{response: discovery.SourceSearchResponse{Results: []discovery.Candidate{
		{CandidateID: "soundcloud:late", Provider: "soundcloud", SourceURL: "https://soundcloud.com/a/late", Title: "Artist - Song (Live)", Downloadable: true},
		{CandidateID: "youtube:official", Provider: "youtube", SourceURL: "https://www.youtube.com/watch?v=one", Title: "Artist - Song (Official Audio)", Downloadable: true},
	}}}
	builder, err := NewBaselineBuilder(BaselineBuilderConfig{Search: search, Providers: []string{"youtube", "soundcloud"}, MaxCandidates: 10, NewID: func() string { return "revision-1" }, Now: func() time.Time { return time.Unix(1, 0) }})
	if err != nil {
		t.Fatal(err)
	}
	input, err := builder.Build(context.Background(), "Artist Song", []string{"soundcloud", "youtube", "bad"}, 2)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := ParseRevisionPayload(input.Payload)
	if err != nil {
		t.Fatal(err)
	}
	if input.ID != "revision-1" || payload.Stage != StageBaseline || payload.Candidates[0].CandidateID != "youtube:official" {
		t.Fatalf("payload = %#v", payload)
	}
	if payload.Candidates[0].SourceQuality.Recommendation != discovery.SourceQualityPreferred {
		t.Fatalf("official-audio baseline fixture recommendation = %q, want production %q", payload.Candidates[0].SourceQuality.Recommendation, discovery.SourceQualityPreferred)
	}
	if !strings.Contains(string(input.Payload), "sourceUrl") || len(search.seen) != 2 {
		t.Fatalf("baseline lost server URL or provider clamp: %s %#v", input.Payload, search.seen)
	}
	if err := NewPayloadValidator().ValidateBaseline(context.Background(), input); err != nil {
		t.Fatal(err)
	}
}

func TestBaselineBuilderYouTubeMusicQualityPassesValidation(t *testing.T) {
	search := &fixtureSearch{response: discovery.SourceSearchResponse{Results: []discovery.Candidate{{
		CandidateID: "youtube:music", Provider: "youtube", SourceURL: "https://www.youtube.com/watch?v=music", Title: "iPod Touch", Artist: "Ninajirachi", Downloadable: true,
		Metadata: map[string]interface{}{"discoverySurface": "youtube_music_songs"},
	}}}}
	builder, err := NewBaselineBuilder(BaselineBuilderConfig{Search: search, NewID: func() string { return "revision-music" }})
	if err != nil {
		t.Fatal(err)
	}
	input, err := builder.Build(context.Background(), "Ninajirachi iPod Touch", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := ParseRevisionPayload(input.Payload)
	if err != nil {
		t.Fatal(err)
	}
	quality := payload.Candidates[0].SourceQuality
	if quality.Classification != discovery.SourceQualityOfficialAudio || quality.Recommendation != discovery.SourceQualityPreferred {
		t.Fatalf("YouTube Music quality = %#v, want official/preferred", quality)
	}
	if strings.Contains(string(input.Payload), "discoverySurface") {
		t.Fatalf("baseline persisted raw discovery metadata: %s", input.Payload)
	}
	if err := NewPayloadValidator().ValidateBaseline(context.Background(), input); err != nil {
		t.Fatalf("ValidateBaseline() rejected builder-owned YouTube Music quality: %v", err)
	}
}

func TestValidateBaselineRejectsUnknownSourceQualityEnums(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*RevisionPayload)
	}{
		{name: "classification", mutate: func(payload *RevisionPayload) {
			payload.Candidates[0].SourceQuality.Classification = "invented_quality"
		}},
		{name: "recommendation", mutate: func(payload *RevisionPayload) {
			payload.Candidates[0].SourceQuality.Recommendation = "invented_recommendation"
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			baseline := baselineForTest(t)
			payload, err := ParseRevisionPayload(baseline.Payload)
			if err != nil {
				t.Fatal(err)
			}
			test.mutate(&payload)
			raw := mustJSON(t, payload)
			if _, err := ParseRevisionPayload(raw); err == nil {
				t.Fatalf("ParseRevisionPayload() accepted unknown source-quality %s", test.name)
			}
			if err := NewPayloadValidator().ValidateBaseline(context.Background(), RevisionInput{ID: baseline.ID, Payload: raw}); err == nil {
				t.Fatalf("ValidateBaseline() accepted unknown source-quality %s", test.name)
			}
		})
	}
}

func TestWorkerProjectionAndEnhancementRejectLeaksAndInventedCandidates(t *testing.T) {
	baseline := baselineForTest(t)
	payload, err := ParseRevisionPayload(baseline.Payload)
	if err != nil {
		t.Fatal(err)
	}
	projection, err := WorkerProjection(payload.Candidates)
	if err != nil || strings.Contains(string(mustJSON(t, projection)), "sourceUrl") {
		t.Fatalf("projection leaked URL: %v %s", err, mustJSON(t, projection))
	}
	enhancement := payload
	enhancement.Stage = StageDirectJudge
	enhancement.Provenance = Provenance{Source: "candidate_assembly_worker", WorkerSchemaVersion: "omp.agent-search.worker.revision.v1"}
	enhancement.Recommendations[0].Rationale = "grounded result"
	raw, err := enhancement.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	snapshot := Snapshot{Revisions: []Revision{{Kind: RevisionBaseline, Payload: baseline.Payload}}}
	validator := NewPayloadValidator()
	if err := validator.ValidateEnhancement(context.Background(), snapshot, RevisionInput{ID: "revision-2", Payload: raw}); err != nil {
		t.Fatal(err)
	}
	enhancement.Recommendations[0].Rationale = "https://leak.invalid/token"
	raw, _ = json.Marshal(enhancement)
	if err := validator.ValidateEnhancement(context.Background(), snapshot, RevisionInput{ID: "revision-2", Payload: raw}); err == nil {
		t.Fatal("accepted URL rationale")
	}
	enhancement = payload
	enhancement.Stage = StageDeepAgent
	enhancement.Candidates[0].CandidateID = "invented"
	raw, _ = json.Marshal(enhancement)
	if err := validator.ValidateEnhancement(context.Background(), snapshot, RevisionInput{ID: "revision-3", Payload: raw}); err == nil {
		t.Fatal("accepted invented candidate")
	}
}

func baselineForTest(t *testing.T) RevisionInput {
	t.Helper()
	search := &fixtureSearch{response: discovery.SourceSearchResponse{Results: []discovery.Candidate{{CandidateID: "youtube:one", Provider: "youtube", SourceURL: "https://youtube.com/watch?v=one", Title: "Song Official Audio", Downloadable: true}}}}
	builder, err := NewBaselineBuilder(BaselineBuilderConfig{Search: search, NewID: func() string { return "revision-1" }})
	if err != nil {
		t.Fatal(err)
	}
	input, err := builder.Build(context.Background(), "song", nil, 1)
	if err != nil {
		t.Fatal(err)
	}
	return input
}
func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
