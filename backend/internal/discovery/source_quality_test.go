package discovery

import (
	"context"
	"testing"
)

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
