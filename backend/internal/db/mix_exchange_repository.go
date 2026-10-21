package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

// MixExchangeSource contains only canonical source identity and the known track
// duration. It never carries object keys, source URLs or playback credentials.
type MixExchangeSource struct {
	TrackID        int64
	SourceFileHash string
	DurationMs     sql.NullInt64
}

var ErrMixExchangeSourceMismatch = errors.New("mix exchange source mismatch")

// MixExchangeSourceExpectation binds each resolved clip to the portable identity
// and authored source window, including clips with no stem edits.
type MixExchangeSourceExpectation struct {
	TrackID        int64
	SourceFileHash string
	SourceEndMs    int64
}

type MixExchangeRepository struct{ db *DB }

// CreateVerified revalidates recipient ownership, unique hash resolution and
// current source duration in the SAME transaction that inserts the plan. It
// grants no library membership or other audio capability.
//
// Lock the recipient user FOR UPDATE first: user_library's foreign key takes a
// conflicting KEY SHARE lock on that user for inserts, including inserts by
// ordinary READ COMMITTED writers. Then lock ALL existing recipient library
// rows and their tracks in track order, not just matching hashes: otherwise an
// unrelated owned track could acquire a required hash after the predicate read.
// READ COMMITTED is intentional: after waiting for a pre-existing membership
// insert at the user lock, the next statement must see its committed row.
// These locks freeze ownership, identity, duration and ambiguity until commit;
// a second unlocked lookup or SERIALIZABLE alone with nonserializable writers
// would not establish that boundary. No lock protocol is required of writers.
func (r *MixExchangeRepository) CreateVerified(ctx context.Context, plan *MixPlan, expected []MixExchangeSourceExpectation) error {
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var userID uuid.UUID
	if err := tx.QueryRowContext(ctx, `SELECT id FROM users WHERE id=$1 FOR UPDATE`, plan.UserID).Scan(&userID); err != nil {
		return fmt.Errorf("lock exchange recipient: %w", err)
	}
	rows, err := tx.QueryContext(ctx, `SELECT t.id, t.source_file_hash, t.duration_ms
 FROM user_library ul JOIN tracks t ON t.id = ul.track_id
 WHERE ul.user_id = $1 ORDER BY t.id FOR SHARE OF ul, t`, plan.UserID)
	if err != nil {
		return err
	}
	defer rows.Close()
	byHash := make(map[string][]MixExchangeSource)
	for rows.Next() {
		var source MixExchangeSource
		if err := rows.Scan(&source.TrackID, &source.SourceFileHash, &source.DurationMs); err != nil {
			return err
		}
		byHash[source.SourceFileHash] = append(byHash[source.SourceFileHash], source)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, want := range expected {
		matches := byHash[want.SourceFileHash]
		if len(matches) != 1 || matches[0].TrackID != want.TrackID || want.TrackID <= 0 || want.SourceFileHash == "" || want.SourceEndMs <= 0 {
			return ErrMixExchangeSourceMismatch
		}
		source := matches[0]
		if source.DurationMs.Valid && source.DurationMs.Int64 > 0 && want.SourceEndMs > source.DurationMs.Int64 {
			return ErrMixExchangeSourceMismatch
		}
	}
	// Publish generated identity/version/timestamps only after a successful commit.
	created := *plan
	if created.ID == uuid.Nil {
		created.ID = uuid.New()
	}
	if err := tx.QueryRowContext(ctx, `INSERT INTO mix_plans (id, user_id, schema_version, name, payload, summary)
 VALUES ($1,$2,$3,$4,$5,$6) RETURNING version, created_at, updated_at`,
		created.ID, created.UserID, created.SchemaVersion, created.Name, created.Payload, created.Summary,
	).Scan(&created.Version, &created.CreatedAt, &created.UpdatedAt); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	*plan = created
	return nil
}

func NewMixExchangeRepository(database *DB) *MixExchangeRepository {
	return &MixExchangeRepository{db: database}
}

func (r *MixExchangeRepository) FindSourcesByTrackIDs(ctx context.Context, userID uuid.UUID, trackIDs []int64) ([]MixExchangeSource, error) {
	if len(trackIDs) == 0 {
		return []MixExchangeSource{}, nil
	}
	return r.findSources(ctx, `SELECT t.id, t.source_file_hash, t.duration_ms
 FROM user_library ul JOIN tracks t ON t.id = ul.track_id
 WHERE ul.user_id = $1 AND t.id = ANY($2) ORDER BY t.id`, userID, pq.Array(trackIDs))
}

// Return every recipient-owned match, not an arbitrary first row: the caller
// must reject ambiguity. There is deliberately no global hash lookup fallback.
func (r *MixExchangeRepository) FindSourcesByHashes(ctx context.Context, userID uuid.UUID, hashes []string) ([]MixExchangeSource, error) {
	if len(hashes) == 0 {
		return []MixExchangeSource{}, nil
	}
	return r.findSources(ctx, `SELECT t.id, t.source_file_hash, t.duration_ms
 FROM user_library ul JOIN tracks t ON t.id = ul.track_id
 WHERE ul.user_id = $1 AND t.source_file_hash = ANY($2) ORDER BY t.id`, userID, pq.Array(hashes))
}

func (r *MixExchangeRepository) findSources(ctx context.Context, query string, userID uuid.UUID, values any) ([]MixExchangeSource, error) {
	rows, err := r.db.QueryContext(ctx, query, userID, values)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	sources := make([]MixExchangeSource, 0)
	for rows.Next() {
		var source MixExchangeSource
		if err := rows.Scan(&source.TrackID, &source.SourceFileHash, &source.DurationMs); err != nil {
			return nil, err
		}
		sources = append(sources, source)
	}
	return sources, rows.Err()
}
