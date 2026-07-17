package research

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"

	store "github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
)

const researchPostgresDSN = "postgres://omp:omp_dev_password@localhost:25131/openmusicplayer?sslmode=disable"

func newPostgresResearchRepository(t *testing.T, cfg PostgresRepositoryConfig) (*PostgresRepository, *store.DB) {
	t.Helper()
	dsn := os.Getenv("OMP_POSTGRES_TEST_DSN")
	if dsn == "" {
		dsn = os.Getenv("POSTGRES_DSN")
	}
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or POSTGRES_DSN=" + researchPostgresDSN + " to run Postgres research repository integration tests")
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open postgres: %v", err)
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &store.DB{DB: raw}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping postgres: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate postgres: %v", err)
	}
	return NewPostgresRepository(database, cfg), database
}

func researchUser(t *testing.T, database *store.DB) string {
	t.Helper()
	id := uuid.NewString()
	if _, err := database.Exec(`INSERT INTO users (id,email,username,password_hash) VALUES ($1,$2,$3,'test')`, id, "research-"+id+"@example.test", "research_"+strings.ReplaceAll(id[:8], "-", "")); err != nil {
		t.Fatalf("create user: %v", err)
	}
	t.Cleanup(func() { _, _ = database.Exec(`DELETE FROM users WHERE id=$1`, id) })
	return id
}

func researchInput(owner string) CreateInput {
	return CreateInput{
		ID: uuid.NewString(), OwnerID: owner, IdempotencyKey: uuid.NewString(), RequestHash: strings.Repeat("a", 64),
		Request: json.RawMessage(`{"query":"fixture song","providers":["youtube"],"limit":2}`), RetrySafe: true, MaxAttempts: 2,
		Baseline: RevisionInput{ID: uuid.NewString(), Payload: researchBaselinePayload()},
	}
}

func researchBaselinePayload() json.RawMessage {
	return json.RawMessage(`{"schemaVersion":"omp.research.revision.v1","stage":"baseline","query":"fixture song","candidates":[{"candidateId":"youtube:fixture-a","provider":"youtube","sourceUrl":"https://www.youtube.com/watch?v=fixturea","title":"Fixture Song","downloadable":true,"playable":false,"sourceQuality":{"score":100,"classification":"official_audio","recommendation":"preferred","confidence":1}},{"candidateId":"youtube:fixture-b","provider":"youtube","sourceUrl":"https://www.youtube.com/watch?v=fixtureb","title":"Fixture Song Live","downloadable":true,"playable":false,"sourceQuality":{"score":50,"classification":"live","recommendation":"review","confidence":0.5,"warnings":["live"]}}],"recommendations":[{"candidateId":"youtube:fixture-a","rank":1,"confidence":1,"classification":"official_audio"},{"candidateId":"youtube:fixture-b","rank":2,"confidence":0.5,"classification":"live","warnings":["live"]}],"provenance":{"source":"deterministic_discovery_v1"},"timing":{"baselineBuildMs":1}}`)
}

func enhancement(claim Claim, id string) RevisionInput {
	return RevisionInput{ID: id, Payload: json.RawMessage(fmt.Sprintf(`{"schemaVersion":"omp.research.revision.v1","stage":"direct_judge","query":"fixture song","candidates":[{"candidateId":"youtube:fixture-a","provider":"youtube","sourceUrl":"https://www.youtube.com/watch?v=fixture","title":"Fixture Song","downloadable":true,"playable":false,"sourceQuality":{"score":100,"classification":"official_audio","recommendation":"preferred","confidence":1}}],"recommendations":[{"candidateId":"youtube:fixture-a","rank":1,"confidence":1,"classification":"official_audio"}],"provenance":{"source":"candidate_assembly_worker","workerSchemaVersion":"omp.agent-search.worker.revision.v1"},"timing":{"workerInferenceMs":1}}`))}
}

