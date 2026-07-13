package discovery

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestOllamaSourceQualityRequestContractAndValidResponse(t *testing.T) {
	candidate := ollamaTestCandidate("youtube:clean")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/generate" || r.URL.RawQuery != "" {
			t.Fatalf("request = %s %s?%s", r.Method, r.URL.Path, r.URL.RawQuery)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Fatalf("Content-Type = %q", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("Authorization = %q", got)
		}
		var request ollamaGenerateRequest
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if request.Model != "test-model" || request.Stream || request.Options.NumPredict != ollamaNumPredict || request.Options.Temperature != ollamaTemperature {
			t.Fatalf("request fields = %#v", request)
		}
		if request.Format["type"] != "object" || request.Format["additionalProperties"] != false {
			t.Fatalf("format = %#v", request.Format)
		}
		schema, err := json.Marshal(request.Format)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(schema), "judgments") || strings.Contains(string(schema), "provenance") || strings.Contains(string(schema), "sourceUrl") {
			t.Fatalf("output schema not strict or leaked disallowed fields: %s", schema)
		}
		var prompt ollamaPrompt
		if err := json.Unmarshal([]byte(request.Prompt), &prompt); err != nil {
			t.Fatalf("prompt is not JSON: %v", err)
		}
		if prompt.Query != "artist song" || len(prompt.Candidates) != 1 {
			t.Fatalf("prompt = %#v", prompt)
		}
		got := prompt.Candidates[0]
		if got.CandidateID != candidate.CandidateID || got.Provider != candidate.Provider || got.SourceID != candidate.SourceID || got.SourceURL != candidate.SourceURL || got.Title != candidate.Title || got.Artist != candidate.Artist || got.Uploader != candidate.Uploader || got.DurationMs != candidate.DurationMs || got.Downloadable != candidate.Downloadable {
			t.Fatalf("candidate prompt record = %#v", got)
		}
		if values := got.MetadataHints["description"]; len(values) != 1 || values[0] != "official upload" {
			t.Fatalf("metadata hints = %#v", got.MetadataHints)
		}
		_, _ = w.Write([]byte(ollamaTestEnvelopeWithExtras(t, ollamaTestInner("youtube:clean"))))
	}))
	defer server.Close()

	judge := NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{Enabled: true, BaseURL: server.URL, Model: "test-model", APIKey: "test-key"})
	judgments, err := judge.JudgeSourceQuality(context.Background(), "artist song", []SourceQualityCandidateFeature{candidate})
	if err != nil {
		t.Fatalf("JudgeSourceQuality: %v", err)
	}
	if len(judgments) != 1 || judgments[0].CandidateID != candidate.CandidateID || judgments[0].Quality.Provenance != ollamaSourceQualityProvenance {
		t.Fatalf("judgments = %#v", judgments)
	}
}

func TestOllamaSourceQualityRejectsUnknownAndDuplicateIDs(t *testing.T) {
	for _, inner := range []string{
		ollamaTestInner("youtube:unknown"),
		`{"judgments":[` + ollamaTestJudgment("youtube:clean") + `,` + ollamaTestJudgment("youtube:clean") + `]}`,
		ollamaTestInner(""),
	} {
		t.Run("invalid grounded id", func(t *testing.T) {
			if err := ollamaTestJudgeError(t, ollamaTestEnvelope(t, inner)); err == nil {
				t.Fatal("JudgeSourceQuality accepted invalid candidate IDs")
			}
		})
	}
}

func TestOllamaSourceQualityRejectsTrailingOuterAndStrictInnerJSON(t *testing.T) {
	validInner := ollamaTestInner("youtube:clean")
	cases := []string{
		`{"done":true}`,
		`{"response":` + mustJSON(t, validInner) + `}`,
		ollamaTestEnvelope(t, validInner) + ` {}`,
		ollamaTestEnvelope(t, `{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9,"provenance":"model"}}]}`),
		ollamaTestEnvelope(t, `{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9},"extra":true}]}`),
		ollamaTestEnvelope(t, validInner+` {}`),
	}
	for _, response := range cases {
		t.Run("invalid JSON framing or inner schema", func(t *testing.T) {
			if err := ollamaTestJudgeError(t, response); err == nil {
				t.Fatal("JudgeSourceQuality accepted trailing JSON or an invalid inner schema")
			}
		})
	}
}

