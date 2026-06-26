package matcher

import (
	"context"
	"errors"
	"testing"
)

type fakeDisambiguator struct {
	decision *DisambiguationDecision
	err      error
}

func (f fakeDisambiguator) Disambiguate(context.Context, DisambiguationInput) (*DisambiguationDecision, error) {
	return f.decision, f.err
}

func testSuggestions() []MatchResult {
	return []MatchResult{
		{
			MBID:        "11111111-1111-1111-1111-111111111111",
			Title:       "Wrong Song",
			Artist:      "Wrong Artist",
			Album:       "Wrong Album",
			ReleaseID:   "22222222-2222-2222-2222-222222222222",
			CoverArtURL: "https://coverartarchive.org/release/22222222-2222-2222-2222-222222222222/front-250",
			Confidence:  0.62,
		},
		{
			MBID:        "33333333-3333-3333-3333-333333333333",
			Title:       "Cheerleader",
			Artist:      "Porter Robinson",
			Album:       "Cheerleader",
			ReleaseID:   "44444444-4444-4444-4444-444444444444",
			CoverArtURL: "https://coverartarchive.org/release/44444444-4444-4444-4444-444444444444/front-250",
			Confidence:  0.64,
		},
	}
}

func TestDecodeDisambiguationDecisionRejectsMalformedJSON(t *testing.T) {
	if _, err := decodeDisambiguationDecision(`{"match":true`); err == nil {
		t.Fatal("malformed JSON decoded without error")
	}
	if _, err := decodeDisambiguationDecision(`{"match":false,"candidate_id":"","confidence":0,"evidence":"none","title":"","artist":"","album":"","release_id":"","cover_art_url":"","extra":"nope"}`); err == nil {
		t.Fatal("JSON with unknown fields decoded without error")
	}
}

func TestValidateDisambiguationDecisionRejectsHallucinatedCandidate(t *testing.T) {
	decision := &DisambiguationDecision{
		Match:       true,
		CandidateID: "99999999-9999-9999-9999-999999999999",
		Confidence:  0.92,
		Evidence:    "provider title matches",
		Title:       "Made Up",
		Artist:      "Nobody",
	}
	if _, err := validateDisambiguationDecision(decision, testSuggestions()); err == nil {
		t.Fatal("hallucinated candidate id validated successfully")
	}
}

func TestApplyDisambiguationCandidateIDOnlySelectionToleratesEchoDrift(t *testing.T) {
	suggestions := testSuggestions()
	output := &MatchOutput{BestMatch: &suggestions[0], Suggestions: suggestions}
	decision := &DisambiguationDecision{
		Match:       true,
		CandidateID: "33333333-3333-3333-3333-333333333333",
		Confidence:  0.91,
		Evidence:    "provider title and artist match the second candidate",
		Title:       "cheer leader",
		Artist:      "PORTER ROBINSON",
		Album:       "",
		ReleaseID:   "release id drift",
		CoverArtURL: "https://example.com/drift.jpg",
	}

	if err := applyDisambiguation(output, decision); err != nil {
		t.Fatalf("applyDisambiguation rejected echoed-field drift: %v", err)
	}
	if output.BestMatch.MBID != decision.CandidateID || output.Suggestions[0].MBID != decision.CandidateID {
		t.Fatalf("grounded candidate was not promoted: best=%q first=%q", output.BestMatch.MBID, output.Suggestions[0].MBID)
	}
	if output.Disambiguation.Title != "Cheerleader" || output.Disambiguation.Artist != "Porter Robinson" || output.Disambiguation.Album != "Cheerleader" {
		t.Fatalf("disambiguation output was not grounded from selected candidate: %#v", output.Disambiguation)
	}
	if output.Disambiguation.ReleaseID != "44444444-4444-4444-4444-444444444444" || output.Disambiguation.CoverArtURL != "https://coverartarchive.org/release/44444444-4444-4444-4444-444444444444/front-250" {
		t.Fatalf("disambiguation release fields were not grounded from selected candidate: %#v", output.Disambiguation)
	}
}

func TestApplyDisambiguationNoMatchLeavesIdentityUnverified(t *testing.T) {
	suggestions := testSuggestions()
	output := &MatchOutput{BestMatch: &suggestions[0], Suggestions: suggestions}
	decision := &DisambiguationDecision{
		Match:      false,
		Confidence: 0.2,
		Evidence:   "no candidate matches the provider evidence",
	}
	if err := applyDisambiguation(output, decision); err != nil {
		t.Fatalf("applyDisambiguation no-match error: %v", err)
	}
	if output.Verified {
		t.Fatal("no-match decision verified a candidate")
	}
	if output.BestMatch.MBID != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("no-match changed best match to %q", output.BestMatch.MBID)
	}
	if output.Disambiguation != decision {
		t.Fatal("no-match decision was not recorded for provenance")
	}
}

