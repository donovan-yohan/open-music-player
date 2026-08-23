package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

const (
	djLineupDefaultBlocks   = 3
	djLineupDefaultPerBlock = 5
	djLineupMaxPerBlock     = 50
)

type DJLineupStore interface {
	ListDJLineupTracks(ctx context.Context, userID uuid.UUID) ([]db.DJLineupTrack, error)
}

type DJPinReader interface {
	GetDJPin(ctx context.Context, userID uuid.UUID) (*db.DJPin, error)
}

type DJLineupHandlers struct {
	store       DJLineupStore
	pins        DJPinReader
	skipSignals DJSkipSignalStore
}

func NewDJLineupHandlers(store DJLineupStore) *DJLineupHandlers {
	return &DJLineupHandlers{store: store}
}

// NewDJLineupHandlersWithPinStore wires lineup generation to the user's vibe
// pin so the lineup can filter candidate tracks to the pinned envelope.
func NewDJLineupHandlersWithPinStore(store DJLineupStore, pins DJPinReader) *DJLineupHandlers {
	return &DJLineupHandlers{store: store, pins: pins}
}

// NewDJLineupHandlersWithSkipSignals wires lineup generation to the user's skip
// telemetry so recently-skipped material (and its genre/energy neighborhood) is
// demoted, and rapid skipping enables fast-exit sequencing.
func NewDJLineupHandlersWithSkipSignals(store DJLineupStore, pins DJPinReader, skips DJSkipSignalStore) *DJLineupHandlers {
	return &DJLineupHandlers{store: store, pins: pins, skipSignals: skips}
}

type DJLineupRequestedFilters struct {
	Energy *string `json:"energy"`
	Genre  *string `json:"genre"`
	Q      *string `json:"q"`
}

type DJLineupTrackResponse struct {
	ID         int64   `json:"id"`
	Title      string  `json:"title"`
	Artist     string  `json:"artist"`
	Album      string  `json:"album"`
	DurationMs int     `json:"durationMs"`
	BPM        float64 `json:"bpm"`
	Camelot    string  `json:"camelot"`
	Energy     float64 `json:"energy"`
}

type DJLineupBlock struct {
	ID     string                  `json:"id"`
	Title  string                  `json:"title"`
	Reason string                  `json:"reason"`
	Detail string                  `json:"detail,omitempty"`
	Tracks []DJLineupTrackResponse `json:"tracks"`
}

// DJLineupPinned mirrors the active vibe pin's block identity in lineup
// responses; nil (and thus omitted) when no unexpired pin exists.
type DJLineupPinned struct {
	BlockID string `json:"blockId"`
}

type DJLineupResponse struct {
	Requested DJLineupRequestedFilters `json:"requested"`
	Pinned    *DJLineupPinned          `json:"pinned,omitempty"`
	Blocks    []DJLineupBlock          `json:"blocks"`
}

type djLineupQuery struct {
	Requested DJLineupRequestedFilters
	Blocks    int
	PerBlock  int
	Seed      int64
	ExcludeID map[int64]struct{}
	BlockID   string
}

type djLineupTheme struct {
	ID     string
	Title  string
	Reason string
}

var djLineupThemes = []djLineupTheme{
	{ID: "on-repeat", Title: "On repeat", Reason: "The ones you keep coming back to."},
	{ID: "flashback", Title: "Flashback", Reason: "Haven't heard this in a minute."},
	{ID: "fresh-finds", Title: "Fresh finds", Reason: "Barely played. Worth your time."},
}

