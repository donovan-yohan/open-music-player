package discovery

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

const radarDailyInterval = 24 * time.Hour
const radarPublicationLease = 20 * time.Second // exceeds unchanged 15-second request budget
const radarCacheBytes = 262144

// The MusicBrainz source is fixed by musicbrainz.Client. Version this identity
// when the source or candidate interpretation changes, never with a device ID.
const radarDailyNamespace = "recording-radar-v1:musicbrainz-ws2:daily-v1"

var errRadarDailyUnavailable = errors.New("daily radar unavailable")

type radarDailyStore struct {
	database  *db.DB
	namespace string
	// Private fixture clock. Production uses PostgreSQL clock_timestamp() inside
	// the atomic claim/publication, never an instance/device/request timestamp.
	now func() time.Time
}
type radarDailyState struct {
	admitted bool
	active   bool
	phase    string
	data     string
	token    uuid.UUID
}

// NewDailyRadarService is the normal serving constructor. Keep admission AND
// last-good candidates in the existing durable database: the configured Redis
// cache is allkeys-lru and may evict even non-expiring attempt keys. Neither a
// cache miss nor a server restart may re-admit provider work inside 24 hours.
// Public MusicBrainz metadata caching/search/matcher traffic remains unchanged.
func NewDailyRadarService(seeds RadarSeedReader, membership RadarMembershipReader, catalog RadarCatalog, database *db.DB) *RadarService {
	s := NewRadarService(seeds, membership, catalog)
	s.daily = &radarDailyStore{database: database, namespace: radarDailyNamespace}
	return s
}

// The conditional upsert commits the attempt before provider I/O. Concurrent
// cold accounts serialize only this short row operation, not provider work.
// Failed/canceled/abandoned attempts are never deleted or automatically retried.
const radarBeginSQL = `
WITH stamp AS MATERIALIZED (SELECT COALESCE($4::timestamptz,clock_timestamp()) AS now)
INSERT INTO release_radar_daily(user_id,source,attempted_at,token,phase)
SELECT $1,$2,stamp.now,$3,'pending' FROM stamp
ON CONFLICT(user_id,source) DO UPDATE
SET attempted_at=EXCLUDED.attempted_at,token=EXCLUDED.token,phase='pending'
WHERE release_radar_daily.attempted_at <= EXCLUDED.attempted_at - INTERVAL '24 hours'
RETURNING phase,COALESCE(candidates,'')`

const radarFinishSQL = `
WITH stamp AS MATERIALIZED (SELECT COALESCE($6::timestamptz,clock_timestamp()) AS now)
UPDATE release_radar_daily SET phase=$4,
 candidates=CASE WHEN $4='ready' THEN $5 ELSE candidates END
FROM stamp
WHERE user_id=$1 AND source=$2 AND token=$3 AND phase='pending'
 AND attempted_at <= stamp.now AND attempted_at+INTERVAL '20 seconds' > stamp.now`

// Observe the same shared-clock lease used by publication. A retained snapshot
// alone is not evidence that a pending publisher can still complete.
const radarReadSQL = `
WITH stamp AS MATERIALIZED (SELECT COALESCE($3::timestamptz,clock_timestamp()) AS now)
SELECT phase,COALESCE(candidates,''),
 attempted_at <= stamp.now AND attempted_at+INTERVAL '20 seconds' > stamp.now
FROM release_radar_daily,stamp WHERE user_id=$1 AND source=$2`

func (s *radarDailyStore) clock() any {
	if s.now != nil {
		return s.now().UTC()
	}
	return nil
}
func (s *radarDailyStore) begin(ctx context.Context, user uuid.UUID) (radarDailyState, error) {
	if s == nil || s.database == nil || s.database.DB == nil || user == uuid.Nil || ctx.Err() != nil {
		return radarDailyState{}, errRadarDailyUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	state := radarDailyState{token: uuid.New()}
	err := s.database.QueryRowContext(ctx, radarBeginSQL, user, s.namespace, state.token, s.clock()).Scan(&state.phase, &state.data)
	if err == nil {
		state.admitted = true
	} else if errors.Is(err, sql.ErrNoRows) {
		// If a simultaneous deletion/rollback removed the row, refuse rather than
		// treating it as a new eligible account. No fallback provider computation.
		err = s.database.QueryRowContext(ctx, radarReadSQL, user, s.namespace, s.clock()).Scan(&state.phase, &state.data, &state.active)
	}
	if err != nil || len(state.data) > radarCacheBytes || (state.phase != "pending" && state.phase != "ready" && state.phase != "failed") {
		return radarDailyState{}, errRadarDailyUnavailable
	}
	return state, nil
}
func (s *radarDailyStore) finish(ctx context.Context, user uuid.UUID, token uuid.UUID, phase, data string) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if len(data) > radarCacheBytes {
		return errRadarDailyUnavailable
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	result, err := s.database.ExecContext(ctx, radarFinishSQL, user, s.namespace, token, phase, data, s.clock())
	if err != nil {
		return errRadarDailyUnavailable
	}
	n, err := result.RowsAffected()
	if err != nil || n != 1 {
		return errRadarDailyUnavailable
	}
	return nil
}

func (s *RadarService) readDaily(ctx context.Context, user uuid.UUID, now time.Time) (RadarPage, error) {
	state, err := s.daily.begin(ctx, user)
	if err != nil {
		return RadarPage{}, err
	}
	if state.admitted {
		finished := false
		defer func() {
			if !finished {
				// Synchronous, bounded failure-only bookkeeping, never provider work.
				// The original account/source/token/pending/lease predicates still
				// apply. If the pool or lease is gone, readers refuse expired pending.
				_ = s.daily.finish(context.WithoutCancel(ctx), user, state.token, "failed", "")
			}
		}()
		if ctx.Err() != nil {
			return RadarPage{}, ctx.Err()
		}
		page, err := s.candidates(ctx, user, now)
		// A partial provider failure is a failed attempt, not a successful empty feed.
		failed := err != nil || ctx.Err() != nil || containsRadar(page.Coverage.Reasons, "seeds_unavailable") || page.Coverage.ProviderStatus == "unavailable" || page.Coverage.ProviderStatus == "timeout"
		phase, data := "failed", ""
		if !failed {
			b, e := json.Marshal(page)
			if e != nil || len(b) > radarCacheBytes {
				failed = true
			} else {
				phase, data = "ready", string(b)
			}
		}
		if e := s.daily.finish(ctx, user, state.token, phase, data); e != nil {
			return RadarPage{}, e
		}
		finished = true
		if failed {
			return RadarPage{}, errRadarDailyUnavailable
		}
		return s.filterMembership(ctx, user, page)
	}
	// Bounded existing-state response, not duplicate provider work: concurrent cold
	// readers receive 503; live warm pending readers may see the original good snapshot
	// with original dates and fresh ownership. Failed attempts always reach the
	// existing HTTP/native error owner. Last-good bytes stay intact in the row;
	// an existing native page can remain visible/stale, never as a fresh success.
	if state.phase == "failed" || (state.phase == "pending" && !state.active) || state.data == "" {
		return RadarPage{}, errRadarDailyUnavailable
	}
	var page RadarPage
	if json.Unmarshal([]byte(state.data), &page) != nil || page.PolicyVersion != RadarPolicy || len(page.Items) > 200 || page.GeneratedAt.After(now.UTC()) {
		return RadarPage{}, errRadarDailyUnavailable
	}
	return s.filterMembership(ctx, user, page)
}
