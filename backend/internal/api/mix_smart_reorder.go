package api

import "math"

// Smart Reorder sequences a playlist by DJ adjacency: tracks that mix well
// end up next to each other. It is pure derivation over the same analyzer
// facts the auto-blend generator already decodes, and it reuses that file's
// distance semantics rather than forking a second metric.
//
// Two rules keep the result honest:
//
//  1. Only fully analyzed tracks (tempo *and* Camelot key) enter the wheel.
//     A track missing either fact carries no evidence about where it belongs,
//     so it is never guessed into the sequence.
//  2. Unanalyzed tracks keep their relative position: each one stays at the
//     tail of its local run, i.e. immediately after the analyzed track it
//     already followed, in its original relative order. Unanalyzed tracks
//     ahead of the first analyzed track stay at the front.

const (
	// Wrap-aware Camelot number distance maxes out at 6 (opposite side of the
	// wheel), so dividing by 6 puts the key term on the same 0..1 scale as the
	// tempo term and makes the sum a fair blend of both.
	smartReorderKeyDistanceDivisor = 6.0
	// Relative major/minor (same number, different letter) is a real match but
	// not an identical key. A penalty of one twelfth of the key scale keeps it
	// ranked just behind an exact key match without ever outweighing tempo.
	smartReorderLetterPenalty = 1.0 / 12.0
	// Float comparisons pick the earliest candidate on a tie so the ordering
	// is deterministic for identical tracks.
	smartReorderTieEpsilon = 1e-9
)

// smartReorderIsOrderable reports whether a track carries the full analyzer
// evidence the wheel needs. Partial analysis is treated as unanalyzed: a BPM
// without a key gives no key evidence, and scoring it as "key distance zero"
// would silently pull it next to everything.
func smartReorderIsOrderable(facts autoBlendTrackFacts) bool {
	return facts.HasBPM && facts.BPM > 0 && facts.HasCamelot
}

// smartReorderDistance scores an ordered pair: lower means a better mix.
//
// Tempo term: |bpm difference| / max bpm, matching autoBlendTempoRatio.
// Key term: the wrap-aware Camelot number distance from
// autoBlendCamelotDistance (12 -> 1 is one step, not eleven), normalized,
// plus the relative major/minor penalty.
//
// Callers must only pass pairs where both tracks are orderable; otherwise the
// tempo ratio is +Inf by construction.
func smartReorderDistance(a, b autoBlendTrackFacts) float64 {
	tempo := autoBlendTempoRatio(a.BPM, b.BPM, a.HasBPM, b.HasBPM)
	_, numberDistance := autoBlendCamelotDistance(
		a.CamelotNumber, a.CamelotLetter, a.HasCamelot,
		b.CamelotNumber, b.CamelotLetter, b.HasCamelot,
	)
	if numberDistance == math.MaxInt {
		return math.MaxFloat64
	}
	key := float64(numberDistance) / smartReorderKeyDistanceDivisor
	if a.CamelotLetter != b.CamelotLetter {
		key += smartReorderLetterPenalty
	}
	return tempo + key
}

// smartReorderOrder returns the new ordering as indices into facts.
//
// Analyzed tracks are sequenced greedily nearest-neighbor from the first
// analyzed track in the current order (keeping the user's chosen opener), then
// each unanalyzed track is re-emitted directly after the analyzed track it
// trailed before. The result is always a permutation of the input.
func smartReorderOrder(facts []autoBlendTrackFacts) []int {
	identity := make([]int, len(facts))
	for i := range facts {
		identity[i] = i
	}

	orderable := make([]int, 0, len(facts))
	leading := make([]int, 0)
	trailing := make(map[int][]int)
	anchor := -1
	for i := range facts {
		if smartReorderIsOrderable(facts[i]) {
			orderable = append(orderable, i)
			anchor = i
			continue
		}
		if anchor < 0 {
			leading = append(leading, i)
			continue
		}
		trailing[anchor] = append(trailing[anchor], i)
	}

	// Fewer than two orderable tracks means there is nothing to sequence.
	if len(orderable) < 2 {
		return identity
	}

	visited := make(map[int]bool, len(orderable))
	sequence := make([]int, 0, len(orderable))
	current := orderable[0]
	visited[current] = true
	sequence = append(sequence, current)
	for len(sequence) < len(orderable) {
		best := -1
		bestDistance := math.MaxFloat64
		for _, candidate := range orderable {
			if visited[candidate] {
				continue
			}
			distance := smartReorderDistance(facts[current], facts[candidate])
			if best < 0 || distance < bestDistance-smartReorderTieEpsilon {
				best = candidate
				bestDistance = distance
			}
		}
		if best < 0 {
			break
		}
		visited[best] = true
		sequence = append(sequence, best)
		current = best
	}

	order := make([]int, 0, len(facts))
	order = append(order, leading...)
	for _, index := range sequence {
		order = append(order, index)
		order = append(order, trailing[index]...)
	}
	if len(order) != len(facts) {
		// Defensive: never return a partial ordering, which would drop tracks.
		return identity
	}
	return order
}
