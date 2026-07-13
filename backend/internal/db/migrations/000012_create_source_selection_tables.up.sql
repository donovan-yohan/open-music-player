CREATE TABLE IF NOT EXISTS source_selection_sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    query TEXT NOT NULL,
    context TEXT NOT NULL DEFAULT '',
    candidates JSONB NOT NULL,
    recommended_candidate_id TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    CONSTRAINT chk_source_selection_sessions_candidates CHECK (
        jsonb_typeof(candidates) = 'array'
        AND jsonb_array_length(candidates) BETWEEN 1 AND 50
        AND octet_length(candidates::text) <= 49152
    ),
    CONSTRAINT chk_source_selection_sessions_recommended_candidate_id CHECK (
        char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
    ),
    CONSTRAINT chk_source_selection_sessions_expiry CHECK (expires_at > created_at),
    CONSTRAINT uq_source_selection_sessions_id_user UNIQUE (id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_source_selection_sessions_user_expires ON source_selection_sessions(user_id, expires_at DESC);
CREATE INDEX IF NOT EXISTS idx_source_selection_sessions_expires ON source_selection_sessions(expires_at);

CREATE TABLE IF NOT EXISTS source_selection_decisions (
    id UUID PRIMARY KEY,
    session_id UUID,
    session_owner_id UUID,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    selected_candidate_id TEXT NOT NULL,
    recommended_candidate_id TEXT NOT NULL,
    action VARCHAR(16) NOT NULL,
    origin VARCHAR(32) NOT NULL,
    reason TEXT,
    selected_candidate JSONB NOT NULL,
    source_quality JSONB NOT NULL DEFAULT '{}'::jsonb,
    download_job_id UUID REFERENCES download_jobs(id) ON DELETE SET NULL,
    track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_source_selection_decisions_selected_candidate_id CHECK (char_length(BTRIM(selected_candidate_id)) BETWEEN 1 AND 256),
    CONSTRAINT chk_source_selection_decisions_recommended_candidate_id CHECK (char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256),
    CONSTRAINT chk_source_selection_decisions_action CHECK (action IN ('accepted', 'overridden')),
    CONSTRAINT chk_source_selection_decisions_origin CHECK (origin IN ('discovery', 'direct_url', 'playlist_explicit')),
    CONSTRAINT chk_source_selection_decisions_reason CHECK (reason IS NULL OR char_length(BTRIM(reason)) BETWEEN 1 AND 2000),
    CONSTRAINT chk_source_selection_decisions_candidate CHECK (jsonb_typeof(selected_candidate) = 'object' AND selected_candidate ->> 'candidateId' = selected_candidate_id AND octet_length(selected_candidate::text) <= 49152),
    CONSTRAINT chk_source_selection_decisions_source_quality CHECK (jsonb_typeof(source_quality) = 'object'),
    CONSTRAINT chk_source_selection_decisions_action_matches_recommendation CHECK ((action = 'accepted' AND selected_candidate_id = recommended_candidate_id) OR (action = 'overridden' AND selected_candidate_id <> recommended_candidate_id)),
    CONSTRAINT chk_source_selection_decisions_session_reference CHECK ((session_id IS NULL) = (session_owner_id IS NULL)),
    CONSTRAINT chk_source_selection_decisions_session_owner_matches_user CHECK (session_id IS NULL OR session_owner_id = user_id),
    CONSTRAINT fk_source_selection_decisions_session_owner FOREIGN KEY (session_id, session_owner_id)
        REFERENCES source_selection_sessions (id, user_id) ON DELETE SET NULL (session_id, session_owner_id)
);
CREATE INDEX IF NOT EXISTS idx_source_selection_decisions_user_created ON source_selection_decisions(user_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_source_selection_decisions_one_per_session ON source_selection_decisions(session_id) WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_source_selection_decisions_download_job_id ON source_selection_decisions(download_job_id) WHERE download_job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_source_selection_decisions_track_id ON source_selection_decisions(track_id) WHERE track_id IS NOT NULL;
