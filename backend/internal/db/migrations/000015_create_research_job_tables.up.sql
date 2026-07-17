CREATE TABLE research_jobs (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    idempotency_key VARCHAR(128) NOT NULL,
    request_hash VARCHAR(128) NOT NULL,
    request_snapshot JSONB NOT NULL,
    retry_safe BOOLEAN NOT NULL DEFAULT FALSE,
    query TEXT NOT NULL,
    providers JSONB NOT NULL,
    result_limit SMALLINT NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'queued',
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    terminal_reason VARCHAR(64),
    degradation_code VARCHAR(128),
    failure_class VARCHAR(64),
    failure_code VARCHAR(128),
    failure_message VARCHAR(2000),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    next_attempt_at TIMESTAMP WITH TIME ZONE,
    latest_revision_number BIGINT NOT NULL DEFAULT 0,
    event_sequence BIGINT NOT NULL DEFAULT 0,
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_research_jobs_id_user UNIQUE (id, user_id),
    CONSTRAINT uq_research_jobs_user_idempotency UNIQUE (user_id, idempotency_key),
    CONSTRAINT chk_research_jobs_idempotency_key CHECK (char_length(BTRIM(idempotency_key)) BETWEEN 1 AND 128),
    CONSTRAINT chk_research_jobs_request_hash CHECK (char_length(BTRIM(request_hash)) BETWEEN 16 AND 128),
    CONSTRAINT chk_research_jobs_query CHECK (char_length(BTRIM(query)) BETWEEN 1 AND 4096),
    CONSTRAINT chk_research_jobs_providers CHECK (jsonb_typeof(providers) = 'array' AND jsonb_array_length(providers) BETWEEN 1 AND 16 AND octet_length(providers::text) <= 4096),
    CONSTRAINT chk_research_jobs_request_snapshot CHECK (jsonb_typeof(request_snapshot) = 'object' AND octet_length(request_snapshot::text) <= 65536),
    CONSTRAINT chk_research_jobs_limit CHECK (result_limit BETWEEN 1 AND 25),
    CONSTRAINT chk_research_jobs_status CHECK (status IN ('queued', 'running', 'cancel_requested', 'completed', 'degraded', 'cancelled')),
    CONSTRAINT chk_research_jobs_terminal_reason CHECK (terminal_reason IS NULL OR char_length(BTRIM(terminal_reason)) BETWEEN 1 AND 64),
    CONSTRAINT chk_research_jobs_degradation_code CHECK (degradation_code IS NULL OR degradation_code IN ('model_disabled', 'model_unavailable', 'budget_exhausted', 'transient', 'timeout', 'runner_terminal', 'validation_rejected', 'safety_rejected', 'enhancement_rejected', 'lease_expired', 'no_candidates')),
    CONSTRAINT chk_research_jobs_failure_class CHECK (failure_class IS NULL OR failure_class IN ('transient', 'terminal', 'safety', 'validation', 'timeout')),
    CONSTRAINT chk_research_jobs_failure_code CHECK (failure_code IS NULL OR char_length(BTRIM(failure_code)) BETWEEN 1 AND 128),
    CONSTRAINT chk_research_jobs_failure_message CHECK (failure_message IS NULL OR char_length(BTRIM(failure_message)) BETWEEN 1 AND 2000),
    CONSTRAINT chk_research_jobs_attempts CHECK (attempt_count >= 0 AND max_attempts BETWEEN 1 AND 10 AND attempt_count <= max_attempts),
    CONSTRAINT chk_research_jobs_counters CHECK (latest_revision_number >= 0 AND event_sequence >= 0)
);
CREATE INDEX idx_research_jobs_user_created ON research_jobs(user_id, created_at DESC);
CREATE INDEX idx_research_jobs_queued_claim ON research_jobs(next_attempt_at, created_at, id) WHERE status = 'queued';