func TestPostgresCreateAtomicityAndSemanticIdempotency(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{DailyLimit: 2})
	owner := researchUser(t, database)
	input := researchInput(owner)
	first, err := repo.Create(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	if first.Job.Status != JobQueued || first.Job.LatestRevision != 1 || len(first.Revisions) != 1 {
		t.Fatalf("unexpected create snapshot: %#v", first)
	}
	second, err := repo.Create(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	if second.Job.ID != first.Job.ID || len(second.Revisions) != 1 {
		t.Fatal("idempotent create did not return original snapshot")
	}
	input.RequestHash = strings.Repeat("b", 64)
	if _, err := repo.Create(context.Background(), input); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("idempotency conflict = %v", err)
	}
	events, err := repo.Events(context.Background(), first.Job.ID, owner, 0, 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || events[0].Kind != EventCreated || events[1].Kind != EventRevisionAppended {
		t.Fatalf("baseline events = %#v", events)
	}
}

func TestPostgresReviewConcurrentIdempotencyConflict(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{DailyLimit: 100})
	owner := researchUser(t, database)
	first, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	second, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	key := uuid.NewString()
	inputs := []struct {
		jobID string
		input ReviewInput
	}{
		{first.Job.ID, ReviewInput{RevisionID: first.Revisions[0].ID, RevisionNumber: 1, CandidateID: "youtube:fixture-a", Action: ReviewAccepted, IdempotencyKey: key}},
		{second.Job.ID, ReviewInput{RevisionID: second.Revisions[0].ID, RevisionNumber: 1, CandidateID: "youtube:fixture-b", Action: ReviewOverridden, IdempotencyKey: key}},
	}
	start := make(chan struct{})
	errs := make(chan error, len(inputs))
	var wg sync.WaitGroup
	for _, item := range inputs {
		wg.Add(1)
		go func(item struct {
			jobID string
			input ReviewInput
		}) {
			defer wg.Done()
			<-start
			errs <- repo.Review(context.Background(), item.jobID, owner, item.input)
		}(item)
	}
	close(start)
	wg.Wait()
	close(errs)

	var successes, conflicts int
	for err := range errs {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrIdempotencyConflict):
			conflicts++
		default:
			t.Fatalf("concurrent review = %v", err)
		}
	}
	if successes != 1 || conflicts != 1 {
		t.Fatalf("review outcomes successes=%d conflicts=%d", successes, conflicts)
	}
	var records int
	if err := database.QueryRow(`SELECT COUNT(*) FROM research_reviews WHERE user_id=$1 AND idempotency_key=$2`, owner, key).Scan(&records); err != nil || records != 1 {
		t.Fatalf("idempotency records=%d err=%v", records, err)
	}
}

func TestPostgresEmptyBaselineIsTerminalWithoutBudgetOrClaim(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
	owner := researchUser(t, database)
	input := researchInput(owner)
	input.Baseline.Payload = json.RawMessage(`{"schemaVersion":"omp.research.revision.v1","stage":"baseline","query":"fixture song","candidates":[],"recommendations":[],"provenance":{"source":"deterministic_discovery_v1"},"timing":{"baselineBuildMs":1}}`)
	snapshot, err := repo.Create(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Job.Status != JobDegraded || snapshot.Job.LatestRevision != 1 || len(snapshot.Revisions) != 1 || snapshot.LatestDegradation == nil || snapshot.LatestDegradation.Code != DegradationNoCandidates {
		t.Fatalf("empty baseline snapshot %#v", snapshot)
	}
	if _, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute)); !errors.Is(err, ErrNoJobAvailable) {
		t.Fatalf("empty baseline was claimable: %v", err)
	}
	var reserved int
	if err := database.QueryRow(`SELECT COUNT(*) FROM research_user_daily_budgets WHERE user_id=$1`, owner).Scan(&reserved); err != nil || reserved != 0 {
		t.Fatalf("empty baseline reserved model budget count=%d err=%v", reserved, err)
	}
}

func TestPostgresTerminalTelemetryWritesOnceAndIsExposed(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
	owner := researchUser(t, database)
	created, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	value := int64(1)
	telemetry := TerminalTelemetry{ProcessStartupToRequestAcceptedMs: &value, ToolCalls: 2, ModelAttempts: []TerminalModelAttempt{{Stage: StageDirectJudge, Attempt: 1, DurationMs: 1, Status: "success"}}}
	if err := repo.RecordTerminal(context.Background(), *claim, telemetry); err != nil {
		t.Fatal(err)
	}
	if err := repo.RecordTerminal(context.Background(), *claim, telemetry); !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("duplicate telemetry=%v", err)
	}
	snapshot, err := repo.Get(context.Background(), created.Job.ID, owner)
	if err != nil || snapshot.LatestTerminalTelemetry == nil || snapshot.LatestTerminalTelemetry.ToolCalls != 2 {
		t.Fatalf("snapshot telemetry=%#v err=%v", snapshot, err)
	}
	events, err := repo.Events(context.Background(), created.Job.ID, owner, 0, 10)
	if err != nil || len(events) != 4 || events[3].Kind != EventRunnerTerminal || events[3].Telemetry == nil {
		t.Fatalf("terminal event=%#v err=%v", events, err)
	}
}

