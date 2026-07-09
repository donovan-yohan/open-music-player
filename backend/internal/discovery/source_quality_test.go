package discovery

import (
	"context"
	"errors"
	"testing"
)

type fakeSourceQualityJudge struct {
	judgments []SourceQualityJudgment
	err       error
	seen      []SourceQualityCandidateFeature
}

func (f *fakeSourceQualityJudge) JudgeSourceQuality(_ context.Context, _ string, candidates []SourceQualityCandidateFeature) ([]SourceQualityJudgment, error) {
	f.seen = candidates
	if f.err != nil {
		return nil, f.err
	}
	return f.judgments, nil
}

func TestSourceQualityRanksOfficialAudioAheadOfMusicVideo(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{
				{
					CandidateID:  "youtube:video",
					Provider:     "youtube",
					SourceID:     "video",
					SourceURL:    "https://www.youtube.com/watch?v=video",
					Title:        "Ninajirachi - iPod Touch (Official Music Video)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   245000,
					Downloadable: true,
				},
				{
					CandidateID:  "youtube:audio",
					Provider:     "youtube",
					SourceID:     "audio",
					SourceURL:    "https://www.youtube.com/watch?v=audio",
					Title:        "Ninajirachi - iPod Touch (Official Audio)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   240000,
					Downloadable: true,
				},
			}},
		},
		DefaultProviders: []string{"youtube"},
	})

	resp := svc.Search(context.Background(), "Ninajirachi iPod Touch", []string{"youtube"}, 10)

	if len(resp.Results) != 2 {
		t.Fatalf("results = %d, want 2", len(resp.Results))
	}
	if resp.Results[0].CandidateID != "youtube:audio" {
		t.Fatalf("top result = %s, want official audio first", resp.Results[0].CandidateID)
	}
	quality := sourceQualityFromMetadata(t, resp.Results[0].Metadata)
	if quality.Classification != SourceQualityOfficialAudio || quality.Recommendation != SourceQualityPreferred {
		t.Fatalf("official audio quality = %#v, want preferred official_audio", quality)
	}
	videoQuality := sourceQualityFromMetadata(t, resp.Results[1].Metadata)
	if videoQuality.Classification != SourceQualityMusicVideo || videoQuality.Recommendation == SourceQualityPreferred {
		t.Fatalf("music video quality = %#v, want non-preferred music_video", videoQuality)
	}
	if resp.Sections[0].Kind != "sources" || resp.Sections[0].Items[0].Candidate.CandidateID != "youtube:audio" {
		t.Fatalf("sources section did not preserve ranked candidates: %#v", resp.Sections)
	}
}

