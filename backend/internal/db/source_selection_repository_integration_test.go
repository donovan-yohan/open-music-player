package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func newSourceSelectionTestRepository(t *testing.T) (*DB, *SourceSelectionRepository, context.Context) {
	t.Helper()
	if postgresTestDSN() == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres source selection integration tests")
	}
	database, ctx := newFavoritesTestDB(t)
	if _, err := database.Exec(`DROP TABLE IF EXISTS source_selection_queue_intents; DROP TABLE IF EXISTS source_selection_decisions; DROP TABLE IF EXISTS source_selection_sessions;`); err != nil {
		t.Fatalf("reset source selection schema: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("re-run migration: %v", err)
	}
	if _, err := database.Exec(`TRUNCATE TABLE source_selection_queue_intents, source_selection_decisions, source_selection_sessions, download_jobs, user_library, tracks, users RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate source selection tables: %v", err)
	}
	return database, NewSourceSelectionRepository(database), ctx
}

func seedSourceSelectionUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`, id, email, "source-selection", "x"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return id
}

func sourceSelectionCandidate(t *testing.T, id string, score int) json.RawMessage {
	t.Helper()
	candidate, err := json.Marshal(map[string]any{
		"candidateId": id, "provider": "youtube", "sourceId": strings.TrimPrefix(id, "youtube:"),
		"sourceUrl": "https://example.test/watch/" + id, "title": "Track " + id, "downloadable": true,
		"metadata": map[string]any{"sourceQuality": map[string]any{
			"score": score, "classification": "official_audio", "recommendation": "preferred",
			"confidence": 0.9, "provenance": "test",
		}},
	})
	if err != nil {
		t.Fatalf("marshal candidate: %v", err)
	}
	return candidate
}

func sourceSelectionCandidates(t *testing.T, candidates ...json.RawMessage) json.RawMessage {
	t.Helper()
	snapshot, err := json.Marshal(candidates)
	if err != nil {
		t.Fatalf("marshal candidates: %v", err)
	}
	return snapshot
}

func createSourceSelectionSession(t *testing.T, repo *SourceSelectionRepository, ctx context.Context, userID uuid.UUID, expiry time.Time) *SourceSelectionSession {
	t.Helper()
	session := &SourceSelectionSession{
		UserID: userID, Query: "artist track", Context: "library import",
		Candidates: sourceSelectionCandidates(t,
			sourceSelectionCandidate(t, "youtube:recommended", 94),
			sourceSelectionCandidate(t, "youtube:alternate", 71)),
		RecommendedCandidateID: "youtube:recommended", ExpiresAt: expiry,
	}
	if err := repo.CreateSession(ctx, session); err != nil {
		t.Fatalf("create session: %v", err)
	}
	return session
}

func trustedSourceSelectionCandidate() TrustedSourceSelectionCandidate {
	return TrustedSourceSelectionCandidate{
		CandidateID: "youtube:trusted", Provider: "youtube", SourceID: "trusted",
		SourceURL: "https://example.test/watch/trusted", Title: "Trusted track", Downloadable: true,
		SourceQuality: &TrustedSourceSelectionQuality{
			Score: 90, Classification: "official_audio", Recommendation: "preferred", Confidence: 0.9,
			Reasons: []string{"official audio"}, Provenance: "server_resolver",
		},
	}
}

func TestSourceSelectionMigrateFreshInitAndRerun(t *testing.T) {
	database, _, _ := newSourceSelectionTestRepository(t)
	before := sourceSelectionSchemaFingerprint(t, database)
	if err := database.Migrate(); err != nil {
		t.Fatalf("rerun migration: %v", err)
	}
	after := sourceSelectionSchemaFingerprint(t, database)
	if before != after {
		t.Fatalf("source-selection schema changed on rerun\nbefore:\n%s\nafter:\n%s", before, after)
	}
	if !strings.Contains(after, "idx_source_selection_decisions_one_per_session|CREATE UNIQUE INDEX") ||
		!strings.Contains(after, "download_job_id|uuid") ||
		!strings.Contains(after, "fk_source_selection_decisions_session_owner") {
		t.Fatalf("fresh schema misses required source-selection constraints:\n%s", after)
	}
}

func sourceSelectionSchemaFingerprint(t *testing.T, database *DB) string {
	t.Helper()
	rows, err := database.Query(`
		SELECT 'constraint|' || c.conname || '|' || pg_get_constraintdef(c.oid)
		FROM pg_constraint AS c
		JOIN pg_class AS r ON r.oid = c.conrelid
		WHERE r.relname IN ('source_selection_sessions', 'source_selection_decisions')
		UNION ALL
		SELECT 'index|' || indexname || '|' || indexdef
		FROM pg_indexes
		WHERE tablename IN ('source_selection_sessions', 'source_selection_decisions')
		UNION ALL
		SELECT 'column|' || table_name || '.' || column_name || '|' || udt_name
		FROM information_schema.columns
		WHERE table_schema = 'public' AND table_name IN ('source_selection_sessions', 'source_selection_decisions')
		ORDER BY 1
	`)
	if err != nil {
		t.Fatalf("read source-selection schema: %v", err)
	}
	defer rows.Close()
	var entries []string
	for rows.Next() {
		var entry string
		if err := rows.Scan(&entry); err != nil {
			t.Fatalf("scan source-selection schema: %v", err)
		}
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate source-selection schema: %v", err)
	}
	return strings.Join(entries, "\n")
}

func TestSourceSelectionDiscoveryDecisionSingleUseAndIdempotency(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "single-use@test.local")
	session := createSourceSelectionSession(t, repo, ctx, userID, time.Now().Add(10*time.Minute))

	first, err := repo.CreateDiscoveryDecision(ctx, userID, session.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
	if err != nil {
		t.Fatalf("first decision: %v", err)
	}
	retry, err := repo.CreateDiscoveryDecision(ctx, userID, session.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
	if err != nil || retry.ID != first.ID {
		t.Fatalf("idempotent retry = %#v, %v; want existing %s", retry, err, first.ID)
	}
	if _, err := repo.CreateDiscoveryDecision(ctx, userID, session.ID, "youtube:alternate", SourceSelectionActionOverridden, "prefer shorter intro"); !errors.Is(err, ErrSourceSelectionConflict) || !errors.Is(err, ErrSourceSelectionConsumed) {
		t.Fatalf("conflicting retry = %v; want consumed conflict", err)
	}
	if _, err := repo.CreateDiscoveryDecision(ctx, userID, session.ID, "youtube:unknown", SourceSelectionActionOverridden, ""); !errors.Is(err, ErrInvalidSourceSelection) {
		t.Fatalf("invalid retry = %v; want invalid source selection", err)
	}
	var count int
	if err := database.QueryRow(`SELECT COUNT(*) FROM source_selection_decisions WHERE session_id = $1`, session.ID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("decision count = %d, %v; want 1, nil", count, err)
	}

	concurrentSession := createSourceSelectionSession(t, repo, ctx, userID, time.Now().Add(10*time.Minute))
	start := make(chan struct{})
	results := make(chan *SourceSelectionDecision, 2)
	errs := make(chan error, 2)
	var workers sync.WaitGroup
	for range 2 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			decision, err := repo.CreateDiscoveryDecision(context.Background(), userID, concurrentSession.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
			if err != nil {
				errs <- err
				return
			}
			results <- decision
		}()
	}
	close(start)
	workers.Wait()
	close(results)
	close(errs)
	for err := range errs {
		t.Fatalf("concurrent decision: %v", err)
	}
	var decisions []*SourceSelectionDecision
	for decision := range results {
		decisions = append(decisions, decision)
	}
	if len(decisions) != 2 || decisions[0].ID != decisions[1].ID {
		t.Fatalf("concurrent idempotent decisions = %#v", decisions)
	}
	if err := database.QueryRow(`SELECT COUNT(*) FROM source_selection_decisions WHERE session_id = $1`, concurrentSession.ID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("concurrent decision count = %d, %v; want 1, nil", count, err)
	}
}

func TestSourceSelectionLockWaitPastExpiryIsRejected(t *testing.T) {
	database, repo, _ := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "locked-expiry@test.local")
	session := createSourceSelectionSession(t, repo, context.Background(), userID, time.Now().Add(5*time.Minute))

	tx, err := database.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatalf("begin locking transaction: %v", err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`SELECT id FROM source_selection_sessions WHERE id = $1 FOR UPDATE`, session.ID); err != nil {
		t.Fatalf("lock session: %v", err)
	}
	if _, err := tx.Exec(`UPDATE source_selection_sessions SET expires_at = clock_timestamp() + INTERVAL '150 milliseconds' WHERE id = $1`, session.ID); err != nil {
		t.Fatalf("shorten session expiry: %v", err)
	}
	result := make(chan error, 1)
	go func() {
		_, err := repo.CreateDiscoveryDecision(context.Background(), userID, session.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
		result <- err
	}()
	time.Sleep(250 * time.Millisecond)
	if err := tx.Commit(); err != nil {
		t.Fatalf("release locking transaction: %v", err)
	}
	if err := <-result; !errors.Is(err, ErrSourceSelectionSessionNotFound) {
		t.Fatalf("decision after lock wait past expiry = %v; want expired session", err)
	}
}

func TestSourceSelectionSchemaOwnershipAndPurgeRetention(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	ownerID := seedSourceSelectionUser(t, database, "owner@test.local")
	otherID := seedSourceSelectionUser(t, database, "other@test.local")
	session := createSourceSelectionSession(t, repo, ctx, ownerID, time.Now().Add(10*time.Minute))
	decision, err := repo.CreateDiscoveryDecision(ctx, ownerID, session.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
	if err != nil {
		t.Fatalf("create owned decision: %v", err)
	}
	_, err = database.Exec(`
		INSERT INTO source_selection_decisions
			(id, session_id, session_owner_id, user_id, selected_candidate_id, recommended_candidate_id, action, origin, selected_candidate, source_quality)
		VALUES ($1, $2, $3, $3, 'youtube:recommended', 'youtube:recommended', 'accepted', 'discovery', $4::jsonb, '{}'::jsonb)
	`, uuid.New(), session.ID, otherID, sourceSelectionCandidate(t, "youtube:recommended", 90))
	if err == nil {
		t.Fatal("cross-user session reference satisfied the schema constraint")
	}
	if _, err := database.Exec(`UPDATE source_selection_sessions SET created_at = clock_timestamp() - INTERVAL '2 seconds', expires_at = clock_timestamp() - INTERVAL '1 second' WHERE id = $1`, session.ID); err != nil {
		t.Fatalf("expire session: %v", err)
	}
	purged, err := repo.PurgeExpiredSessions(ctx)
	if err != nil || purged != 1 {
		t.Fatalf("purge expired sessions = %d, %v; want 1, nil", purged, err)
	}
	retained, err := repo.GetDecisionForUser(ctx, ownerID, decision.ID)
	if err != nil || retained.SessionID.Valid || retained.UserID != ownerID {
		t.Fatalf("retained decision after session purge = %#v, %v", retained, err)
	}
	var sessionOwnerID uuid.NullUUID
	if err := database.QueryRow(`SELECT session_owner_id FROM source_selection_decisions WHERE id = $1`, decision.ID).Scan(&sessionOwnerID); err != nil || sessionOwnerID.Valid {
		t.Fatalf("session owner after purge = %#v, %v; want NULL, nil", sessionOwnerID, err)
	}
}

func TestSourceSelectionTrustedCandidateValidation(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "trusted@test.local")
	valid := trustedSourceSelectionCandidate()
	decision, err := repo.CreateTrustedSourceSelectionDecision(ctx, userID, SourceSelectionOriginDirectURL, valid, "resolved server-side")
	if err != nil || decision.Origin != SourceSelectionOriginDirectURL || decision.SessionID.Valid {
		t.Fatalf("trusted direct decision = %#v, %v", decision, err)
	}
	var stored map[string]any
	if err := json.Unmarshal(decision.SelectedCandidate, &stored); err != nil || stored["sourceUrl"] != valid.SourceURL {
		t.Fatalf("trusted snapshot = %#v, %v", stored, err)
	}
	for _, tc := range []struct {
		name   string
		mutate func(*TrustedSourceSelectionCandidate)
	}{
		{name: "http URL", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.SourceURL = "http://example.test/track" }},
		{name: "malformed URL", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.SourceURL = "https://" }},
		{name: "blank provider", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.Provider = " " }},
		{name: "blank source ID", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.SourceID = " " }},
		{name: "not downloadable", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.Downloadable = false }},
		{name: "oversize title", mutate: func(candidate *TrustedSourceSelectionCandidate) {
			candidate.Title = strings.Repeat("a", maxTrustedSourceTitleBytes+1)
		}},
		{name: "invalid quality", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.SourceQuality.Score = 101 }},
		{name: "blank provenance", mutate: func(candidate *TrustedSourceSelectionCandidate) { candidate.SourceQuality.Provenance = "" }},
		{name: "oversize provenance", mutate: func(candidate *TrustedSourceSelectionCandidate) {
			candidate.SourceQuality.Provenance = strings.Repeat("a", maxTrustedSourceProvenance+1)
		}},
		{name: "oversize quality evidence", mutate: func(candidate *TrustedSourceSelectionCandidate) {
			candidate.SourceQuality.Reasons = []string{strings.Repeat("a", maxTrustedSourceQualityText+1)}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			candidate := trustedSourceSelectionCandidate()
			tc.mutate(&candidate)
			if _, err := repo.CreateTrustedSourceSelectionDecision(ctx, userID, SourceSelectionOriginPlaylistExplicit, candidate, ""); !errors.Is(err, ErrInvalidTrustedSourceCandidate) {
				t.Fatalf("trusted candidate error = %v; want invalid trusted candidate", err)
			}
		})
	}
	if _, err := repo.CreateTrustedSourceSelectionDecision(ctx, userID, SourceSelectionOriginDiscovery, valid, ""); !errors.Is(err, ErrInvalidSourceSelection) {
		t.Fatalf("discovery trusted bypass error = %v", err)
	}
}