func TestPostgresCancelledClaimAllowsTerminalTelemetryBeforeTerminalOutcome(t *testing.T) {
	for _, test := range []struct {
		name     string
		terminal func(*PostgresRepository, Claim) (*Snapshot, error)
	}{
		{name: "completion", terminal: func(repo *PostgresRepository, claim Claim) (*Snapshot, error) {
			return repo.Finish(context.Background(), claim, JobCompleted)
		}},
		{name: "degradation", terminal: func(repo *PostgresRepository, claim Claim) (*Snapshot, error) {
			return repo.Degrade(context.Background(), claim, PublicDegradation(DegradationTransient))
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
			owner := researchUser(t, database)
			created, err := repo.Create(context.Background(), researchInput(owner))
			if err != nil {
				t.Fatal(err)
			}
			claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			appended, err := repo.AppendEnhancement(context.Background(), *claim, enhancement(*claim, uuid.NewString()))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := repo.Cancel(context.Background(), created.Job.ID, owner); err != nil {
				t.Fatal(err)
			}
			value := int64(1)
			telemetry := TerminalTelemetry{ProcessStartupToRequestAcceptedMs: &value}
			if err := repo.RecordTerminal(context.Background(), *claim, telemetry); err != nil {
				t.Fatalf("record terminal after cancellation request: %v", err)
			}
			if err := repo.RecordTerminal(context.Background(), *claim, telemetry); !errors.Is(err, ErrInvalidTransition) {
				t.Fatalf("duplicate telemetry=%v", err)
			}
			snapshot, err := test.terminal(repo, *claim)
			if err != nil || snapshot.Job.Status != JobCancelled || snapshot.Job.LatestRevision != appended.Number || snapshot.Job.LatestRevisionID != appended.ID || snapshot.LatestTerminalTelemetry == nil {
				t.Fatalf("terminal cancellation snapshot=%#v err=%v", snapshot, err)
			}
			var status string
			if err := database.QueryRow(`SELECT status FROM research_runs WHERE id=$1`, claim.Run.ID).Scan(&status); err != nil || status != string(RunCancelled) {
				t.Fatalf("run status=%q err=%v", status, err)
			}
		})
	}
}

func TestPostgresCancellationWinsOverRunnerSuccess(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
	owner := researchUser(t, database)
	created, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Cancel(context.Background(), created.Job.ID, owner); err != nil {
		t.Fatal(err)
	}
	snapshot, err := repo.Finish(context.Background(), *claim, JobCompleted)
	if err != nil || snapshot.Job.Status != JobCancelled {
		t.Fatalf("cancel/success race snapshot=%#v err=%v", snapshot, err)
	}
	var status string
	if err := database.QueryRow(`SELECT status FROM research_runs WHERE id=$1`, claim.Run.ID).Scan(&status); err != nil || status != string(RunCancelled) {
		t.Fatalf("run status=%q err=%v", status, err)
	}
}

func TestPostgresOwnershipIsolationAndOrderedPolling(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
	owner, stranger := researchUser(t, database), researchUser(t, database)
	snapshot, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Get(context.Background(), snapshot.Job.ID, stranger); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign get = %v", err)
	}
	if _, err := repo.Events(context.Background(), snapshot.Job.ID, stranger, 0, 10); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign events = %v", err)
	}
	if _, err := repo.Cancel(context.Background(), snapshot.Job.ID, stranger); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign cancel = %v", err)
	}
	if _, err := repo.Cancel(context.Background(), snapshot.Job.ID, owner); err != nil {
		t.Fatal(err)
	}
	events, err := repo.Events(context.Background(), snapshot.Job.ID, owner, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Sequence != 2 {
		t.Fatalf("after-cursor events = %#v", events)
	}
	all, err := repo.Events(context.Background(), snapshot.Job.ID, owner, 0, 20)
	if err != nil {
		t.Fatal(err)
	}
	for i, event := range all {
		if event.Sequence != int64(i+1) {
			t.Fatalf("unordered events: %#v", all)
		}
	}
}

