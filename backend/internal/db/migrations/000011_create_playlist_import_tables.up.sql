CREATE TABLE IF NOT EXISTS track_sources (
    id BIGSERIAL PRIMARY KEY,
    track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    provider VARCHAR(50) NOT NULL,
    source_id TEXT NOT NULL DEFAULT '',
    source_url TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_track_sources_provider_source_id
    ON track_sources(provider, source_id)
    WHERE source_id <> '';
CREATE INDEX IF NOT EXISTS idx_track_sources_provider_source_url
    ON track_sources(provider, source_url)
    WHERE source_url <> '';
CREATE INDEX IF NOT EXISTS idx_track_sources_track_id ON track_sources(track_id);

CREATE TABLE IF NOT EXISTS playlist_import_jobs (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    playlist_id BIGINT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    source_url TEXT NOT NULL,
    source_title TEXT,
    status VARCHAR(32) NOT NULL DEFAULT 'resolving',
    total_items INTEGER NOT NULL DEFAULT 0,
    imported_items INTEGER NOT NULL DEFAULT 0,
    queued_items INTEGER NOT NULL DEFAULT 0,
    failed_items INTEGER NOT NULL DEFAULT 0,
    skipped_items INTEGER NOT NULL DEFAULT 0,
    max_items INTEGER NOT NULL DEFAULT 500,
    error TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_playlist_import_jobs_user_updated ON playlist_import_jobs(user_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_playlist_import_jobs_playlist_id ON playlist_import_jobs(playlist_id);

CREATE TABLE IF NOT EXISTS playlist_import_items (
    id BIGSERIAL PRIMARY KEY,
    import_job_id UUID NOT NULL REFERENCES playlist_import_jobs(id) ON DELETE CASCADE,
    source_index INTEGER NOT NULL,
    playlist_position INTEGER NOT NULL,
    source_id TEXT NOT NULL DEFAULT '',
    source_url TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    uploader TEXT NOT NULL DEFAULT '',
    duration_ms INTEGER NOT NULL DEFAULT 0,
    thumbnail_url TEXT NOT NULL DEFAULT '',
    status VARCHAR(32) NOT NULL DEFAULT 'pending',
    error TEXT,
    track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
    download_job_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (import_job_id, source_index)
);
CREATE INDEX IF NOT EXISTS idx_playlist_import_items_job_source ON playlist_import_items(import_job_id, source_index);
CREATE INDEX IF NOT EXISTS idx_playlist_import_items_download_job_id ON playlist_import_items(download_job_id) WHERE download_job_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_playlist_import_items_status ON playlist_import_items(status);