// GetLineup handles GET /api/v1/dj/lineup. It is deterministic and relies only
// on persisted library, play-event, and audio-analysis facts; it never invokes
// an LLM or writes lineup state.
func (h *DJLineupHandlers) GetLineup(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDJLineupError(w, http.StatusUnauthorized, "not authenticated")
		return
	}

	query, err := parseDJLineupQuery(r)
	if err != nil {
		writeDJLineupError(w, http.StatusBadRequest, err.Error())
		return
	}
	tracks, err := h.store.ListDJLineupTracks(r.Context(), userCtx.UserID)
	if err != nil {
		writeDJLineupError(w, http.StatusInternalServerError, "failed to load DJ lineup")
		return
	}

	var pin *db.DJPin
	if h.pins != nil {
		pin, err = h.pins.GetDJPin(r.Context(), userCtx.UserID)
		if err != nil {
			writeDJLineupError(w, http.StatusInternalServerError, "failed to load DJ pin")
			return
		}
	}
	if pin != nil {
		tracks = filterDJLineupTracksByPin(tracks, *pin)
	}

	signals, err := loadDJSkipSignals(r.Context(), h.skipSignals, userCtx.UserID)
	if err != nil {
		writeDJLineupError(w, http.StatusInternalServerError, "failed to load skip signals")
		return
	}
	signals.withCandidates(tracks)

	response := DJLineupResponse{
		Requested: query.Requested,
		Blocks:    buildDJLineup(tracks, query, signals),
	}
	if pin != nil {
		response.Pinned = &DJLineupPinned{BlockID: pin.BlockID}
	}
	writeDJLineupJSON(w, http.StatusOK, response)
}

// filterDJLineupTracksByPin keeps only tracks inside the pinned vibe envelope:
// energy within [low, high] inclusive and — when the pin carries a non-empty
// genre list — at least one matching pinned genre.
func filterDJLineupTracksByPin(tracks []db.DJLineupTrack, pin db.DJPin) []db.DJLineupTrack {
	filtered := make([]db.DJLineupTrack, 0, len(tracks))
	for _, track := range tracks {
		if matchesDJLineupPin(track, pin) {
			filtered = append(filtered, track)
		}
	}
	return filtered
}

func parseDJLineupQuery(r *http.Request) (djLineupQuery, error) {
	values := r.URL.Query()
	query := djLineupQuery{
		Blocks:    djLineupDefaultBlocks,
		PerBlock:  djLineupDefaultPerBlock,
		ExcludeID: make(map[int64]struct{}),
	}

	if raw, present := values["energy"]; present {
		energy := strings.ToLower(strings.TrimSpace(firstDJLineupValue(raw)))
		if energy != "low" && energy != "medium" && energy != "high" {
			return query, errors.New("energy must be one of: low, medium, high")
		}
		query.Requested.Energy = &energy
	}
	if raw, present := values["genre"]; present {
		genre := strings.TrimSpace(firstDJLineupValue(raw))
		if genre != "" {
			query.Requested.Genre = &genre
		}
	}
	if raw, present := values["q"]; present {
		search := strings.TrimSpace(firstDJLineupValue(raw))
		if search != "" {
			query.Requested.Q = &search
		}
	}

	var err error
	if _, present := values["eraStart"]; present {
		return query, errors.New("era filtering is not supported: the library has no release-year data")
	}
	if _, present := values["eraEnd"]; present {
		return query, errors.New("era filtering is not supported: the library has no release-year data")
	}

	if raw, present := values["blocks"]; present {
		query.Blocks, err = parseDJLineupBoundedInt(firstDJLineupValue(raw), "blocks", 1, len(djLineupThemes))
		if err != nil {
			return query, err
		}
	}
	if raw, present := values["perBlock"]; present {
		query.PerBlock, err = parseDJLineupBoundedInt(firstDJLineupValue(raw), "perBlock", 1, djLineupMaxPerBlock)
		if err != nil {
			return query, err
		}
	}
	if raw, present := values["seed"]; present {
		query.Seed, err = strconv.ParseInt(strings.TrimSpace(firstDJLineupValue(raw)), 10, 64)
		if err != nil {
			return query, errors.New("seed must be an integer")
		}
	}
	if raw, present := values["block"]; present {
		query.BlockID = strings.ToLower(strings.TrimSpace(firstDJLineupValue(raw)))
		if !isDJLineupTheme(query.BlockID) {
			return query, errors.New("block must be one of: on-repeat, flashback, fresh-finds")
		}
	}
	for _, raw := range values["excludeIds"] {
		for _, part := range strings.Split(raw, ",") {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			id, err := strconv.ParseInt(part, 10, 64)
			if err != nil || id <= 0 {
				return query, fmt.Errorf("excludeIds must contain positive integer track IDs")
			}
			query.ExcludeID[id] = struct{}{}
		}
	}

	return query, nil
}

