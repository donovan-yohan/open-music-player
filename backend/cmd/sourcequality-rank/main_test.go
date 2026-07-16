package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/discovery"
)

func sourceQualityOf(t *testing.T, candidate discovery.Candidate) discovery.SourceQuality {
	t.Helper()
	raw, ok := candidate.Metadata[discovery.SourceQualityMetadataKey]
	if !ok {
		t.Fatalf("candidate %q is missing sourceQuality metadata", candidate.CandidateID)
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("marshal sourceQuality for %q: %v", candidate.CandidateID, err)
	}
	var quality discovery.SourceQuality
	if err := json.Unmarshal(encoded, &quality); err != nil {
		t.Fatalf("unmarshal sourceQuality for %q: %v", candidate.CandidateID, err)
	}
	return quality
}

func TestRunRanksOfficialAudioAboveMusicVideo(t *testing.T) {
	req := request{
		Query: "ninajirachi ipod touch",
		Candidates: []discovery.Candidate{
			{
				CandidateID:  "youtube:mv",
				Provider:     "youtube",
				SourceID:     "mv",
				SourceURL:    "https://www.youtube.com/watch?v=mv",
				Title:        "Ninajirachi - iPod Touch (Official Music Video)",
				Artist:       "Ninajirachi",
				Uploader:     "Ninajirachi",
				DurationMs:   231000,
				Downloadable: true,
			},
			{
				CandidateID:  "youtube:audio",
				Provider:     "youtube",
				SourceID:     "audio",
				SourceURL:    "https://www.youtube.com/watch?v=audio",
				Title:        "Ninajirachi - iPod Touch (Official Audio)",
				Artist:       "Ninajirachi",
				Uploader:     "Ninajirachi - Topic",
				DurationMs:   231000,
				Downloadable: true,
			},
		},
	}
	input, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	var out bytes.Buffer
	if err := run(bytes.NewReader(input), &out); err != nil {
		t.Fatalf("run returned error: %v", err)
	}
	var resp response
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if len(resp.Ranked) != 2 {
		t.Fatalf("expected 2 ranked candidates, got %d", len(resp.Ranked))
	}
	if resp.Ranked[0].CandidateID != "youtube:audio" {
		t.Fatalf("expected official audio to win, got %q", resp.Ranked[0].CandidateID)
	}
	winnerQuality := sourceQualityOf(t, resp.Ranked[0])
	if winnerQuality.Classification != discovery.SourceQualityOfficialAudio {
		t.Fatalf("expected winner classification %q, got %q", discovery.SourceQualityOfficialAudio, winnerQuality.Classification)
	}
	loserQuality := sourceQualityOf(t, resp.Ranked[1])
	if loserQuality.Classification != discovery.SourceQualityMusicVideo {
		t.Fatalf("expected loser classification %q, got %q", discovery.SourceQualityMusicVideo, loserQuality.Classification)
	}
	if winnerQuality.Score <= loserQuality.Score {
		t.Fatalf("expected winner score above loser: winner=%d loser=%d", winnerQuality.Score, loserQuality.Score)
	}
}

func TestRunAttachesSourceQualityAndPreservesOriginalMetadata(t *testing.T) {
	req := request{
		Query: "artist song",
		Candidates: []discovery.Candidate{
			{
				CandidateID:  "soundcloud:track",
				Provider:     "soundcloud",
				SourceURL:    "https://soundcloud.com/artist/song",
				Title:        "Artist - Song",
				Artist:       "Artist",
				Uploader:     "Artist",
				DurationMs:   210000,
				Downloadable: true,
				Metadata: map[string]interface{}{
					"discoverySurface": "soundcloud_search",
				},
			},
		},
	}
	input, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	var out bytes.Buffer
	if err := run(bytes.NewReader(input), &out); err != nil {
		t.Fatalf("run returned error: %v", err)
	}
	var resp response
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if len(resp.Ranked) != 1 {
		t.Fatalf("expected 1 ranked candidate, got %d", len(resp.Ranked))
	}
	got := resp.Ranked[0]
	if surface, _ := got.Metadata["discoverySurface"].(string); surface != "soundcloud_search" {
		t.Fatalf("expected original discoverySurface metadata to be preserved, got %v", got.Metadata["discoverySurface"])
	}
	quality := sourceQualityOf(t, got)
	if quality.Provenance == "" {
		t.Fatalf("expected sourceQuality provenance to be populated")
	}
	if quality.Confidence <= 0 || quality.Confidence > 1 {
		t.Fatalf("expected confidence in (0,1], got %v", quality.Confidence)
	}
}

func TestRunRejectsInvalidJSON(t *testing.T) {
	var out bytes.Buffer
	err := run(strings.NewReader("{not json"), &out)
	if err == nil {
		t.Fatalf("expected an error for malformed input")
	}
	if !strings.Contains(err.Error(), "decode request") {
		t.Fatalf("expected decode error, got %v", err)
	}
}

func TestRankIsStableForEqualScores(t *testing.T) {
	candidates := []discovery.Candidate{
		{CandidateID: "youtube:a", Provider: "youtube", SourceURL: "https://youtu.be/a", Title: "Song A", Downloadable: true},
		{CandidateID: "youtube:b", Provider: "youtube", SourceURL: "https://youtu.be/b", Title: "Song B", Downloadable: true},
	}
	ranked := rank("song", candidates)
	if ranked[0].CandidateID != "youtube:a" || ranked[1].CandidateID != "youtube:b" {
		t.Fatalf("expected stable input order for equal scores, got %q then %q", ranked[0].CandidateID, ranked[1].CandidateID)
	}
}