CREATE TABLE research_runs (
    id UUID PRIMARY KEY,
    job_id UUID NOT NULL,
    user_id UUID NOT NULL,
    attempt INTEGER NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'running',
    lease_owner VARCHAR(128),
    lease_token UUID,
    lease_until TIMESTAMP WITH TIME ZONE,
    last_heartbeat_at TIMESTAMP WITH TIME ZONE,
    failure_class VARCHAR(64),
    failure_code VARCHAR(128),
    retryable BOOLEAN NOT NULL DEFAULT FALSE,
    slot_released BOOLEAN NOT NULL DEFAULT FALSE,
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    terminal_telemetry JSONB,
    CONSTRAINT uq_research_runs_id_job_user UNIQUE (id, job_id, user_id),
    CONSTRAINT uq_research_runs_job_attempt UNIQUE (job_id, attempt),
    CONSTRAINT fk_research_runs_job_owner FOREIGN KEY (job_id, user_id)
        REFERENCES research_jobs(id, user_id) ON DELETE CASCADE,
    CONSTRAINT chk_research_runs_attempt CHECK (attempt >= 1),
    CONSTRAINT chk_research_runs_status CHECK (status IN ('running', 'completed', 'degraded', 'cancelled', 'timed_out', 'lease_lost')),
    CONSTRAINT chk_research_runs_lease_owner CHECK (lease_owner IS NULL OR char_length(BTRIM(lease_owner)) BETWEEN 1 AND 128),
    CONSTRAINT chk_research_runs_lease_shape CHECK (
        (lease_owner IS NULL AND lease_token IS NULL AND lease_until IS NULL)
        OR (lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_until IS NOT NULL)
    ),
    CONSTRAINT chk_research_runs_failure_class CHECK (failure_class IS NULL OR failure_class IN ('transient', 'terminal', 'safety', 'validation', 'timeout')),
    CONSTRAINT chk_research_runs_failure_code CHECK (failure_code IS NULL OR char_length(BTRIM(failure_code)) BETWEEN 1 AND 128),
    CONSTRAINT chk_research_runs_terminal_telemetry CHECK (terminal_telemetry IS NULL OR (jsonb_typeof(terminal_telemetry) = 'object' AND octet_length(terminal_telemetry::text) <= 16384))
);
CREATE INDEX idx_research_runs_job_created ON research_runs(job_id, created_at DESC);
CREATE INDEX idx_research_runs_expired_lease ON research_runs(lease_until, id)
    WHERE status = 'running' AND lease_until IS NOT NULL;

CREATE TABLE research_revisions (
    id UUID PRIMARY KEY,
    job_id UUID NOT NULL,
    user_id UUID NOT NULL,
    run_id UUID,
    kind VARCHAR(16) NOT NULL,
    revision_number BIGINT NOT NULL,
    stage VARCHAR(64) NOT NULL,
    candidate_snapshot JSONB NOT NULL,
    result_snapshot JSONB NOT NULL,
    provenance_snapshot JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_research_revisions_id_job_user UNIQUE (id, job_id, user_id),
    CONSTRAINT uq_research_revisions_job_number UNIQUE (job_id, revision_number),
    CONSTRAINT fk_research_revisions_job_owner FOREIGN KEY (job_id, user_id)
        REFERENCES research_jobs(id, user_id) ON DELETE CASCADE,
    CONSTRAINT fk_research_revisions_run_owner FOREIGN KEY (run_id, job_id, user_id)
        REFERENCES research_runs(id, job_id, user_id) ON DELETE CASCADE,
    CONSTRAINT chk_research_revisions_number CHECK (revision_number >= 1),
    CONSTRAINT chk_research_revisions_kind CHECK (kind IN ('baseline', 'enhancement')),
    CONSTRAINT chk_research_revisions_stage CHECK (stage IN ('baseline', 'direct_judge', 'deep_agent')),
    CONSTRAINT chk_research_revisions_kind_run CHECK ((kind = 'baseline' AND run_id IS NULL) OR (kind = 'enhancement' AND run_id IS NOT NULL)),
    CONSTRAINT chk_research_revisions_candidate_snapshot CHECK (jsonb_typeof(candidate_snapshot) = 'object' AND octet_length(candidate_snapshot::text) <= 65536),
    CONSTRAINT chk_research_revisions_result_snapshot CHECK (jsonb_typeof(result_snapshot) = 'object' AND octet_length(result_snapshot::text) <= 65536),
    CONSTRAINT chk_research_revisions_provenance_snapshot CHECK (jsonb_typeof(provenance_snapshot) = 'object' AND octet_length(provenance_snapshot::text) <= 65536)
);
CREATE INDEX idx_research_revisions_job_number ON research_revisions(job_id, revision_number DESC);

