package api

import (
	"math"
	"sort"
	"strconv"

	"github.com/openmusicplayer/backend/internal/db"
)

const (
	// djHarmonicLineupBlockID is deliberately NOT a member of djLineupThemes.
	// The three themed blocks are a frozen design contract (their count bounds
	// the blocks parameter and their ids spell the block enum error); the
	// harmonic block is an additive, flag-gated fourth block that leads the
	// response because it continues the queue the listener already built.
	djHarmonicLineupBlockID = "harmonic"

	// djHarmonicLineupBPMTolerance is the absolute BPM window around the
	// anchor — roughly +/-5% at club tempo, matching the nearby endpoint's
	// default feel. Beat-matchable without pitching a track past recognition.
	djHarmonicLineupBPMTolerance = 6.0

	// djHarmonicLineupMinCandidates is the floor below which the block is
	// omitted entirely. Two "compatible" tracks is not a set worth showing as
	// a DJ suggestion, and a thin block reads as a bug to the listener.
	djHarmonicLineupMinCandidates = 3

	// djHarmonicLineupSeedOffset keeps the harmonic block's shuffle stream
	// disjoint from the themed blocks. Theme offsets are seed+index*7919 for
	// index 0..2, so *4 cannot collide with any of them.
	djHarmonicLineupSeedOffset int64 = 7919 * 4
)

var djHarmonicLineupTheme = djLineupTheme{
	ID:     djHarmonicLineupBlockID,
	Title:  "In key",
	Reason: "Mixes cleanly from what you just queued.",
}

// djHarmonicAnchor is the resolved queue-tail track: the harmonic origin the
// block mixes out of. Number/Letter are the parsed camelot position, so the
// compatibility rule never has to re-parse a label.
type djHarmonicAnchor struct {
	TrackID int64
	BPM     float64
	Number  int
	Letter  byte
}

// djHarmonicLineupInputs is everything buildDJLineup needs to emit the
// harmonic block. It is populated by the handler (which owns all I/O) and is
// nil whenever the block must not be produced, which keeps buildDJLineup pure.
type djHarmonicLineupInputs struct {
	Anchor     djHarmonicAnchor
	Candidates []db.NearbyTrack
}

// resolveDJHarmonicAnchor finds the client-supplied queue-tail track inside the
// library projection the lineup already loaded. There is no server-side play
// queue, so the tail arrives as a request parameter; resolving it against the
// user's own library is what makes it authoritative rather than trusted.
//
// It reads db.DJLineupTrack's compact-analysis projection, which is the same
// semantics as track_analysis.effective_bpm/effective_camelot used by the
// candidate query, so no new SQL and no new repository method is needed.
// Validation is explicit because ListDJLineupTracks does not filter on
// analysis status: an unanalyzed anchor simply has no usable BPM or camelot.
func resolveDJHarmonicAnchor(tracks []db.DJLineupTrack, anchorTrackID int64) (djHarmonicAnchor, bool) {
	if anchorTrackID <= 0 {
		return djHarmonicAnchor{}, false
	}
	for _, track := range tracks {
		if track.ID != anchorTrackID {
			continue
		}
		if track.BPM <= 0 || math.IsNaN(track.BPM) || math.IsInf(track.BPM, 0) {
			return djHarmonicAnchor{}, false
		}
		number, letter, ok := autoBlendParseCamelot(track.Camelot)
		if !ok {
			return djHarmonicAnchor{}, false
		}
		return djHarmonicAnchor{TrackID: track.ID, BPM: track.BPM, Number: number, Letter: letter}, true
	}
	return djHarmonicAnchor{}, false
}

// includesHarmonicBlock reports whether this request's block selection could
// show the harmonic block at all. A request pinned to one themed block never
// can, so the caller skips the candidate read entirely rather than paying for
// a result it would discard.
func (q djLineupQuery) includesHarmonicBlock() bool {
	return q.BlockID == "" || q.BlockID == djHarmonicLineupBlockID
}

