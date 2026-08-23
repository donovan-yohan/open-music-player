package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

// DJLineupTrack is the minimal per-user library projection needed to build a
// deterministic DJ lineup. It deliberately keeps selection data separate from
// API response types so the API layer can be unit-tested against a fake store.
type DJLineupTrack struct {
	ID                   int64
	Title                string
	Artist               string
	Album                string
	DurationMs           int
	BPM                  float64
	Camelot              string
	Energy               float64
	GenreHints           []string
	AddedAt              time.Time
	RecentPlayCount      int64
	LastRecentPlayedAt   time.Time
	TotalPlayCount       int64
	HistoricalPlayCount  int64
	MidWindowPlayCount   int64
	LastHistoricalPlayed time.Time
}

// DJLineupRepository reads existing library, play-event, and analysis data for
// a user's personalized DJ lineup. It adds no persistent state.
type DJLineupRepository struct {
	db *DB
}

func NewDJLineupRepository(db *DB) *DJLineupRepository {
	return &DJLineupRepository{db: db}
}

// ListDJLineupTracks returns every track in the user's library with its play
// windows and effective compact analysis facts. Play windows split at 90 days
// (recent), 90-180 days (mid), and older than 180 days (historical); together
// they partition history so every played track belongs to a lineup theme.
//
// Skipped events are excluded from these play windows: a skip is not a listen,
// so a track that was only ever skipped keeps TotalPlayCount 0 and remains
// fresh-finds eligible. Skip telemetry is read separately by ListSkipStats /
// CountRecentSkips, which do consider skip rows.
//
// The read is intentionally unbounded: correct cross-block partitioning and
// partial fills require scoring every library track before selection caps the
// result. Bounding this per theme would starve later blocks on large
// libraries; revisit only with a real performance signal.
func (r *DJLineupRepository) ListDJLineupTracks(ctx context.Context, userID uuid.UUID) ([]DJLineupTrack, error) {
	query := `
		WITH play_stats AS (
			SELECT pe.track_id,
				COUNT(*) FILTER (WHERE pe.played_at >= NOW() - INTERVAL '90 days') AS recent_play_count,
				MAX(pe.played_at) FILTER (WHERE pe.played_at >= NOW() - INTERVAL '90 days') AS last_recent_played_at,
				COUNT(*) AS total_play_count,
				COUNT(*) FILTER (WHERE pe.played_at >= NOW() - INTERVAL '180 days' AND pe.played_at < NOW() - INTERVAL '90 days') AS mid_window_play_count,
				COUNT(*) FILTER (WHERE pe.played_at < NOW() - INTERVAL '180 days') AS historical_play_count,
				MAX(pe.played_at) FILTER (WHERE pe.played_at < NOW() - INTERVAL '90 days') AS last_prior_played_at
			FROM play_events pe
			WHERE pe.user_id = $1 AND NOT pe.skipped
			GROUP BY pe.track_id
		)
		SELECT t.id,
			COALESCE(tmo.title, t.title),
			COALESCE(tmo.artist, t.artist, ''),
			COALESCE(tmo.album, t.album, ''),
			COALESCE(t.duration_ms, 0),
			COALESCE(ta.summary_json, '{}'::jsonb),
			COALESCE(ta.overrides_json, '{}'::jsonb),
			ul.added_at,
			COALESCE(ps.recent_play_count, 0),
			ps.last_recent_played_at,
			COALESCE(ps.total_play_count, 0),
			COALESCE(ps.historical_play_count, 0),
			COALESCE(ps.mid_window_play_count, 0),
			ps.last_prior_played_at
		FROM user_library ul
		JOIN tracks t ON t.id = ul.track_id
		LEFT JOIN track_metadata_overrides tmo
			ON tmo.user_id = ul.user_id AND tmo.track_id = ul.track_id
		LEFT JOIN track_analysis ta ON ta.track_id = t.id
		LEFT JOIN play_stats ps ON ps.track_id = t.id
		WHERE ul.user_id = $1
	`

	rows, err := r.db.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	tracks := make([]DJLineupTrack, 0)
	for rows.Next() {
		var track DJLineupTrack
		var summaryJSON, overridesJSON json.RawMessage
		var lastRecentPlayedAt, lastPriorPlayedAt sql.NullTime
		if err := rows.Scan(
			&track.ID,
			&track.Title,
			&track.Artist,
			&track.Album,
			&track.DurationMs,
			&summaryJSON,
			&overridesJSON,
			&track.AddedAt,
			&track.RecentPlayCount,
			&lastRecentPlayedAt,
			&track.TotalPlayCount,
			&track.HistoricalPlayCount,
			&track.MidWindowPlayCount,
			&lastPriorPlayedAt,
		); err != nil {
			return nil, err
		}
		if lastRecentPlayedAt.Valid {
			track.LastRecentPlayedAt = lastRecentPlayedAt.Time
		}
		if lastPriorPlayedAt.Valid {
			track.LastHistoricalPlayed = lastPriorPlayedAt.Time
		}
		track.BPM, track.Camelot, track.Energy, track.GenreHints = djLineupAnalysisFacts(summaryJSON, overridesJSON)
		tracks = append(tracks, track)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
}

func djLineupAnalysisFacts(summaryJSON, overridesJSON json.RawMessage) (float64, string, float64, []string) {
	effectiveJSON, _ := projectCompactAnalysis(summaryJSON, overridesJSON)
	return djLineupNumber(effectiveJSON, "bpm"),
		djLineupString(effectiveJSON, "camelot"),
		djLineupNumber(effectiveJSON, "energy"),
		djLineupHintValues(summaryJSON, "genre_hints")
}

func djLineupNumber(document json.RawMessage, key string) float64 {
	var fields map[string]json.RawMessage
	if json.Unmarshal(document, &fields) != nil {
		return 0
	}
	raw, ok := fields[key]
	if !ok {
		return 0
	}
	var direct float64
	if json.Unmarshal(raw, &direct) == nil {
		return direct
	}
	var fact struct {
		Value *float64 `json:"value"`
	}
	if json.Unmarshal(raw, &fact) == nil && fact.Value != nil {
		return *fact.Value
	}
	return 0
}

func djLineupString(document json.RawMessage, key string) string {
	var fields map[string]json.RawMessage
	if json.Unmarshal(document, &fields) != nil {
		return ""
	}
	raw, ok := fields[key]
	if !ok {
		return ""
	}
	var direct string
	if json.Unmarshal(raw, &direct) == nil {
		return strings.TrimSpace(direct)
	}
	var fact struct {
		Value *string `json:"value"`
	}
	if json.Unmarshal(raw, &fact) == nil && fact.Value != nil {
		return strings.TrimSpace(*fact.Value)
	}
	return ""
}

func djLineupHintValues(document json.RawMessage, key string) []string {
	var fields map[string]json.RawMessage
	if json.Unmarshal(document, &fields) != nil {
		return nil
	}
	raw, ok := fields[key]
	if !ok {
		return nil
	}
	var values []json.RawMessage
	if json.Unmarshal(raw, &values) != nil {
		return nil
	}

	seen := make(map[string]struct{}, len(values))
	hints := make([]string, 0, len(values))
	for _, rawValue := range values {
		var value string
		if json.Unmarshal(rawValue, &value) != nil {
			var hint struct {
				Value string `json:"value"`
			}
			if json.Unmarshal(rawValue, &hint) != nil {
				continue
			}
			value = hint.Value
		}
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		normalized := strings.ToLower(value)
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		hints = append(hints, value)
	}
	return hints
}
