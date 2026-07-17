package research

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

var ErrIdempotencyConflict = errors.New("research idempotency key conflicts with a different request")

// PostgresRepositoryConfig deliberately keeps all process policy at the
// composition boundary. The repository itself never relies on a local queue or
// semaphore, so these limits remain correct when several API/worker processes
// use the same database.
type PostgresRepositoryConfig struct {
	Clock                    func() time.Time
	DailyUnitsPerAttempt     int64
	DailyLimit               int64
	MaxConcurrentRunsPerUser int
}

type PostgresRepository struct {
	db                       *db.DB
	now                      func() time.Time
	dailyUnitsPerAttempt     int64
	dailyLimit               int64
	maxConcurrentRunsPerUser int
}

// NewPostgresRepository accepts an optional config so existing composition can
// use safe defaults while production wiring can inject deterministic policy.
func NewPostgresRepository(database *db.DB, configs ...PostgresRepositoryConfig) *PostgresRepository {
	cfg := PostgresRepositoryConfig{}
	if len(configs) > 0 {
		cfg = configs[0]
	}
	if cfg.Clock == nil {
		cfg.Clock = time.Now
	}
	if cfg.DailyUnitsPerAttempt <= 0 {
		cfg.DailyUnitsPerAttempt = 1
	}
	if cfg.DailyLimit <= 0 {
		cfg.DailyLimit = 10
	}
	if cfg.MaxConcurrentRunsPerUser <= 0 {
		cfg.MaxConcurrentRunsPerUser = 1
	}
	return &PostgresRepository{database, cfg.Clock, cfg.DailyUnitsPerAttempt, cfg.DailyLimit, cfg.MaxConcurrentRunsPerUser}
}

type researchRequest struct {
	Query     string          `json:"query"`
	Providers json.RawMessage `json:"providers"`
	Limit     int             `json:"limit"`
}

func parseRequest(raw json.RawMessage) (researchRequest, error) {
	var request researchRequest
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil || strings.TrimSpace(request.Query) == "" || request.Limit < 1 || request.Limit > 25 {
		return researchRequest{}, ErrInvalidRevision
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return researchRequest{}, ErrInvalidRevision
	}
	var providers []string
	if err := json.Unmarshal(request.Providers, &providers); err != nil || len(providers) == 0 || len(providers) > 16 {
		return researchRequest{}, ErrInvalidRevision
	}
	return request, nil
}

