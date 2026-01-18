-- Create user_library table (links users to shared tracks)
CREATE TABLE user_library (
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    added_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, track_id)
);

-- Composite index for efficient user library queries
CREATE INDEX idx_user_library_user_id ON user_library(user_id);

-- Index for finding which users have a track
CREATE INDEX idx_user_library_track_id ON user_library(track_id);
