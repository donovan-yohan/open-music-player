-- Rollback: Remove full-text search indexes and performance optimizations

DROP INDEX IF EXISTS idx_tracks_search;
DROP INDEX IF EXISTS idx_tracks_mb_verified;
DROP INDEX IF EXISTS idx_user_library_user_added_at;
DROP INDEX IF EXISTS idx_playlist_tracks_position;
DROP INDEX IF EXISTS idx_download_jobs_user_id;
DROP INDEX IF EXISTS idx_download_jobs_status;