func (r *PostgresRepository) Create(ctx context.Context, input CreateInput) (*Snapshot, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("research repository is not configured")
	}
	if err := ValidateCreate(input); err != nil {
		return nil, err
	}
	if input.ID == "" {
		input.ID = uuid.NewString()
	}
	if len(strings.TrimSpace(input.RequestHash)) < 16 || len(input.RequestHash) > 128 {
		return nil, ErrInvalidRevision
	}
	request, err := parseRequest(input.Request)
	if err != nil {
		return nil, err
	}
	baseline, err := ParseRevisionPayload(input.Baseline.Payload)
	if err != nil || baseline.Stage != StageBaseline {
		return nil, ErrInvalidRevision
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := lockBudgetOwner(ctx, tx, input.OwnerID); err != nil {
		return nil, err
	}

	var priorID, priorHash string
	err = tx.QueryRowContext(ctx, `SELECT id, request_hash FROM research_jobs WHERE user_id = $1 AND idempotency_key = $2 FOR UPDATE`, input.OwnerID, input.IdempotencyKey).Scan(&priorID, &priorHash)
	if err == nil {
		if priorHash != input.RequestHash {
			return nil, ErrIdempotencyConflict
		}
		snapshot, err := loadSnapshot(ctx, tx, priorID, input.OwnerID)
		return snapshot, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	now := r.now().UTC()
	emptyBaseline := len(baseline.Candidates) == 0
	budgetReserved := false
	if !emptyBaseline {
		budgetReserved, err = r.reserveBudget(ctx, tx, input.OwnerID, now)
		if err != nil {
			return nil, err
		}
	}
	status := JobQueued
	var code any
	var message any
	var failureClass any
	if emptyBaseline {
		d := PublicDegradation(DegradationNoCandidates)
		status, code, message, failureClass = JobDegraded, string(d.Code), d.Message, string(FailureTerminal)
	} else if !budgetReserved {
		d := PublicDegradation(DegradationBudgetExhausted)
		status, code, message, failureClass = JobDegraded, string(d.Code), d.Message, string(FailureTerminal)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO research_jobs (
			id, user_id, idempotency_key, request_hash, request_snapshot, retry_safe,
		query, providers, result_limit, status, degradation_code, failure_class, failure_code, failure_message,
			max_attempts, next_attempt_at, latest_revision_number, event_sequence, created_at, updated_at, finished_at
		) VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7,$8::jsonb,$9,$10,$11,$12,$13,$14,$15,$16,0,0,$17,$17,$18)`,
		input.ID, input.OwnerID, input.IdempotencyKey, input.RequestHash, input.Request, input.RetrySafe,
		request.Query, request.Providers, request.Limit, status, code, failureClass, code, message, input.MaxAttempts, now, now, nullableTime(status == JobDegraded, now)); err != nil {
		return nil, err
	}
	if err := r.appendEvent(ctx, tx, input.ID, EventCreated, eventPayload{}); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO research_revisions (id, job_id, user_id, kind, revision_number, stage, candidate_snapshot, result_snapshot, provenance_snapshot, created_at)
		VALUES ($1,$2,$3,'baseline',1,'baseline',$4::jsonb,$4::jsonb,'{}'::jsonb,$5)`, input.Baseline.ID, input.ID, input.OwnerID, input.Baseline.Payload, now); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE research_jobs SET latest_revision_number = 1, updated_at = $2 WHERE id = $1`, input.ID, now); err != nil {
		return nil, err
	}
	if err := r.appendEvent(ctx, tx, input.ID, EventRevisionAppended, eventPayload{RevisionID: input.Baseline.ID, Revision: 1}); err != nil {
		return nil, err
	}
	if status == JobDegraded {
		d := PublicDegradation(DegradationCode(code.(string)))
		if err := r.appendEvent(ctx, tx, input.ID, EventDegraded, eventPayload{Degradation: &d}); err != nil {
			return nil, err
		}
	}
	snapshot, err := loadSnapshot(ctx, tx, input.ID, input.OwnerID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return snapshot, nil
}

func nullableTime(ok bool, value time.Time) any {
	if !ok {
		return nil
	}
	return value
}

func (r *PostgresRepository) Get(ctx context.Context, jobID, ownerID string) (*Snapshot, error) {
	return loadSnapshot(ctx, r.db, jobID, ownerID)
}

func (r *PostgresRepository) Events(ctx context.Context, jobID, ownerID string, afterSequence int64, limit int) ([]Event, error) {
	if _, err := r.Get(ctx, jobID, ownerID); err != nil {
		return nil, err
	}
	if afterSequence < 0 {
		afterSequence = 0
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 100 {
		limit = 100
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT sequence, kind, payload, created_at FROM research_events
		WHERE job_id = $1 AND sequence > $2 ORDER BY sequence ASC LIMIT $3`, jobID, afterSequence, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	events := make([]Event, 0)
	for rows.Next() {
		var event Event
		var raw json.RawMessage
		if err := rows.Scan(&event.Sequence, &event.Kind, &raw, &event.CreatedAt); err != nil {
			return nil, err
		}
		event.JobID = jobID
		if err := decodeEventPayload(raw, &event); err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, rows.Err()
}

func (r *PostgresRepository) Cancel(ctx context.Context, jobID, ownerID string) (*Snapshot, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	job, degradation, err := loadJob(ctx, tx, jobID, ownerID, true)
	if err != nil {
		return nil, err
	}
	now := r.now().UTC()
	switch job.Status {
	case JobQueued:
		if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status = 'cancelled', cancel_requested = TRUE, terminal_reason = 'cancelled', finished_at = $2, updated_at = $2 WHERE id = $1`, jobID, now); err == nil {
			err = r.appendEvent(ctx, tx, jobID, EventCancelled, eventPayload{})
		}
	case JobRunning:
		if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status = 'cancel_requested', cancel_requested = TRUE, updated_at = $2 WHERE id = $1`, jobID, now); err == nil {
			err = r.appendEvent(ctx, tx, jobID, EventCancelRequested, eventPayload{})
		}
	case JobCancelRequested, JobCancelled, JobCompleted, JobDegraded:
		_ = degradation
	default:
		return nil, ErrInvalidTransition
	}
	if err != nil {
		return nil, err
	}
	snapshot, err := loadSnapshot(ctx, tx, jobID, ownerID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return snapshot, nil
}

func (r *PostgresRepository) Retry(ctx context.Context, jobID, ownerID string) (*Snapshot, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := lockBudgetOwner(ctx, tx, ownerID); err != nil {
		return nil, err
	}
	job, degradation, err := loadJob(ctx, tx, jobID, ownerID, true)
	if err != nil {
		return nil, err
	}
	if !CanRetry(job, degradation) || degradation.Code == DegradationBudgetExhausted {
		return nil, ErrInvalidTransition
	}
	now := r.now().UTC()
	ok, err := r.reserveBudget(ctx, tx, ownerID, now)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, ErrInvalidTransition
	}
	if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status = 'queued', next_attempt_at = $2, degradation_code = NULL, failure_code = NULL, failure_message = NULL, updated_at = $2 WHERE id = $1`, jobID, now); err != nil {
		return nil, err
	}
	if err = r.appendEvent(ctx, tx, jobID, EventRetried, eventPayload{}); err != nil {
		return nil, err
	}
	snapshot, err := loadSnapshot(ctx, tx, jobID, ownerID)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return snapshot, nil
}

func (r *PostgresRepository) Claim(ctx context.Context, workerID string, leaseExpiresAt time.Time) (*Claim, error) {
	if strings.TrimSpace(workerID) == "" {
		return nil, ErrNoJobAvailable
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	now := r.now().UTC()
	rows, err := tx.QueryContext(ctx, `
		WITH per_user AS (
			SELECT DISTINCT ON (user_id) id
			FROM research_jobs
			WHERE status = 'queued' AND (next_attempt_at IS NULL OR next_attempt_at <= $1)
			ORDER BY user_id, next_attempt_at NULLS FIRST, created_at, id
		), candidates AS (
			SELECT job.id, job.user_id, job.next_attempt_at, job.created_at
			FROM research_jobs job JOIN per_user ON per_user.id = job.id
			ORDER BY job.next_attempt_at NULLS FIRST, job.created_at, job.id
			LIMIT 32
			FOR UPDATE OF job SKIP LOCKED
		)
		SELECT id, user_id FROM candidates`, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type queuedJob struct{ id, owner string }
	queued := make([]queuedJob, 0, 32)
	for rows.Next() {
		var item queuedJob
		if err := rows.Scan(&item.id, &item.owner); err != nil {
			return nil, err
		}
		queued = append(queued, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for _, item := range queued {
		jobID, ownerID := item.id, item.owner
		if err := r.acquireSlot(ctx, tx, ownerID, now); err != nil {
			if errors.Is(err, ErrNoJobAvailable) {
				continue
			}
			return nil, err
		}
		var nextAttempt int
		if err := tx.QueryRowContext(ctx, `UPDATE research_jobs SET status = 'running', attempt_count = attempt_count + 1, started_at = COALESCE(started_at,$2), updated_at = $2 WHERE id = $1 AND status = 'queued' RETURNING attempt_count`, jobID, now).Scan(&nextAttempt); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				continue
			}
			return nil, err
		}
		runID, token := uuid.NewString(), uuid.NewString()
		if _, err := tx.ExecContext(ctx, `INSERT INTO research_runs (id,job_id,user_id,attempt,status,lease_owner,lease_token,lease_until,last_heartbeat_at,started_at,created_at,updated_at) VALUES ($1,$2,$3,$4,'running',$5,$6,$7,$8,$8,$8,$8)`, runID, jobID, ownerID, nextAttempt, workerID, token, leaseExpiresAt.UTC(), now); err != nil {
			return nil, err
		}
		if err := r.appendEvent(ctx, tx, jobID, EventClaimed, eventPayload{RunID: runID}); err != nil {
			return nil, err
		}
		snapshot, err := loadSnapshot(ctx, tx, jobID, ownerID)
		if err != nil {
			return nil, err
		}
		claim := &Claim{Snapshot: *snapshot, Run: Run{ID: runID, JobID: jobID, WorkerID: workerID, LeaseToken: token, Status: RunRunning, Attempt: nextAttempt, LeaseExpiresAt: leaseExpiresAt.UTC(), StartedAt: now}}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return claim, nil
	}
	return nil, ErrNoJobAvailable
}

func (r *PostgresRepository) RenewLease(ctx context.Context, claim Claim, leaseExpiresAt time.Time) (bool, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var cancelRequested bool
	err = tx.QueryRowContext(ctx, `
		UPDATE research_runs run SET lease_until = $5, last_heartbeat_at = $6, updated_at = $6
		FROM research_jobs job
		WHERE run.id = $1 AND run.job_id = $2 AND run.lease_token = $3 AND run.lease_owner = $4
		  AND run.status = 'running' AND job.id = run.job_id AND job.status IN ('running','cancel_requested')
		  AND run.lease_until > $7
		RETURNING job.cancel_requested`, claim.Run.ID, claim.Run.JobID, claim.Run.LeaseToken, claim.Run.WorkerID, leaseExpiresAt.UTC(), r.now().UTC(), r.now().UTC()).Scan(&cancelRequested)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrLeaseLost
	}
	if err != nil {
		return false, err
	}
	if err := r.appendEvent(ctx, tx, claim.Run.JobID, EventLeaseRenewed, eventPayload{RunID: claim.Run.ID}); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return cancelRequested, nil
}

func (r *PostgresRepository) RecoverExpiredLeases(ctx context.Context, now time.Time) (int, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `SELECT id, job_id, user_id FROM research_runs WHERE status = 'running' AND lease_until < $1 ORDER BY lease_until, id FOR UPDATE SKIP LOCKED LIMIT 100`, now.UTC())
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	type expiredRun struct{ id, job, owner string }
	expired := []expiredRun{}
	for rows.Next() {
		var run expiredRun
		if err := rows.Scan(&run.id, &run.job, &run.owner); err != nil {
			return 0, err
		}
		expired = append(expired, run)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	for _, run := range expired {
		job, degradation, err := loadJob(ctx, tx, run.job, run.owner, true)
		if err != nil {
			return 0, err
		}
		if err := r.releaseSlot(ctx, tx, run.id, run.owner, now); err != nil {
			return 0, err
		}
		if job.Status == JobCancelRequested {
			if _, err = tx.ExecContext(ctx, `UPDATE research_runs SET status='cancelled', finished_at=$2, updated_at=$2 WHERE id=$1`, run.id, now); err != nil {
				return 0, err
			}
			if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status='cancelled', terminal_reason='cancelled', finished_at=$2, updated_at=$2 WHERE id=$1 AND status='cancel_requested'`, run.job, now); err != nil {
				return 0, err
			}
			if err = r.appendEvent(ctx, tx, run.job, EventCancelled, eventPayload{RunID: run.id}); err != nil {
				return 0, err
			}
			continue
		}
		_ = degradation
		if job.RetrySafe && job.Attempts < job.MaxAttempts {
			budgetReserved, err := r.reserveBudget(ctx, tx, run.owner, now)
			if err != nil {
				return 0, err
			}
			if !budgetReserved {
				d := PublicDegradation(DegradationBudgetExhausted)
				if _, err = tx.ExecContext(ctx, `UPDATE research_runs SET status='timed_out', failure_class='timeout', failure_code='lease_expired', retryable=FALSE, finished_at=$2, updated_at=$2 WHERE id=$1`, run.id, now); err != nil {
					return 0, err
				}
				if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status='degraded', degradation_code=$2, failure_class='terminal', failure_code=$2, failure_message=$3, finished_at=$4, updated_at=$4 WHERE id=$1 AND status='running'`, run.job, d.Code, d.Message, now); err != nil {
					return 0, err
				}
				if err = r.appendEvent(ctx, tx, run.job, EventLeaseRecovered, eventPayload{RunID: run.id}); err != nil {
					return 0, err
				}
				if err = r.appendEvent(ctx, tx, run.job, EventDegraded, eventPayload{RunID: run.id, Degradation: &d}); err != nil {
					return 0, err
				}
				continue
			}
			if _, err = tx.ExecContext(ctx, `UPDATE research_runs SET status='timed_out', failure_class='timeout', failure_code='lease_expired', retryable=TRUE, finished_at=$2, updated_at=$2 WHERE id=$1`, run.id, now); err != nil {
				return 0, err
			}
			if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status='queued', next_attempt_at=$2, updated_at=$2 WHERE id=$1 AND status='running'`, run.job, now); err != nil {
				return 0, err
			}
			if err = r.appendEvent(ctx, tx, run.job, EventLeaseRecovered, eventPayload{RunID: run.id}); err != nil {
				return 0, err
			}
			if err = r.appendEvent(ctx, tx, run.job, EventRetried, eventPayload{RunID: run.id}); err != nil {
				return 0, err
			}
		} else {
			d := PublicDegradation(DegradationLeaseExpired)
			d.Retryable = false
			if _, err = tx.ExecContext(ctx, `UPDATE research_runs SET status='timed_out', failure_class='timeout', failure_code='lease_expired', retryable=FALSE, finished_at=$2, updated_at=$2 WHERE id=$1`, run.id, now); err != nil {
				return 0, err
			}
			if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status='degraded', degradation_code=$2, failure_class='timeout', failure_code=$2, failure_message=$3, finished_at=$4, updated_at=$4 WHERE id=$1 AND status='running'`, run.job, d.Code, d.Message, now); err != nil {
				return 0, err
			}
			if err = r.appendEvent(ctx, tx, run.job, EventLeaseRecovered, eventPayload{RunID: run.id}); err != nil {
				return 0, err
			}
			if err = r.appendEvent(ctx, tx, run.job, EventDegraded, eventPayload{RunID: run.id, Degradation: &d}); err != nil {
				return 0, err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return len(expired), nil
}

func (r *PostgresRepository) AppendEnhancement(ctx context.Context, claim Claim, input RevisionInput) (*Revision, error) {
	if err := ValidateEnhancement(input); err != nil {
		return nil, err
	}
	stage, candidateIDs, err := parseEnhancement(input.Payload)
	if err != nil {
		return nil, err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	owner, err := r.verifyActiveClaim(ctx, tx, claim, JobRunning, RunRunning)
	if err != nil {
		return nil, err
	}
	var baseline json.RawMessage
	if err := tx.QueryRowContext(ctx, `SELECT result_snapshot FROM research_revisions WHERE job_id=$1 AND user_id=$2 AND revision_number=1`, claim.Run.JobID, owner).Scan(&baseline); err != nil {
		return nil, err
	}
	allowed, err := candidateIDsFromRevision(baseline)
	if err != nil {
		return nil, ErrInvalidRevision
	}
	if len(allowed) == 0 {
		return nil, ErrInvalidRevision
	}
	for _, id := range candidateIDs {
		if !allowed[id] {
			return nil, ErrInvalidRevision
		}
	}
	var number int
	if err := tx.QueryRowContext(ctx, `UPDATE research_jobs SET latest_revision_number=latest_revision_number+1,updated_at=$2 WHERE id=$1 RETURNING latest_revision_number`, claim.Run.JobID, r.now().UTC()).Scan(&number); err != nil {
		return nil, err
	}
	now := r.now().UTC()
	if _, err := tx.ExecContext(ctx, `INSERT INTO research_revisions (id,job_id,user_id,run_id,kind,revision_number,stage,candidate_snapshot,result_snapshot,provenance_snapshot,created_at) VALUES ($1,$2,$3,$4,'enhancement',$5,$6,'{}'::jsonb,$7::jsonb,'{}'::jsonb,$8)`, input.ID, claim.Run.JobID, owner, claim.Run.ID, number, stage, input.Payload, now); err != nil {
		return nil, err
	}
	if err := r.appendEvent(ctx, tx, claim.Run.JobID, EventRevisionAppended, eventPayload{RunID: claim.Run.ID, RevisionID: input.ID, Revision: number}); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &Revision{ID: input.ID, JobID: claim.Run.JobID, Number: number, Kind: RevisionEnhancement, Payload: append(json.RawMessage(nil), input.Payload...), ValidatedAt: now}, nil
}

func (r *PostgresRepository) RecordTerminal(ctx context.Context, claim Claim, telemetry TerminalTelemetry) error {
	if err := ValidateTerminalTelemetry(telemetry); err != nil {
		return err
	}
	raw, err := json.Marshal(telemetry)
	if err != nil || len(raw) > 16*1024 {
		return ErrInvalidRevision
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	owner, _, err := r.verifyCompletableClaim(ctx, tx, claim)
	if err != nil {
		return err
	}
	_ = owner
	var runID string
	err = tx.QueryRowContext(ctx, `UPDATE research_runs SET terminal_telemetry=$2::jsonb,updated_at=$3 WHERE id=$1 AND terminal_telemetry IS NULL RETURNING id`, claim.Run.ID, raw, r.now().UTC()).Scan(&runID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrInvalidTransition
	}
	if err != nil {
		return err
	}
	if err := r.appendEvent(ctx, tx, claim.Run.JobID, EventRunnerTerminal, eventPayload{RunID: runID, Telemetry: &telemetry}); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *PostgresRepository) Degrade(ctx context.Context, claim Claim, degradation Degradation) (*Snapshot, error) {
	if err := ValidateDegradation(degradation); err != nil {
		return nil, err
	}
	return r.completeClaim(ctx, claim, JobDegraded, degradation)
}

func (r *PostgresRepository) RetryClaim(ctx context.Context, claim Claim, retryAt time.Time) (*Snapshot, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	owner, err := r.verifyClaim(ctx, tx, claim, JobDegraded, RunDegraded)
	if err != nil {
		return nil, err
	}
	if err := lockBudgetOwner(ctx, tx, owner); err != nil {
		return nil, err
	}
	job, degradation, err := loadJob(ctx, tx, claim.Run.JobID, owner, true)
	if err != nil {
		return nil, err
	}
	if !CanRetry(job, degradation) {
		return nil, ErrInvalidTransition
	}
	ok, err := r.reserveBudget(ctx, tx, owner, r.now().UTC())
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, ErrInvalidTransition
	}
	if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status='queued',next_attempt_at=$2,degradation_code=NULL,failure_code=NULL,failure_message=NULL,updated_at=$2 WHERE id=$1 AND status='degraded'`, claim.Run.JobID, retryAt.UTC()); err != nil {
		return nil, err
	}
	if err = r.appendEvent(ctx, tx, claim.Run.JobID, EventRetried, eventPayload{RunID: claim.Run.ID}); err != nil {
		return nil, err
	}
	snapshot, err := loadSnapshot(ctx, tx, claim.Run.JobID, owner)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return snapshot, nil
}

