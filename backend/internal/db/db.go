package db

import (
	"database/sql"
	"fmt"
	"log"

	_ "github.com/lib/pq"
)

type DB struct {
	*sql.DB

	// TrigramEnabled reports whether the pg_trgm extension is installed on this
	// database. Migrate() populates it as a best-effort step; when false, search
	// stays on the FTS path only. Repositories read this flag to decide whether the
	// similarity() typo-tolerance fallback is available.
	TrigramEnabled bool
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

	return &DB{DB: db}, nil
}

func (db *DB) Migrate() error {
	// Keep startup self-sufficient for local-first dogfood. The SQL files under
	// internal/db/migrations are reference notes for backend-owned schema slices,
	// but a fresh server must be able to create every backend table needed by auth,
	// library, playlists, queue/download, and playback without a separate migration CLI.
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
		metadata_status VARCHAR(50) NOT NULL DEFAULT 'provider',
		metadata_confidence DOUBLE PRECISION,
		metadata_provenance JSONB,
		cover_art_url TEXT,
		metadata_user_edited BOOLEAN NOT NULL DEFAULT FALSE,
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
		PRIMARY KEY (playlist_id, track_id)
	);
	CREATE INDEX IF NOT EXISTS idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id);
	CREATE INDEX IF NOT EXISTS idx_playlist_tracks_track_id ON playlist_tracks(track_id);

	CREATE TABLE IF NOT EXISTS track_favorites (
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		PRIMARY KEY (user_id, track_id)
	);
	CREATE INDEX IF NOT EXISTS idx_track_favorites_user_created ON track_favorites(user_id, created_at DESC);
	CREATE INDEX IF NOT EXISTS idx_track_favorites_track_id ON track_favorites(track_id);

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

	CREATE TABLE IF NOT EXISTS source_selection_sessions (
		id UUID PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		query TEXT NOT NULL,
		context TEXT NOT NULL DEFAULT '',
		candidates JSONB NOT NULL,
		recommended_candidate_id TEXT NOT NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
		CONSTRAINT chk_source_selection_sessions_candidates CHECK (
			jsonb_typeof(candidates) = 'array'
			AND jsonb_array_length(candidates) BETWEEN 1 AND 50
			AND octet_length(candidates::text) <= 49152
		),
		CONSTRAINT chk_source_selection_sessions_recommended_candidate_id CHECK (
			char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
		),
		CONSTRAINT chk_source_selection_sessions_expiry CHECK (expires_at > created_at),
		CONSTRAINT uq_source_selection_sessions_id_user UNIQUE (id, user_id)
	);
	CREATE INDEX IF NOT EXISTS idx_source_selection_sessions_user_expires
		ON source_selection_sessions(user_id, expires_at DESC);
	CREATE INDEX IF NOT EXISTS idx_source_selection_sessions_expires
		ON source_selection_sessions(expires_at);

	CREATE TABLE IF NOT EXISTS source_selection_decisions (
		id UUID PRIMARY KEY,
		session_id UUID,
		session_owner_id UUID,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		selected_candidate_id TEXT NOT NULL,
		recommended_candidate_id TEXT NOT NULL,
		action VARCHAR(16) NOT NULL,
		origin VARCHAR(32) NOT NULL,
		reason TEXT,
		selected_candidate JSONB NOT NULL,
		source_quality JSONB NOT NULL DEFAULT '{}'::jsonb,
		download_job_id UUID REFERENCES download_jobs(id) ON DELETE SET NULL,
		track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_source_selection_decisions_selected_candidate_id CHECK (
			char_length(BTRIM(selected_candidate_id)) BETWEEN 1 AND 256
		),
		CONSTRAINT chk_source_selection_decisions_recommended_candidate_id CHECK (
			char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
		),
		CONSTRAINT chk_source_selection_decisions_action CHECK (action IN ('accepted', 'overridden')),
		CONSTRAINT chk_source_selection_decisions_origin CHECK (origin IN ('discovery', 'direct_url', 'playlist_explicit')),
		CONSTRAINT chk_source_selection_decisions_reason CHECK (reason IS NULL OR char_length(BTRIM(reason)) BETWEEN 1 AND 2000),
		CONSTRAINT chk_source_selection_decisions_candidate CHECK (
			jsonb_typeof(selected_candidate) = 'object'
			AND selected_candidate ->> 'candidateId' = selected_candidate_id
			AND octet_length(selected_candidate::text) <= 49152
		),
		CONSTRAINT chk_source_selection_decisions_source_quality CHECK (jsonb_typeof(source_quality) = 'object'),
		CONSTRAINT chk_source_selection_decisions_action_matches_recommendation CHECK (
			(action = 'accepted' AND selected_candidate_id = recommended_candidate_id)
			OR (action = 'overridden' AND selected_candidate_id <> recommended_candidate_id)
		),
		CONSTRAINT chk_source_selection_decisions_session_reference CHECK (
			(session_id IS NULL) = (session_owner_id IS NULL)
		),
		CONSTRAINT chk_source_selection_decisions_session_owner_matches_user CHECK (
			session_id IS NULL OR session_owner_id = user_id
		),
		CONSTRAINT fk_source_selection_decisions_session_owner
			FOREIGN KEY (session_id, session_owner_id)
			REFERENCES source_selection_sessions (id, user_id)
			ON DELETE SET NULL (session_id, session_owner_id)
	);
	CREATE INDEX IF NOT EXISTS idx_source_selection_decisions_user_created
		ON source_selection_decisions(user_id, created_at DESC);
	CREATE UNIQUE INDEX IF NOT EXISTS idx_source_selection_decisions_one_per_session
		ON source_selection_decisions(session_id) WHERE session_id IS NOT NULL;
	CREATE INDEX IF NOT EXISTS idx_source_selection_decisions_download_job_id
		ON source_selection_decisions(download_job_id) WHERE download_job_id IS NOT NULL;
	CREATE INDEX IF NOT EXISTS idx_source_selection_decisions_track_id
		ON source_selection_decisions(track_id) WHERE track_id IS NOT NULL;

	CREATE TABLE IF NOT EXISTS source_selection_queue_intents (
		decision_id UUID PRIMARY KEY REFERENCES source_selection_decisions(id) ON DELETE CASCADE,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		download_job_id UUID NOT NULL UNIQUE REFERENCES download_jobs(id) ON DELETE CASCADE,
		queue_item_id TEXT NOT NULL UNIQUE,
		insert_position TEXT NOT NULL DEFAULT 'last',
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_source_selection_queue_intents_item_id CHECK (
			char_length(BTRIM(queue_item_id)) BETWEEN 1 AND 128
		),
		CONSTRAINT chk_source_selection_queue_intents_position CHECK (
			char_length(BTRIM(insert_position)) BETWEEN 1 AND 32
		)
	);
	CREATE INDEX IF NOT EXISTS idx_source_selection_queue_intents_user_job
		ON source_selection_queue_intents(user_id, download_job_id);

	CREATE TABLE IF NOT EXISTS track_sources (
		id BIGSERIAL PRIMARY KEY,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		provider VARCHAR(50) NOT NULL,
		source_id TEXT NOT NULL DEFAULT '',
		source_url TEXT NOT NULL DEFAULT '',
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
	);
	CREATE UNIQUE INDEX IF NOT EXISTS idx_track_sources_provider_source_id ON track_sources(provider, source_id) WHERE source_id <> '';
	CREATE INDEX IF NOT EXISTS idx_track_sources_provider_source_url ON track_sources(provider, source_url) WHERE source_url <> '';
	CREATE INDEX IF NOT EXISTS idx_track_sources_track_id ON track_sources(track_id);

	CREATE TABLE IF NOT EXISTS playlist_import_jobs (
		id UUID PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		playlist_id BIGINT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
		source_url TEXT NOT NULL,
		source_title TEXT,
		status VARCHAR(32) NOT NULL DEFAULT 'resolving',
		total_items INTEGER NOT NULL DEFAULT 0,
		imported_items INTEGER NOT NULL DEFAULT 0,
		queued_items INTEGER NOT NULL DEFAULT 0,
		failed_items INTEGER NOT NULL DEFAULT 0,
		skipped_items INTEGER NOT NULL DEFAULT 0,
		max_items INTEGER NOT NULL DEFAULT 500,
		error TEXT,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
	);
	CREATE INDEX IF NOT EXISTS idx_playlist_import_jobs_user_updated ON playlist_import_jobs(user_id, updated_at DESC);
	CREATE INDEX IF NOT EXISTS idx_playlist_import_jobs_playlist_id ON playlist_import_jobs(playlist_id);

	CREATE TABLE IF NOT EXISTS playlist_import_items (
		id BIGSERIAL PRIMARY KEY,
		import_job_id UUID NOT NULL REFERENCES playlist_import_jobs(id) ON DELETE CASCADE,
		source_index INTEGER NOT NULL,
		playlist_position INTEGER NOT NULL,
		source_id TEXT NOT NULL DEFAULT '',
		source_url TEXT NOT NULL DEFAULT '',
		title TEXT NOT NULL DEFAULT '',
		artist TEXT NOT NULL DEFAULT '',
		album TEXT NOT NULL DEFAULT '',
		uploader TEXT NOT NULL DEFAULT '',
		duration_ms INTEGER NOT NULL DEFAULT 0,
		thumbnail_url TEXT NOT NULL DEFAULT '',
		status VARCHAR(32) NOT NULL DEFAULT 'pending',
		error TEXT,
		track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
		download_job_id TEXT,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		UNIQUE (import_job_id, source_index)
	);
	CREATE INDEX IF NOT EXISTS idx_playlist_import_items_job_source ON playlist_import_items(import_job_id, source_index);
	CREATE INDEX IF NOT EXISTS idx_playlist_import_items_download_job_id ON playlist_import_items(download_job_id) WHERE download_job_id IS NOT NULL;
	CREATE INDEX IF NOT EXISTS idx_playlist_import_items_status ON playlist_import_items(status);

	CREATE INDEX IF NOT EXISTS idx_tracks_fulltext ON tracks USING GIN (to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')));

	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_url TEXT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_type VARCHAR(50);
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS storage_key VARCHAR(500);
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS file_size_bytes BIGINT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_json JSONB;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_status VARCHAR(50) NOT NULL DEFAULT 'provider';
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_confidence DOUBLE PRECISION;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_provenance JSONB;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS cover_art_url TEXT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_user_edited BOOLEAN NOT NULL DEFAULT FALSE;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS genre VARCHAR(200);

	CREATE INDEX IF NOT EXISTS idx_tracks_genre ON tracks(genre);

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

	CREATE TABLE IF NOT EXISTS track_analysis (
		track_id BIGINT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
		schema_version INTEGER NOT NULL DEFAULT 1,
		status VARCHAR(32) NOT NULL DEFAULT 'pending',
		summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		overrides_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		artifacts_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		provenance_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		error TEXT,
		requested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		started_at TIMESTAMP WITH TIME ZONE,
		completed_at TIMESTAMP WITH TIME ZONE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_track_analysis_schema_version CHECK (schema_version >= 1),
		CONSTRAINT chk_track_analysis_status CHECK (status IN ('pending', 'analyzing', 'analyzed', 'failed', 'stale', 'unsupported'))
	);
	CREATE INDEX IF NOT EXISTS idx_track_analysis_status ON track_analysis(status);
	CREATE INDEX IF NOT EXISTS idx_track_analysis_updated_at ON track_analysis(updated_at DESC);
	ALTER TABLE track_analysis ADD COLUMN IF NOT EXISTS overrides_json JSONB NOT NULL DEFAULT '{}'::jsonb;

	CREATE TABLE IF NOT EXISTS play_events (
		id BIGSERIAL PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		played_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		context_type VARCHAR(32),
		context_id TEXT
	);
	CREATE INDEX IF NOT EXISTS idx_play_events_user_played_at ON play_events(user_id, played_at DESC);

	`

	_, err := db.Exec(schema)
	if err != nil {
		return fmt.Errorf("failed to run migrations: %w", err)
	}
	if err := db.refreshTrackAnalysisStatusConstraint(); err != nil {
		return err
	}

	// Best-effort: enable pg_trgm for fuzzy/typo-tolerant local search. This is
	// intentionally OUTSIDE the required schema above and MUST NOT be fatal:
	// CREATE EXTENSION can require privileges (superuser) the runtime user may not
	// have. If it fails, we log it and keep TrigramEnabled false so search degrades
	// gracefully to the FTS path — the server still starts and search still works.
	db.TrigramEnabled = db.tryEnableTrigram()

	return nil
}

func (db *DB) refreshTrackAnalysisStatusConstraint() error {
	_, err := db.Exec(`
		ALTER TABLE track_analysis DROP CONSTRAINT IF EXISTS chk_track_analysis_status;
		ALTER TABLE track_analysis ADD CONSTRAINT chk_track_analysis_status
			CHECK (status IN ('pending', 'analyzing', 'analyzed', 'failed', 'stale', 'unsupported'));
	`)
	if err != nil {
		return fmt.Errorf("failed to refresh track_analysis status constraint: %w", err)
	}
	return nil
}

// tryEnableTrigram installs the pg_trgm extension and its supporting trigram GIN
// indexes on tracks(title)/tracks(artist). Every step is best-effort: any failure
// is logged and results in a false return so callers know the fuzzy fallback is
// unavailable. It never returns an error, so it can never abort startup.
func (db *DB) tryEnableTrigram() bool {
	if _, err := db.Exec(`CREATE EXTENSION IF NOT EXISTS pg_trgm`); err != nil {
		log.Printf("db: pg_trgm extension unavailable; fuzzy search disabled, FTS still works: %v", err)
		return false
	}

	// Trigram GIN indexes accelerate the similarity() fallback. If index creation
	// fails the fallback still works (just slower), so we only log and continue.
	for _, stmt := range []string{
		`CREATE INDEX IF NOT EXISTS idx_tracks_title_trgm ON tracks USING GIN (title gin_trgm_ops)`,
		`CREATE INDEX IF NOT EXISTS idx_tracks_artist_trgm ON tracks USING GIN (artist gin_trgm_ops)`,
	} {
		if _, err := db.Exec(stmt); err != nil {
			log.Printf("db: failed to create trigram index (fuzzy search may be slower): %v", err)
		}
	}

	return true
}