func TestSourceQualityJudgeCanPromoteGroundedCandidate(t *testing.T) {
	judge := &fakeSourceQualityJudge{judgments: []SourceQualityJudgment{
		{
			CandidateID: "youtube:b",
			Quality: SourceQuality{
				Score:          96,
				Classification: SourceQualityOfficialAudio,
				Recommendation: SourceQualityPreferred,
				Confidence:     1.7,
				Reasons:        []string{"structured judge selected existing candidate"},
				Provenance:     "fake_source_quality_judge",
			},
		},
		{
			CandidateID: "youtube:a",
			Quality: SourceQuality{
				Score:          -10,
				Classification: "hallucinated_type",
				Recommendation: "definitely",
				Confidence:     -1,
			},
		},
		{
			CandidateID: "youtube:not-returned-by-provider",
			Quality:     SourceQuality{Score: 100, Classification: SourceQualityOfficialAudio},
		},
	}}
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{
				{
					CandidateID:  "youtube:a",
					Provider:     "youtube",
					SourceID:     "a",
					SourceURL:    "https://www.youtube.com/watch?v=a",
					Title:        "Artist - Song",
					Artist:       "Artist",
					Uploader:     "Uploader",
					DurationMs:   240000,
					Downloadable: true,
					Metadata: map[string]interface{}{
						"description": "Provider description",
						"tags":        []interface{}{"official", "audio"},
						"raw":         "not passed to judge",
					},
				},
				{
					CandidateID:  "youtube:b",
					Provider:     "youtube",
					SourceID:     "b",
					SourceURL:    "https://www.youtube.com/watch?v=b",
					Title:        "Artist - Song upload",
					Artist:       "Artist",
					Uploader:     "Uploader",
					DurationMs:   240000,
					Downloadable: true,
				},
			}},
		},
		DefaultProviders:   []string{"youtube"},
		SourceQualityJudge: judge,
	})

	resp := svc.Search(context.Background(), "Artist Song", []string{"youtube"}, 10)

	if got := resp.Results[0].CandidateID; got != "youtube:b" {
		t.Fatalf("top result = %s, want judge-promoted youtube:b", got)
	}
	promoted := sourceQualityFromMetadata(t, resp.Results[0].Metadata)
	if promoted.Provenance != "fake_source_quality_judge" || promoted.Confidence != 1 {
		t.Fatalf("promoted source quality not normalized/preserved: %#v", promoted)
	}
	demoted := sourceQualityFromMetadata(t, resp.Results[1].Metadata)
	if demoted.Classification != SourceQualityUnknown || demoted.Recommendation != SourceQualityAvoid || demoted.Confidence != 0 {
		t.Fatalf("demoted source quality not normalized: %#v", demoted)
	}
	if len(judge.seen) != 2 {
		t.Fatalf("judge saw %d candidates, want 2", len(judge.seen))
	}
	hints := judge.seen[0].MetadataHints
	if hints["description"] != "Provider description" {
		t.Fatalf("description hint = %#v, want Provider description", hints["description"])
	}
	tags, ok := hints["tags"].([]string)
	if !ok || len(tags) != 2 || tags[0] != "official" || tags[1] != "audio" {
		t.Fatalf("tags hint = %#v, want normalized string tags", hints["tags"])
	}
	if _, ok := hints["raw"]; ok {
		t.Fatalf("raw metadata leaked into judge hints: %#v", hints)
	}
}

func TestSourceQualityJudgeErrorFallsBackToDeterministicRanking(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{
				{
					CandidateID:  "youtube:video",
					Provider:     "youtube",
					SourceID:     "video",
					SourceURL:    "https://www.youtube.com/watch?v=video",
					Title:        "Ninajirachi - iPod Touch (Official Music Video)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   245000,
					Downloadable: true,
				},
				{
					CandidateID:  "youtube:audio",
					Provider:     "youtube",
					SourceID:     "audio",
					SourceURL:    "https://www.youtube.com/watch?v=audio",
					Title:        "Ninajirachi - iPod Touch (Official Audio)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   240000,
					Downloadable: true,
				},
			}},
		},
		DefaultProviders:   []string{"youtube"},
		SourceQualityJudge: &fakeSourceQualityJudge{err: errors.New("model offline")},
	})

	resp := svc.Search(context.Background(), "Ninajirachi iPod Touch", []string{"youtube"}, 10)

	if got := resp.Results[0].CandidateID; got != "youtube:audio" {
		t.Fatalf("top result = %s, want deterministic official audio fallback", got)
	}
	quality := sourceQualityFromMetadata(t, resp.Results[0].Metadata)
	if quality.Provenance != "deterministic_source_quality_v1" {
		t.Fatalf("fallback provenance = %s, want deterministic_source_quality_v1", quality.Provenance)
	}
}

