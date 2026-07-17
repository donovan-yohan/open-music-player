package db

import (
	"encoding/json"
	"testing"
)

// Research decisions persist the revision candidate verbatim enough for a later
// download/queue rehydration to consume it without a research-specific path.
func TestCandidateFromPersistedSelectionAcceptsResearchRevisionCandidate(t *testing.T) {
	snapshot := json.RawMessage(`{
		"candidateId":"youtube:fixture-a",
		"provider":"youtube",
		"sourceId":"fixture-a",
		"sourceUrl":"https://www.youtube.com/watch?v=fixturea",
		"title":"Fixture Song",
		"artist":"Fixture Artist",
		"uploader":"Fixture Uploader",
		"durationMs":123000,
		"downloadable":true,
		"playable":false,
		"sourceQuality":{"score":100,"classification":"official_audio","recommendation":"preferred","confidence":1}
	}`)
	candidate, err := candidateFromPersistedSelection(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	if candidate.CandidateID != "youtube:fixture-a" || candidate.Provider != "youtube" || candidate.SourceURL == "" || candidate.Title != "Fixture Song" {
		t.Fatalf("rehydrated candidate = %#v", candidate)
	}
}

func TestCandidateFromPersistedSelectionRejectsNondownloadableResearchSnapshot(t *testing.T) {
	snapshot := json.RawMessage(`{
		"candidateId":"youtube:fixture-a",
		"provider":"youtube",
		"sourceUrl":"https://www.youtube.com/watch?v=fixturea",
		"title":"Fixture Song",
		"downloadable":false
	}`)

	if _, err := candidateFromPersistedSelection(snapshot); err == nil {
		t.Fatal("nondownloadable persisted research candidate was accepted")
	}
}
