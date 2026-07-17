-- Research decisions have no equivalent pre-000016 origin. Remove them rather
-- than relabeling their semantic origin before restoring the former constraint.
DELETE FROM source_selection_decisions
WHERE origin = 'research';

DROP INDEX IF EXISTS idx_source_selection_decisions_one_per_research_review;
ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS fk_source_selection_decisions_research_review;
ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_research_review;
ALTER TABLE source_selection_decisions
    DROP COLUMN IF EXISTS research_review_id;
ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_origin;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT chk_source_selection_decisions_origin
    CHECK (origin IN ('discovery', 'direct_url', 'playlist_explicit'));
