package api

import (
	"context"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

const (
	// skipRateDemotionThreshold is the per-track 30-day skip rate at or above
	// which a track is demoted within its block ordering.
	skipRateDemotionThreshold = 0.5

	// fastExitSkipCount is the number of skips in the trailing window that
	// triggers fast-exit mode.
	fastExitSkipCount = 3

	// fastExitWindow is the trailing window in which fastExitSkipCount skips
	// trigger fast-exit mode. It decays automatically: the mode is only this
	// window, there is no stored state to clear.
	fastExitWindow = 10 * time.Minute

	// fastExitEnergyNeighborhood is how far a track's energy may differ from a
	// heavily-skipped track's energy while still counting as "same neighborhood".
	fastExitEnergyNeighborhood = 0.15

	// skipStatsWindowDays bounds the skip-rate lookback used for sequencing.
	skipStatsWindowDays = 30
)

// DJSkipSignalStore is the optional read-side extension to DJLineupStore that
// exposes the user's skip telemetry for lineup sequencing. Handlers work
// without it (skips simply do not influence ordering), so existing fakes and
// deployments keep compiling and behaving as before.
type DJSkipSignalStore interface {
	ListSkipStats(ctx context.Context, userID uuid.UUID, days int) ([]db.SkipStats, error)
	CountRecentSkips(ctx context.Context, userID uuid.UUID, window time.Duration) (int64, error)
}

// djSkippedNeighborhood describes one heavily-skipped track's genre/energy
// neighborhood: peers near it are demoted alongside it.
type djSkippedNeighborhood struct {
	genres map[string]struct{}
	energy float64
}

// djSkipSignals is the resolved skip state for one lineup request.
type djSkipSignals struct {
	statsByTrack   map[int64]db.SkipStats
	recentSkips    int64
	fastExitActive bool
	neighborhoods  []djSkippedNeighborhood
	tracksByID     map[int64]db.DJLineupTrack
}

func newDJSkipSignals(stats []db.SkipStats, recentSkips int64) djSkipSignals {
	signals := djSkipSignals{
		statsByTrack: make(map[int64]db.SkipStats, len(stats)),
		recentSkips:  recentSkips,
	}
	for _, stat := range stats {
		signals.statsByTrack[stat.TrackID] = stat
	}
	signals.fastExitActive = recentSkips >= fastExitSkipCount
	return signals
}

// loadDJSkipSignals resolves the user's skip state; a nil store yields zero
// signals so lineup behavior degrades to the pre-skip baseline unchanged.
func loadDJSkipSignals(ctx context.Context, store DJSkipSignalStore, userID uuid.UUID) (djSkipSignals, error) {
	if store == nil {
		return newDJSkipSignals(nil, 0), nil
	}
	stats, err := store.ListSkipStats(ctx, userID, skipStatsWindowDays)
	if err != nil {
		return djSkipSignals{}, err
	}
	recentSkips, err := store.CountRecentSkips(ctx, userID, fastExitWindow)
	if err != nil {
		return djSkipSignals{}, err
	}
	return newDJSkipSignals(stats, recentSkips), nil
}

// withCandidates attaches candidate tracks so neighborhoods can be derived
// from their genre hints and energy values. It must be called before
// neighborhoodDemoted is meaningful.
func (s *djSkipSignals) withCandidates(tracks []db.DJLineupTrack) *djSkipSignals {
	s.tracksByID = make(map[int64]db.DJLineupTrack, len(tracks))
	for _, track := range tracks {
		s.tracksByID[track.ID] = track
	}
	s.neighborhoods = nil
	for trackID, stat := range s.statsByTrack {
		if stat.SkipRate() < skipRateDemotionThreshold {
			continue
		}
		track, ok := s.tracksByID[trackID]
		if !ok {
			continue
		}
		genres := make(map[string]struct{}, len(track.GenreHints))
		for _, genre := range track.GenreHints {
			normalized := strings.ToLower(strings.TrimSpace(genre))
			if normalized != "" {
				genres[normalized] = struct{}{}
			}
		}
		if len(genres) > 0 || track.Energy > 0 {
			s.neighborhoods = append(s.neighborhoods, djSkippedNeighborhood{
				genres: genres,
				energy: track.Energy,
			})
		}
	}
	return s
}

// fastExit reports whether enough skips occurred inside the trailing window.
func (s djSkipSignals) fastExit() bool {
	return s.fastExitActive
}

// demoted reports whether a track's own skip rate crosses the threshold.
func (s djSkipSignals) demoted(track db.DJLineupTrack) bool {
	stat, ok := s.statsByTrack[track.ID]
	if !ok {
		return false
	}
	return stat.SkipRate() >= skipRateDemotionThreshold
}

// neighborhoodDemoted reports whether a track is itself heavily skipped, or
// shares a genre/energy neighborhood with a heavily-skipped track.
func (s djSkipSignals) neighborhoodDemoted(track db.DJLineupTrack) bool {
	if s.demoted(track) {
		return true
	}
	for _, neighborhood := range s.neighborhoods {
		for _, genre := range track.GenreHints {
			normalized := strings.ToLower(strings.TrimSpace(genre))
			if normalized == "" {
				continue
			}
			if _, ok := neighborhood.genres[normalized]; ok {
				return true
			}
		}
		if track.Energy > 0 && neighborhood.energy > 0 &&
			math.Abs(track.Energy-neighborhood.energy) <= fastExitEnergyNeighborhood {
			return true
		}
	}
	return false
}

// applyDJSkipSequencing reorders (and, in fast-exit mode, prunes) one block's
// already theme-ordered candidates according to the user's skip signal. With no
// skip data it returns the input slice untouched: empty-skip-data behavior is
// byte-identical to the pre-skip lineup.
func applyDJSkipSequencing(candidates []db.DJLineupTrack, themeID string, signals djSkipSignals) []db.DJLineupTrack {
	if len(signals.statsByTrack) == 0 && !signals.fastExit() {
		return candidates
	}

	demotedFlags := make(map[int64]bool, len(candidates))
	for _, track := range candidates {
		demotedFlags[track.ID] = signals.neighborhoodDemoted(track)
	}

	// Fast-exit mode: fresh finds are out entirely — the listener is rejecting
	// unfamiliar material right now. Every fresh-finds candidate is unplayed
	// by definition, so the block empties naturally and decays with the window.
	if signals.fastExit() && themeID == "fresh-finds" {
		return nil
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		left, right := candidates[i], candidates[j]
		leftDemoted, rightDemoted := demotedFlags[left.ID], demotedFlags[right.ID]
		if leftDemoted != rightDemoted {
			return !leftDemoted
		}
		// Fast-exit on-repeat: last-played recency outweighs play counts so
		// freshly re-affirmed familiar material leads the block.
		if signals.fastExit() && themeID == "on-repeat" && !left.LastRecentPlayedAt.Equal(right.LastRecentPlayedAt) {
			return left.LastRecentPlayedAt.After(right.LastRecentPlayedAt)
		}
		return false
	})
	return candidates
}