func TestOllamaSourceQualityRejectsInvalidQualityAndOutputBounds(t *testing.T) {
	base := `{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9}}`
	tooManyReasons := strings.TrimSuffix(strings.Repeat(`"reason",`, ollamaMaxReasons+1), ",")
	tooManyWarnings := strings.TrimSuffix(strings.Repeat(`"warning",`, ollamaMaxWarnings+1), ",")
	tooManyJudgments := strings.TrimSuffix(strings.Repeat(base+`,`, ollamaMaxJudgments+1), ",")
	cases := []string{
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":101,"classification":"official_audio","recommendation":"preferred","confidence":0.9}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"made_up","recommendation":"preferred","confidence":0.9}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"made_up","confidence":0.9}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":1.1}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9,"reasons":[` + tooManyReasons + `]}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9,"warnings":[` + tooManyWarnings + `]}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9,"reasons":["` + strings.Repeat("x", ollamaMaxReasonBytes+1) + `"]}}]}`,
		`{"judgments":[{"candidateId":"youtube:clean","quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9,"warnings":["` + strings.Repeat("x", ollamaMaxWarningBytes+1) + `"]}}]}`,
		`{"judgments":[]}`,
		`{"judgments":[` + tooManyJudgments + `]}`,
	}
	for _, inner := range cases {
		t.Run("invalid output", func(t *testing.T) {
			if err := ollamaTestJudgeError(t, ollamaTestEnvelope(t, inner)); err == nil {
				t.Fatal("JudgeSourceQuality accepted invalid output")
			}
		})
	}
}

func TestOllamaSourceQualityBoundsInputAndResponse(t *testing.T) {
	originalURL := "https://example.test/" + strings.Repeat("u", ollamaMaxFeatureStringBytes+32)
	candidates := make([]SourceQualityCandidateFeature, ollamaMaxCandidates+2)
	for index := range candidates {
		candidates[index] = SourceQualityCandidateFeature{
			CandidateID: "id-" + fmt.Sprint(index), Provider: strings.Repeat("p", ollamaMaxFeatureStringBytes+1), SourceID: strings.Repeat("s", ollamaMaxFeatureStringBytes+1), SourceURL: originalURL, Title: strings.Repeat("t", ollamaMaxFeatureStringBytes+1), Artist: strings.Repeat("a", ollamaMaxFeatureStringBytes+1), Uploader: strings.Repeat("u", ollamaMaxFeatureStringBytes+1), Downloadable: true,
			MetadataHints: map[string]interface{}{strings.Repeat("k", ollamaMaxHintKeyBytes+1): strings.Repeat("v", ollamaMaxHintValueBytes+1)},
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request ollamaGenerateRequest
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		if len(request.Prompt) > ollamaMaxRequestBytes || r.ContentLength > ollamaMaxRequestBytes {
			t.Fatalf("unbounded request: prompt=%d content-length=%d", len(request.Prompt), r.ContentLength)
		}
		var prompt ollamaPrompt
		if err := json.Unmarshal([]byte(request.Prompt), &prompt); err != nil {
			t.Fatal(err)
		}
		if len(prompt.Query) != ollamaMaxQueryBytes || len(prompt.Candidates) != ollamaMaxCandidates {
			t.Fatalf("input not bounded: query=%d candidates=%d", len(prompt.Query), len(prompt.Candidates))
		}
		for _, candidate := range prompt.Candidates {
			if len(candidate.Provider) > ollamaMaxFeatureStringBytes || len(candidate.SourceID) > ollamaMaxFeatureStringBytes || len(candidate.SourceURL) > ollamaMaxFeatureStringBytes || len(candidate.Title) > ollamaMaxFeatureStringBytes || len(candidate.Artist) > ollamaMaxFeatureStringBytes || len(candidate.Uploader) > ollamaMaxFeatureStringBytes || len(candidate.MetadataHints) > ollamaMaxMetadataHints {
				t.Fatalf("candidate not bounded: %#v", candidate)
			}
			for key, values := range candidate.MetadataHints {
				if len(key) > ollamaMaxHintKeyBytes || len(values) > ollamaMaxHintValues || len(values[0]) > ollamaMaxHintValueBytes {
					t.Fatalf("hint not bounded: %q %#v", key, values)
				}
			}
		}
		_, _ = w.Write([]byte(ollamaTestEnvelope(t, ollamaTestInner("id-0"))))
	}))
	defer server.Close()
	judge := NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{Enabled: true, BaseURL: server.URL})
	if _, err := judge.JudgeSourceQuality(context.Background(), strings.Repeat("q", ollamaMaxQueryBytes+1), candidates); err != nil {
		t.Fatalf("bounded input: %v", err)
	}
	if candidates[0].SourceURL != originalURL {
		t.Fatalf("candidate URL mutated: %q", candidates[0].SourceURL)
	}

	if err := ollamaTestJudgeError(t, strings.Repeat("x", ollamaMaxResponseBytes+1)); err == nil {
		t.Fatal("JudgeSourceQuality accepted oversized response")
	}
}

