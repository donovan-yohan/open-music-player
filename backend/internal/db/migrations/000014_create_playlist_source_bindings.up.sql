CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_id_user
    ON playlists(id, user_id);

CREATE TABLE IF NOT EXISTS playlist_source_bindings (
    id BIGSERIAL PRIMARY KEY,
    playlist_id BIGINT NOT NULL UNIQUE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider VARCHAR(50) NOT NULL,
    provider_playlist_id TEXT NOT NULL,
    canonical_url TEXT NOT NULL,
    sync_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    last_sync_status VARCHAR(32),
    last_sync_started_at TIMESTAMP WITH TIME ZONE,
    last_sync_completed_at TIMESTAMP WITH TIME ZONE,
    last_sync_error_redacted TEXT,
    snapshot_fingerprint VARCHAR(512),
    snapshot_generation BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_playlist_source_bindings_identity CHECK (
        char_length(BTRIM(provider)) BETWEEN 1 AND 50
        AND char_length(BTRIM(provider_playlist_id)) BETWEEN 1 AND 1024
        AND char_length(BTRIM(canonical_url)) BETWEEN 1 AND 8192
    ),
    CONSTRAINT chk_playlist_source_bindings_generation CHECK (snapshot_generation >= 0),
    CONSTRAINT fk_playlist_source_bindings_playlist_owner
        FOREIGN KEY (playlist_id, user_id)
        REFERENCES playlists (id, user_id)
        ON DELETE CASCADE,
    CONSTRAINT uq_playlist_source_bindings_user_provider_playlist
        UNIQUE (user_id, provider, provider_playlist_id)
);
CREATE INDEX IF NOT EXISTS idx_playlist_source_bindings_provider_source
    ON playlist_source_bindings(provider, provider_playlist_id);
CREATE INDEX IF NOT EXISTS idx_playlist_source_bindings_sync_enabled
    ON playlist_source_bindings(sync_enabled) WHERE sync_enabled = TRUE;

CREATE TABLE IF NOT EXISTS playlist_source_entries (
    id BIGSERIAL PRIMARY KEY,
    source_binding_id BIGINT NOT NULL REFERENCES playlist_source_bindings(id) ON DELETE CASCADE,
    provider_entry_id TEXT NOT NULL,
    source_url TEXT NOT NULL DEFAULT '',
    track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
    source_order INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_playlist_source_entries_provider_entry_id CHECK (
        char_length(BTRIM(provider_entry_id)) BETWEEN 1 AND 1024
    ),
    CONSTRAINT chk_playlist_source_entries_source_order CHECK (source_order >= 0),
    UNIQUE (source_binding_id, provider_entry_id)
);
CREATE INDEX IF NOT EXISTS idx_playlist_source_entries_track_id
    ON playlist_source_entries(track_id) WHERE track_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_playlist_source_entries_binding_order
    ON playlist_source_entries(source_binding_id, source_order);

ALTER TABLE playlist_import_items
    ADD COLUMN IF NOT EXISTS playlist_source_entry_id BIGINT
    REFERENCES playlist_source_entries(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_playlist_import_items_source_entry
    ON playlist_import_items(playlist_source_entry_id) WHERE playlist_source_entry_id IS NOT NULL;
