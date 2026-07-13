package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	SourceSelectionActionAccepted   = "accepted"
	SourceSelectionActionOverridden = "overridden"

	SourceSelectionOriginDiscovery        = "discovery"
	SourceSelectionOriginDirectURL        = "direct_url"
	SourceSelectionOriginPlaylistExplicit = "playlist_explicit"

	maxSourceSelectionCandidates   = 50
	maxSourceSelectionSnapshotSize = 48 * 1024
	maxSourceSelectionCandidateID  = 256
	maxSourceSelectionQueryBytes   = 4096
	maxSourceSelectionContextBytes = 4096
	maxSourceSelectionReasonBytes  = 2000
	maxSourceSelectionSessionTTL   = time.Hour
	maxTrustedSourceProviderBytes  = 50
	maxTrustedSourceIDBytes        = 256
	maxTrustedSourceURLBytes       = 4096
	maxTrustedSourceTitleBytes     = 500
	maxTrustedSourceQualityEntries = 8
	maxTrustedSourceQualityText    = 200
	maxTrustedSourceProvenance     = 256
)

var (
	ErrSourceSelectionSessionNotFound  = errors.New("source selection session not found or expired")
	ErrSourceSelectionDecisionNotFound = errors.New("source selection decision not found")
	ErrInvalidSourceSelection          = errors.New("invalid source selection")
	ErrSourceSelectionConsumed         = errors.New("source selection session already has a decision")
	ErrSourceSelectionConflict         = errors.New("source selection decision conflicts with existing decision")
	ErrInvalidTrustedSourceCandidate   = errors.New("invalid trusted source selection candidate")
)

// SourceSelectionSession is the server-owned, short-lived candidate snapshot.
// Decisions must resolve a candidate from Candidates rather than accepting a
// caller-provided URL or candidate payload.
type SourceSelectionSession struct {
	ID                     uuid.UUID
	UserID                 uuid.UUID
	Query                  string
	Context                string
	Candidates             json.RawMessage
	RecommendedCandidateID string
	CreatedAt              time.Time
	ExpiresAt              time.Time
}

// SourceSelectionDecision preserves the selected source and quality evidence
// even after its short-lived session has been purged.
type SourceSelectionDecision struct {
	ID                     uuid.UUID
	SessionID              uuid.NullUUID
	UserID                 uuid.UUID
	SelectedCandidateID    string
	RecommendedCandidateID string
	Action                 string
	Origin                 string
	Reason                 sql.NullString
	SelectedCandidate      json.RawMessage
	SourceQuality          json.RawMessage
	DownloadJobID          uuid.NullUUID
	TrackID                sql.NullInt64
	CreatedAt              time.Time
}

// TrustedSourceSelectionCandidate is a server-only input for resolved direct
// URLs and explicit playlist items. It intentionally is not a request DTO.
type TrustedSourceSelectionCandidate struct {
	CandidateID   string
	Provider      string
	SourceID      string
	SourceURL     string
	Title         string
	Downloadable  bool
	SourceQuality *TrustedSourceSelectionQuality
}

// TrustedSourceSelectionQuality is the bounded source-quality evidence kept
// with a server-resolved candidate when one is available.
type TrustedSourceSelectionQuality struct {
	Score          int
	Classification string
	Recommendation string
	Confidence     float64
	Reasons        []string
	Warnings       []string
	Provenance     string
}

type SourceSelectionRepository struct {
	db *DB
}

func NewSourceSelectionRepository(db *DB) *SourceSelectionRepository {
	return &SourceSelectionRepository{db: db}
}

func (r *SourceSelectionRepository) CreateSession(ctx context.Context, session *SourceSelectionSession) error {
	if session == nil {
		return fmt.Errorf("%w: session is required", ErrInvalidSourceSelection)
	}
	if session.ID == uuid.Nil {
		session.ID = uuid.New()
	}
	if err := validateSession(session); err != nil {
		return err
	}

	return r.db.QueryRowContext(ctx, `
		INSERT INTO source_selection_sessions
			(id, user_id, query, context, candidates, recommended_candidate_id, expires_at)
		VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)
		RETURNING created_at
	`, session.ID, session.UserID, session.Query, session.Context, session.Candidates,
		session.RecommendedCandidateID, session.ExpiresAt).Scan(&session.CreatedAt)
}

