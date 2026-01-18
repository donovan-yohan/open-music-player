-- Create tracks table
CREATE TABLE tracks (
    id BIGSERIAL PRIMARY KEY,
    identity_hash VARCHAR(64) NOT NULL UNIQUE,
    title VARCHAR(500) NOT NULL,
    artist VARCHAR(500),
    album VARCHAR(500),
    duration_ms INTEGER,
    version VARCHAR(100),

    -- MusicBrainz identifiers
    mb_recording_id UUID,
    mb_release_id UUID,
    mb_artist_id UUID,
    mb_verified BOOLEAN NOT NULL DEFAULT FALSE,

    -- Source and storage info
    source_url TEXT,
    source_type VARCHAR(50),
    storage_key VARCHAR(500),
    file_size_bytes BIGINT,

    -- Flexible metadata storage
    metadata_json JSONB,

    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Unique index on identity_hash for deduplication
CREATE UNIQUE INDEX idx_tracks_identity_hash ON tracks(identity_hash);

-- Index on MusicBrainz recording ID for MB lookups
CREATE INDEX idx_tracks_mb_recording_id ON tracks(mb_recording_id) WHERE mb_recording_id IS NOT NULL;

-- Index for searching by title/artist
CREATE INDEX idx_tracks_title ON tracks(title);
CREATE INDEX idx_tracks_artist ON tracks(artist);
