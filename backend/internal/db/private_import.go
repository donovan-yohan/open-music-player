package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

var (
	ErrPrivateImportNotFound       = errors.New("private import receipt not found")
	ErrPrivateImportIntentConflict = errors.New("operation already committed with different import intent")
	ErrPrivateImportSourceChanged  = errors.New("canonical source won by a different attempt; verify that source before retry")
	ErrPrivateImportMetadataReview = errors.New("existing Library metadata differs; review the current Library entry")
)

const PrivateImportMaxBytes = 64 << 20
const privateImportMaxDurationMs = 30 * 60 * 1000

var privateImportSHA256 = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// PrivateImportIntent is already-authorized internal input, never an HTTP DTO.
// AttemptID names a previously stored, exclusively owned and immutable object;
// it is not part of the immutable client operation's intent.
type PrivateImportIntent struct {
	OwnerID, OperationID, AttemptID uuid.UUID
	SHA256                          string
	ByteLength                      int64
	DurationMs                      int32
	Title, Artist, Album            string // Effective accepted display text, not raw tags.
}

// PrivateImportSource is an internal canonical-source tuple, not a receipt.
type PrivateImportSource struct {
	TrackID    int64
	Key        string
	SHA256     string
	ByteLength int64
	DurationMs int32
}

type PrivateImportReceipt struct {
	OwnerID, OperationID uuid.UUID
	TrackID              int64
	SHA256               string
	ByteLength           int64
	CommittedAt          time.Time
}

func (in PrivateImportIntent) ObjectKey() string {
	return privateImportKeyPrefix(in.OwnerID) + in.AttemptID.String() + ".mp3"
}

func privateImportKeyPrefix(owner uuid.UUID) string {
	// Keep owner namespaces separate without putting the literal account ID
	// on the analyzer wire. This is naming, not an authorization check.
	namespace := sha256.Sum256([]byte("private-import/owner/v1:" + owner.String()))
	return "private-import/v1/" + hex.EncodeToString(namespace[:]) + "/"
}

func (s PrivateImportSource) validFor(owner uuid.UUID) bool {
	attempt, ok := strings.CutPrefix(s.Key, privateImportKeyPrefix(owner))
	attempt, hasExt := strings.CutSuffix(attempt, ".mp3")
	id, err := uuid.Parse(attempt)
	return owner != uuid.Nil && ok && hasExt && err == nil && id != uuid.Nil && id.String() == attempt &&
		privateImportSHA256.MatchString(s.SHA256) && s.ByteLength > 0 && s.ByteLength <= PrivateImportMaxBytes &&
		s.DurationMs > 0 && s.DurationMs <= privateImportMaxDurationMs
}

func (in PrivateImportIntent) normalize() (PrivateImportIntent, string, error) {
	source := PrivateImportSource{Key: in.ObjectKey(), SHA256: in.SHA256, ByteLength: in.ByteLength, DurationMs: in.DurationMs}
	if !source.validFor(in.OwnerID) {
		return in, "", errors.New("invalid private import source facts")
	}
	return in.normalizeManifest()
}

// The same normalization and fingerprint are used before reading any bytes
// and by the canonical commit. Measured facts never alter operation identity.
func (in PrivateImportIntent) normalizeManifest() (PrivateImportIntent, string, error) {
	in.Title, in.Artist, in.Album = strings.TrimSpace(in.Title), strings.TrimSpace(in.Artist), strings.TrimSpace(in.Album)
	if in.OwnerID == uuid.Nil || in.OperationID == uuid.Nil || in.Title == "" ||
		!privateImportSHA256.MatchString(in.SHA256) || in.ByteLength <= 0 || in.ByteLength > PrivateImportMaxBytes {
		return in, "", errors.New("invalid private import intent")
	}
	for _, v := range []string{in.Title, in.Artist, in.Album} {
		if !utf8.ValidString(v) || strings.ContainsRune(v, 0) || utf8.RuneCountInString(v) > 500 {
			return in, "", errors.New("invalid private import display text")
		}
	}
	// Hash a fixed versioned tuple, excluding attempt, key and measured facts
	// that the upstream intake may obtain again without changing user intent.
	encoded, _ := json.Marshal([]any{"private-import/v1", in.SHA256, in.ByteLength, in.Title, in.Artist, in.Album})
	hash := sha256.Sum256(encoded)
	return in, hex.EncodeToString(hash[:]), nil
}

