package matcher

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

const (
	// DisambiguationAutoConfidence is the minimum model confidence required before
	// a validated candidate selection may promote an existing MusicBrainz candidate
	// to an automatic match. The candidate data itself remains MusicBrainz data.
	DisambiguationAutoConfidence = 0.85
	maxDisambiguationEvidenceLen = 300
	maxMetadataStringLen         = 500
	maxMetadataArrayLen          = 4
	maxMetadataMapLen            = 12
)

// Disambiguator chooses among already-grounded MusicBrainz candidates. It is
// advisory only: implementations must not browse, resolve URLs, or invent rows.
type Disambiguator interface {
	Disambiguate(ctx context.Context, input DisambiguationInput) (*DisambiguationDecision, error)
}

// MetadataContext is the compact, bounded metadata context sent to a local model.
type MetadataContext struct {
	RawProvider   map[string]interface{} `json:"raw_provider,omitempty"`
	Deterministic map[string]interface{} `json:"deterministic,omitempty"`
	Title         string                 `json:"title,omitempty"`
	Artist        string                 `json:"artist,omitempty"`
	Album         string                 `json:"album,omitempty"`
	Uploader      string                 `json:"uploader,omitempty"`
	DurationMs    int                    `json:"duration_ms,omitempty"`
	SourceType    string                 `json:"source_type,omitempty"`
	SourceDomain  string                 `json:"source_domain,omitempty"`
	ThumbnailURL  string                 `json:"thumbnail_url,omitempty"`
}

// TrackMetadata contains the input metadata for matching.
type TrackMetadata struct {
	Title         string                 `json:"title"`      // Video/track title
	Artist        string                 `json:"artist"`     // Provider or deterministic artist
	Album         string                 `json:"album"`      // Provider album when known
	Uploader      string                 `json:"uploader"`   // Channel/uploader name (fallback for artist)
	DurationMs    int                    `json:"durationMs"` // Duration in milliseconds
	SourceType    string                 `json:"sourceType"`
	SourceDomain  string                 `json:"sourceDomain"`
	ThumbnailURL  string                 `json:"thumbnailUrl"`
	RawProvider   map[string]interface{} `json:"rawProvider,omitempty"`
	Deterministic map[string]interface{} `json:"deterministic,omitempty"`
}

// DisambiguationInput is the only model input: existing candidates plus bounded
// metadata context. The model never receives tools and never creates candidates.
type DisambiguationInput struct {
	Metadata    MetadataContext `json:"metadata"`
	ParsedTitle *ParsedTitle    `json:"parsed_title,omitempty"`
	Candidates  []MatchResult   `json:"candidates"`
}

// DisambiguationDecision is the strict structured JSON returned by the model.
// CandidateID must match an input MusicBrainz recording ID when Match is true.
type DisambiguationDecision struct {
	Match       bool    `json:"match"`
	CandidateID string  `json:"candidate_id"`
	Confidence  float64 `json:"confidence"`
	Evidence    string  `json:"evidence"`
	Title       string  `json:"title"`
	Artist      string  `json:"artist"`
	Album       string  `json:"album"`
	ReleaseID   string  `json:"release_id"`
	CoverArtURL string  `json:"cover_art_url"`
}

func buildDisambiguationInput(metadata TrackMetadata, parsed *ParsedTitle, candidates []MatchResult) DisambiguationInput {
	return DisambiguationInput{
		Metadata: MetadataContext{
			RawProvider:   boundedMetadataMap(metadata.RawProvider),
			Deterministic: boundedMetadataMap(metadata.Deterministic),
			Title:         truncateMetadataString(metadata.Title),
			Artist:        truncateMetadataString(metadata.Artist),
			Album:         truncateMetadataString(metadata.Album),
			Uploader:      truncateMetadataString(metadata.Uploader),
			DurationMs:    metadata.DurationMs,
			SourceType:    truncateMetadataString(metadata.SourceType),
			SourceDomain:  truncateMetadataString(metadata.SourceDomain),
			ThumbnailURL:  truncateMetadataString(metadata.ThumbnailURL),
		},
		ParsedTitle: parsed,
		Candidates:  candidates,
	}
}

func boundedMetadataMap(input map[string]interface{}) map[string]interface{} {
	return boundedMetadataMapWithDepth(input, 0)
}