func TestSourceSelectionAttachmentsAreOwnedOneTimeAndDeleteSafe(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "attachments@test.local")
	otherID := seedSourceSelectionUser(t, database, "attachments-other@test.local")
	decision, err := repo.CreateTrustedSourceSelectionDecision(ctx, userID, SourceSelectionOriginDirectURL, trustedSourceSelectionCandidate(), "")
	if err != nil {
		t.Fatalf("create decision: %v", err)
	}
	ownedJob, overwriteJob, foreignJob := uuid.New(), uuid.New(), uuid.New()
	for id, owner := range map[uuid.UUID]uuid.UUID{ownedJob: userID, overwriteJob: userID, foreignJob: otherID} {
		if _, err := database.Exec(`INSERT INTO download_jobs (id, user_id, url, source_type) VALUES ($1, $2, $3, $4)`, id, owner, "https://example.test/download", "youtube"); err != nil {
			t.Fatalf("seed download job: %v", err)
		}
	}
	if err := repo.AttachDownloadJobForUser(ctx, userID, decision.ID, ownedJob); err != nil {
		t.Fatalf("attach owned download job: %v", err)
	}
	if err := repo.AttachDownloadJobForUser(ctx, userID, decision.ID, ownedJob); err != nil {
		t.Fatalf("same download attachment should be idempotent: %v", err)
	}
	if err := repo.AttachDownloadJobForUser(ctx, userID, decision.ID, overwriteJob); !errors.Is(err, ErrSourceSelectionConflict) {
		t.Fatalf("download overwrite = %v; want conflict", err)
	}
	if err := repo.AttachDownloadJobForUser(ctx, userID, decision.ID, foreignJob); !errors.Is(err, ErrSourceSelectionDecisionNotFound) {
		t.Fatalf("foreign download attachment = %v; want not found", err)
	}
	if _, err := database.Exec(`DELETE FROM download_jobs WHERE id = $1`, ownedJob); err != nil {
		t.Fatalf("delete attached job: %v", err)
	}
	updated, err := repo.GetDecisionForUser(ctx, userID, decision.ID)
	if err != nil || updated.DownloadJobID.Valid {
		t.Fatalf("deleted job attachment = %#v, %v; want NULL, nil", updated.DownloadJobID, err)
	}

	ownedTrack := seedSourceSelectionTrack(t, database, "owned")
	overwriteTrack := seedSourceSelectionTrack(t, database, "overwrite")
	foreignTrack := seedSourceSelectionTrack(t, database, "foreign")
	for _, trackID := range []int64{ownedTrack, overwriteTrack} {
		if _, err := database.Exec(`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, userID, trackID); err != nil {
			t.Fatalf("seed owned track: %v", err)
		}
	}
	if _, err := database.Exec(`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, otherID, foreignTrack); err != nil {
		t.Fatalf("seed foreign track: %v", err)
	}
	if err := repo.AttachTrackForUser(ctx, userID, decision.ID, ownedTrack); err != nil {
		t.Fatalf("attach owned track: %v", err)
	}
	if err := repo.AttachTrackForUser(ctx, userID, decision.ID, ownedTrack); err != nil {
		t.Fatalf("same track attachment should be idempotent: %v", err)
	}
	if err := repo.AttachTrackForUser(ctx, userID, decision.ID, overwriteTrack); !errors.Is(err, ErrSourceSelectionConflict) {
		t.Fatalf("track overwrite = %v; want conflict", err)
	}
	if err := repo.AttachTrackForUser(ctx, userID, decision.ID, foreignTrack); !errors.Is(err, ErrSourceSelectionDecisionNotFound) {
		t.Fatalf("foreign track attachment = %v; want not found", err)
	}
}

func seedSourceSelectionTrack(t *testing.T, database *DB, suffix string) int64 {
	t.Helper()
	var id int64
	if err := database.QueryRow(`INSERT INTO tracks (identity_hash, title) VALUES ($1, $2) RETURNING id`, fmt.Sprintf("source-selection-%s-%s", suffix, uuid.NewString()), "Track "+suffix).Scan(&id); err != nil {
		t.Fatalf("seed track: %v", err)
	}
	return id
}