func (r *PostgresRepository) Finish(ctx context.Context, claim Claim, status JobStatus) (*Snapshot, error) {
	if status != JobCompleted && status != JobCancelled {
		return nil, ErrInvalidTransition
	}
	return r.completeClaim(ctx, claim, status, Degradation{})
}

func (r *PostgresRepository) completeClaim(ctx context.Context, claim Claim, status JobStatus, degradation Degradation) (*Snapshot, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	owner, canceled, err := r.verifyCompletableClaim(ctx, tx, claim)
	if err != nil {
		return nil, err
	}
	if canceled {
		status = JobCancelled
		degradation = Degradation{}
	}
	job, _, err := loadJob(ctx, tx, claim.Run.JobID, owner, false)
	if err != nil {
		return nil, err
	}
	if status == JobDegraded {
		degradation = effectiveDegradation(job, PublicDegradation(degradation.Code))
	}
	now := r.now().UTC()
	runStatus := RunCompleted
	event := EventCompleted
	if status == JobCancelled {
		runStatus = RunCancelled
		event = EventCancelled
	}
	if status == JobDegraded {
		runStatus = RunDegraded
		if degradation.Code == DegradationTimeout {
			runStatus = RunTimedOut
		}
		event = EventDegraded
	}
	if _, err = tx.ExecContext(ctx, `UPDATE research_runs SET status=$2,retryable=$3,failure_class=$4,failure_code=$5,finished_at=$6,updated_at=$6 WHERE id=$1 AND status='running'`, claim.Run.ID, runStatus, degradation.Retryable, failureClass(degradation), nullableString(degradation.Code), now); err != nil {
		return nil, err
	}
	if err = r.releaseSlot(ctx, tx, claim.Run.ID, owner, now); err != nil {
		return nil, err
	}
	if status == JobDegraded {
		if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status='degraded',degradation_code=$2,failure_class=$3,failure_code=$2,failure_message=$4,finished_at=$5,updated_at=$5 WHERE id=$1 AND status='running'`, claim.Run.JobID, degradation.Code, failureClass(degradation), nullableReviewReason(degradation.Message), now); err != nil {
			return nil, err
		}
	} else {
		if _, err = tx.ExecContext(ctx, `UPDATE research_jobs SET status=$2,terminal_reason=$3,finished_at=$4,updated_at=$4 WHERE id=$1`, claim.Run.JobID, status, strings.ReplaceAll(string(status), "_", "-"), now); err != nil {
			return nil, err
		}
	}
	payload := eventPayload{RunID: claim.Run.ID}
	if status == JobDegraded {
		payload.Degradation = &degradation
	}
	if err = r.appendEvent(ctx, tx, claim.Run.JobID, event, payload); err != nil {
		return nil, err
	}
	snapshot, err := loadSnapshot(ctx, tx, claim.Run.JobID, owner)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return snapshot, nil
}

// Review resolves the current revision only after taking an owned job-row lock.
// It writes the review, its durable source-selection decision, and the reviewed
// event in one transaction. The idempotency advisory lock serializes replays
// before either the review or its linked decision can be duplicated.
func (r *PostgresRepository) Review(ctx context.Context, jobID, ownerID string, input ReviewInput) (*db.SourceSelectionDecision, error) {
	if err := ValidateReview(input); err != nil {
		return nil, err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := lockReviewIdempotency(ctx, tx, ownerID, input.IdempotencyKey); err != nil {
		return nil, err
	}
	job, _, err := loadJob(ctx, tx, jobID, ownerID, true)
	if err != nil {
		return nil, err
	}

	var existing struct {
		ID, JobID, RevisionID, CandidateID, Action, Reason string
	}
	err = tx.QueryRowContext(ctx, `
		SELECT id, job_id, revision_id, candidate_id, action, COALESCE(reason, '')
		FROM research_reviews
		WHERE user_id = $1 AND idempotency_key = $2
		FOR UPDATE`, ownerID, input.IdempotencyKey).Scan(
		&existing.ID, &existing.JobID, &existing.RevisionID, &existing.CandidateID, &existing.Action, &existing.Reason,
	)
	if err == nil {
		if existing.JobID != jobID || existing.CandidateID != input.CandidateID || existing.Action != string(input.Action) || existing.Reason != input.Reason {
			return nil, ErrIdempotencyConflict
		}
		decision, err := r.researchDecisionForReview(ctx, tx, existing.ID)
		if err == nil {
			if err := tx.Commit(); err != nil {
				return nil, err
			}
			return decision, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		// Historical reviews predate source-selection decisions. Their stored
		// immutable revision and review fields are sufficient to bridge safely.
		decision, err = r.createResearchDecision(ctx, tx, ownerID, existing.ID, existing.RevisionID, existing.CandidateID, ReviewAction(existing.Action), existing.Reason)
		if err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return decision, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	var revisionID string
	err = tx.QueryRowContext(ctx, `
		SELECT id
		FROM research_revisions
		WHERE job_id = $1 AND user_id = $2 AND revision_number = $3`, jobID, ownerID, job.LatestRevision).Scan(&revisionID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if _, _, err := r.researchReviewCandidate(ctx, tx, ownerID, revisionID, input.CandidateID, input.Action); err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, `
		INSERT INTO research_reviews
			(id, job_id, revision_id, user_id, candidate_id, action, reason, idempotency_key, created_at)
		VALUES ($1,$2,$3,$4,$5,$6,NULLIF($7, ''),$8,$9)`,
		uuid.NewString(), jobID, revisionID, ownerID, input.CandidateID, input.Action, input.Reason, input.IdempotencyKey, r.now().UTC()); err != nil {
		return nil, err
	}
	var reviewID string
	if err = tx.QueryRowContext(ctx, `SELECT id FROM research_reviews WHERE user_id = $1 AND idempotency_key = $2`, ownerID, input.IdempotencyKey).Scan(&reviewID); err != nil {
		return nil, err
	}
	decision, err := r.createResearchDecision(ctx, tx, ownerID, reviewID, revisionID, input.CandidateID, input.Action, input.Reason)
	if err != nil {
		return nil, err
	}
	if err = r.appendEvent(ctx, tx, jobID, EventReviewed, eventPayload{RevisionID: revisionID, Revision: job.LatestRevision}); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return decision, nil
}

func (r *PostgresRepository) researchDecisionForReview(ctx context.Context, tx *sql.Tx, reviewID string) (*db.SourceSelectionDecision, error) {
	decision := &db.SourceSelectionDecision{}
	err := tx.QueryRowContext(ctx, sourceSelectionDecisionSelect+` WHERE research_review_id = $1`, reviewID).Scan(sourceSelectionDecisionScanTargets(decision)...)
	return decision, err
}

// researchReviewCandidate resolves a review candidate from its immutable
// revision before Review writes any durable review state.
func (r *PostgresRepository) researchReviewCandidate(ctx context.Context, tx *sql.Tx, ownerID, revisionID, candidateID string, action ReviewAction) (RevisionPayload, *CandidateSnapshot, error) {
	var snapshot json.RawMessage
	if err := tx.QueryRowContext(ctx, `SELECT result_snapshot FROM research_revisions WHERE id = $1 AND user_id = $2`, revisionID, ownerID).Scan(&snapshot); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return RevisionPayload{}, nil, ErrNotFound
		}
		return RevisionPayload{}, nil, err
	}
	payload, err := ParseRevisionPayload(snapshot)
	if err != nil || len(payload.Recommendations) == 0 {
		return RevisionPayload{}, nil, ErrInvalidReview
	}
	for i := range payload.Candidates {
		selected := &payload.Candidates[i]
		if selected.CandidateID != candidateID {
			continue
		}
		if !selected.Downloadable ||
			(action == ReviewAccepted && candidateID != payload.Recommendations[0].CandidateID) ||
			(action == ReviewOverridden && candidateID == payload.Recommendations[0].CandidateID) {
			return RevisionPayload{}, nil, ErrInvalidReview
		}
		return payload, selected, nil
	}
	return RevisionPayload{}, nil, ErrInvalidReview
}

// createResearchDecision derives every persisted candidate field from the
// immutable revision payload. It must only be called from Review's transaction.
func (r *PostgresRepository) createResearchDecision(ctx context.Context, tx *sql.Tx, ownerID, reviewID, revisionID, candidateID string, action ReviewAction, reason string) (*db.SourceSelectionDecision, error) {
	payload, selected, err := r.researchReviewCandidate(ctx, tx, ownerID, revisionID, candidateID, action)
	if err != nil {
		return nil, err
	}
	candidateSnapshot, err := json.Marshal(selected)
	if err != nil {
		return nil, err
	}
	quality, err := json.Marshal(selected.SourceQuality)
	if err != nil {
		return nil, err
	}
	decision := &db.SourceSelectionDecision{ID: uuid.New()}
	err = tx.QueryRowContext(ctx, `
		INSERT INTO source_selection_decisions
			(id, research_review_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason, selected_candidate, source_quality)
		VALUES ($1,$2,$3,$4,$5,$6,'research',NULLIF($7, ''),$8::jsonb,$9::jsonb)
		RETURNING id, session_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason,
			selected_candidate, source_quality, download_job_id, track_id, created_at`,
		decision.ID, reviewID, ownerID, candidateID, payload.Recommendations[0].CandidateID, action, reason, candidateSnapshot, quality,
	).Scan(sourceSelectionDecisionScanTargets(decision)...)
	if err != nil {
		return nil, err
	}
	return decision, nil
}

const sourceSelectionDecisionSelect = `
	SELECT id, session_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason,
		selected_candidate, source_quality, download_job_id, track_id, created_at
	FROM source_selection_decisions`

func sourceSelectionDecisionScanTargets(decision *db.SourceSelectionDecision) []any {
	return []any{&decision.ID, &decision.SessionID, &decision.UserID, &decision.SelectedCandidateID,
		&decision.RecommendedCandidateID, &decision.Action, &decision.Origin, &decision.Reason,
		&decision.SelectedCandidate, &decision.SourceQuality, &decision.DownloadJobID, &decision.TrackID, &decision.CreatedAt}
}

func nullableReviewReason(value string) any {
	if value == "" {
		return nil
	}
	return value
}
func nullableString(value DegradationCode) any {
	if value == "" {
		return nil
	}
	return string(value)
}
func failureClass(d Degradation) any {
	switch d.Code {
	case DegradationTransient, DegradationModelUnavailable, DegradationLeaseExpired:
		return string(FailureTransient)
	case DegradationTimeout:
		return string(FailureTimeout)
	case DegradationSafetyRejected:
		return string(FailureSafety)
	case DegradationValidationRejected, DegradationEnhancementRejected:
		return string(FailureValidation)
	default:
		if d.Code == "" {
			return nil
		}
		return string(FailureTerminal)
	}
}

func lockBudgetOwner(ctx context.Context, tx *sql.Tx, ownerID string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, ownerID)
	return err
}

func lockReviewIdempotency(ctx context.Context, tx *sql.Tx, ownerID, idempotencyKey string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))`, ownerID, idempotencyKey)
	return err
}

