ALTER TABLE research_jobs
    ADD COLUMN IF NOT EXISTS assigned_variant VARCHAR(64),
    ADD COLUMN IF NOT EXISTS variant_cohort VARCHAR(64);

UPDATE research_jobs
SET assigned_variant = 'deterministic_only'
WHERE assigned_variant IS NULL
   OR assigned_variant NOT IN ('deterministic_only', 'direct_structured_judge', 'bounded_agent_dark_launch');

UPDATE research_jobs
SET variant_cohort = 'default'
WHERE variant_cohort IS NULL
   OR variant_cohort !~ '^[a-z0-9][a-z0-9._-]{0,63}$'
   OR variant_cohort ~* '(token|secret|password|api[-_]?key|bearer|^sk-)';

ALTER TABLE research_jobs
    ALTER COLUMN assigned_variant SET DEFAULT 'deterministic_only',
    ALTER COLUMN assigned_variant SET NOT NULL,
    ALTER COLUMN variant_cohort SET DEFAULT 'default',
    ALTER COLUMN variant_cohort SET NOT NULL;

ALTER TABLE research_jobs
    DROP CONSTRAINT IF EXISTS chk_research_jobs_assigned_variant;
ALTER TABLE research_jobs
    ADD CONSTRAINT chk_research_jobs_assigned_variant
    CHECK (assigned_variant IN ('deterministic_only', 'direct_structured_judge', 'bounded_agent_dark_launch'));

ALTER TABLE research_jobs
    DROP CONSTRAINT IF EXISTS chk_research_jobs_variant_cohort;
ALTER TABLE research_jobs
    ADD CONSTRAINT chk_research_jobs_variant_cohort
    CHECK (
        variant_cohort ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
        AND variant_cohort !~* '(token|secret|password|api[-_]?key|bearer|^sk-)'
    );

CREATE OR REPLACE FUNCTION reject_research_job_variant_mutation()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.assigned_variant IS DISTINCT FROM OLD.assigned_variant
        OR NEW.variant_cohort IS DISTINCT FROM OLD.variant_cohort THEN
        RAISE EXCEPTION 'research job variant assignment is immutable';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_research_jobs_variant_immutable ON research_jobs;
CREATE TRIGGER trg_research_jobs_variant_immutable
    BEFORE UPDATE OF assigned_variant, variant_cohort ON research_jobs
    FOR EACH ROW EXECUTE FUNCTION reject_research_job_variant_mutation();
