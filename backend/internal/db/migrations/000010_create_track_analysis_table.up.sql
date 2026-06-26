CREATE TABLE IF NOT EXISTS track_analysis (
    track_id BIGINT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    schema_version INTEGER NOT NULL DEFAULT 1,
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    artifacts_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    provenance_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    error TEXT,
    requested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_track_analysis_schema_version CHECK (schema_version >= 1),
    CONSTRAINT chk_track_analysis_status CHECK (status IN ('pending', 'analyzing', 'analyzed', 'failed', 'unsupported'))
);

CREATE INDEX IF NOT EXISTS idx_track_analysis_status ON track_analysis(status);
CREATE INDEX IF NOT EXISTS idx_track_analysis_updated_at ON track_analysis(updated_at DESC);