func TestPostgresConcurrentClaimsRespectUserSlotsAndProgressOtherUsers(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{MaxConcurrentRunsPerUser: 1})
	owner, other := researchUser(t, database), researchUser(t, database)
	for _, user := range []string{owner, owner, other} {
		if _, err := repo.Create(context.Background(), researchInput(user)); err != nil {
			t.Fatal(err)
		}
	}
	first, err := repo.Claim(context.Background(), "worker-1", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	second, err := repo.Claim(context.Background(), "worker-2", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if first.Snapshot.Job.OwnerID == second.Snapshot.Job.OwnerID {
		t.Fatalf("same owner exceeded slot cap: %s", first.Snapshot.Job.OwnerID)
	}
	if _, err := repo.Claim(context.Background(), "worker-3", time.Now().Add(time.Minute)); !errors.Is(err, ErrNoJobAvailable) {
		t.Fatalf("third claim = %v", err)
	}
}

func TestPostgresLeaseRecoveryAndCancelPreserveRevisions(t *testing.T) {
	now := time.Now().UTC()
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{Clock: func() time.Time { return now }})
	owner := researchUser(t, database)
	created, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	claim, err := repo.Claim(context.Background(), "worker", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.AppendEnhancement(context.Background(), *claim, enhancement(*claim, uuid.NewString())); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`UPDATE research_runs SET lease_until=$2 WHERE id=$1`, claim.Run.ID, now.Add(-time.Second)); err != nil {
		t.Fatalf("expire lease: %v", err)
	}
	if _, err := repo.Cancel(context.Background(), created.Job.ID, owner); err != nil {
		t.Fatal(err)
	}
	if recovered, err := repo.RecoverExpiredLeases(context.Background(), now); err != nil || recovered != 1 {
		t.Fatalf("recovered %d: %v", recovered, err)
	}
	snapshot, err := repo.Get(context.Background(), created.Job.ID, owner)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Job.Status != JobCancelled || len(snapshot.Revisions) != 2 {
		t.Fatalf("cancel/recovery snapshot %#v", snapshot)
	}
	if recovered, err := repo.RecoverExpiredLeases(context.Background(), now.Add(time.Second)); err != nil || recovered != 0 {
		t.Fatalf("duplicate recover %d: %v", recovered, err)
	}
}

func TestPostgresRetryOnlyTransientAndBounded(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{DailyLimit: 3})
	owner := researchUser(t, database)
	created, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Degrade(context.Background(), *claim, Degradation{Code: DegradationSafetyRejected}); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Retry(context.Background(), created.Job.ID, owner); !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("safety retry = %v", err)
	}
	created, err = repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	claim, err = repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Degrade(context.Background(), *claim, Degradation{Code: DegradationTransient, Retryable: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := repo.Retry(context.Background(), created.Job.ID, owner); err != nil {
		t.Fatal(err)
	}
	claim, err = repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := repo.Degrade(context.Background(), *claim, Degradation{Code: DegradationTransient, Retryable: true})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.LatestDegradation == nil || snapshot.LatestDegradation.Retryable {
		t.Fatalf("capped transient degradation=%#v", snapshot.LatestDegradation)
	}
	var retryable bool
	if err := database.QueryRow(`SELECT retryable FROM research_runs WHERE id=$1`, claim.Run.ID).Scan(&retryable); err != nil || retryable {
		t.Fatalf("capped run retryable=%t err=%v", retryable, err)
	}
	events, err := repo.Events(context.Background(), created.Job.ID, owner, 0, 20)
	if err != nil || len(events) == 0 || events[len(events)-1].Degradation == nil || events[len(events)-1].Degradation.Retryable {
		t.Fatalf("capped degradation event=%#v err=%v", events, err)
	}
	if _, err := repo.Retry(context.Background(), created.Job.ID, owner); !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("bounded retry = %v", err)
	}
}

