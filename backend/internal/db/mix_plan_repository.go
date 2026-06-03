package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

var ErrMixPlanNotFound = errors.New("mix plan not found")
var ErrMixPlanVersionConflict = errors.New("mix plan version conflict")

type MixPlan struct {
	ID            uuid.UUID
	UserID        uuid.UUID
	SchemaVersion int
	Name          string
	Payload       json.RawMessage
	Summary       json.RawMessage
	Version       int
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

type MixPlanRepository struct {
	db *DB
}

func NewMixPlanRepository(db *DB) *MixPlanRepository {
	return &MixPlanRepository{db: db}
}

func (r *MixPlanRepository) Create(ctx context.Context, plan *MixPlan) error {
	if plan.ID == uuid.Nil {
		plan.ID = uuid.New()
	}

	query := `
		INSERT INTO mix_plans (id, user_id, schema_version, name, payload, summary)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING version, created_at, updated_at
	`

	return r.db.QueryRowContext(ctx, query,
		plan.ID, plan.UserID, plan.SchemaVersion, plan.Name, plan.Payload, plan.Summary,
	).Scan(&plan.Version, &plan.CreatedAt, &plan.UpdatedAt)
}

func (r *MixPlanRepository) GetByIDForUser(ctx context.Context, userID, id uuid.UUID) (*MixPlan, error) {
	query := `
		SELECT id, user_id, schema_version, name, payload, summary, version, created_at, updated_at
		FROM mix_plans
		WHERE id = $1 AND user_id = $2
	`

	plan := &MixPlan{}
	err := r.db.QueryRowContext(ctx, query, id, userID).Scan(
		&plan.ID, &plan.UserID, &plan.SchemaVersion, &plan.Name, &plan.Payload, &plan.Summary,
		&plan.Version, &plan.CreatedAt, &plan.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrMixPlanNotFound
		}
		return nil, err
	}

	return plan, nil
}

func (r *MixPlanRepository) GetByUserID(ctx context.Context, userID uuid.UUID, limit, offset int) ([]MixPlan, int, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}

	query := `
		SELECT id, user_id, schema_version, name, payload, summary, version, created_at, updated_at,
		       COUNT(*) OVER() AS total_count
		FROM mix_plans
		WHERE user_id = $1
		ORDER BY updated_at DESC
		LIMIT $2 OFFSET $3
	`

	rows, err := r.db.QueryContext(ctx, query, userID, limit, offset)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var plans []MixPlan
	var total int
	for rows.Next() {
		var plan MixPlan
		err := rows.Scan(
			&plan.ID, &plan.UserID, &plan.SchemaVersion, &plan.Name, &plan.Payload, &plan.Summary,
			&plan.Version, &plan.CreatedAt, &plan.UpdatedAt, &total,
		)
		if err != nil {
			return nil, 0, err
		}
		plans = append(plans, plan)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	return plans, total, nil
}

func (r *MixPlanRepository) Update(ctx context.Context, plan *MixPlan, expectedVersion int) error {
	query := `
		UPDATE mix_plans
		SET schema_version = $1,
		    name = $2,
		    payload = $3,
		    summary = $4,
		    version = version + 1,
		    updated_at = NOW()
		WHERE id = $5 AND user_id = $6 AND version = $7
		RETURNING version, created_at, updated_at
	`

	err := r.db.QueryRowContext(ctx, query,
		plan.SchemaVersion, plan.Name, plan.Payload, plan.Summary,
		plan.ID, plan.UserID, expectedVersion,
	).Scan(&plan.Version, &plan.CreatedAt, &plan.UpdatedAt)
	if err == nil {
		return nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}

	var currentVersion int
	versionQuery := `SELECT version FROM mix_plans WHERE id = $1 AND user_id = $2`
	versionErr := r.db.QueryRowContext(ctx, versionQuery, plan.ID, plan.UserID).Scan(&currentVersion)
	if errors.Is(versionErr, sql.ErrNoRows) {
		return ErrMixPlanNotFound
	}
	if versionErr != nil {
		return versionErr
	}
	return ErrMixPlanVersionConflict
}

func (r *MixPlanRepository) FindMissingTrackIDs(ctx context.Context, userID uuid.UUID, trackIDs []int64) ([]int64, error) {
	if len(trackIDs) == 0 {
		return nil, nil
	}

	uniqueTrackIDs := dedupeInt64(trackIDs)
	query := `
		SELECT DISTINCT track_id
		FROM user_library
		WHERE user_id = $1 AND track_id = ANY($2)
	`
	rows, err := r.db.QueryContext(ctx, query, userID, pq.Array(uniqueTrackIDs))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	owned := make(map[int64]bool, len(uniqueTrackIDs))
	for rows.Next() {
		var trackID int64
		if err := rows.Scan(&trackID); err != nil {
			return nil, err
		}
		owned[trackID] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	missing := make([]int64, 0)
	for _, trackID := range uniqueTrackIDs {
		if !owned[trackID] {
			missing = append(missing, trackID)
		}
	}
	return missing, nil
}

func dedupeInt64(values []int64) []int64 {
	seen := make(map[int64]bool, len(values))
	unique := make([]int64, 0, len(values))
	for _, value := range values {
		if seen[value] {
			continue
		}
		seen[value] = true
		unique = append(unique, value)
	}
	return unique
}
