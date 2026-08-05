ALTER TABLE source_selection_sessions
    ALTER COLUMN recommended_candidate_id DROP NOT NULL;
ALTER TABLE source_selection_sessions
    DROP CONSTRAINT IF EXISTS chk_source_selection_sessions_recommended_candidate_id;
ALTER TABLE source_selection_sessions
    ADD CONSTRAINT chk_source_selection_sessions_recommended_candidate_id CHECK (
        recommended_candidate_id IS NULL
        OR char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
    );

ALTER TABLE source_selection_decisions
    ALTER COLUMN recommended_candidate_id DROP NOT NULL;
ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_recommended_candidate_id;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT chk_source_selection_decisions_recommended_candidate_id CHECK (
        recommended_candidate_id IS NULL
        OR char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
    );
ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_action;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT chk_source_selection_decisions_action CHECK (
        action IN ('selected', 'accepted', 'overridden')
    );
ALTER TABLE source_selection_decisions
    DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_action_matches_recommendation;
ALTER TABLE source_selection_decisions
    ADD CONSTRAINT chk_source_selection_decisions_action_matches_recommendation CHECK (
        (recommended_candidate_id IS NULL AND action = 'selected')
        OR (recommended_candidate_id IS NOT NULL AND (
            (action = 'accepted' AND selected_candidate_id = recommended_candidate_id)
            OR (action = 'overridden' AND selected_candidate_id <> recommended_candidate_id)
        ))
    ) NOT VALID;