CREATE FUNCTION reject_research_revision_mutation()
RETURNS TRIGGER AS $$
BEGIN
    -- Permit foreign-key cascading deletes when a parent job is removed.
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'research revisions are immutable';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_research_revisions_immutable
    BEFORE UPDATE OR DELETE ON research_revisions
    FOR EACH ROW EXECUTE FUNCTION reject_research_revision_mutation();

CREATE TABLE research_events (
    id BIGSERIAL PRIMARY KEY,
    job_id UUID NOT NULL REFERENCES research_jobs(id) ON DELETE CASCADE,
    sequence BIGINT NOT NULL,
    kind VARCHAR(32) NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_research_events_job_sequence UNIQUE (job_id, sequence),
    CONSTRAINT chk_research_events_sequence CHECK (sequence >= 1),
    CONSTRAINT chk_research_events_kind CHECK (kind IN ('created', 'revision_appended', 'claimed', 'lease_renewed', 'lease_recovered', 'degraded', 'cancel_requested', 'cancelled', 'retried', 'completed', 'reviewed', 'runner_terminal')),
    CONSTRAINT chk_research_events_payload CHECK (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 16384)
);
CREATE INDEX idx_research_events_job_sequence ON research_events(job_id, sequence);

CREATE TABLE research_reviews (
    id UUID PRIMARY KEY,
    job_id UUID NOT NULL,
    revision_id UUID NOT NULL,
    user_id UUID NOT NULL,
    candidate_id VARCHAR(256) NOT NULL,
    action VARCHAR(16) NOT NULL,
    reason VARCHAR(2000),
    idempotency_key VARCHAR(128) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_research_reviews_user_idempotency UNIQUE (user_id, idempotency_key),
    CONSTRAINT fk_research_reviews_revision_owner FOREIGN KEY (revision_id, job_id, user_id)
        REFERENCES research_revisions(id, job_id, user_id) ON DELETE CASCADE,
    CONSTRAINT chk_research_reviews_candidate_id CHECK (char_length(BTRIM(candidate_id)) BETWEEN 1 AND 256),
    CONSTRAINT chk_research_reviews_action CHECK (action IN ('accepted', 'overridden')),
    CONSTRAINT chk_research_reviews_reason CHECK (reason IS NULL OR char_length(BTRIM(reason)) BETWEEN 1 AND 2000),
    CONSTRAINT chk_research_reviews_idempotency_key CHECK (char_length(BTRIM(idempotency_key)) BETWEEN 1 AND 128)
);
CREATE INDEX idx_research_reviews_revision_created ON research_reviews(revision_id, created_at DESC);
CREATE INDEX idx_research_reviews_user_created ON research_reviews(user_id, created_at DESC);

CREATE TABLE research_user_daily_budgets (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    budget_day DATE NOT NULL,
    reserved_units BIGINT NOT NULL DEFAULT 0,
    consumed_units BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, budget_day),
    CONSTRAINT chk_research_user_daily_budgets_units CHECK (reserved_units >= 0 AND consumed_units >= 0)
);
CREATE INDEX idx_research_user_daily_budgets_day ON research_user_daily_budgets(budget_day, user_id);

CREATE TABLE research_user_runtime_slots (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    active_run_count INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_research_user_runtime_slots_active_runs CHECK (active_run_count >= 0)
);
