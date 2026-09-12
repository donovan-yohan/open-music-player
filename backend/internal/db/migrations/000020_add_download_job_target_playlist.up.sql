-- Reference note only; the canonical schema is backend/internal/db/db.go.
--
-- A queue enqueue can carry the playlist the user picked for a discovery result.
-- The target lives on the download job so the intent survives both the user
-- leaving the screen and a restart mid-download. ON DELETE SET NULL is the
-- deliberate behavior for a playlist deleted while the download is still
-- running: the download keeps going, it just has nowhere to land.
ALTER TABLE download_jobs
    ADD COLUMN IF NOT EXISTS target_playlist_id BIGINT
    REFERENCES playlists(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_download_jobs_target_playlist
    ON download_jobs(target_playlist_id) WHERE target_playlist_id IS NOT NULL;