func TestOllamaSourceQualityErrorsForNon2xxAndTimeout(t *testing.T) {
	non2xx := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusBadGateway) }))
	defer non2xx.Close()
	judge := NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{Enabled: true, BaseURL: non2xx.URL})
	if _, err := judge.JudgeSourceQuality(context.Background(), "query", []SourceQualityCandidateFeature{ollamaTestCandidate("youtube:clean")}); err == nil {
		t.Fatal("JudgeSourceQuality accepted non-2xx response")
	}

	timeout := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(50 * time.Millisecond)
		_, _ = w.Write([]byte(ollamaTestEnvelope(t, ollamaTestInner("youtube:clean"))))
	}))
	defer timeout.Close()
	judge = NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{Enabled: true, BaseURL: timeout.URL, Timeout: time.Millisecond})
	if _, err := judge.JudgeSourceQuality(context.Background(), "query", []SourceQualityCandidateFeature{ollamaTestCandidate("youtube:clean")}); err == nil {
		t.Fatal("JudgeSourceQuality accepted timed out response")
	}
}

func TestOllamaSourceQualityDisabledNilAndEmptySkipNetwork(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls.Add(1) }))
	defer server.Close()
	if judge := NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{BaseURL: server.URL}); judge != nil {
		t.Fatal("disabled judge is not nil")
	}
	var nilJudge *OllamaSourceQualityJudge
	if judgments, err := nilJudge.JudgeSourceQuality(context.Background(), "query", []SourceQualityCandidateFeature{ollamaTestCandidate("youtube:clean")}); err != nil || len(judgments) != 0 {
		t.Fatalf("nil judge = %#v, %v", judgments, err)
	}
	judge := NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{Enabled: true, BaseURL: server.URL})
	if judgments, err := judge.JudgeSourceQuality(context.Background(), "query", nil); err != nil || len(judgments) != 0 {
		t.Fatalf("empty candidates = %#v, %v", judgments, err)
	}
	if calls.Load() != 0 {
		t.Fatalf("network calls = %d, want 0", calls.Load())
	}
}

func ollamaTestJudgeError(t *testing.T, response string) error {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(response)) }))
	defer server.Close()
	judge := NewOllamaSourceQualityJudge(OllamaSourceQualityConfig{Enabled: true, BaseURL: server.URL})
	_, err := judge.JudgeSourceQuality(context.Background(), "query", []SourceQualityCandidateFeature{ollamaTestCandidate("youtube:clean")})
	return err
}

func ollamaTestCandidate(id string) SourceQualityCandidateFeature {
	return SourceQualityCandidateFeature{CandidateID: id, Provider: "youtube", SourceID: "clean", SourceURL: "https://www.youtube.com/watch?v=clean", Title: "Artist - Song", Artist: "Artist", Uploader: "Artist - Topic", DurationMs: 180000, Downloadable: true, MetadataHints: map[string]interface{}{"description": "official upload"}}
}

func ollamaTestEnvelope(t *testing.T, inner string) string {
	t.Helper()
	return mustJSON(t, map[string]interface{}{"response": inner, "done": true})
}

func ollamaTestEnvelopeWithExtras(t *testing.T, inner string) string {
	t.Helper()
	return mustJSON(t, map[string]interface{}{
		"response": inner,
		"done":     true,
		"thinking": "provider reasoning",
		"logprobs": []interface{}{map[string]interface{}{"token": "{"}},
		"future":   map[string]interface{}{"field": true},
	})
}

func ollamaTestInner(id string) string {
	return `{"judgments":[` + ollamaTestJudgment(id) + `]}`
}

func ollamaTestJudgment(id string) string {
	return `{"candidateId":` + fmt.Sprintf("%q", id) + `,"quality":{"score":90,"classification":"official_audio","recommendation":"preferred","confidence":0.9,"reasons":["official audio"],"warnings":["verify metadata"]}}`
}

func mustJSON(t *testing.T, value interface{}) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}
