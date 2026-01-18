-- Create playlist_tracks table
CREATE TABLE playlist_tracks (
    playlist_id BIGINT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    added_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),

    PRIMARY KEY (playlist_id, track_id)
);

-- Index for ordering tracks within a playlist
CREATE INDEX idx_playlist_tracks_position ON playlist_tracks(playlist_id, position);

-- Index for finding which playlists contain a track
CREATE INDEX idx_playlist_tracks_track_id ON playlist_tracks(track_id);