func boundedMetadataMapWithDepth(input map[string]interface{}, depth int) map[string]interface{} {
	if len(input) == 0 {
		return nil
	}
	bounded := make(map[string]interface{}, minInt(len(input), maxMetadataMapLen))
	count := 0
	for key, value := range input {
		if count >= maxMetadataMapLen {
			break
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		bounded[key] = boundedMetadataValue(value, depth)
		count++
	}
	return bounded
}

func boundedMetadataValue(value interface{}, depth int) interface{} {
	if depth >= 2 {
		return nil
	}
	switch v := value.(type) {
	case string:
		return truncateMetadataString(v)
	case []interface{}:
		limit := minInt(len(v), maxMetadataArrayLen)
		items := make([]interface{}, 0, limit)
		for i := 0; i < limit; i++ {
			items = append(items, boundedMetadataValue(v[i], depth+1))
		}
		return items
	case map[string]interface{}:
		if depth >= 1 {
			return nil
		}
		return boundedMetadataMapWithDepth(v, depth+1)
	default:
		return value
	}
}

func truncateMetadataString(value string) string {
	runes := []rune(strings.TrimSpace(value))
	if len(runes) <= maxMetadataStringLen {
		return string(runes)
	}
	return string(runes[:maxMetadataStringLen])
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func decodeDisambiguationDecision(raw string) (*DisambiguationDecision, error) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	var decision DisambiguationDecision
	if err := decoder.Decode(&decision); err != nil {
		return nil, fmt.Errorf("decode disambiguation decision: %w", err)
	}
	var trailing struct{}
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, fmt.Errorf("decode disambiguation decision: trailing data")
	}
	return &decision, nil
}

func validateDisambiguationDecision(decision *DisambiguationDecision, candidates []MatchResult) (int, error) {
	if decision == nil {
		return -1, fmt.Errorf("missing disambiguation decision")
	}
	decision.CandidateID = strings.TrimSpace(decision.CandidateID)
	decision.Evidence = strings.TrimSpace(decision.Evidence)
	if decision.Confidence < 0 || decision.Confidence > 1 {
		return -1, fmt.Errorf("disambiguation confidence %.3f outside 0..1", decision.Confidence)
	}
	if len([]rune(decision.Evidence)) > maxDisambiguationEvidenceLen {
		return -1, fmt.Errorf("disambiguation evidence is too long")
	}
	if !decision.Match {
		if decision.CandidateID != "" {
			return -1, fmt.Errorf("no-match disambiguation included a candidate_id")
		}
		return -1, nil
	}
	if decision.CandidateID == "" {
		return -1, fmt.Errorf("match disambiguation missing candidate_id")
	}
	if decision.Evidence == "" {
		return -1, fmt.Errorf("match disambiguation missing evidence")
	}
	for i := range candidates {
		candidate := candidates[i]
		if candidate.MBID != decision.CandidateID {
			continue
		}
		decision.Title = candidate.Title
		decision.Artist = candidate.Artist
		decision.Album = candidate.Album
		decision.ReleaseID = candidate.ReleaseID
		decision.CoverArtURL = candidate.CoverArtURL
		return i, nil
	}
	return -1, fmt.Errorf("disambiguation selected unknown candidate %q", decision.CandidateID)
}

func applyDisambiguation(output *MatchOutput, decision *DisambiguationDecision) error {
	if output == nil || decision == nil || len(output.Suggestions) == 0 {
		return nil
	}
	idx, err := validateDisambiguationDecision(decision, output.Suggestions)
	if err != nil {
		return err
	}
	output.Disambiguation = decision
	if !decision.Match || idx < 0 {
		return nil
	}
	selected := output.Suggestions[idx]
	selected.Confidence = decision.Confidence
	selected.MatchReasons = append(selected.MatchReasons, "ollama_disambiguation")
	output.BestMatch = &selected
	output.Suggestions = moveSuggestionToFront(output.Suggestions, idx, selected)
	if decision.Confidence >= DisambiguationAutoConfidence {
		output.Verified = true
	}
	return nil
}

func tryApplyDisambiguation(ctx context.Context, disambiguator Disambiguator, input DisambiguationInput, output *MatchOutput) {
	if disambiguator == nil || output == nil || output.Verified || len(output.Suggestions) == 0 {
		return
	}
	decision, err := disambiguator.Disambiguate(ctx, input)
	if err != nil {
		return
	}
	_ = applyDisambiguation(output, decision)
}

func moveSuggestionToFront(suggestions []MatchResult, idx int, selected MatchResult) []MatchResult {
	if idx <= 0 {
		suggestions[0] = selected
		return suggestions
	}
	updated := make([]MatchResult, 0, len(suggestions))
	updated = append(updated, selected)
	updated = append(updated, suggestions[:idx]...)
	updated = append(updated, suggestions[idx+1:]...)
	return updated
}
