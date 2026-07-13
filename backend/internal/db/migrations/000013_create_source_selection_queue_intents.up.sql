CREATE TABLE IF NOT EXISTS source_selection_queue_intents (
    decision_id UUID PRIMARY KEY REFERENCES source_selection_decisions(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    download_job_id UUID NOT NULL UNIQUE REFERENCES download_jobs(id) ON DELETE CASCADE,
    queue_item_id TEXT NOT NULL UNIQUE,
    insert_position TEXT NOT NULL DEFAULT 'last',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_source_selection_queue_intents_item_id CHECK (char_length(BTRIM(queue_item_id)) BETWEEN 1 AND 128),
    CONSTRAINT chk_source_selection_queue_intents_position CHECK (char_length(BTRIM(insert_position)) BETWEEN 1 AND 32)
);
CREATE INDEX IF NOT EXISTS idx_source_selection_queue_intents_user_job ON source_selection_queue_intents(user_id, download_job_id);