func firstDJLineupValue(values []string) string {
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func parseDJLineupBoundedInt(raw, name string, min, max int) (int, error) {
	value, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || value < min || value > max {
		return 0, fmt.Errorf("%s must be an integer between %d and %d", name, min, max)
	}
	return value, nil
}

func isDJLineupTheme(id string) bool {
	for _, theme := range djLineupThemes {
		if theme.ID == id {
			return true
		}
	}
	return false
}

func buildDJLineup(tracks []db.DJLineupTrack, query djLineupQuery, signals djSkipSignals) []DJLineupBlock {
	filtered := make([]db.DJLineupTrack, 0, len(tracks))
	for _, track := range tracks {
		if matchesDJLineupFilters(track, query) {
			filtered = append(filtered, track)
		}
	}

	themes := selectedDJLineupThemes(query)
	blocks := make([]DJLineupBlock, 0, len(themes))
	usedTrackIDs := make(map[int64]struct{})
	for themeIndex, theme := range themes {
		candidates := eligibleDJLineupTracks(filtered, usedTrackIDs, theme.ID)
		orderDJLineupTracks(candidates, theme.ID)
		candidates = applyDJSkipSequencing(candidates, theme.ID, signals)
		tracks := selectDJLineupTracks(candidates, query.PerBlock, query.Seed+int64(themeIndex)*7919)
		if len(tracks) == 0 {
			continue
		}

		block := DJLineupBlock{
			ID:     theme.ID,
			Title:  theme.Title,
			Reason: theme.Reason,
			Detail: djLineupDetail(theme.ID, candidates),
			Tracks: make([]DJLineupTrackResponse, 0, len(tracks)),
		}
		for _, track := range tracks {
			usedTrackIDs[track.ID] = struct{}{}
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
		blocks = append(blocks, block)
	}
	return blocks
}

func selectedDJLineupThemes(query djLineupQuery) []djLineupTheme {
	if query.BlockID != "" {
		for _, theme := range djLineupThemes {
			if theme.ID == query.BlockID {
				return []djLineupTheme{theme}
			}
		}
		return nil
	}
	return djLineupThemes[:query.Blocks]
}

// djLineupDetail derives a data-grounded one-liner for a block from the same
// aggregates that selected its candidates. It returns an empty string when the
// underlying data is absent so responses never fabricate context.
func djLineupDetail(themeID string, candidates []db.DJLineupTrack) string {
	switch themeID {
	case "on-repeat":
		return djLineupOnRepeatDetail(candidates)
	case "flashback":
		return djLineupFlashbackDetail(candidates)
	case "fresh-finds":
		return djLineupFreshFindsDetail(candidates)
	default:
		return ""
	}
}

// on-repeat: "<N> plays in the last 90 days" summed across candidates, capped
// at a 999+ display.
func djLineupOnRepeatDetail(candidates []db.DJLineupTrack) string {
	var total int64
	for _, track := range candidates {
		total += track.RecentPlayCount
	}
	if total <= 0 {
		return ""
	}
	if total > 999 {
		return "999+ plays in the last 90 days"
	}
	return fmt.Sprintf("%d plays in the last 90 days", total)
}

// flashback: "Last played <Month Year>" from the most recent prior play across
// candidates; omitted when none of them carry a pre-recent play timestamp.
func djLineupFlashbackDetail(candidates []db.DJLineupTrack) string {
	var latest time.Time
	for _, track := range candidates {
		if track.LastHistoricalPlayed.After(latest) {
			latest = track.LastHistoricalPlayed
		}
	}
	if latest.IsZero() {
		return ""
	}
	return "Last played " + latest.Format("January 2006")
}

// fresh-finds: "<N> unplayed tracks waiting" counts the zero-play library
// tracks eligible for the block.
func djLineupFreshFindsDetail(candidates []db.DJLineupTrack) string {
	if len(candidates) == 0 {
		return ""
	}
	return fmt.Sprintf("%d unplayed tracks waiting", len(candidates))
}

func matchesDJLineupFilters(track db.DJLineupTrack, query djLineupQuery) bool {
	if _, excluded := query.ExcludeID[track.ID]; excluded {
		return false
	}
	if query.Requested.Energy != nil && !matchesDJLineupEnergy(track.Energy, *query.Requested.Energy) {
		return false
	}
	if query.Requested.Genre != nil {
		found := false
		for _, genre := range track.GenreHints {
			if strings.EqualFold(strings.TrimSpace(genre), *query.Requested.Genre) {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	if query.Requested.Q != nil && !matchesDJLineupSearch(track, *query.Requested.Q) {
		return false
	}

	// The tracks schema has no release-year column. Era filtering is therefore
	// not offered: the query parser rejects eraStart/eraEnd rather than
	// accepting filters it cannot honor.
	return true
}

func matchesDJLineupEnergy(energy float64, bucket string) bool {
	switch bucket {
	case "low":
		return energy < 0.35
	case "medium":
		return energy >= 0.35 && energy <= 0.65
	case "high":
		return energy > 0.65
	default:
		return false
	}
}

func matchesDJLineupSearch(track db.DJLineupTrack, query string) bool {
	needle := strings.ToLower(strings.TrimSpace(query))
	if needle == "" {
		return true
	}
	for _, value := range []string{track.Title, track.Artist, track.Album} {
		if strings.Contains(strings.ToLower(value), needle) {
			return true
		}
	}
	for _, genre := range track.GenreHints {
		if strings.Contains(strings.ToLower(genre), needle) {
			return true
		}
	}
	return false
}

func eligibleDJLineupTracks(tracks []db.DJLineupTrack, usedTrackIDs map[int64]struct{}, themeID string) []db.DJLineupTrack {
	eligible := make([]db.DJLineupTrack, 0, len(tracks))
	for _, track := range tracks {
		if _, used := usedTrackIDs[track.ID]; used {
			continue
		}
		switch themeID {
		case "on-repeat":
			if track.RecentPlayCount == 0 {
				continue
			}
		case "flashback":
			if track.HistoricalPlayCount+track.MidWindowPlayCount == 0 || track.RecentPlayCount > 0 {
				continue
			}
		case "fresh-finds":
			if track.TotalPlayCount > 0 {
				continue
			}
		}
		eligible = append(eligible, track)
	}
	return eligible
}

func orderDJLineupTracks(tracks []db.DJLineupTrack, themeID string) {
	sort.Slice(tracks, func(i, j int) bool {
		left, right := tracks[i], tracks[j]
		switch themeID {
		case "on-repeat":
			if left.RecentPlayCount != right.RecentPlayCount {
				return left.RecentPlayCount > right.RecentPlayCount
			}
			if !left.LastRecentPlayedAt.Equal(right.LastRecentPlayedAt) {
				return left.LastRecentPlayedAt.After(right.LastRecentPlayedAt)
			}
		case "flashback":
			if left.MidWindowPlayCount != right.MidWindowPlayCount {
				return left.MidWindowPlayCount > right.MidWindowPlayCount
			}
			if !left.LastHistoricalPlayed.Equal(right.LastHistoricalPlayed) {
				return left.LastHistoricalPlayed.After(right.LastHistoricalPlayed)
			}
		case "fresh-finds":
			if !left.AddedAt.Equal(right.AddedAt) {
				return left.AddedAt.After(right.AddedAt)
			}
		}
		return left.ID > right.ID
	})
}

func selectDJLineupTracks(candidates []db.DJLineupTrack, perBlock int, seed int64) []db.DJLineupTrack {
	if len(candidates) == 0 {
		return nil
	}
	poolSize := perBlock * 3
	if poolSize > len(candidates) {
		poolSize = len(candidates)
	}
	pool := append([]db.DJLineupTrack(nil), candidates[:poolSize]...)
	rng := rand.New(rand.NewSource(seed))
	rng.Shuffle(len(pool), func(i, j int) {
		pool[i], pool[j] = pool[j], pool[i]
	})
	if len(pool) > perBlock {
		pool = pool[:perBlock]
	}
	return pool
}

func writeDJLineupJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeDJLineupError(w http.ResponseWriter, status int, message string) {
	writeErrorResponse(w, status, djLineupErrorCode(status), message)
}

func djLineupErrorCode(status int) string {
	switch status {
	case http.StatusUnauthorized:
		return "unauthorized"
	case http.StatusBadRequest:
		return "invalid_request"
	default:
		return "internal_error"
	}
}
