-- Create download_jobs table
CREATE TABLE download_jobs (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    url TEXT NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    progress INTEGER DEFAULT 0,
    error TEXT,
    metadata_json JSONB,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Index for user's download jobs
CREATE INDEX idx_download_jobs_user_id ON download_jobs(user_id);

-- Index for finding jobs by status
CREATE INDEX idx_download_jobs_status ON download_jobs(status);

-- Composite index for user's jobs by status
CREATE INDEX idx_download_jobs_user_status ON download_jobs(user_id, status);