// ResolvePrivateImportCommit returns a historical receipt, or the exact source
// that the caller must verify before attempting the SQL commit. A replay does
// not require bytes (it is a historical fact, not a readiness assertion).
func (r *TrackRepository) ResolvePrivateImportCommit(ctx context.Context, intent PrivateImportIntent) (*PrivateImportReceipt, PrivateImportSource, error) {
	in, fingerprint, err := intent.normalize()
	if err != nil {
		return nil, PrivateImportSource{}, err
	}
	receipt, err := readPrivateImportReceipt(ctx, r.db, in.OwnerID, in.OperationID, fingerprint)
	if !errors.Is(err, ErrPrivateImportNotFound) {
		return receipt, PrivateImportSource{}, err
	}
	source := PrivateImportSource{Key: in.ObjectKey(), SHA256: in.SHA256, ByteLength: in.ByteLength, DurationMs: in.DurationMs}
	err = r.db.QueryRowContext(ctx, `
		SELECT id, storage_key, COALESCE(duration_ms, 0) FROM tracks
		WHERE private_owner_id = $1 AND source_file_hash = $2 AND file_size_bytes = $3
	`, in.OwnerID, in.SHA256, in.ByteLength).Scan(&source.TrackID, &source.Key, &source.DurationMs)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, PrivateImportSource{}, err
	}
	if !source.validFor(in.OwnerID) {
		return nil, PrivateImportSource{}, errors.New("invalid stored private import source")
	}
	return nil, source, nil
}

// GetPrivateImportReceipt is internal readback; no HTTP route consumes it.
// Unknown and foreign operation IDs are intentionally indistinguishable.
func (r *TrackRepository) GetPrivateImportReceipt(ctx context.Context, owner, operation uuid.UUID) (*PrivateImportReceipt, error) {
	return readPrivateImportReceipt(ctx, r.db, owner, operation, "")
}

func readPrivateImportReceipt(ctx context.Context, q trackQueryRower, owner, operation uuid.UUID, fingerprint string) (*PrivateImportReceipt, error) {
	receipt := PrivateImportReceipt{OwnerID: owner, OperationID: operation}
	var storedFingerprint string
	err := q.QueryRowContext(ctx, `
		SELECT r.track_id, t.source_file_hash, t.file_size_bytes, r.committed_at, r.intent_hash
		FROM private_import_receipts r JOIN tracks t ON t.id = r.track_id
		WHERE r.owner_id = $1 AND r.operation_id = $2
	`, owner, operation).Scan(&receipt.TrackID, &receipt.SHA256, &receipt.ByteLength, &receipt.CommittedAt, &storedFingerprint)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPrivateImportNotFound
	}
	if err != nil {
		return nil, err
	}
	if fingerprint != "" && fingerprint != storedFingerprint {
		return nil, ErrPrivateImportIntentConflict
	}
	return &receipt, nil
}

