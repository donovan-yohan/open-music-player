ALTER TABLE source_selection_decisions
    ADD COLUMN IF NOT EXISTS research_review_id UUID;

ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_origin;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT chk_source_selection_decisions_origin
    CHECK (origin IN ('discovery', 'direct_url', 'playlist_explicit', 'research'));

ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_research_review;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT chk_source_selection_decisions_research_review
    CHECK (
        (origin = 'research' AND session_id IS NULL AND research_review_id IS NOT NULL)
        OR (origin <> 'research' AND research_review_id IS NULL)
    );

ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS fk_source_selection_decisions_research_review;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT fk_source_selection_decisions_research_review
    FOREIGN KEY (research_review_id) REFERENCES research_reviews(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS idx_source_selection_decisions_one_per_research_review
    ON source_selection_decisions(research_review_id)
    WHERE research_review_id IS NOT NULL;