func (r *SourceSelectionRepository) GetSessionForUser(ctx context.Context, userID, id uuid.UUID) (*SourceSelectionSession, error) {
	session := &SourceSelectionSession{}
	err := r.db.QueryRowContext(ctx, `
		SELECT id, user_id, query, context, candidates, recommended_candidate_id, created_at, expires_at
		FROM source_selection_sessions
		WHERE id = $1 AND user_id = $2 AND expires_at > clock_timestamp()
	`, id, userID).Scan(&session.ID, &session.UserID, &session.Query, &session.Context,
		&session.Candidates, &session.RecommendedCandidateID, &session.CreatedAt, &session.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSourceSelectionSessionNotFound
	}
	if err != nil {
		return nil, err
	}
	return session, nil
}

// CreateDiscoveryDecision atomically locks an owned, unexpired session and
// derives the selected candidate and source-quality evidence from its JSONB
// snapshot. Callers can control only candidate ID, action, and optional reason.
func (r *SourceSelectionRepository) CreateDiscoveryDecision(ctx context.Context, userID, sessionID uuid.UUID, candidateID, action, reason string) (*SourceSelectionDecision, error) {
	reason = strings.TrimSpace(reason)
	if userID == uuid.Nil || sessionID == uuid.Nil || !validCandidateID(candidateID) || !validAction(action) || !validReason(reason) {
		return nil, fmt.Errorf("%w: discovery decision fields", ErrInvalidSourceSelection)
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	var candidates json.RawMessage
	var recommended string
	var expiresAt time.Time
	err = tx.QueryRowContext(ctx, `
		SELECT s.candidates, s.recommended_candidate_id, s.expires_at
		FROM source_selection_sessions AS s
		WHERE s.id = $1
			AND s.user_id = $2
		FOR UPDATE OF s
	`, sessionID, userID).Scan(&candidates, &recommended, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSourceSelectionSessionNotFound
	}
	if err != nil {
		return nil, err
	}
	var now time.Time
	if err := tx.QueryRowContext(ctx, `SELECT clock_timestamp()`).Scan(&now); err != nil {
		return nil, err
	}
	if !expiresAt.After(now) {
		return nil, ErrSourceSelectionSessionNotFound
	}
	byID, _, err := validateCandidatesSnapshot(candidates, recommended)
	if err != nil {
		return nil, err
	}
	candidate, ok := byID[candidateID]
	if !ok {
		return nil, fmt.Errorf("%w: candidate is absent from session", ErrInvalidSourceSelection)
	}
	_, quality, err := validateCandidateSnapshot(candidate)
	if err != nil {
		return nil, err
	}
	if (action == SourceSelectionActionAccepted) != (candidateID == recommended) {
		return nil, fmt.Errorf("%w: action does not match recommendation", ErrInvalidSourceSelection)
	}

	existing := &SourceSelectionDecision{}
	err = tx.QueryRowContext(ctx, decisionSelect+` WHERE session_id = $1`, sessionID).Scan(decisionScanTargets(existing)...)
	if err == nil {
		if existing.UserID == userID && existing.SessionID.Valid && existing.SessionID.UUID == sessionID &&
			existing.SelectedCandidateID == candidateID && existing.Action == action && sameNullableReason(existing.Reason, reason) {
			if err := tx.Commit(); err != nil {
				return nil, err
			}
			return existing, nil
		}
		return nil, fmt.Errorf("%w: %w", ErrSourceSelectionConflict, ErrSourceSelectionConsumed)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}

	decision := &SourceSelectionDecision{ID: uuid.New()}
	err = tx.QueryRowContext(ctx, `
		INSERT INTO source_selection_decisions
			(id, session_id, session_owner_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason, selected_candidate, source_quality)
		VALUES ($1, $2, $3, $3, $4, $5, $6, $7, NULLIF($8, ''), $9::jsonb, $10::jsonb)
		RETURNING id, session_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason,
			selected_candidate, source_quality, download_job_id, track_id, created_at
	`, decision.ID, sessionID, userID, candidateID, recommended, action, SourceSelectionOriginDiscovery,
		reason, candidate, quality).Scan(decisionScanTargets(decision)...)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return decision, nil
}

// CreateTrustedSourceSelectionDecision is intentionally server-only: it is for
// a resolved direct URL or an explicit playlist item, neither of which has a
// discovery-session snapshot. Do not use it for discovery selections.
func (r *SourceSelectionRepository) CreateTrustedSourceSelectionDecision(ctx context.Context, userID uuid.UUID, origin string, candidate TrustedSourceSelectionCandidate, reason string) (*SourceSelectionDecision, error) {
	reason = strings.TrimSpace(reason)
	if userID == uuid.Nil || !validTrustedOrigin(origin) || !validReason(reason) {
		return nil, fmt.Errorf("%w: trusted decision fields", ErrInvalidSourceSelection)
	}
	snapshot, quality, err := marshalTrustedSourceSelectionCandidate(candidate)
	if err != nil {
		return nil, err
	}
	decision := &SourceSelectionDecision{ID: uuid.New()}
	err = r.db.QueryRowContext(ctx, `
		INSERT INTO source_selection_decisions
			(id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason, selected_candidate, source_quality)
		VALUES ($1, $2, $3, $3, $4, $5, NULLIF($6, ''), $7::jsonb, $8::jsonb)
		RETURNING id, session_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason,
			selected_candidate, source_quality, download_job_id, track_id, created_at
	`, decision.ID, userID, candidate.CandidateID, SourceSelectionActionAccepted, origin, reason, snapshot, quality).Scan(decisionScanTargets(decision)...)
	if err != nil {
		return nil, err
	}
	return decision, nil
}

func (r *SourceSelectionRepository) GetDecisionForUser(ctx context.Context, userID, id uuid.UUID) (*SourceSelectionDecision, error) {
	decision := &SourceSelectionDecision{}
	err := r.db.QueryRowContext(ctx, decisionSelect+` WHERE id = $1 AND user_id = $2`, id, userID).Scan(decisionScanTargets(decision)...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSourceSelectionDecisionNotFound
	}
	if err != nil {
		return nil, err
	}
	return decision, nil
}

func (r *SourceSelectionRepository) ListDecisionsForUser(ctx context.Context, userID uuid.UUID, limit, offset int) ([]SourceSelectionDecision, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := r.db.QueryContext(ctx, decisionSelect+` WHERE user_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2 OFFSET $3`, userID, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var decisions []SourceSelectionDecision
	for rows.Next() {
		var decision SourceSelectionDecision
		if err := rows.Scan(decisionScanTargets(&decision)...); err != nil {
			return nil, err
		}
		decisions = append(decisions, decision)
	}
	return decisions, rows.Err()
}

func (r *SourceSelectionRepository) AttachDownloadJobForUser(ctx context.Context, userID, decisionID, downloadJobID uuid.UUID) error {
	if userID == uuid.Nil || decisionID == uuid.Nil || downloadJobID == uuid.Nil {
		return fmt.Errorf("%w: download job attachment", ErrInvalidSourceSelection)
	}
	if err := requireOwnedDownloadJob(ctx, r.db, userID, downloadJobID); err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE source_selection_decisions AS d
		SET download_job_id = $3
		WHERE d.id = $1 AND d.user_id = $2
			AND (d.download_job_id IS NULL OR d.download_job_id = $3)
			AND EXISTS (SELECT 1 FROM download_jobs AS j WHERE j.id = $3 AND j.user_id = $2)
	`, decisionID, userID, downloadJobID)
	if err != nil {
		return err
	}
	return attachmentResult(result, func() (*SourceSelectionDecision, error) {
		return r.GetDecisionForUser(ctx, userID, decisionID)
	}, func(decision *SourceSelectionDecision) bool {
		return decision.DownloadJobID.Valid && decision.DownloadJobID.UUID != downloadJobID
	})
}

// SourceSelectionQueueIntent records the Redis playback item that must exist
// for a decision-backed download. It is durable because Redis publication can
// be interrupted after the SQL job attachment commits.
type SourceSelectionQueueIntent struct {
	DecisionID     uuid.UUID
	DownloadJobID  uuid.UUID
	QueueItemID    string
	InsertPosition string
}

// AttachDownloadJobWithQueueIntent atomically connects the server-owned
// decision to its SQL job and records the stable playback queue identity before
// either Redis queue is published.
func (r *SourceSelectionRepository) AttachDownloadJobWithQueueIntent(ctx context.Context, userID, decisionID, downloadJobID uuid.UUID, queueItemID, insertPosition string) (*SourceSelectionQueueIntent, error) {
	if userID == uuid.Nil || decisionID == uuid.Nil || downloadJobID == uuid.Nil || !validBoundedText(queueItemID, 128, false) || !validBoundedText(insertPosition, 32, false) {
		return nil, fmt.Errorf("%w: queue intent attachment", ErrInvalidSourceSelection)
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	var ownedJob bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM download_jobs WHERE id = $1 AND user_id = $2)`, downloadJobID, userID).Scan(&ownedJob); err != nil {
		return nil, err
	}
	if !ownedJob {
		return nil, ErrSourceSelectionDecisionNotFound
	}

	var attachedJob sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT download_job_id::text FROM source_selection_decisions WHERE id = $1 AND user_id = $2 FOR UPDATE`, decisionID, userID).Scan(&attachedJob); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrSourceSelectionDecisionNotFound
		}
		return nil, err
	}
	if attachedJob.Valid && attachedJob.String != downloadJobID.String() {
		return nil, ErrSourceSelectionConflict
	}
	if !attachedJob.Valid {
		if _, err := tx.ExecContext(ctx, `UPDATE source_selection_decisions SET download_job_id = $3 WHERE id = $1 AND user_id = $2`, decisionID, userID, downloadJobID); err != nil {
			return nil, err
		}
	}

	intent := &SourceSelectionQueueIntent{DecisionID: decisionID, DownloadJobID: downloadJobID, QueueItemID: queueItemID, InsertPosition: insertPosition}
	if _, err := tx.ExecContext(ctx, `INSERT INTO source_selection_queue_intents (decision_id, user_id, download_job_id, queue_item_id, insert_position) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (decision_id) DO NOTHING`, decisionID, userID, downloadJobID, queueItemID, insertPosition); err != nil {
		return nil, err
	}
	var existingJobID uuid.UUID
	if err := tx.QueryRowContext(ctx, `SELECT download_job_id, queue_item_id, insert_position FROM source_selection_queue_intents WHERE decision_id = $1 AND user_id = $2 FOR UPDATE`, decisionID, userID).Scan(&existingJobID, &intent.QueueItemID, &intent.InsertPosition); err != nil {
		return nil, err
	}
	if existingJobID != downloadJobID {
		return nil, ErrSourceSelectionConflict
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return intent, nil
}

func (r *SourceSelectionRepository) AttachTrackForUser(ctx context.Context, userID, decisionID uuid.UUID, trackID int64) error {
	if userID == uuid.Nil || decisionID == uuid.Nil || trackID <= 0 {
		return fmt.Errorf("%w: track attachment", ErrInvalidSourceSelection)
	}
	if err := requireOwnedLibraryTrack(ctx, r.db, userID, trackID); err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE source_selection_decisions AS d
		SET track_id = $3
		WHERE d.id = $1 AND d.user_id = $2
			AND (d.track_id IS NULL OR d.track_id = $3)
			AND EXISTS (SELECT 1 FROM user_library AS l WHERE l.user_id = $2 AND l.track_id = $3)
	`, decisionID, userID, trackID)
	if err != nil {
		return err
	}
	return attachmentResult(result, func() (*SourceSelectionDecision, error) {
		return r.GetDecisionForUser(ctx, userID, decisionID)
	}, func(decision *SourceSelectionDecision) bool {
		return decision.TrackID.Valid && decision.TrackID.Int64 != trackID
	})
}

