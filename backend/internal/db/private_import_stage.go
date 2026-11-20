package db

import (
	"context"
	"database/sql"
	"errors"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
)

var (
	ErrPrivateImportStageCapacity = errors.New("private intake capacity exhausted")
	ErrPrivateImportStagePending  = errors.New("private intake attempt is pending or its write is uncertain")
	ErrPrivateImportStageClosed   = errors.New("private intake attempt is closed")
)

// PrivateImportManifest is the trusted, accepted intent before any bytes are
// read. The intake owns AttemptID and DurationMs; callers cannot supply them.
type PrivateImportManifest struct {
	OwnerID, OperationID uuid.UUID
	SHA256               string
	ByteLength           int64
	Title, Artist, Album string
}

type PrivateImportStage struct {
	Intent        PrivateImportIntent
	NeedsReadback bool
}

// PrivateImportReservation grants only the reserving producer the Put barrier.
// A copied handle shares the same consumed gate; recovery has no grant.
type PrivateImportReservation struct {
	intent    PrivateImportIntent
	authorize func(context.Context, PrivateImportIntent) error
}

func (r *PrivateImportReservation) Intent() PrivateImportIntent { return r.intent }

func (r *PrivateImportReservation) AuthorizePut(ctx context.Context, durationMs int32) (PrivateImportIntent, error) {
	in := r.intent
	in.DurationMs = durationMs
	if r.authorize == nil {
		return in, ErrPrivateImportStageClosed
	}
	return in, r.authorize(ctx, in)
}

type privateStageSQLError struct {
	action string
	cause  error
}

func (e privateStageSQLError) Error() string { return "private intake SQL: " + e.action }
func (e privateStageSQLError) Unwrap() error { return e.cause }

func privateStageSQL(action string, cause error) error {
	if cause == nil {
		return nil
	}
	return privateStageSQLError{action, cause}
}

const privateImportStageBatchLimit = 16

func lockPrivateImportOperation(ctx context.Context, tx *sql.Tx, owner, operation uuid.UUID) error {
	op := "private-import/v1:" + owner.String() + ":" + operation.String()
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, op)
	return privateStageSQL("lock operation", err)
}