func TestSourceQualityRanksOfficialAudioAheadOfVisualizerAndLyricVideo(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{
				{
					CandidateID:  "youtube:visualizer",
					Provider:     "youtube",
					SourceID:     "visualizer",
					SourceURL:    "https://www.youtube.com/watch?v=visualizer",
					Title:        "Ninajirachi - iPod Touch (Official Visualizer)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   240000,
					Downloadable: true,
				},
				{
					CandidateID:  "youtube:lyric",
					Provider:     "youtube",
					SourceID:     "lyric",
					SourceURL:    "https://www.youtube.com/watch?v=lyric",
					Title:        "Ninajirachi - iPod Touch (Official Lyric Video)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   240000,
					Downloadable: true,
				},
				{
					CandidateID:  "youtube:audio",
					Provider:     "youtube",
					SourceID:     "audio",
					SourceURL:    "https://www.youtube.com/watch?v=audio",
					Title:        "Ninajirachi - iPod Touch (Official Audio)",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi",
					DurationMs:   240000,
					Downloadable: true,
				},
			}},
		},
		DefaultProviders: []string{"youtube"},
	})

	resp := svc.Search(context.Background(), "Ninajirachi iPod Touch", []string{"youtube"}, 10)

	if len(resp.Results) != 3 {
		t.Fatalf("results = %d, want 3", len(resp.Results))
	}
	if got := resp.Results[0].CandidateID; got != "youtube:audio" {
		t.Fatalf("top result = %s, want official audio first", got)
	}
	visualizerQuality := sourceQualityFromMetadata(t, resp.Results[1].Metadata)
	if visualizerQuality.Classification != SourceQualityVisualizer || visualizerQuality.Recommendation == SourceQualityPreferred {
		t.Fatalf("visualizer quality = %#v, want non-preferred visualizer", visualizerQuality)
	}
	lyricQuality := sourceQualityFromMetadata(t, resp.Results[2].Metadata)
	if lyricQuality.Classification != SourceQualityLyricVideo || lyricQuality.Recommendation == SourceQualityPreferred {
		t.Fatalf("lyric quality = %#v, want non-preferred lyric_video", lyricQuality)
	}
}

func TestSourceQualityPrefersTopicAudioOverLongLiveClip(t *testing.T) {
	svc := NewService(ServiceConfig{
		Providers: []Provider{
			fakeProvider{name: "youtube", items: []Candidate{
				{
					CandidateID:  "youtube:live",
					Provider:     "youtube",
					SourceID:     "live",
					SourceURL:    "https://www.youtube.com/watch?v=live",
					Title:        "iPod Touch live at festival with interview intro",
					Artist:       "Ninajirachi",
					Uploader:     "Festival Channel",
					DurationMs:   14 * 60 * 1000,
					Downloadable: true,
				},
				{
					CandidateID:  "youtube:topic",
					Provider:     "youtube",
					SourceID:     "topic",
					SourceURL:    "https://www.youtube.com/watch?v=topic",
					Title:        "iPod Touch",
					Artist:       "Ninajirachi",
					Uploader:     "Ninajirachi - Topic",
					DurationMs:   239000,
					Downloadable: true,
				},
			}},
		},
		DefaultProviders: []string{"youtube"},
	})

	resp := svc.Search(context.Background(), "Ninajirachi iPod Touch", []string{"youtube"}, 10)

	if got := resp.Results[0].CandidateID; got != "youtube:topic" {
		t.Fatalf("top result = %s, want topic audio first", got)
	}
	topicQuality := sourceQualityFromMetadata(t, resp.Results[0].Metadata)
	if topicQuality.Classification != SourceQualityTopicAudio {
		t.Fatalf("topic classification = %s, want topic_audio", topicQuality.Classification)
	}
	liveQuality := sourceQualityFromMetadata(t, resp.Results[1].Metadata)
	if liveQuality.Recommendation != SourceQualityAvoid {
		t.Fatalf("live recommendation = %s, want avoid; quality=%#v", liveQuality.Recommendation, liveQuality)
	}
}

func TestSourceQualityUsesMetadataHints(t *testing.T) {
	quality := EvaluateSourceQuality("Ninajirachi iPod Touch", Candidate{
		CandidateID:  "youtube:metadata",
		Provider:     "youtube",
		SourceURL:    "https://www.youtube.com/watch?v=metadata",
		Title:        "Ninajirachi - iPod Touch",
		Artist:       "Ninajirachi",
		Uploader:     "Ninajirachi",
		DurationMs:   240000,
		Downloadable: true,
		Metadata: map[string]interface{}{
			"description": "Official music video.",
		},
	})

	if quality.Classification != SourceQualityMusicVideo {
		t.Fatalf("classification = %s, want music_video from metadata hint; quality=%#v", quality.Classification, quality)
	}
	if quality.Recommendation != SourceQualityAvoid {
		t.Fatalf("recommendation = %s, want avoid; quality=%#v", quality.Recommendation, quality)
	}
}