func (r *SourceSelectionRepository) PurgeExpiredSessions(ctx context.Context) (int64, error) {
	result, err := r.db.ExecContext(ctx, `DELETE FROM source_selection_sessions WHERE expires_at <= NOW()`)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

const decisionSelect = `
	SELECT id, session_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, reason,
		selected_candidate, source_quality, download_job_id, track_id, created_at
	FROM source_selection_decisions`

func decisionScanTargets(decision *SourceSelectionDecision) []any {
	return []any{&decision.ID, &decision.SessionID, &decision.UserID, &decision.SelectedCandidateID,
		&decision.RecommendedCandidateID, &decision.Action, &decision.Origin, &decision.Reason,
		&decision.SelectedCandidate, &decision.SourceQuality, &decision.DownloadJobID, &decision.TrackID, &decision.CreatedAt}
}

func validateSession(session *SourceSelectionSession) error {
	if session.UserID == uuid.Nil || !validBoundedText(session.Query, maxSourceSelectionQueryBytes, false) ||
		!validBoundedText(session.Context, maxSourceSelectionContextBytes, true) || !validCandidateID(session.RecommendedCandidateID) {
		return fmt.Errorf("%w: session fields", ErrInvalidSourceSelection)
	}
	if session.ExpiresAt.Before(time.Now().Add(time.Second)) || session.ExpiresAt.After(time.Now().Add(maxSourceSelectionSessionTTL)) {
		return fmt.Errorf("%w: session expiry", ErrInvalidSourceSelection)
	}
	_, _, err := validateCandidatesSnapshot(session.Candidates, session.RecommendedCandidateID)
	return err
}

func validateCandidatesSnapshot(snapshot json.RawMessage, recommended string) (map[string]json.RawMessage, json.RawMessage, error) {
	if len(snapshot) == 0 || len(snapshot) > maxSourceSelectionSnapshotSize {
		return nil, nil, fmt.Errorf("%w: candidate snapshot size", ErrInvalidSourceSelection)
	}
	var candidates []json.RawMessage
	if err := json.Unmarshal(snapshot, &candidates); err != nil || len(candidates) == 0 || len(candidates) > maxSourceSelectionCandidates {
		return nil, nil, fmt.Errorf("%w: candidate snapshot", ErrInvalidSourceSelection)
	}
	byID := make(map[string]json.RawMessage, len(candidates))
	for _, candidate := range candidates {
		candidateID, _, err := validateCandidateSnapshot(candidate)
		if err != nil {
			return nil, nil, err
		}
		if _, duplicate := byID[candidateID]; duplicate {
			return nil, nil, fmt.Errorf("%w: duplicate candidate id", ErrInvalidSourceSelection)
		}
		byID[candidateID] = candidate
	}
	recommendedCandidate, ok := byID[recommended]
	if !ok {
		return nil, nil, fmt.Errorf("%w: recommended candidate is absent", ErrInvalidSourceSelection)
	}
	return byID, recommendedCandidate, nil
}

func validateCandidateSnapshot(snapshot json.RawMessage) (string, json.RawMessage, error) {
	if len(snapshot) == 0 || len(snapshot) > maxSourceSelectionSnapshotSize {
		return "", nil, fmt.Errorf("%w: candidate snapshot size", ErrInvalidSourceSelection)
	}
	var candidate map[string]json.RawMessage
	if err := json.Unmarshal(snapshot, &candidate); err != nil || candidate == nil {
		return "", nil, fmt.Errorf("%w: candidate snapshot object", ErrInvalidSourceSelection)
	}
	var candidateID string
	if err := json.Unmarshal(candidate["candidateId"], &candidateID); err != nil || !validCandidateID(candidateID) {
		return "", nil, fmt.Errorf("%w: candidate id", ErrInvalidSourceSelection)
	}
	quality := json.RawMessage(`{}`)
	if metadataRaw, ok := candidate["metadata"]; ok {
		var metadata map[string]json.RawMessage
		if json.Unmarshal(metadataRaw, &metadata) == nil {
			if sourceQuality, ok := metadata["sourceQuality"]; ok && json.Valid(sourceQuality) {
				var object map[string]json.RawMessage
				if json.Unmarshal(sourceQuality, &object) == nil && object != nil {
					quality = sourceQuality
				}
			}
		}
	}
	return candidateID, quality, nil
}

func marshalTrustedSourceSelectionCandidate(candidate TrustedSourceSelectionCandidate) (json.RawMessage, json.RawMessage, error) {
	if !validCandidateID(candidate.CandidateID) ||
		!validBoundedText(candidate.Provider, maxTrustedSourceProviderBytes, false) ||
		!validBoundedText(candidate.SourceID, maxTrustedSourceIDBytes, false) ||
		!validBoundedText(candidate.SourceURL, maxTrustedSourceURLBytes, false) ||
		!validBoundedText(candidate.Title, maxTrustedSourceTitleBytes, false) ||
		!candidate.Downloadable {
		return nil, nil, fmt.Errorf("%w: required candidate fields", ErrInvalidTrustedSourceCandidate)
	}
	parsedURL, err := url.ParseRequestURI(candidate.SourceURL)
	if err != nil || parsedURL.Scheme != "https" || parsedURL.Host == "" || parsedURL.User != nil {
		return nil, nil, fmt.Errorf("%w: source URL", ErrInvalidTrustedSourceCandidate)
	}

	quality := json.RawMessage(`{}`)
	metadata := map[string]any{}
	if candidate.SourceQuality != nil {
		if err := validateTrustedSourceSelectionQuality(*candidate.SourceQuality); err != nil {
			return nil, nil, err
		}
		encoded, err := json.Marshal(struct {
			Score          int      `json:"score"`
			Classification string   `json:"classification"`
			Recommendation string   `json:"recommendation"`
			Confidence     float64  `json:"confidence"`
			Reasons        []string `json:"reasons,omitempty"`
			Warnings       []string `json:"warnings,omitempty"`
			Provenance     string   `json:"provenance"`
		}{
			Score: candidate.SourceQuality.Score, Classification: candidate.SourceQuality.Classification,
			Recommendation: candidate.SourceQuality.Recommendation, Confidence: candidate.SourceQuality.Confidence,
			Reasons: candidate.SourceQuality.Reasons, Warnings: candidate.SourceQuality.Warnings,
			Provenance: candidate.SourceQuality.Provenance,
		})
		if err != nil {
			return nil, nil, fmt.Errorf("%w: marshal source quality", ErrInvalidTrustedSourceCandidate)
		}
		quality = encoded
		metadata["sourceQuality"] = json.RawMessage(encoded)
	}
	snapshot, err := json.Marshal(struct {
		CandidateID  string         `json:"candidateId"`
		Provider     string         `json:"provider"`
		SourceID     string         `json:"sourceId"`
		SourceURL    string         `json:"sourceUrl"`
		Title        string         `json:"title"`
		Downloadable bool           `json:"downloadable"`
		Metadata     map[string]any `json:"metadata,omitempty"`
	}{
		CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID,
		SourceURL: candidate.SourceURL, Title: candidate.Title, Downloadable: candidate.Downloadable, Metadata: metadata,
	})
	if err != nil || len(snapshot) > maxSourceSelectionSnapshotSize {
		return nil, nil, fmt.Errorf("%w: candidate snapshot", ErrInvalidTrustedSourceCandidate)
	}
	return snapshot, quality, nil
}

func validateTrustedSourceSelectionQuality(quality TrustedSourceSelectionQuality) error {
	if quality.Score < 0 || quality.Score > 100 || quality.Confidence < 0 || quality.Confidence > 1 ||
		!validBoundedText(quality.Classification, maxTrustedSourceQualityText, false) ||
		!validBoundedText(quality.Recommendation, maxTrustedSourceQualityText, false) ||
		!validBoundedText(quality.Provenance, maxTrustedSourceProvenance, false) ||
		!validTrustedSourceQualityText(quality.Reasons) || !validTrustedSourceQualityText(quality.Warnings) {
		return fmt.Errorf("%w: source quality", ErrInvalidTrustedSourceCandidate)
	}
	return nil
}

func validTrustedSourceQualityText(values []string) bool {
	if len(values) > maxTrustedSourceQualityEntries {
		return false
	}
	for _, value := range values {
		if !validBoundedText(value, maxTrustedSourceQualityText, false) {
			return false
		}
	}
	return true
}

func validAction(action string) bool {
	return action == SourceSelectionActionAccepted || action == SourceSelectionActionOverridden
}

func validTrustedOrigin(origin string) bool {
	return origin == SourceSelectionOriginDirectURL || origin == SourceSelectionOriginPlaylistExplicit
}

func validCandidateID(candidateID string) bool {
	return validBoundedText(candidateID, maxSourceSelectionCandidateID, false)
}

func validReason(reason string) bool {
	return validBoundedText(reason, maxSourceSelectionReasonBytes, true)
}

func validBoundedText(value string, maxBytes int, optional bool) bool {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return optional
	}
	return len(value) <= maxBytes
}

func attachmentResult(result sql.Result, getDecision func() (*SourceSelectionDecision, error), conflicts func(*SourceSelectionDecision) bool) error {
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 1 {
		return nil
	}
	decision, err := getDecision()
	if err != nil {
		return err
	}
	if conflicts(decision) {
		return ErrSourceSelectionConflict
	}
	return ErrSourceSelectionDecisionNotFound
}

func sameNullableReason(existing sql.NullString, requested string) bool {
	if requested == "" {
		return !existing.Valid
	}
	return existing.Valid && existing.String == requested
}

func requireOwnedDownloadJob(ctx context.Context, database *DB, userID, downloadJobID uuid.UUID) error {
	var exists bool
	if err := database.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM download_jobs WHERE id = $1 AND user_id = $2)`, downloadJobID, userID).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrSourceSelectionDecisionNotFound
	}
	return nil
}

func requireOwnedLibraryTrack(ctx context.Context, database *DB, userID uuid.UUID, trackID int64) error {
	var exists bool
	if err := database.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM user_library WHERE user_id = $1 AND track_id = $2)`, userID, trackID).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return ErrSourceSelectionDecisionNotFound
	}
	return nil
}