// ReservePrivateImportStage grants exactly one attempt before any byte IO.
// Closed operations keep tombstones; neither retry nor expiry reallocates a key.
func (r *TrackRepository) ReservePrivateImportStage(ctx context.Context, m PrivateImportManifest) (*PrivateImportReservation, *PrivateImportReceipt, error) {
	in, fingerprint, err := (PrivateImportIntent{OwnerID: m.OwnerID, OperationID: m.OperationID,
		SHA256: m.SHA256, ByteLength: m.ByteLength, Title: m.Title, Artist: m.Artist, Album: m.Album}).normalizeManifest()
	if err != nil {
		return nil, nil, err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, nil, privateStageSQL("begin reservation", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := lockPrivateImportOperation(ctx, tx, in.OwnerID, in.OperationID); err != nil {
		return nil, nil, err
	}
	receipt, err := readPrivateImportReceipt(ctx, tx, in.OwnerID, in.OperationID, fingerprint)
	if !errors.Is(err, ErrPrivateImportNotFound) {
		return nil, receipt, privateStageSQL("read reservation receipt", err)
	}
	var phase, storedFingerprint string
	err = tx.QueryRowContext(ctx, `SELECT phase,intent_hash FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, in.OwnerID, in.OperationID).Scan(&phase, &storedFingerprint)
	if err == nil {
		if fingerprint != storedFingerprint {
			return nil, nil, ErrPrivateImportIntentConflict
		}
		switch phase {
		case "reserved", "putting", "observed", "stored":
			return nil, nil, ErrPrivateImportStagePending
		default:
			return nil, nil, ErrPrivateImportStageClosed
		}
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, nil, privateStageSQL("read reservation attempt", err)
	}
	// Only reservation can increase this count. Serializing this short SQL
	// section across instances bounds aggregate bytes without serializing Put.
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('private-import/v1:stage-capacity',0))`); err != nil {
		return nil, nil, privateStageSQL("lock capacity", err)
	}
	var active, owned int
	var allowed bool
	if err := tx.QueryRowContext(ctx, `SELECT count(*),count(*) FILTER (WHERE owner_id=$1),EXISTS(SELECT 1 FROM users WHERE id=$1)
		FROM private_import_attempts WHERE phase IN ('reserved','putting','observed','stored','retiring','quarantined')`, in.OwnerID).Scan(&active, &owned, &allowed); err != nil {
		return nil, nil, privateStageSQL("read capacity", err)
	}
	if !allowed {
		return nil, nil, ErrPrivateImportStageClosed
	}
	if active >= 4 || owned >= 1 {
		return nil, nil, ErrPrivateImportStageCapacity
	}
	in.AttemptID, err = uuid.NewRandom()
	if err != nil {
		return nil, nil, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO private_import_attempts
		(owner_id,operation_id,attempt_id,intent_hash,sha256,byte_length,title,artist,album,phase,expires_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'reserved',clock_timestamp() + INTERVAL '10 minutes')`,
		in.OwnerID, in.OperationID, in.AttemptID, fingerprint, in.SHA256, in.ByteLength, in.Title, in.Artist, in.Album); err != nil {
		return nil, nil, privateStageSQL("insert reservation", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, nil, privateStageSQL("commit reservation", err)
	}
	var consumed atomic.Bool
	return &PrivateImportReservation{intent: in, authorize: func(ctx context.Context, in PrivateImportIntent) error {
		if !consumed.CompareAndSwap(false, true) {
			return ErrPrivateImportStageClosed
		}
		return r.authorizePrivateImportPut(ctx, in, fingerprint)
	}}, nil, nil
}

func (r *TrackRepository) RefusePrivateImportStage(ctx context.Context, in PrivateImportIntent) error {
	_, err := r.db.ExecContext(ctx, `UPDATE private_import_attempts SET phase='refused',title='',artist='',album=''
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND phase='reserved'`, in.OwnerID, in.OperationID, in.AttemptID)
	return privateStageSQL("refuse reservation", err)
}

// Only the one-shot reservation reaches this barrier. If SQL's ACK is lost,
// its sole producer still has not dispatched and can burn the exact attempt
// without object IO. Recovery, including observed or quarantined attempts,
// has no such proof and may not downgrade an attempt.
func (r *TrackRepository) authorizePrivateImportPut(ctx context.Context, in PrivateImportIntent, fingerprint string) error {
	in, _, err := in.normalize()
	if err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx, `UPDATE private_import_attempts SET phase='putting',duration_ms=$5
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND intent_hash=$4 AND phase='reserved'
		AND expires_at > clock_timestamp()`, in.OwnerID, in.OperationID, in.AttemptID, fingerprint, in.DurationMs)
	err = requireIntakeTransition("authorize Put", result, err)
	if err == nil {
		return nil
	}
	settle, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer cancel()
	_, refuseErr := r.db.ExecContext(settle, `UPDATE private_import_attempts SET phase='refused',title='',artist='',album=''
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND intent_hash=$4
		AND (phase='reserved' OR (phase='putting' AND duration_ms=$5))`, in.OwnerID, in.OperationID, in.AttemptID, fingerprint, in.DurationMs)
	return errors.Join(err, privateStageSQL("settle undispatched Put", refuseErr))
}

// AcknowledgePrivateImportPut consumes a positive completion, not the mere
// existence of bytes. An expired acknowledgment may only authorize cleanup.
func (r *TrackRepository) AcknowledgePrivateImportPut(ctx context.Context, in PrivateImportIntent) error {
	_, err := r.db.ExecContext(ctx, `UPDATE private_import_attempts
		SET phase=CASE WHEN phase='quarantined' OR expires_at <= statement_timestamp() THEN 'retiring' ELSE 'stored' END,
			title=CASE WHEN expires_at <= statement_timestamp() THEN '' ELSE title END,
			artist=CASE WHEN expires_at <= statement_timestamp() THEN '' ELSE artist END,
			album=CASE WHEN expires_at <= statement_timestamp() THEN '' ELSE album END
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND phase IN ('putting','observed','quarantined')`,
		in.OwnerID, in.OperationID, in.AttemptID)
	return privateStageSQL("acknowledge Put", err)
}

func requireIntakeTransition(action string, result sql.Result, err error) error {
	if err != nil {
		return privateStageSQL(action, err)
	}
	n, err := result.RowsAffected()
	if err == nil && n != 1 {
		return ErrPrivateImportStageClosed
	}
	return privateStageSQL(action, err)
}

// ReadPrivateImportStageReceipt reconciles only this exact historical
// intent. It cannot resolve a dedupe source or admit another object read.
func (r *TrackRepository) ReadPrivateImportStageReceipt(ctx context.Context, in PrivateImportIntent) (*PrivateImportReceipt, error) {
	in, fingerprint, err := in.normalizeManifest()
	if err != nil {
		return nil, err
	}
	receipt, err := readPrivateImportReceipt(ctx, r.db, in.OwnerID, in.OperationID, fingerprint)
	return receipt, privateStageSQL("read exact historical receipt", err)
}

func (r *TrackRepository) LoadPrivateImportStage(ctx context.Context, owner, operation uuid.UUID) (PrivateImportStage, *PrivateImportReceipt, error) {
	var stage PrivateImportStage
	receipt, err := r.GetPrivateImportReceipt(ctx, owner, operation)
	if !errors.Is(err, ErrPrivateImportNotFound) {
		return stage, receipt, privateStageSQL("load stage receipt", err)
	}
	in := &stage.Intent
	in.OwnerID, in.OperationID = owner, operation
	var phase string
	var live bool
	err = r.db.QueryRowContext(ctx, `SELECT attempt_id,sha256,byte_length,COALESCE(duration_ms,0),title,artist,album,phase,expires_at>clock_timestamp()
		FROM private_import_attempts WHERE owner_id=$1 AND operation_id=$2`, owner, operation).Scan(
		&in.AttemptID, &in.SHA256, &in.ByteLength, &in.DurationMs, &in.Title, &in.Artist, &in.Album, &phase, &live)
	if errors.Is(err, sql.ErrNoRows) {
		return stage, nil, ErrPrivateImportNotFound
	}
	if err != nil {
		return stage, nil, privateStageSQL("load stage attempt", err)
	}
	if live {
		switch phase {
		case "reserved":
			return stage, nil, ErrPrivateImportStagePending
		case "putting", "observed":
			stage.NeedsReadback = true
			return stage, nil, nil
		case "stored":
			return stage, nil, nil
		}
	}
	// A concurrent canonical transaction may have sealed the stage between
	// the two reads; prefer the real historical receipt if it appeared.
	receipt, err = r.GetPrivateImportReceipt(ctx, owner, operation)
	if errors.Is(err, ErrPrivateImportNotFound) {
		err = ErrPrivateImportStageClosed
	}
	return stage, receipt, privateStageSQL("load stage receipt", err)
}

// Observed does not mean acknowledged or safe to delete. It permits only
// canonical commit of an independently reverified object within retention.
func (r *TrackRepository) ObservePrivateImportPut(ctx context.Context, in PrivateImportIntent) error {
	result, err := r.db.ExecContext(ctx, `UPDATE private_import_attempts SET phase=CASE WHEN phase='putting' THEN 'observed' ELSE phase END
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND phase IN ('putting','observed','stored')
		AND expires_at > clock_timestamp()`, in.OwnerID, in.OperationID, in.AttemptID)
	return requireIntakeTransition("observe Put", result, err)
}

// This check is part of the existing canonical transaction, not a second
// commit. Locking the exact attempt excludes any collector through receipt
// publication. Unmanaged callers are retained for the predecessor seam.
func lockPrivateImportStageForCommit(ctx context.Context, tx *sql.Tx, in PrivateImportIntent, fingerprint string) (string, error) {
	var phase string
	var matches bool
	err := tx.QueryRowContext(ctx, `SELECT phase,COALESCE(owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND intent_hash=$4 AND duration_ms=$5,FALSE)
		FROM private_import_attempts
		WHERE (owner_id=$1 AND operation_id=$2) OR attempt_id=$3 FOR UPDATE`,
		in.OwnerID, in.OperationID, in.AttemptID, fingerprint, in.DurationMs).Scan(&phase, &matches)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", privateStageSQL("lock attempt for commit", err)
	}
	if !matches || (phase != "stored" && phase != "observed") {
		return "", ErrPrivateImportStageClosed
	}
	// Evaluate the database clock after acquiring the lock, not in the
	// projecting SELECT that may have waited behind another transaction.
	var live bool
	if err := tx.QueryRowContext(ctx, `SELECT expires_at>clock_timestamp() FROM private_import_attempts WHERE attempt_id=$1`, in.AttemptID).Scan(&live); err != nil {
		return "", privateStageSQL("read attempt expiry", err)
	}
	if !live {
		return "", ErrPrivateImportStageClosed
	}
	return phase, nil
}

func sealPrivateImportStage(ctx context.Context, tx *sql.Tx, in PrivateImportIntent, phase string, won bool) error {
	if phase == "" {
		return nil
	}
	final := "quarantined"
	if won {
		final = "winner"
	} else if phase == "stored" {
		final = "retiring"
	}
	// The four canonical writes can block after the original clock check.
	// Recheck at the last write while we still hold the attempt row lock.
	result, err := tx.ExecContext(ctx, `UPDATE private_import_attempts SET phase=$4,title='',artist='',album='',cleanup_after=clock_timestamp()
		WHERE owner_id=$1 AND operation_id=$2 AND attempt_id=$3 AND expires_at>clock_timestamp()`, in.OwnerID, in.OperationID, in.AttemptID, final)
	return requireIntakeTransition("seal attempt", result, err)
}

// ExpirePrivateImportStages durably burns write eligibility before any
// deletion. Only acknowledged Put is deletable. An unacknowledged remote
// write can outlive its local context/process, so quarantine it instead.
func (r *TrackRepository) ExpirePrivateImportStages(ctx context.Context, limit int) error {
	if limit < 1 || limit > privateImportStageBatchLimit {
		return errors.New("invalid private intake batch limit")
	}
	_, err := r.db.ExecContext(ctx, `WITH expired AS (
		SELECT attempt_id FROM private_import_attempts WHERE phase IN ('reserved','putting','observed','stored') AND expires_at<=clock_timestamp()
		ORDER BY expires_at,attempt_id LIMIT $1 FOR UPDATE SKIP LOCKED
	) UPDATE private_import_attempts a SET phase=CASE a.phase WHEN 'reserved' THEN 'refused' WHEN 'stored' THEN 'retiring' ELSE 'quarantined' END,
		title='',artist='',album='',cleanup_after=clock_timestamp() FROM expired e WHERE a.attempt_id=e.attempt_id`, limit)
	return privateStageSQL("expire attempts", err)
}

// CollectPrivateImportStage holds the exact retiring row through its deletion
// readback. A failed deletion remains retryable without reopening the write.
// deleteExact receives a derived key, never a manifest path or bucket listing.
func (r *TrackRepository) CollectPrivateImportStage(ctx context.Context, deleteExact func(context.Context, string) error) (bool, bool, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return false, false, privateStageSQL("begin collection", err)
	}
	defer func() { _ = tx.Rollback() }()
	var in PrivateImportIntent
	err = tx.QueryRowContext(ctx, `SELECT owner_id,attempt_id FROM private_import_attempts
		WHERE phase='retiring' AND cleanup_after<=clock_timestamp() ORDER BY cleanup_after,attempt_id LIMIT 1 FOR UPDATE SKIP LOCKED`).Scan(&in.OwnerID, &in.AttemptID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, false, nil
	}
	if err != nil {
		return false, false, privateStageSQL("select retiring attempt", err)
	}
	var referenced bool
	key := in.ObjectKey()
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM tracks WHERE storage_key=$1)`, key).Scan(&referenced); err != nil {
		return true, false, privateStageSQL("check canonical reference", err)
	}
	var deleteErr error
	if referenced {
		deleteErr = errors.New("retiring private attempt still referenced by a track")
	} else {
		deleteErr = deleteExact(ctx, key)
	}
	if deleteErr != nil {
		_, err = tx.ExecContext(ctx, `UPDATE private_import_attempts SET cleanup_after=clock_timestamp()+INTERVAL '30 seconds' WHERE attempt_id=$1`, in.AttemptID)
		if err == nil {
			err = tx.Commit()
		}
		return true, false, errors.Join(deleteErr, privateStageSQL("record collection backoff", err))
	}
	if _, err := tx.ExecContext(ctx, `UPDATE private_import_attempts SET phase='cleaned' WHERE attempt_id=$1`, in.AttemptID); err != nil {
		return true, false, privateStageSQL("record collection", err)
	}
	if err := tx.Commit(); err != nil {
		return true, false, privateStageSQL("commit collection", err)
	}
	return true, true, nil
}
