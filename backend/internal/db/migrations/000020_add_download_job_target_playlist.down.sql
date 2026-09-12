-- Reference note only; the canonical schema is backend/internal/db/db.go.
--
-- Dropping the column discards every unfinished download's playlist target, so
-- those downloads land in the library only. That is recoverable by hand and is
-- the intended rollback.
DROP INDEX IF EXISTS idx_download_jobs_target_playlist;
ALTER TABLE download_jobs DROP COLUMN IF EXISTS target_playlist_id;