// CommitVerifiedPrivateImport publishes the track, membership, analysis
// obligation and receipt in one transaction. The caller must have verified
// the exact source returned by ResolvePrivateImportCommit over object storage
// and must own its immutability. This method does not publish or delete bytes.
func (r *TrackRepository) CommitVerifiedPrivateImport(ctx context.Context, intent PrivateImportIntent, verified PrivateImportSource) (*PrivateImportReceipt, error) {
	in, fingerprint, err := intent.normalize()
	if err != nil {
		return nil, err
	}
	if !verified.validFor(in.OwnerID) || verified.SHA256 != in.SHA256 || verified.ByteLength != in.ByteLength ||
		(verified.TrackID == 0 && (verified.Key != in.ObjectKey() || verified.DurationMs != in.DurationMs)) {
		return nil, errors.New("private import verification does not match intent")
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	// Two independent operations can race for exact bytes (partial unique
	// index), but the same account/operation must settle only one manifest.
	if err = lockPrivateImportOperation(ctx, tx, in.OwnerID, in.OperationID); err != nil {
		return nil, err
	}
	old, err := readPrivateImportReceipt(ctx, tx, in.OwnerID, in.OperationID, fingerprint)
	if err == nil {
		if err = tx.Commit(); err != nil {
			return nil, err
		}
		return old, nil
	}
	if !errors.Is(err, ErrPrivateImportNotFound) {
		return nil, err
	}
	stagePhase, err := lockPrivateImportStageForCommit(ctx, tx, in, fingerprint)
	if err != nil {
		return nil, err
	}
	var trackID int64
	if verified.TrackID == 0 {
		identity := sha256.Sum256([]byte(fmt.Sprintf("private-import/v1:%s:%s:%d", in.OwnerID, in.SHA256, in.ByteLength)))
		err = tx.QueryRowContext(ctx, `
			INSERT INTO tracks (private_owner_id, identity_hash, title, artist, album, duration_ms,
				storage_key, source_file_hash, file_size_bytes, source_type, codec, content_type)
			VALUES ($1,$2,$3,NULLIF($4,''),NULLIF($5,''),$6,$7,$8,$9,'library_upload','mp3','audio/mpeg')
			ON CONFLICT (private_owner_id, source_file_hash, file_size_bytes) WHERE private_owner_id IS NOT NULL DO NOTHING
			RETURNING id
		`, in.OwnerID, hex.EncodeToString(identity[:]), in.Title, in.Artist, in.Album, in.DurationMs, verified.Key, in.SHA256, in.ByteLength).Scan(&trackID)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
	}
	if trackID == 0 {
		var key, title, artist, album string
		var duration int32
		err = tx.QueryRowContext(ctx, `
			SELECT t.id, t.storage_key, COALESCE(t.duration_ms, 0), COALESCE(o.title,t.title), COALESCE(o.artist,t.artist,''), COALESCE(o.album,t.album,'')
			FROM tracks t LEFT JOIN track_metadata_overrides o ON o.track_id = t.id AND o.user_id = t.private_owner_id
			WHERE t.private_owner_id = $1 AND t.source_file_hash = $2 AND t.file_size_bytes = $3 FOR KEY SHARE OF t
		`, in.OwnerID, in.SHA256, in.ByteLength).Scan(&trackID, &key, &duration, &title, &artist, &album)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrPrivateImportSourceChanged
		}
		if err != nil {
			return nil, err
		}
		if key != verified.Key || duration != verified.DurationMs || (verified.TrackID != 0 && trackID != verified.TrackID) {
			// Don't commit a receipt for the winning row on the strength of a
			// losing attempt's bytes. Re-resolve and open the winner first.
			return nil, ErrPrivateImportSourceChanged
		}
		if title != in.Title || artist != in.Artist || album != in.Album {
			return nil, ErrPrivateImportMetadataReview
		}
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO user_library(user_id, track_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, in.OwnerID, trackID); err != nil {
		return nil, fmt.Errorf("insert canonical private membership: %w", err)
	}
	// 'stale' is the existing reclaimable/unclaimed state; 'pending' means a
	// worker already owns a lease. Successful replays never reset it.
	if _, err = tx.ExecContext(ctx, `
		INSERT INTO track_analysis (track_id,status,provenance_json)
		VALUES ($1,'stale','{"trigger":"post_library_upload"}') ON CONFLICT (track_id) DO NOTHING
	`, trackID); err != nil {
		return nil, fmt.Errorf("insert canonical private analysis obligation: %w", err)
	}
	receipt := &PrivateImportReceipt{OwnerID: in.OwnerID, OperationID: in.OperationID, TrackID: trackID, SHA256: in.SHA256, ByteLength: in.ByteLength}
	if err = tx.QueryRowContext(ctx, `
		INSERT INTO private_import_receipts (owner_id,operation_id,track_id,intent_hash) VALUES ($1,$2,$3,$4) RETURNING committed_at
	`, receipt.OwnerID, receipt.OperationID, receipt.TrackID, fingerprint).Scan(&receipt.CommittedAt); err != nil {
		return nil, fmt.Errorf("insert canonical private receipt: %w", err)
	}
	if err = sealPrivateImportStage(ctx, tx, in, stagePhase, verified.Key == in.ObjectKey()); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return receipt, nil
}

// Mutable override/readback timestamps do not renew claims. A phase timestamp
// can be absent on an older row; requested_at is the non-null last claim time.
const privateImportClaimTime = `(CASE track_analysis.status
	WHEN 'analyzing' THEN COALESCE(track_analysis.started_at, track_analysis.requested_at)
	WHEN 'failed' THEN COALESCE(track_analysis.completed_at, track_analysis.started_at, track_analysis.requested_at)
	ELSE track_analysis.requested_at
END)`

// $1 and $2 are the live name and version in both queries. Analyzer identities
// are opaque, not ordered. Private admission can fill an empty fence but must
// not replace a conflicting one; that transition belongs to reconciliation.
const privateImportIdentityMatches = `(
	COALESCE(track_analysis.provenance_json->>'expected_analyzer', '') IN ('', $1)
	AND COALESCE(track_analysis.provenance_json->>'expected_analyzer_version', '') IN ('', $2)
)`

// Use the same eligibility predicate for selection and the contested UPDATE.
const privateImportRepairable = `(` + privateImportIdentityMatches + ` AND (
	track_analysis.status = 'stale'
	OR (track_analysis.status = 'failed' AND ` + privateImportClaimTime + ` <= NOW() - INTERVAL '30 seconds')
	OR (track_analysis.status IN ('pending','analyzing') AND ` + privateImportClaimTime + ` <= NOW() - INTERVAL '30 minutes')
))`

func (r *TrackRepository) GetPrivateImportAnalysisCandidates(ctx context.Context, name, version string, limit int) ([]PrivateImportSource, error) {
	if name == "" || version == "" || limit < 1 || limit > 50 {
		return nil, errors.New("invalid private analysis candidate query")
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT t.id, t.private_owner_id, t.storage_key, t.source_file_hash, t.file_size_bytes, COALESCE(t.duration_ms, 0)
		FROM tracks t LEFT JOIN track_analysis ON track_analysis.track_id = t.id
		WHERE t.private_owner_id IS NOT NULL
		  AND EXISTS (SELECT 1 FROM private_import_receipts r WHERE r.track_id = t.id)
		  AND (track_analysis.track_id IS NULL OR `+privateImportRepairable+`)
		ORDER BY COALESCE(`+privateImportClaimTime+`, t.created_at), t.id LIMIT $3
	`, name, version, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var sources []PrivateImportSource
	for rows.Next() {
		var source PrivateImportSource
		var owner uuid.UUID
		if err := rows.Scan(&source.TrackID, &owner, &source.Key, &source.SHA256, &source.ByteLength, &source.DurationMs); err != nil {
			return nil, err
		}
		if !source.validFor(owner) {
			return nil, errors.New("invalid committed private import source")
		}
		sources = append(sources, source)
	}
	return sources, rows.Err()
}

// ClaimPrivateImportAnalysis rechecks the exact immutable source and the
// repair predicate as one SQL operation. The per-claim token fences late
// workers even if the replacement uses the same analyzer identity.
func (r *AnalysisRepository) ClaimPrivateImportAnalysis(ctx context.Context, source PrivateImportSource, claim uuid.UUID, name, version string) (bool, error) {
	if source.TrackID <= 0 || claim == uuid.Nil || name == "" || version == "" {
		return false, errors.New("invalid private import analysis claim")
	}
	result, err := r.db.ExecContext(ctx, `
		INSERT INTO track_analysis (track_id,status,dispatch_token,provenance_json)
		SELECT t.id, 'pending', $8::uuid, jsonb_build_object('trigger','post_library_upload',
			'expected_analyzer',$1::text,'expected_analyzer_version',$2::text)
		FROM tracks t WHERE t.id = $3 AND t.private_owner_id IS NOT NULL
		  AND t.storage_key = $4 AND t.source_file_hash = $5 AND t.file_size_bytes = $6 AND t.duration_ms = $7
		  AND EXISTS (SELECT 1 FROM private_import_receipts r WHERE r.track_id = t.id)
		ON CONFLICT (track_id) DO UPDATE SET status = EXCLUDED.status, dispatch_token = EXCLUDED.dispatch_token,
			provenance_json = track_analysis.provenance_json || EXCLUDED.provenance_json,
			error = NULL, requested_at = NOW(), started_at = NULL, completed_at = NULL, updated_at = NOW()
		WHERE `+privateImportRepairable,
		name, version, source.TrackID, source.Key, source.SHA256, source.ByteLength, source.DurationMs, claim.String())
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	return rows > 0, err
}