// djHarmonicLineupDetail states the anchor the block mixed out of. The anchor
// is conveyed only here: no new response field exists, so a fallback response
// is structurally identical to a lineup that never had a harmonic block.
func djHarmonicLineupDetail(anchor djHarmonicAnchor) string {
	bpm := strconv.FormatFloat(math.Round(anchor.BPM*10)/10, 'f', -1, 64)
	return "From " + bpm + " BPM · " + canonicalCamelotLabel(anchor.Number, anchor.Letter)
}

// buildDJHarmonicLineupBlock joins the repository's affinity-ranked harmonic
// candidates back onto the lineup projection and emits the block, or reports
// false so the caller emits nothing at all.
//
// byID is the post-filter, post-pin lineup projection keyed by track id; it is
// read by key only and never iterated, so map ordering cannot leak into the
// response. Walking harmonic.Candidates in repository order is what preserves
// the affinity ranking as the block's ordering authority — orderDJLineupTracks
// is deliberately not applied here.
func buildDJHarmonicLineupBlock(
	harmonic *djHarmonicLineupInputs,
	byID map[int64]db.DJLineupTrack,
	query djLineupQuery,
	signals djSkipSignals,
) (DJLineupBlock, bool) {
	if harmonic == nil {
		return DJLineupBlock{}, false
	}
	anchor := harmonic.Anchor

	candidates := make([]db.DJLineupTrack, 0, len(harmonic.Candidates))
	for _, candidate := range harmonic.Candidates {
		if candidate.ID == anchor.TrackID {
			continue
		}
		// Absent from byID means the candidate was removed by the requested
		// filters, excludeIds, or the active vibe pin. Those constraints win.
		track, inLineup := byID[candidate.ID]
		if !inLineup {
			continue
		}
		// Defensive per-candidate compatibility re-check, mirroring the nearby
		// endpoint: the indexed SQL predicate narrows the set, the canonical
		// distance rule decides membership.
		candidateNumber, candidateLetter, candidateOK := autoBlendParseCamelot(candidate.EffectiveCamelot)
		compatible, _ := autoBlendCamelotDistance(anchor.Number, anchor.Letter, true, candidateNumber, candidateLetter, candidateOK)
		if !compatible {
			continue
		}
		if math.Abs(candidate.EffectiveBPM-anchor.BPM) > djHarmonicLineupBPMTolerance {
			continue
		}
		candidates = append(candidates, track)
	}

	if len(candidates) < djHarmonicLineupMinCandidates {
		return DJLineupBlock{}, false
	}

	candidates = applyDJSkipSequencing(candidates, djHarmonicLineupBlockID, signals)

	// Determinism: seeded selection from the affinity-ranked head, then
	// restored to rank order. Variety comes from the seed, ordering comes from
	// affinity. Ranks are captured after skip sequencing so a demoted track
	// stays demoted, are unique, and the map is only ever read by key.
	rankByID := make(map[int64]int, len(candidates))
	for rank, track := range candidates {
		rankByID[track.ID] = rank
	}
	selected := selectDJLineupTracks(candidates, query.PerBlock, query.Seed+djHarmonicLineupSeedOffset)
	if len(selected) == 0 {
		return DJLineupBlock{}, false
	}
	sort.Slice(selected, func(i, j int) bool {
		return rankByID[selected[i].ID] < rankByID[selected[j].ID]
	})

	block := DJLineupBlock{
		ID:     djHarmonicLineupTheme.ID,
		Title:  djHarmonicLineupTheme.Title,
		Reason: djHarmonicLineupTheme.Reason,
		Detail: djHarmonicLineupDetail(anchor),
		Tracks: make([]DJLineupTrackResponse, 0, len(selected)),
	}
	for _, track := range selected {
		block.Tracks = append(block.Tracks, DJLineupTrackResponse{
			ID:         track.ID,
			Title:      track.Title,
			Artist:     track.Artist,
			Album:      track.Album,
			DurationMs: track.DurationMs,
			BPM:        track.BPM,
			Camelot:    track.Camelot,
			Energy:     track.Energy,
		})
	}
	return block, true
}
