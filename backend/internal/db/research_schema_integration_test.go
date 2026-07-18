package db

import (
	"database/sql"
	"fmt"
	"os"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

func TestResearchVariantMigrationDownUpPreservesPersistedAssignments(t *testing.T) {
	database := newResearchSchemaTestDB(t)
	tx, err := database.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()

	readMigration := func(name string) string {
		t.Helper()
		raw, readErr := os.ReadFile("migrations/" + name)
		if readErr != nil {
			t.Fatal(readErr)
		}
		return string(raw)
	}
	userID := uuid.NewString()
	if _, err := tx.Exec(`INSERT INTO users (id,email,username,password_hash) VALUES ($1,$2,$3,'test')`, userID, "variant-"+userID+"@example.test", "variant"+userID[:8]); err != nil {
		t.Fatal(err)
	}
	assignments := []struct{ variant, cohort string }{{"direct_structured_judge", "direct-live"}, {"bounded_agent_dark_launch", "dark-live"}}
	jobIDs := make([]string, len(assignments))
	for index, assignment := range assignments {
		jobIDs[index] = uuid.NewString()
		if _, err := tx.Exec(`INSERT INTO research_jobs (id,user_id,idempotency_key,request_hash,request_snapshot,retry_safe,query,providers,result_limit,max_attempts,assigned_variant,variant_cohort) VALUES ($1,$2,$3,$4,$5::jsonb,TRUE,$6,$7::jsonb,10,3,$8,$9)`, jobIDs[index], userID, "variant-preserve-"+assignment.cohort, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", `{"query":"fixture query","providers":["youtube"],"limit":10}`, "fixture query", `["youtube"]`, assignment.variant, assignment.cohort); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(readMigration("000017_add_research_variant_assignments.down.sql")); err != nil {
		t.Fatalf("migration down: %v", err)
	}
	var variantColumns int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='research_jobs' AND column_name IN ('assigned_variant','variant_cohort')`).Scan(&variantColumns); err != nil || variantColumns != 2 {
		t.Fatalf("migration down columns=%d err=%v", variantColumns, err)
	}
	if _, err := tx.Exec(readMigration("000017_add_research_variant_assignments.up.sql")); err != nil {
		t.Fatalf("migration up: %v", err)
	}
	for index, assignment := range assignments {
		var variant, cohort string
		if err := tx.QueryRow(`SELECT assigned_variant,variant_cohort FROM research_jobs WHERE id=$1`, jobIDs[index]).Scan(&variant, &cohort); err != nil || variant != assignment.variant || cohort != assignment.cohort {
			t.Fatalf("round-trip assignment=%q/%q want=%q/%q err=%v", variant, cohort, assignment.variant, assignment.cohort, err)
		}
	}
	if _, err := tx.Exec(`UPDATE research_jobs SET assigned_variant='invalid' WHERE id=$1`, jobIDs[0]); err == nil {
		t.Fatal("invalid variant accepted")
	}
	if _, err := tx.Exec(`UPDATE research_jobs SET assigned_variant='bounded_agent_dark_launch' WHERE id=$1`, jobIDs[0]); err == nil {
		t.Fatal("variant assignment mutation accepted")
	}
	if _, err := tx.Exec(`UPDATE research_jobs SET variant_cohort='https://secret.invalid' WHERE id=$1`, jobIDs[0]); err == nil {
		t.Fatal("URL cohort accepted")
	}
	if _, err := tx.Exec(`UPDATE research_jobs SET variant_cohort='api-key-test' WHERE id=$1`, jobIDs[0]); err == nil {
		t.Fatal("secret-like cohort accepted")
	}
}

func newResearchSchemaTestDB(t *testing.T) *DB {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres research schema tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("rerun idempotent test database migration: %v", err)
	}
	return database
}

func createResearchSchemaTestUser(t *testing.T, database *DB) string {
	t.Helper()

	id := uuid.New().String()
	email := fmt.Sprintf("research-schema-%s@example.test", id)
	if _, err := database.Exec(`
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, $3, 'test-password-hash')
	`, id, email, "research_schema_test"); err != nil {
		t.Fatalf("create test user: %v", err)
	}
	t.Cleanup(func() {
		if _, err := database.Exec(`DELETE FROM users WHERE id = $1`, id); err != nil {
			t.Errorf("clean up test user: %v", err)
		}
	})
	return id
}

func insertResearchSchemaTestJob(t *testing.T, database *DB, userID, idempotencyKey string) string {
	t.Helper()

	jobID := uuid.New().String()
	if _, err := database.Exec(`
		INSERT INTO research_jobs (
			id, user_id, idempotency_key, request_hash, request_snapshot, retry_safe,
			query, providers, result_limit, max_attempts
		) VALUES ($1, $2, $3, $4, $5::jsonb, TRUE, $6, $7::jsonb, $8, $9)
	`, jobID, userID, idempotencyKey, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", `{"query":"fixture query","providers":["youtube"],"limit":10}`, "fixture query", `["youtube"]`, 10, 3); err != nil {
		t.Fatalf("create research job: %v", err)
	}
	return jobID
}

func insertResearchSchemaTestRun(t *testing.T, database *DB, jobID, userID string) string {
	t.Helper()

	runID := uuid.New().String()
	if _, err := database.Exec(`
		INSERT INTO research_runs (id, job_id, user_id, attempt)
		VALUES ($1, $2, $3, 1)
	`, runID, jobID, userID); err != nil {
		t.Fatalf("create research run: %v", err)
	}
	return runID
}

func insertResearchSchemaTestRevision(t *testing.T, database *DB, jobID, userID string, runID any, kind, stage string, number int) string {
	t.Helper()

	revisionID := uuid.New().String()
	if _, err := database.Exec(`
		INSERT INTO research_revisions (
			id, job_id, user_id, run_id, kind, revision_number, stage,
			candidate_snapshot, result_snapshot, provenance_snapshot
		) VALUES ($1, $2, $3, $4, $5, $6, $7, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb)
	`, revisionID, jobID, userID, runID, kind, number, stage); err != nil {
		t.Fatalf("create research revision: %v", err)
	}
	return revisionID
}

func TestResearchSchemaConstraintsAgainstPostgres(t *testing.T) {
	database := newResearchSchemaTestDB(t)
	userID := createResearchSchemaTestUser(t, database)
	otherUserID := createResearchSchemaTestUser(t, database)

	for _, relation := range []string{
		"research_jobs",
		"research_runs",
		"research_revisions",
		"research_events",
		"research_reviews",
		"research_user_daily_budgets",
		"research_user_runtime_slots",
		"idx_research_jobs_queued_claim",
		"idx_research_runs_expired_lease",
		"idx_research_events_job_sequence",
	} {
		var exists bool
		if err := database.QueryRow(`SELECT to_regclass($1) IS NOT NULL`, relation).Scan(&exists); err != nil {
			t.Fatalf("check relation %q: %v", relation, err)
		}
		if !exists {
			t.Errorf("expected relation %q to exist", relation)
		}
	}

	for _, status := range []string{"queued", "running", "cancel_requested", "completed", "degraded", "cancelled"} { //nolint:misspell // Validate the persisted status contract.
		if _, err := database.Exec(`
			INSERT INTO research_jobs (
				id, user_id, idempotency_key, request_hash, request_snapshot, retry_safe,
				query, providers, result_limit, status
			) VALUES ($1, $2, $3, $4, '{}'::jsonb, TRUE, 'fixture query', '["youtube"]'::jsonb, 10, $5)
		`, uuid.New().String(), userID, "accepted-job-status-"+status, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status); err != nil {
			t.Errorf("corrected research job status %q was rejected: %v", status, err)
		}
	}
	for _, status := range []string{"not-a-status", "canceling", "succeeded", "failed"} {
		if _, err := database.Exec(`
			INSERT INTO research_jobs (
				id, user_id, idempotency_key, request_hash, request_snapshot, retry_safe,
				query, providers, result_limit, status
			) VALUES ($1, $2, $3, $4, '{}'::jsonb, TRUE, 'fixture query', '["youtube"]'::jsonb, 10, $5)
		`, uuid.New().String(), userID, "rejected-job-status-"+status, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status); err == nil {
			t.Errorf("obsolete research job status %q was accepted", status)
		}
	}

	jobID := insertResearchSchemaTestJob(t, database, userID, "job-idempotency")
	if _, err := database.Exec(`
		INSERT INTO research_jobs (
			id, user_id, idempotency_key, request_hash, request_snapshot, retry_safe,
			query, providers, result_limit
		) VALUES ($1, $2, 'job-idempotency', $3, '{}'::jsonb, FALSE, 'second query', '["youtube"]'::jsonb, 10)
	`, uuid.New().String(), userID, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"); err == nil {
		t.Error("duplicate research job idempotency key was accepted")
	}
	var requestRoundTrip bool
	if err := database.QueryRow(`
		SELECT request_snapshot = $1::jsonb AND retry_safe
		FROM research_jobs WHERE id = $2
	`, `{"query":"fixture query","providers":["youtube"],"limit":10}`, jobID).Scan(&requestRoundTrip); err != nil {
		t.Fatalf("query research job request round trip: %v", err)
	}
	if !requestRoundTrip {
		t.Error("research job request_snapshot or retry_safe did not round trip")
	}
	if _, err := database.Exec(`
		INSERT INTO research_jobs (
			id, user_id, idempotency_key, request_hash, request_snapshot, retry_safe,
			query, providers, result_limit
		) VALUES ($1, $2, 'over-limit', $3, '{}'::jsonb, FALSE, 'fixture query', '["youtube"]'::jsonb, 26)
	`, uuid.New().String(), userID, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"); err == nil {
		t.Error("research result_limit above 25 was accepted")
	}
	if _, err := database.Exec(`UPDATE research_jobs SET degradation_code = 'transient', failure_class = 'timeout' WHERE id = $1`, jobID); err != nil {
		t.Fatalf("valid degradation and failure enums were rejected: %v", err)
	}
	if _, err := database.Exec(`UPDATE research_jobs SET degradation_code = 'unknown' WHERE id = $1`, jobID); err == nil {
		t.Error("unknown degradation code was accepted")
	}

	for index, status := range []string{"running", "completed", "degraded", "cancelled", "timed_out", "lease_lost"} { //nolint:misspell // Validate the persisted status contract.
		statusJobID := insertResearchSchemaTestJob(t, database, userID, "accepted-run-status-"+status)
		if _, err := database.Exec(`
			INSERT INTO research_runs (id, job_id, user_id, attempt, status)
			VALUES ($1, $2, $3, $4, $5)
		`, uuid.New().String(), statusJobID, userID, index+1, status); err != nil {
			t.Errorf("corrected research run status %q was rejected: %v", status, err)
		}
	}
	for _, status := range []string{"not-a-status", "queued", "leased", "succeeded", "failed"} {
		if _, err := database.Exec(`
			INSERT INTO research_runs (id, job_id, user_id, attempt, status)
			VALUES ($1, $2, $3, 1, $4)
		`, uuid.New().String(), jobID, userID, status); err == nil {
			t.Errorf("obsolete research run status %q was accepted", status)
		}
	}

	eventKinds := []string{
		"created", "revision_appended", "claimed", "lease_renewed", "lease_recovered", "degraded",
		"cancel_requested", "cancelled", //nolint:misspell // Validate the persisted event contract.
		"retried", "completed", "reviewed", "runner_terminal",
	}
	for index, kind := range eventKinds {
		if _, err := database.Exec(`
			INSERT INTO research_events (job_id, sequence, kind, payload)
			VALUES ($1, $2, $3, '{}'::jsonb)
		`, jobID, index+1, kind); err != nil {
			t.Fatalf("insert event kind %q: %v", kind, err)
		}
	}
	if _, err := database.Exec(`
		INSERT INTO research_events (job_id, sequence, kind, payload)
		VALUES ($1, 1, 'created', '{}'::jsonb)
	`, jobID); err == nil {
		t.Error("duplicate research event sequence was accepted")
	}
	for index, kind := range []string{"queued", "progress", "revision", "retry_scheduled", "failed"} {
		if _, err := database.Exec(`
			INSERT INTO research_events (job_id, sequence, kind, payload)
			VALUES ($1, $2, $3, '{}'::jsonb)
		`, jobID, len(eventKinds)+index+1, kind); err == nil {
			t.Errorf("obsolete research event kind %q was accepted", kind)
		}
	}
	rows, err := database.Query(`SELECT sequence FROM research_events WHERE job_id = $1 ORDER BY sequence`, jobID)
	if err != nil {
		t.Fatalf("query ordered events: %v", err)
	}
	defer rows.Close()
	var sequences []int
	for rows.Next() {
		var sequence int
		if err := rows.Scan(&sequence); err != nil {
			t.Fatalf("scan event sequence: %v", err)
		}
		sequences = append(sequences, sequence)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate event sequences: %v", err)
	}
	if fmt.Sprint(sequences) != "[1 2 3 4 5 6 7 8 9 10 11 12]" {
		t.Errorf("ordered event sequences = %v, want [1 2 3 4 5 6 7 8 9 10 11 12]", sequences)
	}

	runID := insertResearchSchemaTestRun(t, database, jobID, userID)
	insertResearchSchemaTestRevision(t, database, jobID, userID, nil, "baseline", "baseline", 1)
	revisionID := insertResearchSchemaTestRevision(t, database, jobID, userID, runID, "enhancement", "deep_agent", 2)
	directJudgeRunID := uuid.New().String()
	if _, err := database.Exec(`
		INSERT INTO research_runs (id, job_id, user_id, attempt)
		VALUES ($1, $2, $3, 2)
	`, directJudgeRunID, jobID, userID); err != nil {
		t.Fatalf("create direct judge research run: %v", err)
	}
	insertResearchSchemaTestRevision(t, database, jobID, userID, directJudgeRunID, "enhancement", "direct_judge", 3)
	if _, err := database.Exec(`UPDATE research_revisions SET stage = 'changed' WHERE id = $1`, revisionID); err == nil {
		t.Error("research revision update was accepted")
	}
	if _, err := database.Exec(`DELETE FROM research_revisions WHERE id = $1`, revisionID); err == nil {
		t.Error("research revision delete was accepted")
	}
	if _, err := database.Exec(`UPDATE research_runs SET terminal_telemetry='{"toolCalls":1,"modelAttempts":[]}'::jsonb WHERE id=$1`, runID); err != nil {
		t.Fatalf("valid terminal telemetry was rejected: %v", err)
	}
	if _, err := database.Exec(`UPDATE research_runs SET terminal_telemetry='[]'::jsonb WHERE id=$1`, runID); err == nil {
		t.Error("non-object terminal telemetry was accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO research_revisions (
			id, job_id, user_id, kind, revision_number, stage,
			candidate_snapshot, result_snapshot, provenance_snapshot
		) VALUES (
			$1, $2, $3, 'baseline', 4, 'baseline', jsonb_build_object('value', repeat('x', 65537)), '{}'::jsonb, '{}'::jsonb
		)
	`, uuid.New().String(), jobID, userID); err == nil {
		t.Error("oversized research revision snapshot was accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO research_revisions (
			id, job_id, user_id, run_id, kind, revision_number, stage,
			candidate_snapshot, result_snapshot, provenance_snapshot
		) VALUES ($1, $2, $3, $4, 'baseline', 4, 'baseline', '{}'::jsonb, '{}'::jsonb, '{}'::jsonb)
	`, uuid.New().String(), jobID, userID, runID); err == nil {
		t.Error("baseline revision with a run was accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO research_revisions (
			id, job_id, user_id, kind, revision_number, stage,
			candidate_snapshot, result_snapshot, provenance_snapshot
		) VALUES ($1, $2, $3, 'enhancement', 4, 'deep_agent', '{}'::jsonb, '{}'::jsonb, '{}'::jsonb)
	`, uuid.New().String(), jobID, userID); err == nil {
		t.Error("enhancement revision without a run was accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO research_revisions (
			id, job_id, user_id, kind, revision_number, stage,
			candidate_snapshot, result_snapshot, provenance_snapshot
		) VALUES ($1, $2, $3, 'baseline', 4, 'assembled', '{}'::jsonb, '{}'::jsonb, '{}'::jsonb)
	`, uuid.New().String(), jobID, userID); err == nil {
		t.Error("obsolete research revision stage was accepted")
	}

	if _, err := database.Exec(`
		INSERT INTO research_reviews (
			id, job_id, revision_id, user_id, candidate_id, action, idempotency_key
		) VALUES ($1, $2, $3, $4, 'candidate-1', 'accepted', 'review-idempotency')
	`, uuid.New().String(), jobID, revisionID, otherUserID); err == nil {
		t.Error("cross-user research review/revision mismatch was accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO research_reviews (
			id, job_id, revision_id, user_id, candidate_id, action, idempotency_key
		) VALUES ($1, $2, $3, $4, 'candidate-1', 'accepted', 'review-idempotency')
	`, uuid.New().String(), jobID, revisionID, userID); err != nil {
		t.Fatalf("insert valid research review: %v", err)
	}
	if _, err := database.Exec(`
		INSERT INTO research_reviews (
			id, job_id, revision_id, user_id, candidate_id, action, idempotency_key
		) VALUES ($1, $2, $3, $4, 'candidate-2', 'overridden', 'review-idempotency')
	`, uuid.New().String(), jobID, revisionID, userID); err == nil {
		t.Error("duplicate research review idempotency key was accepted")
	}
	var reviewID string
	if err := database.QueryRow(`SELECT id FROM research_reviews WHERE user_id=$1 AND idempotency_key='review-idempotency'`, userID).Scan(&reviewID); err != nil {
		t.Fatalf("load valid research review: %v", err)
	}
	researchDecisionID := uuid.New().String()
	if _, err := database.Exec(`
		INSERT INTO source_selection_decisions (
			id, research_review_id, user_id, selected_candidate_id, recommended_candidate_id,
			action, origin, selected_candidate, source_quality
		) VALUES ($1,$2,$3,'candidate-1','candidate-1','accepted','research',$4::jsonb,'{}'::jsonb)
	`, researchDecisionID, reviewID, userID, `{"candidateId":"candidate-1","provider":"youtube","sourceUrl":"https://www.youtube.com/watch?v=fixture","title":"Fixture","downloadable":true}`); err != nil {
		t.Fatalf("valid research source decision was rejected: %v", err)
	}
	if _, err := database.Exec(`
		INSERT INTO source_selection_decisions (
			id, research_review_id, user_id, selected_candidate_id, recommended_candidate_id,
			action, origin, selected_candidate, source_quality
		) VALUES ($1,$2,$3,'candidate-1','candidate-1','accepted','research',$4::jsonb,'{}'::jsonb)
	`, uuid.New().String(), reviewID, userID, `{"candidateId":"candidate-1"}`); err == nil {
		t.Error("duplicate research review decision was accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO source_selection_decisions (
			id, user_id, selected_candidate_id, recommended_candidate_id,
			action, origin, selected_candidate, source_quality
		) VALUES ($1,$2,'candidate-1','candidate-1','accepted','research',$3::jsonb,'{}'::jsonb)
	`, uuid.New().String(), userID, `{"candidateId":"candidate-1"}`); err == nil {
		t.Error("research source decision without linked review was accepted")
	}

	if _, err := database.Exec(`
		INSERT INTO research_user_daily_budgets (user_id, budget_day, reserved_units, consumed_units)
		VALUES ($1, CURRENT_DATE, -1, 0)
	`, userID); err == nil {
		t.Error("negative research budget units were accepted")
	}
	if _, err := database.Exec(`
		INSERT INTO research_user_runtime_slots (user_id, active_run_count) VALUES ($1, -1)
	`, userID); err == nil {
		t.Error("negative active research run count was accepted")
	}
}
