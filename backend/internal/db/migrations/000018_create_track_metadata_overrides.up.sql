-- Reference note only. The canonical schema is the Go startup migration in
-- backend/internal/db/db.go; this file mirrors that DDL and is not executed by a
-- migration runner.
--
-- Issue #344: per-user manual metadata corrections. tracks rows are global and
-- shared across users, so a user edit never mutates tracks.title/artist/album.
-- A NULL column here means "not overridden"; a row with all three NULL is deleted
-- rather than stored. These values are DISPLAY-LAYER ONLY: they must never feed the
-- MusicBrainz matcher, the identity hash, or any ingestion path.

CREATE TABLE IF NOT EXISTS track_metadata_overrides (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    title VARCHAR(500),
    artist VARCHAR(500),
    album VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, track_id),
    CONSTRAINT chk_track_metadata_overrides_not_empty CHECK (
        title IS NOT NULL OR artist IS NOT NULL OR album IS NOT NULL
    )
);
CREATE INDEX IF NOT EXISTS idx_track_metadata_overrides_track_id ON track_metadata_overrides(track_id);
