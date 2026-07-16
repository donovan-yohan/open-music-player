// Command sourcequality-rank ranks a batch of discovery candidates with the real
// deterministic discovery.EvaluateSourceQuality scorer. It exists so the
// out-of-tree agent candidate-assembly evals can call the production source
// quality logic instead of re-implementing it in Python: the eval's
// deterministic baseline arm pipes a fixture pool through this CLI and reads back
// the ranked candidates with attached sourceQuality metadata.
//
// It is intentionally read-only, network-free, and stateless: it reads one JSON
// request on stdin and writes one JSON response on stdout.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"

	"github.com/openmusicplayer/backend/internal/discovery"
)

// request is the stdin envelope. Candidates use the exact discovery.Candidate
// JSON shape so fixture pools are consumed unmodified.
type request struct {
	Query      string                `json:"query"`
	Candidates []discovery.Candidate `json:"candidates"`
}

// response is the stdout envelope. Ranked candidates carry the sourceQuality
// metadata attached by the scorer, in the same descending-suitability order the
// production discovery service would emit.
type response struct {
	Query  string                `json:"query"`
	Ranked []discovery.Candidate `json:"ranked"`
}

type scored struct {
	candidate discovery.Candidate
	quality   discovery.SourceQuality
	index     int
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "sourcequality-rank: %v\n", err)
		os.Exit(1)
	}
}

func run(r io.Reader, w io.Writer) error {
	var req request
	decoder := json.NewDecoder(r)
	if err := decoder.Decode(&req); err != nil {
		return fmt.Errorf("decode request: %w", err)
	}
	ranked := rank(req.Query, req.Candidates)
	encoder := json.NewEncoder(w)
	if err := encoder.Encode(response{Query: req.Query, Ranked: ranked}); err != nil {
		return fmt.Errorf("encode response: %w", err)
	}
	return nil
}

// rank mirrors discovery.rankSourceCandidatesWithQualities: it scores each
// candidate with the exported EvaluateSourceQuality function, attaches the
// quality under discovery.SourceQualityMetadataKey, and orders candidates by
// score, then recommendation strength, then downloadability, then input order.
func rank(query string, candidates []discovery.Candidate) []discovery.Candidate {
	items := make([]scored, 0, len(candidates))
	for index, candidate := range candidates {
		quality := discovery.EvaluateSourceQuality(query, candidate)
		items = append(items, scored{
			candidate: candidateWithSourceQuality(candidate, quality),
			quality:   quality,
			index:     index,
		})
	}
	sort.SliceStable(items, func(i, j int) bool {
		left := items[i]
		right := items[j]
		if left.quality.Score != right.quality.Score {
			return left.quality.Score > right.quality.Score
		}
		if recommendationRank(left.quality.Recommendation) != recommendationRank(right.quality.Recommendation) {
			return recommendationRank(left.quality.Recommendation) > recommendationRank(right.quality.Recommendation)
		}
		if left.candidate.Downloadable != right.candidate.Downloadable {
			return left.candidate.Downloadable
		}
		return left.index < right.index
	})
	ranked := make([]discovery.Candidate, len(items))
	for i, item := range items {
		ranked[i] = item.candidate
	}
	return ranked
}

// candidateWithSourceQuality mirrors the unexported discovery helper: it copies
// the metadata map so the input candidate is not mutated, then attaches the
// quality judgment under the canonical metadata key.
func candidateWithSourceQuality(candidate discovery.Candidate, quality discovery.SourceQuality) discovery.Candidate {
	metadata := make(map[string]interface{}, len(candidate.Metadata)+1)
	for key, value := range candidate.Metadata {
		metadata[key] = value
	}
	metadata[discovery.SourceQualityMetadataKey] = quality
	candidate.Metadata = metadata
	return candidate
}

// recommendationRank mirrors the unexported discovery ordering weights so the CLI
// reproduces the production tie-break without exporting internal helpers.
func recommendationRank(recommendation string) int {
	switch recommendation {
	case discovery.SourceQualityPreferred:
		return 4
	case discovery.SourceQualityAcceptable:
		return 3
	case discovery.SourceQualityReview:
		return 2
	case discovery.SourceQualityAvoid:
		return 1
	default:
		return 0
	}
}