func (r *PostgresRepository) reserveBudget(ctx context.Context, tx *sql.Tx, ownerID string, now time.Time) (bool, error) {
	day := now.UTC().Format("2006-01-02")
	if _, err := tx.ExecContext(ctx, `INSERT INTO research_user_daily_budgets (user_id,budget_day,reserved_units,created_at,updated_at) VALUES ($1,$2,0,$3,$3) ON CONFLICT (user_id,budget_day) DO NOTHING`, ownerID, day, now); err != nil {
		return false, err
	}
	var units int64
	err := tx.QueryRowContext(ctx, `UPDATE research_user_daily_budgets SET reserved_units=reserved_units+$3,updated_at=$4 WHERE user_id=$1 AND budget_day=$2 AND reserved_units+$3 <= $5 RETURNING reserved_units`, ownerID, day, r.dailyUnitsPerAttempt, now, r.dailyLimit).Scan(&units)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}
func (r *PostgresRepository) acquireSlot(ctx context.Context, tx *sql.Tx, ownerID string, now time.Time) error {
	var n int
	err := tx.QueryRowContext(ctx, `INSERT INTO research_user_runtime_slots (user_id,active_run_count,updated_at) VALUES ($1,1,$2) ON CONFLICT (user_id) DO UPDATE SET active_run_count=research_user_runtime_slots.active_run_count+1,updated_at=EXCLUDED.updated_at WHERE research_user_runtime_slots.active_run_count < $3 RETURNING active_run_count`, ownerID, now, r.maxConcurrentRunsPerUser).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNoJobAvailable
	}
	return err
}
func (r *PostgresRepository) releaseSlot(ctx context.Context, tx *sql.Tx, runID, ownerID string, now time.Time) error {
	var id string
	err := tx.QueryRowContext(ctx, `UPDATE research_runs SET slot_released=TRUE,updated_at=$2 WHERE id=$1 AND slot_released=FALSE RETURNING id`, runID, now).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `UPDATE research_user_runtime_slots SET active_run_count=GREATEST(active_run_count-1,0),updated_at=$2 WHERE user_id=$1`, ownerID, now)
	return err
}

type sqlQueryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func loadSnapshot(ctx context.Context, q sqlQueryer, jobID, ownerID string) (*Snapshot, error) {
	job, degradation, err := loadJob(ctx, q, jobID, ownerID, false)
	if err != nil {
		return nil, err
	}
	rows, err := q.QueryContext(ctx, `SELECT id,revision_number,kind,result_snapshot,created_at FROM research_revisions WHERE job_id=$1 AND user_id=$2 ORDER BY revision_number`, jobID, ownerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	snapshot := &Snapshot{Job: job, LatestDegradation: degradation, Revisions: []Revision{}}
	for rows.Next() {
		var revision Revision
		if err := rows.Scan(&revision.ID, &revision.Number, &revision.Kind, &revision.Payload, &revision.ValidatedAt); err != nil {
			return nil, err
		}
		revision.JobID = jobID
		snapshot.Revisions = append(snapshot.Revisions, revision)
		if revision.Number == job.LatestRevision {
			snapshot.Job.LatestRevisionID = revision.ID
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var terminal json.RawMessage
	err = q.QueryRowContext(ctx, `SELECT terminal_telemetry FROM research_runs WHERE job_id=$1 AND user_id=$2 AND terminal_telemetry IS NOT NULL ORDER BY attempt DESC LIMIT 1`, jobID, ownerID).Scan(&terminal)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if len(terminal) > 0 {
		var telemetry TerminalTelemetry
		if err := json.Unmarshal(terminal, &telemetry); err != nil || ValidateTerminalTelemetry(telemetry) != nil {
			return nil, ErrInvalidRevision
		}
		snapshot.LatestTerminalTelemetry = &telemetry
	}
	return snapshot, nil
}
func loadJob(ctx context.Context, q sqlQueryer, jobID, ownerID string, lock bool) (Job, *Degradation, error) {
	query := `SELECT id,user_id,request_snapshot,request_hash,idempotency_key,status,retry_safe,attempt_count,max_attempts,COALESCE(next_attempt_at,created_at),latest_revision_number,created_at,updated_at,cancel_requested,degradation_code,failure_message FROM research_jobs WHERE id=$1 AND user_id=$2`
	if lock {
		query += " FOR UPDATE"
	}
	var job Job
	var code, message sql.NullString
	var cancel bool
	err := q.QueryRowContext(ctx, query, jobID, ownerID).Scan(&job.ID, &job.OwnerID, &job.Request, &job.RequestHash, &job.IdempotencyKey, &job.Status, &job.RetrySafe, &job.Attempts, &job.MaxAttempts, &job.AvailableAt, &job.LatestRevision, &job.CreatedAt, &job.UpdatedAt, &cancel, &code, &message)
	if errors.Is(err, sql.ErrNoRows) {
		return Job{}, nil, ErrNotFound
	}
	if err != nil {
		return Job{}, nil, err
	}
	_ = cancel
	var d *Degradation
	if code.Valid {
		c := DegradationCode(code.String)
		public := effectiveDegradation(job, PublicDegradation(c))
		d = &public
	}
	_ = message
	return job, d, nil
}

func (r *PostgresRepository) verifyActiveClaim(ctx context.Context, tx *sql.Tx, claim Claim, wantJob JobStatus, wantRun RunStatus) (string, error) {
	return r.verifyClaim(ctx, tx, claim, wantJob, wantRun)
}
func (r *PostgresRepository) verifyClaim(ctx context.Context, tx *sql.Tx, claim Claim, wantJob JobStatus, wantRun RunStatus) (string, error) {
	var owner string
	err := tx.QueryRowContext(ctx, `SELECT job.user_id FROM research_runs run JOIN research_jobs job ON job.id=run.job_id WHERE run.id=$1 AND run.job_id=$2 AND run.lease_owner=$3 AND run.lease_token=$4 AND run.status=$5 AND job.status=$6 AND run.lease_until > $7 FOR UPDATE OF run,job`, claim.Run.ID, claim.Run.JobID, claim.Run.WorkerID, claim.Run.LeaseToken, wantRun, wantJob, r.now().UTC()).Scan(&owner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrLeaseLost
	}
	return owner, err
}

func (r *PostgresRepository) verifyCompletableClaim(ctx context.Context, tx *sql.Tx, claim Claim) (string, bool, error) {
	var owner string
	var canceled bool
	err := tx.QueryRowContext(ctx, `SELECT job.user_id,job.cancel_requested FROM research_runs run JOIN research_jobs job ON job.id=run.job_id WHERE run.id=$1 AND run.job_id=$2 AND run.lease_owner=$3 AND run.lease_token=$4 AND run.status='running' AND job.status IN ('running','cancel_requested') AND run.lease_until > $5 FOR UPDATE OF run,job`, claim.Run.ID, claim.Run.JobID, claim.Run.WorkerID, claim.Run.LeaseToken, r.now().UTC()).Scan(&owner, &canceled)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, ErrLeaseLost
	}
	return owner, canceled, err
}

type eventPayload struct {
	RunID       string             `json:"runId,omitempty"`
	RevisionID  string             `json:"revisionId,omitempty"`
	Revision    int                `json:"revision,omitempty"`
	Degradation *Degradation       `json:"degradation,omitempty"`
	Telemetry   *TerminalTelemetry `json:"telemetry,omitempty"`
}

func (r *PostgresRepository) appendEvent(ctx context.Context, tx *sql.Tx, jobID string, kind EventKind, payload eventPayload) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	var seq int64
	err = tx.QueryRowContext(ctx, `UPDATE research_jobs SET event_sequence=event_sequence+1 WHERE id=$1 RETURNING event_sequence`, jobID).Scan(&seq)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO research_events (job_id,sequence,kind,payload,created_at) VALUES ($1,$2,$3,$4::jsonb,$5)`, jobID, seq, kind, raw, r.now().UTC())
	return err
}
func decodeEventPayload(raw json.RawMessage, event *Event) error {
	var payload eventPayload
	if len(raw) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return err
	}
	event.RunID, event.RevisionID, event.Revision, event.Degradation, event.Telemetry = payload.RunID, payload.RevisionID, payload.Revision, payload.Degradation, payload.Telemetry
	return nil
}

func parseEnhancement(raw json.RawMessage) (string, []string, error) {
	payload, err := ParseRevisionPayload(raw)
	if err != nil {
		return "", nil, ErrInvalidRevision
	}
	if payload.Stage != StageDirectJudge && payload.Stage != StageDeepAgent {
		return "", nil, ErrInvalidRevision
	}
	ids := make([]string, 0, len(payload.Candidates)+len(payload.Recommendations))
	for _, candidate := range payload.Candidates {
		if candidate.CandidateID == "" {
			return "", nil, ErrInvalidRevision
		}
		ids = append(ids, candidate.CandidateID)
	}
	for _, recommendation := range payload.Recommendations {
		if recommendation.CandidateID == "" {
			return "", nil, ErrInvalidRevision
		}
		ids = append(ids, recommendation.CandidateID)
	}
	if len(ids) == 0 {
		return "", nil, ErrInvalidRevision
	}
	return string(payload.Stage), ids, nil
}
func candidateIDsFromRevision(raw json.RawMessage) (map[string]bool, error) {
	payload, err := ParseRevisionPayload(raw)
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(payload.Candidates))
	for _, candidate := range payload.Candidates {
		out[candidate.CandidateID] = true
	}
	return out, nil
}