func TestApplyDisambiguationHighConfidencePromotesGroundedCandidate(t *testing.T) {
	suggestions := testSuggestions()
	output := &MatchOutput{BestMatch: &suggestions[0], Suggestions: suggestions}
	decision := &DisambiguationDecision{
		Match:       true,
		CandidateID: "33333333-3333-3333-3333-333333333333",
		Confidence:  0.93,
		Evidence:    "artist/title and cover art match the provider hints",
		Title:       "Cheerleader",
		Artist:      "Porter Robinson",
		Album:       "Cheerleader",
		ReleaseID:   "44444444-4444-4444-4444-444444444444",
		CoverArtURL: "https://coverartarchive.org/release/44444444-4444-4444-4444-444444444444/front-250",
	}
	if err := applyDisambiguation(output, decision); err != nil {
		t.Fatalf("applyDisambiguation error: %v", err)
	}
	if !output.Verified {
		t.Fatal("high-confidence grounded candidate was not verified")
	}
	if output.BestMatch.MBID != decision.CandidateID || output.Suggestions[0].MBID != decision.CandidateID {
		t.Fatalf("grounded candidate was not promoted: best=%q first=%q", output.BestMatch.MBID, output.Suggestions[0].MBID)
	}
}

func TestApplyDisambiguationLowConfidencePromotesButDoesNotVerify(t *testing.T) {
	suggestions := testSuggestions()
	output := &MatchOutput{BestMatch: &suggestions[0], Suggestions: suggestions}
	decision := &DisambiguationDecision{
		Match:       true,
		CandidateID: "33333333-3333-3333-3333-333333333333",
		Confidence:  0.72,
		Evidence:    "weak title match",
		Title:       "Cheerleader",
		Artist:      "Porter Robinson",
		Album:       "Cheerleader",
		ReleaseID:   "44444444-4444-4444-4444-444444444444",
		CoverArtURL: "https://coverartarchive.org/release/44444444-4444-4444-4444-444444444444/front-250",
	}
	if err := applyDisambiguation(output, decision); err != nil {
		t.Fatalf("applyDisambiguation error: %v", err)
	}
	if output.Verified {
		t.Fatal("low-confidence grounded candidate was incorrectly verified")
	}
	if output.BestMatch.MBID != decision.CandidateID || output.Suggestions[0].MBID != decision.CandidateID {
		t.Fatalf("low-confidence grounded candidate was not promoted: best=%q first=%q", output.BestMatch.MBID, output.Suggestions[0].MBID)
	}
}

func TestBoundedMetadataMapDoesNotResetDepthForNestedMaps(t *testing.T) {
	bounded := boundedMetadataMap(map[string]interface{}{
		"level0": map[string]interface{}{
			"level1": map[string]interface{}{
				"level2": "should be removed",
			},
			"kept": "value",
		},
	})

	level0, ok := bounded["level0"].(map[string]interface{})
	if !ok {
		t.Fatalf("level0 map was not retained: %#v", bounded["level0"])
	}
	if level0["kept"] != "value" {
		t.Fatalf("expected primitive value in first nested map to survive, got %#v", level0["kept"])
	}
	if nested, ok := level0["level1"].(map[string]interface{}); ok {
		t.Fatalf("nested map survived depth bound: %#v", nested)
	}
}

func TestTryApplyDisambiguationProviderUnavailableFallback(t *testing.T) {
	suggestions := testSuggestions()
	output := &MatchOutput{BestMatch: &suggestions[0], Suggestions: suggestions}
	tryApplyDisambiguation(context.Background(), fakeDisambiguator{err: errors.New("ollama unavailable")}, DisambiguationInput{}, output)
	if output.Verified {
		t.Fatal("provider error should not verify a match")
	}
	if output.Disambiguation != nil {
		t.Fatalf("provider error should not record a decision: %#v", output.Disambiguation)
	}
	if output.BestMatch.MBID != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("provider error changed best match to %q", output.BestMatch.MBID)
	}
}

func TestNewOllamaDisambiguatorDisabledWhenNotReady(t *testing.T) {
	if NewOllamaDisambiguator(OllamaConfig{Enabled: false, Model: "llama3.1"}) != nil {
		t.Fatal("disabled Ollama config returned a disambiguator")
	}
	if NewOllamaDisambiguator(OllamaConfig{Enabled: true}) != nil {
		t.Fatal("Ollama config without model returned a disambiguator")
	}
}
