package research

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/discovery"
)

type SourceSearcher interface {
	SearchSources(context.Context, string, []string, int) discovery.SourceSearchResponse
}
type BaselineBuilderConfig struct {
	Search        SourceSearcher
	Providers     []string
	MaxProviders  int
	MaxCandidates int
	Now           func() time.Time
	NewID         func() string
}
type BaselineBuilder struct{ config BaselineBuilderConfig }

func NewBaselineBuilder(config BaselineBuilderConfig) (*BaselineBuilder, error) {
	if config.Search == nil {
		return nil, errors.New("research source search is required")
	}
	if config.MaxProviders <= 0 || config.MaxProviders > 2 {
		config.MaxProviders = 2
	}
	if config.MaxCandidates <= 0 || config.MaxCandidates > 25 {
		config.MaxCandidates = 25
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.NewID == nil {
		config.NewID = newResearchID
	}
	return &BaselineBuilder{config}, nil
}
func (b *BaselineBuilder) Build(ctx context.Context, query string, providers []string, limit int) (RevisionInput, error) {
	query = strings.TrimSpace(query)
	if !safeText(query, 512) {
		return RevisionInput{}, errors.New("research query invalid")
	}
	selected := b.providers(providers)
	if limit < 1 {
		limit = b.config.MaxCandidates
	}
	if limit > b.config.MaxCandidates {
		limit = b.config.MaxCandidates
	}
	started := b.config.Now()
	response := b.config.Search.SearchSources(ctx, query, selected, limit)
	positions := map[string]int{}
	for i, p := range selected {
		positions[p] = i
	}
	candidates := make([]CandidateSnapshot, 0, len(response.Results))
	for _, candidate := range response.Results {
		_, ok := positions[candidate.Provider]
		if !ok || !allowedProvider(candidate.Provider) {
			continue
		}
		candidates = append(candidates, snapshotCandidate(candidate, discovery.EvaluateSourceQuality(query, candidate)))
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		a, c := candidates[i], candidates[j]
		if a.SourceQuality.Score != c.SourceQuality.Score {
			return a.SourceQuality.Score > c.SourceQuality.Score
		}
		if recommendationOrder(a.SourceQuality.Recommendation) != recommendationOrder(c.SourceQuality.Recommendation) {
			return recommendationOrder(a.SourceQuality.Recommendation) > recommendationOrder(c.SourceQuality.Recommendation)
		}
		if a.Downloadable != c.Downloadable {
			return a.Downloadable
		}
		if positions[a.Provider] != positions[c.Provider] {
			return positions[a.Provider] < positions[c.Provider]
		}
		return a.CandidateID < c.CandidateID
	})
	if len(candidates) > b.config.MaxCandidates {
		candidates = candidates[:b.config.MaxCandidates]
	}
	recommendations := make([]Recommendation, 0, min(limit, len(candidates)))
	for i, candidate := range candidates[:min(limit, len(candidates))] {
		recommendations = append(recommendations, Recommendation{CandidateID: candidate.CandidateID, Rank: i + 1, Confidence: candidate.SourceQuality.Confidence, Classification: candidate.SourceQuality.Classification, Warnings: append([]string(nil), candidate.SourceQuality.Warnings...), EvidenceRefs: []string{candidate.CandidateID}})
	}
	payload := RevisionPayload{SchemaVersion: RevisionPayloadSchemaVersion, Stage: StageBaseline, Query: query, Candidates: candidates, Recommendations: recommendations, Provenance: Provenance{Source: "deterministic_discovery_v1"}, Timing: SafeTiming{BaselineBuildMs: b.config.Now().Sub(started).Milliseconds()}}
	raw, err := payload.Marshal()
	if err != nil {
		return RevisionInput{}, err
	}
	return RevisionInput{ID: b.config.NewID(), Payload: raw}, nil
}
func (b *BaselineBuilder) providers(requested []string) []string {
	seen := map[string]bool{}
	result := make([]string, 0, b.config.MaxProviders)
	for _, p := range append(append([]string{}, requested...), b.config.Providers...) {
		if !allowedProvider(p) || seen[p] {
			continue
		}
		seen[p] = true
		result = append(result, p)
		if len(result) == b.config.MaxProviders {
			break
		}
	}
	if len(result) == 0 {
		result = []string{"youtube", "soundcloud"}
		if b.config.MaxProviders == 1 {
			result = result[:1]
		}
	}
	return result
}
func newResearchID() string {
	return uuid.NewString()
}
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