func TestPostgresDefaultGeneratedRevisionIDsAreUUIDs(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
	owner := researchUser(t, database)
	builder, err := NewBaselineBuilder(BaselineBuilderConfig{Search: &fixtureSearch{response: discovery.SourceSearchResponse{Results: []discovery.Candidate{{CandidateID: "youtube:fixture-a", Provider: "youtube", SourceURL: "https://www.youtube.com/watch?v=fixturea", Title: "Fixture Song", Downloadable: true}}}}})
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := builder.Build(context.Background(), "fixture song", []string{"youtube"}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := uuid.Parse(baseline.ID); err != nil {
		t.Fatalf("default baseline id %q is not a UUID: %v", baseline.ID, err)
	}
	input := researchInput(owner)
	input.Baseline = baseline
	created, err := repo.Create(context.Background(), input)
	if err != nil {
		t.Fatalf("create with default baseline id: %v", err)
	}
	claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	enhancementInput := enhancement(*claim, newResearchID())
	if _, err := uuid.Parse(enhancementInput.ID); err != nil {
		t.Fatalf("default enhancement id %q is not a UUID: %v", enhancementInput.ID, err)
	}
	appended, err := repo.AppendEnhancement(context.Background(), *claim, enhancementInput)
	if err != nil || appended.ID != enhancementInput.ID || created.Revisions[0].ID != baseline.ID {
		t.Fatalf("default generated revision ids create=%#v append=%#v err=%v", created, appended, err)
	}
}

func TestPostgresAtomicDailyBudgetAndGroundedReview(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{DailyLimit: 1})
	owner := researchUser(t, database)
	inputs := []CreateInput{researchInput(owner), researchInput(owner)}
	var wg sync.WaitGroup
	snapshots := make(chan *Snapshot, 2)
	failures := make(chan error, 2)
	for _, input := range inputs {
		wg.Add(1)
		go func(input CreateInput) {
			defer wg.Done()
			snapshot, err := repo.Create(context.Background(), input)
			if err != nil {
				failures <- err
				return
			}
			snapshots <- snapshot
		}(input)
	}
	wg.Wait()
	close(snapshots)
	close(failures)
	for err := range failures {
		t.Fatal(err)
	}
	var queued, budget *Snapshot
	for snapshot := range snapshots {
		if snapshot.Job.Status == JobQueued {
			queued = snapshot
		} else {
			budget = snapshot
		}
	}
	if queued == nil || budget == nil || budget.LatestDegradation == nil || budget.LatestDegradation.Code != DegradationBudgetExhausted {
		t.Fatalf("budget snapshots queued=%#v budget=%#v", queued, budget)
	}
	claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	_, err = repo.AppendEnhancement(context.Background(), *claim, enhancement(*claim, uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	input := ReviewInput{RevisionID: queued.Revisions[0].ID, RevisionNumber: 1, CandidateID: "youtube:fixture-a", Action: ReviewAccepted, IdempotencyKey: uuid.NewString()}
	if err := repo.Review(context.Background(), queued.Job.ID, owner, input); err != nil {
		t.Fatal(err)
	}
	if err := repo.Review(context.Background(), queued.Job.ID, owner, input); err != nil {
		t.Fatalf("idempotent review: %v", err)
	}
	conflict := input
	conflict.CandidateID = "youtube:fixture-b"
	conflict.Action = ReviewOverridden
	if err := repo.Review(context.Background(), queued.Job.ID, owner, conflict); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("review idempotency conflict = %v", err)
	}
	conflict.IdempotencyKey = uuid.NewString()
	if err := repo.Review(context.Background(), queued.Job.ID, owner, conflict); err != nil {
		t.Fatalf("grounded override = %v", err)
	}
	invalid := input
	invalid.CandidateID = "youtube:fixture-b"
	invalid.IdempotencyKey = uuid.NewString()
	if err := repo.Review(context.Background(), queued.Job.ID, owner, invalid); !errors.Is(err, ErrInvalidReview) {
		t.Fatalf("non-top accepted = %v", err)
	}
}

func TestPostgresRevisionsAreAppendOnlyAndOrdered(t *testing.T) {
	repo, database := newPostgresResearchRepository(t, PostgresRepositoryConfig{})
	owner := researchUser(t, database)
	created, err := repo.Create(context.Background(), researchInput(owner))
	if err != nil {
		t.Fatal(err)
	}
	claim, err := repo.Claim(context.Background(), "worker", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	first, err := repo.AppendEnhancement(context.Background(), *claim, enhancement(*claim, uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	second, err := repo.AppendEnhancement(context.Background(), *claim, enhancement(*claim, uuid.NewString()))
	if err != nil {
		t.Fatal(err)
	}
	if first.Number != 2 || second.Number != 3 {
		t.Fatalf("revision numbers %d,%d", first.Number, second.Number)
	}
	if _, err := database.Exec(`UPDATE research_revisions SET result_snapshot='{}'::jsonb WHERE id=$1`, first.ID); err == nil {
		t.Fatal("revision mutation was accepted")
	}
	snapshot, err := repo.Get(context.Background(), created.Job.ID, owner)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Revisions) != 3 || snapshot.Revisions[2].Number != 3 {
		t.Fatalf("revision ordering %#v", snapshot.Revisions)
	}
}
