package db

import (
	"database/sql"
	"fmt"

	_ "github.com/lib/pq"
)

type DB struct {
	*sql.DB
}

func New(host, port, user, password, dbname string) (*DB, error) {
	connStr := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		host, port, user, password, dbname,
	)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}

	return &DB{db}, nil
}

func (db *DB) Migrate() error {
	// Keep startup self-sufficient for local-first dogfood. The SQL files under
	// internal/db/migrations still document the migration sequence, but a fresh
	// server must be able to create every backend table needed by auth, library,
	// playlists, queue/download, and playback without a separate migration CLI.
	schema := `
	CREATE TABLE IF NOT EXISTS users (
		id UUID PRIMARY KEY,
		email VARCHAR(255) UNIQUE NOT NULL,
		username VARCHAR(50) NOT NULL,
		password_hash VARCHAR(255) NOT NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
	);
	CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

	CREATE TABLE IF NOT EXISTS refresh_tokens (
		id UUID PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		token_hash VARCHAR(255) NOT NULL,
		expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		revoked BOOLEAN DEFAULT FALSE
	);
	CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_id ON refresh_tokens(user_id);
	CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);

	CREATE TABLE IF NOT EXISTS tracks (
		id BIGSERIAL PRIMARY KEY,
		identity_hash VARCHAR(64) NOT NULL UNIQUE,
		title VARCHAR(500) NOT NULL,
		artist VARCHAR(500),
		album VARCHAR(500),
		duration_ms INTEGER,
		version VARCHAR(100),
		mb_recording_id UUID,
		mb_release_id UUID,
		mb_artist_id UUID,
		mb_verified BOOLEAN NOT NULL DEFAULT FALSE,
		source_url TEXT,
		source_type VARCHAR(50),
		storage_key VARCHAR(500),
		file_size_bytes BIGINT,
		metadata_json JSONB,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
	);
	CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_identity_hash ON tracks(identity_hash);
	CREATE INDEX IF NOT EXISTS idx_tracks_mb_recording_id ON tracks(mb_recording_id) WHERE mb_recording_id IS NOT NULL;
	CREATE INDEX IF NOT EXISTS idx_tracks_title ON tracks(title);
	CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist);
	CREATE INDEX IF NOT EXISTS idx_tracks_storage_key ON tracks(storage_key) WHERE storage_key IS NOT NULL;

	CREATE TABLE IF NOT EXISTS user_library (
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		added_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		PRIMARY KEY (user_id, track_id)
	);
	CREATE INDEX IF NOT EXISTS idx_user_library_user_id ON user_library(user_id);
	CREATE INDEX IF NOT EXISTS idx_user_library_track_id ON user_library(track_id);
	CREATE INDEX IF NOT EXISTS idx_user_library_added_at ON user_library(user_id, added_at DESC);

	CREATE TABLE IF NOT EXISTS playlists (
		id BIGSERIAL PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		name VARCHAR(255) NOT NULL,
		description TEXT,
		cover_url TEXT,
		is_public BOOLEAN NOT NULL DEFAULT FALSE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
	);
	CREATE INDEX IF NOT EXISTS idx_playlists_user_id ON playlists(user_id);
	CREATE INDEX IF NOT EXISTS idx_playlists_public ON playlists(is_public) WHERE is_public = TRUE;

	CREATE TABLE IF NOT EXISTS playlist_tracks (
		playlist_id BIGINT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		position INTEGER NOT NULL,
		added_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		PRIMARY KEY (playlist_id, track_id),
		UNIQUE (playlist_id, position)
	);
	CREATE INDEX IF NOT EXISTS idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id);
	CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track_id ON playlist_tracks(track_id);

	CREATE TABLE IF NOT EXISTS download_jobs (
		id UUID PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
		url TEXT NOT NULL,
		source_type VARCHAR(50) NOT NULL,
		status VARCHAR(50) NOT NULL DEFAULT 'queued',
		progress INTEGER DEFAULT 0,
		error TEXT,
		retry_count INTEGER NOT NULL DEFAULT 0,
		mb_recording_id UUID,
		candidate_id TEXT,
		source_id TEXT,
		title TEXT,
		artist TEXT,
		album TEXT,
		uploader TEXT,
		duration_ms INTEGER,
		thumbnail_url TEXT,
		metadata_json JSONB,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		started_at TIMESTAMP WITH TIME ZONE,
		completed_at TIMESTAMP WITH TIME ZONE
	);
	CREATE INDEX IF NOT EXISTS idx_download_jobs_user_id ON download_jobs(user_id);
	CREATE INDEX IF NOT EXISTS idx_download_jobs_status ON download_jobs(status);
	CREATE INDEX IF NOT EXISTS idx_download_jobs_user_status ON download_jobs(user_id, status);
	CREATE INDEX IF NOT EXISTS idx_download_jobs_track_id ON download_jobs(track_id) WHERE track_id IS NOT NULL;

	CREATE INDEX IF NOT EXISTS idx_tracks_fulltext ON tracks USING GIN (to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')));

	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_url TEXT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_type VARCHAR(50);
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS storage_key VARCHAR(500);
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS file_size_bytes BIGINT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_json JSONB;

	CREATE TABLE IF NOT EXISTS mix_plans (
		id UUID PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		schema_version INTEGER NOT NULL DEFAULT 1,
		name VARCHAR(255) NOT NULL,
		payload JSONB NOT NULL,
		summary JSONB NOT NULL DEFAULT '{}'::jsonb,
		version INTEGER NOT NULL DEFAULT 1,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_mix_plans_schema_version CHECK (schema_version >= 1),
		CONSTRAINT chk_mix_plans_version CHECK (version >= 1)
	);

	CREATE INDEX IF NOT EXISTS idx_mix_plans_user_updated ON mix_plans(user_id, updated_at DESC);
	`

	_, err := db.Exec(schema)
	if err != nil {
		return fmt.Errorf("failed to run migrations: %w", err)
	}

	return nil
}