func TestSourceQualityHonorsRequestedLiveVersion(t *testing.T) {
	live := Candidate{
		CandidateID:  "youtube:live",
		Provider:     "youtube",
		SourceURL:    "https://www.youtube.com/watch?v=live",
		Title:        "Shelter live at Second Sky",
		Artist:       "Porter Robinson",
		Uploader:     "Porter Robinson",
		DurationMs:   360000,
		Downloadable: true,
	}

	quality := EvaluateSourceQuality("Porter Robinson Shelter live", live)

	if quality.Classification != SourceQualityLive {
		t.Fatalf("classification = %s, want live", quality.Classification)
	}
	if quality.Recommendation == SourceQualityAvoid {
		t.Fatalf("requested live version should not be avoid: %#v", quality)
	}
}

func TestSourceQualityHonorsRequestedVisualizer(t *testing.T) {
	visualizer := Candidate{
		CandidateID:  "youtube:visualizer",
		Provider:     "youtube",
		SourceURL:    "https://www.youtube.com/watch?v=visualizer",
		Title:        "Shelter (Official Visualizer)",
		Artist:       "Porter Robinson",
		Uploader:     "Porter Robinson",
		DurationMs:   240000,
		Downloadable: true,
	}

	quality := EvaluateSourceQuality("Porter Robinson Shelter visualizer", visualizer)

	if quality.Classification != SourceQualityVisualizer {
		t.Fatalf("classification = %s, want visualizer", quality.Classification)
	}
	if quality.Recommendation == SourceQualityAvoid {
		t.Fatalf("requested visualizer should not be avoid: %#v", quality)
	}
}

func TestSourceQualityDetectsBoundaryKeywords(t *testing.T) {
	cases := []struct {
		name               string
		title              string
		wantClassification string
	}{
		{
			name:               "live at start",
			title:              "Live from Chicago - Shelter",
			wantClassification: SourceQualityLive,
		},
		{
			name:               "cover at start",
			title:              "Cover of Shelter",
			wantClassification: SourceQualityCover,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			quality := EvaluateSourceQuality("Shelter", Candidate{
				CandidateID:  "youtube:" + tc.name,
				Provider:     "youtube",
				SourceURL:    "https://www.youtube.com/watch?v=boundary",
				Title:        tc.title,
				Artist:       "Porter Robinson",
				Uploader:     "Uploader",
				DurationMs:   240000,
				Downloadable: true,
			})

			if quality.Classification != tc.wantClassification {
				t.Fatalf("classification = %s, want %s; quality=%#v", quality.Classification, tc.wantClassification, quality)
			}
		})
	}
}

func TestUniqueStringsReturnsNilAfterFilteringBlankValues(t *testing.T) {
	if got := uniqueStrings([]string{"", "   "}); got != nil {
		t.Fatalf("uniqueStrings blanks = %#v, want nil", got)
	}
}

func sourceQualityFromMetadata(t *testing.T, metadata map[string]interface{}) SourceQuality {
	t.Helper()
	raw, ok := metadata[SourceQualityMetadataKey]
	if !ok {
		t.Fatalf("metadata missing %s: %#v", SourceQualityMetadataKey, metadata)
	}
	quality, ok := raw.(SourceQuality)
	if ok {
		return quality
	}
	asMap, ok := raw.(map[string]interface{})
	if !ok {
		t.Fatalf("source quality has unexpected type %T: %#v", raw, raw)
	}
	return SourceQuality{
		Score:          int(asMap["score"].(float64)),
		Classification: asMap["classification"].(string),
		Recommendation: asMap["recommendation"].(string),
	}
}
