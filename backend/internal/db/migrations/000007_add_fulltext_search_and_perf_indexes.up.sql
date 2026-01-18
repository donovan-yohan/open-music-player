-- Migration: Add full-text search indexes and performance optimizations

-- Add GIN index for full-text search on tracks
-- This enables fast searching across title, artist, album using to_tsvector
CREATE INDEX idx_tracks_search ON tracks
USING GIN (to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')));

-- Add index for mb_verified filter (commonly used in library queries)
CREATE INDEX idx_tracks_mb_verified ON tracks(mb_verified);

-- Add composite index for user_library with added_at for sorting
CREATE INDEX idx_user_library_user_added_at ON user_library(user_id, added_at DESC);

-- Add index for playlist_tracks position ordering
CREATE INDEX idx_playlist_tracks_position ON playlist_tracks(playlist_id, position);

-- Add index for download_jobs user queries
CREATE INDEX idx_download_jobs_user_id ON download_jobs(user_id);

-- Add index for download_jobs status (for finding pending jobs)
CREATE INDEX idx_download_jobs_status ON download_jobs(status);
