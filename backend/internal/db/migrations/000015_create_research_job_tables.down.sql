DROP TRIGGER IF EXISTS trg_research_revisions_immutable ON research_revisions;
DROP FUNCTION IF EXISTS reject_research_revision_mutation();
DROP TABLE IF EXISTS research_reviews;
DROP TABLE IF EXISTS research_events;
DROP TABLE IF EXISTS research_revisions;
DROP TABLE IF EXISTS research_runs;
DROP TABLE IF EXISTS research_user_runtime_slots;
DROP TABLE IF EXISTS research_user_daily_budgets;
DROP TABLE IF EXISTS research_jobs;
