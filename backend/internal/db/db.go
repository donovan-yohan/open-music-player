package db

import (
	"context"
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
	// Multiple API processes and integration tests can initialize concurrently.
	// A transaction-scoped lock cannot cover the legacy self-contained schema
	// setup below, so hold one session advisory lock for the whole migration.
	conn, err := db.Conn(context.Background())
	if err != nil {
		return fmt.Errorf("acquire migration connection: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(context.Background(), `SELECT pg_advisory_lock(hashtextextended('open_music_player_schema_migrate', 0))`); err != nil {
		return fmt.Errorf("lock schema migration: %w", err)
	}
	defer func() {
		_, _ = conn.ExecContext(context.Background(), `SELECT pg_advisory_unlock(hashtextextended('open_music_player_schema_migrate', 0))`)
	}()

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
		-- Content identity of the bytes stored at storage_key, as "sha256:<hex>".
		-- Empty means "not known yet": tracks downloaded before this column, or
		-- tracks whose hash has not been backfilled by a first separation.
		-- Derived artifacts (track_stems) compare against it to detect replaced
		-- audio, so it must only ever be written by whoever wrote those bytes.
		source_file_hash VARCHAR(128) NOT NULL DEFAULT '',
		codec TEXT,
		bitrate_kbps INTEGER,
		sample_rate_hz INTEGER,
		channels INTEGER,
		content_type TEXT,
		audio_quality_probe_attempted_at TIMESTAMP WITH TIME ZONE,
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
	CREATE UNIQUE INDEX IF NOT EXISTS idx_playlists_id_user ON playlists(id, user_id);

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

	-- Per-user manual metadata corrections (issue #344). tracks rows are global and
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
		recommended_candidate_id TEXT,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
		CONSTRAINT chk_source_selection_sessions_candidates CHECK (
			jsonb_typeof(candidates) = 'array'
			AND jsonb_array_length(candidates) BETWEEN 1 AND 50
			AND octet_length(candidates::text) <= 49152
		),
		CONSTRAINT chk_source_selection_sessions_recommended_candidate_id CHECK (
			recommended_candidate_id IS NULL
			OR char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
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
		recommended_candidate_id TEXT,
		action VARCHAR(16) NOT NULL,
		origin VARCHAR(32) NOT NULL,
		reason TEXT,
		selected_candidate JSONB NOT NULL,
		source_quality JSONB NOT NULL DEFAULT '{}'::jsonb,
		download_job_id UUID REFERENCES download_jobs(id) ON DELETE SET NULL,
		track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
		research_review_id UUID,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_source_selection_decisions_selected_candidate_id CHECK (
			char_length(BTRIM(selected_candidate_id)) BETWEEN 1 AND 256
		),
		CONSTRAINT chk_source_selection_decisions_recommended_candidate_id CHECK (
			recommended_candidate_id IS NULL
			OR char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
		),
		CONSTRAINT chk_source_selection_decisions_action CHECK (action IN ('selected', 'accepted', 'overridden')),
		CONSTRAINT chk_source_selection_decisions_action_matches_recommendation CHECK (
			(recommended_candidate_id IS NULL AND action = 'selected')
			OR (recommended_candidate_id IS NOT NULL AND (
				(action = 'accepted' AND selected_candidate_id = recommended_candidate_id)
				OR (action = 'overridden' AND selected_candidate_id <> recommended_candidate_id)
			))
		),
		CONSTRAINT chk_source_selection_decisions_origin CHECK (origin IN ('discovery', 'direct_url', 'playlist_explicit', 'research')),
		CONSTRAINT chk_source_selection_decisions_reason CHECK (reason IS NULL OR char_length(BTRIM(reason)) BETWEEN 1 AND 2000),
		CONSTRAINT chk_source_selection_decisions_candidate CHECK (
			jsonb_typeof(selected_candidate) = 'object'
			AND selected_candidate ->> 'candidateId' = selected_candidate_id
			AND octet_length(selected_candidate::text) <= 49152
		),
		CONSTRAINT chk_source_selection_decisions_source_quality CHECK (jsonb_typeof(source_quality) = 'object'),
		CONSTRAINT chk_source_selection_decisions_session_reference CHECK (
			(session_id IS NULL) = (session_owner_id IS NULL)
		),
		CONSTRAINT chk_source_selection_decisions_session_owner_matches_user CHECK (
			session_id IS NULL OR session_owner_id = user_id
		),
		CONSTRAINT chk_source_selection_decisions_research_review CHECK (
			(origin = 'research' AND session_id IS NULL AND research_review_id IS NOT NULL)
			OR (origin <> 'research' AND research_review_id IS NULL)
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

	CREATE TABLE IF NOT EXISTS playlist_source_bindings (
		id BIGSERIAL PRIMARY KEY,
		playlist_id BIGINT NOT NULL UNIQUE,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		provider VARCHAR(50) NOT NULL,
		provider_playlist_id TEXT NOT NULL,
		canonical_url TEXT NOT NULL,
		sync_enabled BOOLEAN NOT NULL DEFAULT FALSE,
		last_sync_status VARCHAR(32),
		last_sync_started_at TIMESTAMP WITH TIME ZONE,
		last_sync_completed_at TIMESTAMP WITH TIME ZONE,
		last_sync_error_redacted TEXT,
		snapshot_fingerprint VARCHAR(512),
		snapshot_generation BIGINT NOT NULL DEFAULT 0,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_playlist_source_bindings_identity CHECK (
			char_length(BTRIM(provider)) BETWEEN 1 AND 50
			AND char_length(BTRIM(provider_playlist_id)) BETWEEN 1 AND 1024
			AND char_length(BTRIM(canonical_url)) BETWEEN 1 AND 8192
		),
		CONSTRAINT chk_playlist_source_bindings_generation CHECK (snapshot_generation >= 0),
		CONSTRAINT fk_playlist_source_bindings_playlist_owner
			FOREIGN KEY (playlist_id, user_id)
			REFERENCES playlists (id, user_id)
			ON DELETE CASCADE,
		CONSTRAINT uq_playlist_source_bindings_user_provider_playlist
			UNIQUE (user_id, provider, provider_playlist_id)
	);
	CREATE INDEX IF NOT EXISTS idx_playlist_source_bindings_provider_source
		ON playlist_source_bindings(provider, provider_playlist_id);
	CREATE INDEX IF NOT EXISTS idx_playlist_source_bindings_sync_enabled
		ON playlist_source_bindings(sync_enabled) WHERE sync_enabled = TRUE;

	CREATE TABLE IF NOT EXISTS playlist_source_entries (
		id BIGSERIAL PRIMARY KEY,
		source_binding_id BIGINT NOT NULL REFERENCES playlist_source_bindings(id) ON DELETE CASCADE,
		provider_entry_id TEXT NOT NULL,
		source_url TEXT NOT NULL DEFAULT '',
		track_id BIGINT REFERENCES tracks(id) ON DELETE SET NULL,
		source_order INTEGER NOT NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_playlist_source_entries_provider_entry_id CHECK (
			char_length(BTRIM(provider_entry_id)) BETWEEN 1 AND 1024
		),
		CONSTRAINT chk_playlist_source_entries_source_order CHECK (source_order >= 0),
		UNIQUE (source_binding_id, provider_entry_id)
	);
	CREATE INDEX IF NOT EXISTS idx_playlist_source_entries_track_id
		ON playlist_source_entries(track_id) WHERE track_id IS NOT NULL;
	CREATE INDEX IF NOT EXISTS idx_playlist_source_entries_binding_order
		ON playlist_source_entries(source_binding_id, source_order);

	ALTER TABLE playlist_import_items
		ADD COLUMN IF NOT EXISTS playlist_source_entry_id BIGINT
		REFERENCES playlist_source_entries(id) ON DELETE SET NULL;
	CREATE INDEX IF NOT EXISTS idx_playlist_import_items_source_entry
		ON playlist_import_items(playlist_source_entry_id) WHERE playlist_source_entry_id IS NOT NULL;

	CREATE INDEX IF NOT EXISTS idx_tracks_fulltext ON tracks USING GIN (to_tsvector('english', COALESCE(title, '') || ' ' || COALESCE(artist, '') || ' ' || COALESCE(album, '')));

	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_url TEXT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_type VARCHAR(50);
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS storage_key VARCHAR(500);
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS file_size_bytes BIGINT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS source_file_hash VARCHAR(128) NOT NULL DEFAULT '';
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS codec TEXT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS bitrate_kbps INTEGER;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS sample_rate_hz INTEGER;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS channels INTEGER;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS content_type TEXT;
	ALTER TABLE tracks ADD COLUMN IF NOT EXISTS audio_quality_probe_attempted_at TIMESTAMP WITH TIME ZONE;
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

	-- FROZEN PROJECTION INTERFACE (omp_* functions)
	--
	-- Every omp_* function below is a FROZEN interface. track_analysis.effective_bpm
	-- and track_analysis.effective_camelot are GENERATED ALWAYS ... STORED over these
	-- functions, and PostgreSQL does NOT recompute already-stored values when a
	-- function body is replaced. Because this block runs CREATE OR REPLACE on every
	-- boot, an in-place semantic edit silently leaves every deployed row on the OLD
	-- projection while only newly written rows use the new one -- and the partial
	-- indexes idx_track_analysis_effective_bpm / idx_track_analysis_effective_camelot_bpm
	-- keep serving those stale values to the nearby/harmonic queries.
	--
	-- Measured on PostgreSQL 15.18 after replacing such a function: VACUUM FULL, a
	-- table-rewriting ALTER TABLE ... ALTER COLUMN TYPE, and an UPDATE that touches
	-- only a non-base column all leave the stored value stale. ONLY these refresh it:
	--   * UPDATE track_analysis SET summary_json = summary_json (assign a BASE column);
	--   * ALTER TABLE track_analysis DROP COLUMN <generated>, then ADD COLUMN
	--     <generated> ... GENERATED ALWAYS AS (...) STORED.
	--
	-- Upgrade path for a SEMANTIC change -- never edit a body in place:
	--   1. Add a NEW versioned function (e.g. omp_effective_analysis_bpm_v2) and leave
	--      the frozen one untouched.
	--   2. In the same release, drop and re-add the generated column against the new
	--      function (or batch-rewrite every row through its base columns) and rebuild
	--      the dependent partial indexes.
	--   3. Keep the old function until no column or index references it.
	-- Only edits that provably cannot change output (comments, whitespace) are allowed
	-- in place.
	--
	-- Backpressure: checkGeneratedProjectionDrift (bottom of this file) compares a
	-- bounded sample of stored values against a fresh evaluation on every Migrate()
	-- and logs loudly on mismatch. generatedProjectionProbes must list every generated
	-- projection column; TestGeneratedProjectionProbeCoversEveryGeneratedColumn fails
	-- if a new one is added without registering it.
	--
	-- Filter projections are generated from the same compact fields served by the
	-- analysis list boundary. The helper functions distinguish absent/invalid
	-- override facts from valid values, so a malformed manual edit cannot hide a
	-- valid analyzer result. manual_timing_v2.bpm is the canonical timing edit
	-- and therefore wins before the ordinary compact BPM field.
	CREATE OR REPLACE FUNCTION omp_compact_number_value(document JSONB, field TEXT)
	RETURNS DOUBLE PRECISION
	LANGUAGE SQL
	IMMUTABLE
	PARALLEL SAFE
	AS $$
		SELECT CASE
			WHEN jsonb_typeof(document -> field) = 'number' THEN
				CASE WHEN (document ->> field)::numeric BETWEEN -1.7976931348623157e308::numeric AND 1.7976931348623157e308::numeric
					THEN (document ->> field)::DOUBLE PRECISION END
			WHEN jsonb_typeof(document -> field) = 'object'
				AND jsonb_typeof(document -> field -> 'value') = 'number' THEN
				CASE WHEN (document -> field ->> 'value')::numeric BETWEEN -1.7976931348623157e308::numeric AND 1.7976931348623157e308::numeric
					THEN (document -> field ->> 'value')::DOUBLE PRECISION END
			WHEN jsonb_typeof(document -> field) = 'object'
				AND NOT ((document -> field) ? 'value')
				AND jsonb_typeof(document -> field -> 'nativeBpm') = 'number' THEN
				CASE WHEN (document -> field ->> 'nativeBpm')::numeric BETWEEN -1.7976931348623157e308::numeric AND 1.7976931348623157e308::numeric
					THEN (document -> field ->> 'nativeBpm')::DOUBLE PRECISION END
		END
	$$;

	CREATE OR REPLACE FUNCTION omp_compact_camelot_value(document JSONB)
	RETURNS TEXT
	LANGUAGE SQL
	IMMUTABLE
	PARALLEL SAFE
	AS $$
		SELECT CASE
			WHEN jsonb_typeof(document -> 'camelot') = 'string'
				AND char_length(BTRIM(document ->> 'camelot')) BETWEEN 1 AND 128
				THEN UPPER(BTRIM(document ->> 'camelot'))
			WHEN jsonb_typeof(document -> 'camelot') = 'object'
				AND jsonb_typeof(document -> 'camelot' -> 'value') = 'string'
				AND char_length(BTRIM(document -> 'camelot' ->> 'value')) BETWEEN 1 AND 128
				THEN UPPER(BTRIM(document -> 'camelot' ->> 'value'))
		END
	$$;

	CREATE OR REPLACE FUNCTION omp_manual_timing_bpm(document JSONB)
	RETURNS DOUBLE PRECISION
	LANGUAGE SQL
	IMMUTABLE
	PARALLEL SAFE
	AS $$
		-- This mirrors decodeCompactManualTimingOverride and validCompactManualTiming:
		-- malformed optional scalar values decode as absent; structurally valid v2
		-- timing wins over its legacy form; timing with an invalid grid is ignored.
		WITH timing AS (
			SELECT document -> 'manual_timing_v2' AS value, TRUE AS requires_schema
			UNION ALL
			SELECT document -> 'manual_timing_override' AS value, FALSE AS requires_schema
		), valid AS (
			SELECT value
			FROM timing
			WHERE jsonb_typeof(value) = 'object'
				AND NOT EXISTS (
					SELECT 1
					FROM jsonb_object_keys(value) AS key
					WHERE key NOT IN (
						'schema_version', 'bpm', 'beat_anchor_ms', 'beats_per_bar',
						'downbeat_phase_index', 'phrase_length_bars', 'confidence',
						'provenance', 'revision', 'updated_at'
					)
				)
				AND (
					(requires_schema
						AND jsonb_typeof(value -> 'schema_version') = 'number'
						AND value ->> 'schema_version' = '2')
					OR (NOT requires_schema AND (
						NOT (value ? 'schema_version')
						OR (jsonb_typeof(value -> 'schema_version') = 'number' AND value ->> 'schema_version' = '2')
					))
				)
				-- A finite decoded BPM outside the manual 30..300 range invalidates the
				-- timing document. An unparseable value is absent, matching Go decoding.
				AND (
					jsonb_typeof(value -> 'bpm') IS DISTINCT FROM 'number'
					OR (value ->> 'bpm')::numeric NOT BETWEEN -1.7976931348623157e308::numeric AND 1.7976931348623157e308::numeric
					OR (value ->> 'bpm')::numeric BETWEEN 30 AND 300
				)
				-- A finite integer anchor below zero invalidates the timing document.
				AND (
					jsonb_typeof(value -> 'beat_anchor_ms') IS DISTINCT FROM 'number'
					OR (value ->> 'beat_anchor_ms')::numeric <> trunc((value ->> 'beat_anchor_ms')::numeric)
					OR (value ->> 'beat_anchor_ms')::numeric NOT BETWEEN -9223372036854775808 AND 9223372036854775807
					OR (value ->> 'beat_anchor_ms')::numeric >= 0
				)
				-- A finite positive meter above 32 beats is rejected by the compact
				-- timing validator. Invalid/non-integer meter values decode as absent.
				AND (
					jsonb_typeof(value -> 'beats_per_bar') IS DISTINCT FROM 'number'
					OR (value ->> 'beats_per_bar')::numeric <> trunc((value ->> 'beats_per_bar')::numeric)
					OR (value ->> 'beats_per_bar')::numeric NOT BETWEEN -9223372036854775808 AND 9223372036854775807
					OR (value ->> 'beats_per_bar')::numeric <= 0
					OR (value ->> 'beats_per_bar')::numeric <= 32
				)
				-- Positive phrases over 128 bars are explicitly rejected by the compact
				-- validator. Non-integer/out-of-range values decode as absent instead.
				AND (
					jsonb_typeof(value -> 'phrase_length_bars') IS DISTINCT FROM 'number'
					OR (value ->> 'phrase_length_bars')::numeric <> trunc((value ->> 'phrase_length_bars')::numeric)
					OR (value ->> 'phrase_length_bars')::numeric NOT BETWEEN -9223372036854775808 AND 9223372036854775807
					OR (value ->> 'phrase_length_bars')::numeric <= 0
					OR (value ->> 'phrase_length_bars')::numeric <= 128
				)
				-- A decoded phase needs a decoded 1..32 meter and must lie in that
				-- meter. Invalid/non-integer phase values themselves decode as absent.
				AND (
					jsonb_typeof(value -> 'downbeat_phase_index') IS DISTINCT FROM 'number'
					OR (value ->> 'downbeat_phase_index')::numeric <> trunc((value ->> 'downbeat_phase_index')::numeric)
					OR (value ->> 'downbeat_phase_index')::numeric NOT BETWEEN 0 AND 9223372036854775807
					OR (
						jsonb_typeof(value -> 'beats_per_bar') = 'number'
						AND (value ->> 'beats_per_bar')::numeric = trunc((value ->> 'beats_per_bar')::numeric)
						AND (value ->> 'beats_per_bar')::numeric BETWEEN 1 AND 32
						AND (value ->> 'downbeat_phase_index')::numeric < (value ->> 'beats_per_bar')::numeric
					)
				)
				-- The Go decoder returns nil unless at least one timing fact survives.
				AND (
					(jsonb_typeof(value -> 'bpm') = 'number'
						AND (value ->> 'bpm')::numeric BETWEEN -1.7976931348623157e308::numeric AND 1.7976931348623157e308::numeric)
					OR (jsonb_typeof(value -> 'beat_anchor_ms') = 'number'
						AND (value ->> 'beat_anchor_ms')::numeric = trunc((value ->> 'beat_anchor_ms')::numeric)
						AND (value ->> 'beat_anchor_ms')::numeric BETWEEN 0 AND 9223372036854775807)
					OR (jsonb_typeof(value -> 'beats_per_bar') = 'number'
						AND (value ->> 'beats_per_bar')::numeric = trunc((value ->> 'beats_per_bar')::numeric)
						AND (value ->> 'beats_per_bar')::numeric BETWEEN 1 AND 32)
					OR (jsonb_typeof(value -> 'downbeat_phase_index') = 'number'
						AND (value ->> 'downbeat_phase_index')::numeric = trunc((value ->> 'downbeat_phase_index')::numeric)
						AND (value ->> 'downbeat_phase_index')::numeric BETWEEN 0 AND 9223372036854775807)
					OR (jsonb_typeof(value -> 'phrase_length_bars') = 'number'
						AND (value ->> 'phrase_length_bars')::numeric = trunc((value ->> 'phrase_length_bars')::numeric)
						AND (value ->> 'phrase_length_bars')::numeric BETWEEN 1 AND 9223372036854775807)
					OR (jsonb_typeof(value -> 'revision') = 'number'
						AND (value ->> 'revision')::numeric = trunc((value ->> 'revision')::numeric)
						AND (value ->> 'revision')::numeric BETWEEN 0 AND 9223372036854775807)
				)
			ORDER BY requires_schema DESC
			LIMIT 1
		)
		SELECT CASE
			WHEN jsonb_typeof(value -> 'bpm') = 'number'
				AND (value ->> 'bpm')::numeric BETWEEN 30 AND 300
				THEN (value ->> 'bpm')::DOUBLE PRECISION
		END
		FROM valid
	$$;

	CREATE OR REPLACE FUNCTION omp_effective_analysis_bpm(summary JSONB, overrides JSONB)
	RETURNS DOUBLE PRECISION
	LANGUAGE SQL
	IMMUTABLE
	PARALLEL SAFE
	AS $$
		SELECT COALESCE(
			omp_manual_timing_bpm(overrides),
			omp_compact_number_value(overrides, 'bpm'),
			omp_compact_number_value(summary, 'bpm')
		)
	$$;

	CREATE OR REPLACE FUNCTION omp_effective_analysis_camelot(summary JSONB, overrides JSONB)
	RETURNS TEXT
	LANGUAGE SQL
	IMMUTABLE
	PARALLEL SAFE
	AS $$
		SELECT COALESCE(
			omp_compact_camelot_value(overrides),
			omp_compact_camelot_value(summary)
		)
	$$;

	CREATE TABLE IF NOT EXISTS track_analysis (
		track_id BIGINT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
		schema_version INTEGER NOT NULL DEFAULT 1,
		status VARCHAR(32) NOT NULL DEFAULT 'pending',
		summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		overrides_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		effective_bpm DOUBLE PRECISION GENERATED ALWAYS AS (omp_effective_analysis_bpm(summary_json, overrides_json)) STORED,
		effective_camelot TEXT GENERATED ALWAYS AS (omp_effective_analysis_camelot(summary_json, overrides_json)) STORED,
		manual_override_revision BIGINT NOT NULL DEFAULT 0,
		manual_override_updated_at TIMESTAMP WITH TIME ZONE,
		artifacts_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		provenance_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		error TEXT,
		requested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		started_at TIMESTAMP WITH TIME ZONE,
		completed_at TIMESTAMP WITH TIME ZONE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_track_analysis_schema_version CHECK (schema_version >= 1),
		CONSTRAINT chk_track_analysis_manual_override_revision CHECK (manual_override_revision >= 0),
		CONSTRAINT chk_track_analysis_status CHECK (status IN ('pending', 'analyzing', 'analyzed', 'failed', 'stale', 'unsupported'))
	);
	CREATE INDEX IF NOT EXISTS idx_track_analysis_status ON track_analysis(status);
	CREATE INDEX IF NOT EXISTS idx_track_analysis_updated_at ON track_analysis(updated_at DESC);
	ALTER TABLE track_analysis ADD COLUMN IF NOT EXISTS overrides_json JSONB NOT NULL DEFAULT '{}'::jsonb;
	ALTER TABLE track_analysis ADD COLUMN IF NOT EXISTS manual_override_revision BIGINT NOT NULL DEFAULT 0;
	ALTER TABLE track_analysis ADD COLUMN IF NOT EXISTS manual_override_updated_at TIMESTAMP WITH TIME ZONE;
	ALTER TABLE track_analysis ADD COLUMN IF NOT EXISTS effective_bpm DOUBLE PRECISION GENERATED ALWAYS AS (omp_effective_analysis_bpm(summary_json, overrides_json)) STORED;
	ALTER TABLE track_analysis ADD COLUMN IF NOT EXISTS effective_camelot TEXT GENERATED ALWAYS AS (omp_effective_analysis_camelot(summary_json, overrides_json)) STORED;
	-- The composite partial index is the nearby query's hot path: Camelot is an
	-- equality candidate set and BPM is a bounded range. The scalar BPM index is
	-- retained for future BPM-only candidate generation.
	CREATE INDEX IF NOT EXISTS idx_track_analysis_effective_bpm
		ON track_analysis(effective_bpm)
		WHERE status = 'analyzed' AND effective_bpm IS NOT NULL;
	CREATE INDEX IF NOT EXISTS idx_track_analysis_effective_camelot_bpm
		ON track_analysis(effective_camelot, effective_bpm)
		WHERE status = 'analyzed' AND effective_camelot IS NOT NULL AND effective_bpm IS NOT NULL;

	-- Stem separation artifacts are deliberately NOT overloaded onto
	-- track_analysis: they have a different lifecycle, a different model
	-- identity, and a different artifact class. track_analysis stays
	-- single-writer (the analyzer); the stems service only ever writes here.
	CREATE TABLE IF NOT EXISTS track_stems (
		id BIGSERIAL PRIMARY KEY,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		channel_set VARCHAR(64) NOT NULL,
		stem_model_version VARCHAR(128) NOT NULL,
		schema_version INTEGER NOT NULL DEFAULT 1,
		status VARCHAR(32) NOT NULL DEFAULT 'pending',
		source_file_hash VARCHAR(128) NOT NULL DEFAULT '',
		source_storage_key TEXT NOT NULL DEFAULT '',
		artifacts_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		provenance_json JSONB NOT NULL DEFAULT '{}'::jsonb,
		error TEXT,
		requested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		started_at TIMESTAMP WITH TIME ZONE,
		completed_at TIMESTAMP WITH TIME ZONE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_track_stems_schema_version CHECK (schema_version >= 1),
		CONSTRAINT chk_track_stems_status CHECK (status IN ('pending', 'separating', 'ready', 'failed', 'stale')),
		CONSTRAINT uq_track_stems_identity UNIQUE (track_id, channel_set, stem_model_version)
	);
	CREATE INDEX IF NOT EXISTS idx_track_stems_status ON track_stems(status);
	CREATE INDEX IF NOT EXISTS idx_track_stems_track ON track_stems(track_id);
	CREATE INDEX IF NOT EXISTS idx_track_stems_updated_at ON track_stems(updated_at DESC);

	CREATE TABLE IF NOT EXISTS play_events (
		id BIGSERIAL PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		track_id BIGINT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
		played_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		context_type VARCHAR(32),
		context_id TEXT,
		skipped BOOLEAN NOT NULL DEFAULT FALSE
	);
	CREATE INDEX IF NOT EXISTS idx_play_events_user_played_at ON play_events(user_id, played_at DESC);
	ALTER TABLE play_events ADD COLUMN IF NOT EXISTS skipped BOOLEAN NOT NULL DEFAULT FALSE;

	-- DJ vibe pins: at most one live pin per user; upsert replaces the previous one.
	CREATE TABLE IF NOT EXISTS dj_pins (
		user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
		block_id TEXT NOT NULL,
		energy_low REAL NOT NULL,
		energy_high REAL NOT NULL,
		genres JSONB NOT NULL DEFAULT '[]',
		created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
		expires_at TIMESTAMPTZ NOT NULL
	);

	-- AcousticBrainz external-reference cache (issue #390). One row per
	-- MusicBrainz recording MBID, loaded one-time from the frozen CC0 dump by
	-- cmd/acousticbrainz-import. This is coverage REFERENCE data only — never
	-- ground truth, never an override of track_analysis (see
	-- docs/AUDIO_MIR_EVALS.md); BackfillAcousticBrainzSummary projects it only
	-- into fields the analyzer and user overrides left empty, provenance-tagged.
	CREATE TABLE IF NOT EXISTS mb_acousticbrainz (
		recording_mbid UUID PRIMARY KEY,
		bpm DOUBLE PRECISION,
		key_key TEXT,
		key_scale TEXT,
		camelot TEXT,
		source TEXT NOT NULL DEFAULT 'acousticbrainz',
		dump_revision TEXT NOT NULL DEFAULT '',
		retrieved_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_mb_acousticbrainz_bpm CHECK (
			bpm IS NULL OR bpm BETWEEN 30 AND 300
		),
		CONSTRAINT chk_mb_acousticbrainz_payload CHECK (
			bpm IS NOT NULL OR camelot IS NOT NULL
		)
	);

	-- ListenBrainz labs similar-artists cache (issue #392). Exactly ONE row per
	-- artist MBID (the primary key); payload is the verbatim labs response for
	-- that artist so candidate expansion never re-hits upstream on a cache hit.
	-- The algorithm column records which pinned algorithm produced the row: a
	-- row whose algorithm differs from the currently pinned one reads back as a
	-- cache MISS and is overwritten by the next successful fetch, rather than
	-- coexisting as a second row. Rows older than the expansion service TTL
	-- (listenbrainz.DefaultCacheTTL) are refreshed on the next read, and are
	-- served as-is with their original retrieved_at when upstream is
	-- unavailable (stale-while-error). Mirrors the mb_acousticbrainz
	-- external-reference conventions: provenance fields (algorithm,
	-- retrieved_at) travel with every row and this table is coverage data
	-- only, never an authority over library facts.
	CREATE TABLE IF NOT EXISTS mb_listenbrainz_similar_artists (
		artist_mbid UUID PRIMARY KEY,
		algorithm TEXT NOT NULL,
		payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'array'),
		retrieved_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_mb_listenbrainz_algorithm CHECK (algorithm <> '')
	);

	CREATE TABLE IF NOT EXISTS research_jobs (
		id UUID PRIMARY KEY,
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		idempotency_key VARCHAR(128) NOT NULL,
		request_hash VARCHAR(128) NOT NULL,
		request_snapshot JSONB NOT NULL,
		retry_safe BOOLEAN NOT NULL DEFAULT FALSE,
		query TEXT NOT NULL,
		providers JSONB NOT NULL,
		result_limit SMALLINT NOT NULL,
		assigned_variant VARCHAR(64) NOT NULL DEFAULT 'deterministic_only',
		variant_cohort VARCHAR(64) NOT NULL DEFAULT 'default',
		status VARCHAR(32) NOT NULL DEFAULT 'queued',
		cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
		terminal_reason VARCHAR(64),
		degradation_code VARCHAR(128),
		failure_class VARCHAR(64),
		failure_code VARCHAR(128),
		failure_message VARCHAR(2000),
		attempt_count INTEGER NOT NULL DEFAULT 0,
		max_attempts INTEGER NOT NULL DEFAULT 3,
		next_attempt_at TIMESTAMP WITH TIME ZONE,
		latest_revision_number BIGINT NOT NULL DEFAULT 0,
		event_sequence BIGINT NOT NULL DEFAULT 0,
		started_at TIMESTAMP WITH TIME ZONE,
		finished_at TIMESTAMP WITH TIME ZONE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT uq_research_jobs_id_user UNIQUE (id, user_id),
		CONSTRAINT uq_research_jobs_user_idempotency UNIQUE (user_id, idempotency_key),
		CONSTRAINT chk_research_jobs_idempotency_key CHECK (
			char_length(BTRIM(idempotency_key)) BETWEEN 1 AND 128
		),
		CONSTRAINT chk_research_jobs_request_hash CHECK (
			char_length(BTRIM(request_hash)) BETWEEN 16 AND 128
		),
		CONSTRAINT chk_research_jobs_query CHECK (
			char_length(BTRIM(query)) BETWEEN 1 AND 4096
		),
		CONSTRAINT chk_research_jobs_providers CHECK (
			jsonb_typeof(providers) = 'array'
			AND jsonb_array_length(providers) BETWEEN 1 AND 16
			AND octet_length(providers::text) <= 4096
		),
		CONSTRAINT chk_research_jobs_request_snapshot CHECK (
			jsonb_typeof(request_snapshot) = 'object'
			AND octet_length(request_snapshot::text) <= 65536
		),
		CONSTRAINT chk_research_jobs_limit CHECK (result_limit BETWEEN 1 AND 25),
		CONSTRAINT chk_research_jobs_assigned_variant CHECK (
			assigned_variant IN ('deterministic_only', 'direct_structured_judge', 'bounded_agent_dark_launch')
		),
		CONSTRAINT chk_research_jobs_variant_cohort CHECK (
			variant_cohort ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
			AND variant_cohort !~* '(token|secret|password|api[-_]?key|bearer|^sk-)'
		),
		CONSTRAINT chk_research_jobs_status CHECK (
			status IN ('queued', 'running', 'cancel_requested', 'completed', 'degraded', 'cancelled')
		),
		CONSTRAINT chk_research_jobs_terminal_reason CHECK (
			terminal_reason IS NULL OR char_length(BTRIM(terminal_reason)) BETWEEN 1 AND 64
		),
		CONSTRAINT chk_research_jobs_degradation_code CHECK (
			degradation_code IS NULL OR degradation_code IN (
				'model_disabled', 'model_unavailable', 'budget_exhausted', 'transient', 'timeout',
				'runner_terminal', 'validation_rejected', 'safety_rejected', 'enhancement_rejected', 'lease_expired', 'no_candidates'
			)
		),
		CONSTRAINT chk_research_jobs_failure_class CHECK (
			failure_class IS NULL OR failure_class IN ('transient', 'terminal', 'safety', 'validation', 'timeout')
		),
		CONSTRAINT chk_research_jobs_failure_code CHECK (
			failure_code IS NULL OR char_length(BTRIM(failure_code)) BETWEEN 1 AND 128
		),
		CONSTRAINT chk_research_jobs_failure_message CHECK (
			failure_message IS NULL OR char_length(BTRIM(failure_message)) BETWEEN 1 AND 2000
		),
		CONSTRAINT chk_research_jobs_attempts CHECK (
			attempt_count >= 0 AND max_attempts BETWEEN 1 AND 10 AND attempt_count <= max_attempts
		),
		CONSTRAINT chk_research_jobs_counters CHECK (
			latest_revision_number >= 0 AND event_sequence >= 0
		)
	);
	CREATE INDEX IF NOT EXISTS idx_research_jobs_user_created
		ON research_jobs(user_id, created_at DESC);
	CREATE INDEX IF NOT EXISTS idx_research_jobs_queued_claim
		ON research_jobs(next_attempt_at, created_at, id) WHERE status = 'queued';

	CREATE TABLE IF NOT EXISTS research_runs (
		id UUID PRIMARY KEY,
		job_id UUID NOT NULL,
		user_id UUID NOT NULL,
		attempt INTEGER NOT NULL,
		status VARCHAR(32) NOT NULL DEFAULT 'running',
		lease_owner VARCHAR(128),
		lease_token UUID,
		lease_until TIMESTAMP WITH TIME ZONE,
		last_heartbeat_at TIMESTAMP WITH TIME ZONE,
		failure_class VARCHAR(64),
		failure_code VARCHAR(128),
		retryable BOOLEAN NOT NULL DEFAULT FALSE,
		slot_released BOOLEAN NOT NULL DEFAULT FALSE,
		started_at TIMESTAMP WITH TIME ZONE,
		finished_at TIMESTAMP WITH TIME ZONE,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		terminal_telemetry JSONB,
		CONSTRAINT uq_research_runs_id_job_user UNIQUE (id, job_id, user_id),
		CONSTRAINT uq_research_runs_job_attempt UNIQUE (job_id, attempt),
		CONSTRAINT fk_research_runs_job_owner FOREIGN KEY (job_id, user_id)
			REFERENCES research_jobs(id, user_id) ON DELETE CASCADE,
		CONSTRAINT chk_research_runs_attempt CHECK (attempt >= 1),
		CONSTRAINT chk_research_runs_status CHECK (
			status IN ('running', 'completed', 'degraded', 'cancelled', 'timed_out', 'lease_lost')
		),
		CONSTRAINT chk_research_runs_lease_owner CHECK (
			lease_owner IS NULL OR char_length(BTRIM(lease_owner)) BETWEEN 1 AND 128
		),
		CONSTRAINT chk_research_runs_lease_shape CHECK (
			(lease_owner IS NULL AND lease_token IS NULL AND lease_until IS NULL)
			OR (lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_until IS NOT NULL)
		),
		CONSTRAINT chk_research_runs_failure_class CHECK (
			failure_class IS NULL OR failure_class IN ('transient', 'terminal', 'safety', 'validation', 'timeout')
		),
		CONSTRAINT chk_research_runs_failure_code CHECK (
			failure_code IS NULL OR char_length(BTRIM(failure_code)) BETWEEN 1 AND 128
		),
		CONSTRAINT chk_research_runs_terminal_telemetry CHECK (
			terminal_telemetry IS NULL OR (jsonb_typeof(terminal_telemetry) = 'object' AND octet_length(terminal_telemetry::text) <= 16384)
		)
	);
	CREATE INDEX IF NOT EXISTS idx_research_runs_job_created
		ON research_runs(job_id, created_at DESC);
	CREATE INDEX IF NOT EXISTS idx_research_runs_expired_lease
		ON research_runs(lease_until, id)
		WHERE status = 'running' AND lease_until IS NOT NULL;

	CREATE TABLE IF NOT EXISTS research_revisions (
		id UUID PRIMARY KEY,
		job_id UUID NOT NULL,
		user_id UUID NOT NULL,
		run_id UUID,
		kind VARCHAR(16) NOT NULL,
		revision_number BIGINT NOT NULL,
		stage VARCHAR(64) NOT NULL,
		candidate_snapshot JSONB NOT NULL,
		result_snapshot JSONB NOT NULL,
		provenance_snapshot JSONB NOT NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT uq_research_revisions_id_job_user UNIQUE (id, job_id, user_id),
		CONSTRAINT uq_research_revisions_job_number UNIQUE (job_id, revision_number),
		CONSTRAINT fk_research_revisions_job_owner FOREIGN KEY (job_id, user_id)
			REFERENCES research_jobs(id, user_id) ON DELETE CASCADE,
		CONSTRAINT fk_research_revisions_run_owner FOREIGN KEY (run_id, job_id, user_id)
			REFERENCES research_runs(id, job_id, user_id) ON DELETE CASCADE,
		CONSTRAINT chk_research_revisions_number CHECK (revision_number >= 1),
		CONSTRAINT chk_research_revisions_kind CHECK (kind IN ('baseline', 'enhancement')),
		CONSTRAINT chk_research_revisions_stage CHECK (stage IN ('baseline', 'direct_judge', 'deep_agent')),
		CONSTRAINT chk_research_revisions_kind_run CHECK (
			(kind = 'baseline' AND run_id IS NULL)
			OR (kind = 'enhancement' AND run_id IS NOT NULL)
		),
		CONSTRAINT chk_research_revisions_candidate_snapshot CHECK (
			jsonb_typeof(candidate_snapshot) = 'object'
			AND octet_length(candidate_snapshot::text) <= 65536
		),
		CONSTRAINT chk_research_revisions_result_snapshot CHECK (
			jsonb_typeof(result_snapshot) = 'object'
			AND octet_length(result_snapshot::text) <= 65536
		),
		CONSTRAINT chk_research_revisions_provenance_snapshot CHECK (
			jsonb_typeof(provenance_snapshot) = 'object'
			AND octet_length(provenance_snapshot::text) <= 65536
		)
	);
	CREATE INDEX IF NOT EXISTS idx_research_revisions_job_number
		ON research_revisions(job_id, revision_number DESC);

	CREATE OR REPLACE FUNCTION reject_research_revision_mutation()
	RETURNS TRIGGER AS $$
	BEGIN
		-- Permit foreign-key cascading deletes when a parent job is removed.
		IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
			RETURN OLD;
		END IF;
		RAISE EXCEPTION 'research revisions are immutable';
	END;
	$$ LANGUAGE plpgsql;
	DROP TRIGGER IF EXISTS trg_research_revisions_immutable ON research_revisions;
	CREATE TRIGGER trg_research_revisions_immutable
		BEFORE UPDATE OR DELETE ON research_revisions
		FOR EACH ROW EXECUTE FUNCTION reject_research_revision_mutation();

	CREATE TABLE IF NOT EXISTS research_events (
		id BIGSERIAL PRIMARY KEY,
		job_id UUID NOT NULL REFERENCES research_jobs(id) ON DELETE CASCADE,
		sequence BIGINT NOT NULL,
		kind VARCHAR(32) NOT NULL,
		payload JSONB NOT NULL DEFAULT '{}'::jsonb,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT uq_research_events_job_sequence UNIQUE (job_id, sequence),
		CONSTRAINT chk_research_events_sequence CHECK (sequence >= 1),
		CONSTRAINT chk_research_events_kind CHECK (
			kind IN (
				'created', 'revision_appended', 'claimed', 'lease_renewed', 'lease_recovered', 'degraded',
				'cancel_requested', 'cancelled', 'retried', 'completed', 'reviewed', 'runner_terminal'
			)
		),
		CONSTRAINT chk_research_events_payload CHECK (
			jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 16384
		)
	);
	CREATE INDEX IF NOT EXISTS idx_research_events_job_sequence
		ON research_events(job_id, sequence);

	CREATE TABLE IF NOT EXISTS research_reviews (
		id UUID PRIMARY KEY,
		job_id UUID NOT NULL,
		revision_id UUID NOT NULL,
		user_id UUID NOT NULL,
		candidate_id VARCHAR(256) NOT NULL,
		action VARCHAR(16) NOT NULL,
		reason VARCHAR(2000),
		idempotency_key VARCHAR(128) NOT NULL,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT uq_research_reviews_user_idempotency UNIQUE (user_id, idempotency_key),
		CONSTRAINT fk_research_reviews_revision_owner FOREIGN KEY (revision_id, job_id, user_id)
			REFERENCES research_revisions(id, job_id, user_id) ON DELETE CASCADE,
		CONSTRAINT chk_research_reviews_candidate_id CHECK (
			char_length(BTRIM(candidate_id)) BETWEEN 1 AND 256
		),
		CONSTRAINT chk_research_reviews_action CHECK (action IN ('accepted', 'overridden')),
		CONSTRAINT chk_research_reviews_reason CHECK (
			reason IS NULL OR char_length(BTRIM(reason)) BETWEEN 1 AND 2000
		),
		CONSTRAINT chk_research_reviews_idempotency_key CHECK (
			char_length(BTRIM(idempotency_key)) BETWEEN 1 AND 128
		)
	);
	CREATE INDEX IF NOT EXISTS idx_research_reviews_revision_created
		ON research_reviews(revision_id, created_at DESC);
	CREATE INDEX IF NOT EXISTS idx_research_reviews_user_created
		ON research_reviews(user_id, created_at DESC);
	ALTER TABLE source_selection_decisions
		ADD COLUMN IF NOT EXISTS research_review_id UUID;
	ALTER TABLE source_selection_decisions
		DROP CONSTRAINT IF EXISTS fk_source_selection_decisions_research_review;
	ALTER TABLE source_selection_decisions
		ADD CONSTRAINT fk_source_selection_decisions_research_review
		FOREIGN KEY (research_review_id) REFERENCES research_reviews(id) ON DELETE CASCADE;
	CREATE TABLE IF NOT EXISTS research_user_daily_budgets (
		user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		budget_day DATE NOT NULL,
		reserved_units BIGINT NOT NULL DEFAULT 0,
		consumed_units BIGINT NOT NULL DEFAULT 0,
		created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		PRIMARY KEY (user_id, budget_day),
		CONSTRAINT chk_research_user_daily_budgets_units CHECK (
			reserved_units >= 0 AND consumed_units >= 0
		)
	);
	CREATE INDEX IF NOT EXISTS idx_research_user_daily_budgets_day
		ON research_user_daily_budgets(budget_day, user_id);

	CREATE TABLE IF NOT EXISTS research_user_runtime_slots (
		user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
		active_run_count INTEGER NOT NULL DEFAULT 0,
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
		CONSTRAINT chk_research_user_runtime_slots_active_runs CHECK (active_run_count >= 0)
	);

	-- Single-row environment marker (issue #407). protected = TRUE means "this
	-- database holds human-owned data": automated test helpers and teardown
	-- tooling MUST refuse to truncate, drop, or restore over it.
	--
	-- The flag is flipped BY HAND on a dogfood/staging database, never by code:
	--   UPDATE omp_environment SET name = 'dogfood', protected = TRUE, updated_at = NOW();
	-- Migrate() only ever inserts the default row when it is missing, so replaying
	-- the schema on a protected database keeps protected = TRUE. Fresh and
	-- throwaway databases stay protected = FALSE and behave exactly as before.
	CREATE TABLE IF NOT EXISTS omp_environment (
		id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
		name TEXT NOT NULL DEFAULT 'unnamed',
		protected BOOLEAN NOT NULL DEFAULT FALSE,
		updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
	);
	INSERT INTO omp_environment (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

	`

	_, err = db.Exec(schema)
	if err != nil {
		return fmt.Errorf("failed to run migrations: %w", err)
	}
	if err := db.refreshTrackAnalysisStatusConstraint(); err != nil {
		return err
	}
	if err := db.refreshTrackAnalysisOverrideRevisionConstraint(); err != nil {
		return err
	}
	if err := db.refreshResearchSchemaConstraints(); err != nil {
		return err
	}
	if err := db.refreshSourceSelectionSchemaConstraints(); err != nil {
		return err
	}

	// Best-effort: enable pg_trgm for fuzzy/typo-tolerant local search. This is
	// intentionally OUTSIDE the required schema above and MUST NOT be fatal:
	// CREATE EXTENSION can require privileges (superuser) the runtime user may not
	// have. If it fails, we log it and keep TrigramEnabled false so search degrades
	// gracefully to the FTS path — the server still starts and search still works.
	db.TrigramEnabled = db.tryEnableTrigram()

	// Schema work is done: verify that the stored generated projections still agree
	// with the frozen omp_* definitions just (re)created above. Best-effort and
	// bounded; a mismatch means a function body was edited in place and deployed
	// rows are stale, which must be loud but must never block startup.
	db.logGeneratedProjectionDrift(context.Background())

	return nil
}

// refreshSourceSelectionSchemaConstraints upgrades only databases whose
// session catalog still carries the pre-neutral NOT NULL recommendation field.
// The action-matching constraint name exists in both contracts, so it is not a
// reliable upgrade signal. Existing accepted/overridden decisions remain
// readable; new discovery sessions intentionally persist no recommendation and
// record `selected`.
func (db *DB) refreshSourceSelectionSchemaConstraints() error {
	var legacySessionRecommendationRequired bool
	err := db.QueryRow(`
		SELECT is_nullable = 'NO'
		FROM information_schema.columns
		WHERE table_schema = current_schema()
			AND table_name = 'source_selection_sessions'
			AND column_name = 'recommended_candidate_id'
	`).Scan(&legacySessionRecommendationRequired)
	if err != nil {
		return fmt.Errorf("inspect source-selection legacy schema: %w", err)
	}
	if !legacySessionRecommendationRequired {
		return nil
	}

	_, err = db.Exec(`
		ALTER TABLE source_selection_sessions
			ALTER COLUMN recommended_candidate_id DROP NOT NULL;
		ALTER TABLE source_selection_sessions
			DROP CONSTRAINT IF EXISTS chk_source_selection_sessions_recommended_candidate_id;
		ALTER TABLE source_selection_sessions
			ADD CONSTRAINT chk_source_selection_sessions_recommended_candidate_id CHECK (
				recommended_candidate_id IS NULL
				OR char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
			);

		ALTER TABLE source_selection_decisions
			ALTER COLUMN recommended_candidate_id DROP NOT NULL;
		ALTER TABLE source_selection_decisions
			DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_recommended_candidate_id;
		ALTER TABLE source_selection_decisions
			ADD CONSTRAINT chk_source_selection_decisions_recommended_candidate_id CHECK (
				recommended_candidate_id IS NULL
				OR char_length(BTRIM(recommended_candidate_id)) BETWEEN 1 AND 256
			);
		ALTER TABLE source_selection_decisions
			DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_action;
		ALTER TABLE source_selection_decisions
			ADD CONSTRAINT chk_source_selection_decisions_action CHECK (
				action IN ('selected', 'accepted', 'overridden')
			);
		ALTER TABLE source_selection_decisions
			DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_action_matches_recommendation;
		ALTER TABLE source_selection_decisions
			ADD CONSTRAINT chk_source_selection_decisions_action_matches_recommendation CHECK (
				(recommended_candidate_id IS NULL AND action = 'selected')
				OR (recommended_candidate_id IS NOT NULL AND (
					(action = 'accepted' AND selected_candidate_id = recommended_candidate_id)
					OR (action = 'overridden' AND selected_candidate_id <> recommended_candidate_id)
				))
			) NOT VALID;
	`)
	if err != nil {
		return fmt.Errorf("refresh source-selection schema constraints: %w", err)
	}
	return nil
}

func (db *DB) refreshResearchSchemaConstraints() error {
	_, err := db.Exec(`
		DROP TRIGGER IF EXISTS trg_research_revisions_immutable ON research_revisions;

		ALTER TABLE research_jobs ADD COLUMN IF NOT EXISTS assigned_variant VARCHAR(64);
		ALTER TABLE research_jobs ADD COLUMN IF NOT EXISTS variant_cohort VARCHAR(64);
		UPDATE research_jobs SET assigned_variant = 'deterministic_only' WHERE assigned_variant IS NULL OR assigned_variant NOT IN ('deterministic_only', 'direct_structured_judge', 'bounded_agent_dark_launch');
		UPDATE research_jobs SET variant_cohort = 'default' WHERE variant_cohort IS NULL OR variant_cohort !~ '^[a-z0-9][a-z0-9._-]{0,63}$' OR variant_cohort ~* '(token|secret|password|api[-_]?key|bearer|^sk-)';
		ALTER TABLE research_jobs ALTER COLUMN assigned_variant SET DEFAULT 'deterministic_only';
		ALTER TABLE research_jobs ALTER COLUMN assigned_variant SET NOT NULL;
		ALTER TABLE research_jobs ALTER COLUMN variant_cohort SET DEFAULT 'default';
		ALTER TABLE research_jobs ALTER COLUMN variant_cohort SET NOT NULL;
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_assigned_variant;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_assigned_variant CHECK (
			assigned_variant IN ('deterministic_only', 'direct_structured_judge', 'bounded_agent_dark_launch')
		);
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_variant_cohort;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_variant_cohort CHECK (
			variant_cohort ~ '^[a-z0-9][a-z0-9._-]{0,63}$'
			AND variant_cohort !~* '(token|secret|password|api[-_]?key|bearer|^sk-)'
		);
		CREATE OR REPLACE FUNCTION reject_research_job_variant_mutation()
		RETURNS TRIGGER AS $$
		BEGIN
			IF NEW.assigned_variant IS DISTINCT FROM OLD.assigned_variant
				OR NEW.variant_cohort IS DISTINCT FROM OLD.variant_cohort THEN
				RAISE EXCEPTION 'research job variant assignment is immutable';
			END IF;
			RETURN NEW;
		END;
		$$ LANGUAGE plpgsql;
		DROP TRIGGER IF EXISTS trg_research_jobs_variant_immutable ON research_jobs;
		CREATE TRIGGER trg_research_jobs_variant_immutable
			BEFORE UPDATE OF assigned_variant, variant_cohort ON research_jobs
			FOR EACH ROW EXECUTE FUNCTION reject_research_job_variant_mutation();

		ALTER TABLE research_jobs ADD COLUMN IF NOT EXISTS request_snapshot JSONB;
		UPDATE research_jobs SET request_snapshot = '{}'::jsonb WHERE request_snapshot IS NULL;
		ALTER TABLE research_jobs ALTER COLUMN request_snapshot SET NOT NULL;
		ALTER TABLE research_jobs ADD COLUMN IF NOT EXISTS retry_safe BOOLEAN NOT NULL DEFAULT FALSE;
		UPDATE research_jobs
		SET status = CASE status
			WHEN 'cancelling' THEN 'cancel_requested'
			WHEN 'succeeded' THEN 'completed'
			WHEN 'failed' THEN 'degraded'
			ELSE status
		END;
		UPDATE research_jobs SET result_limit = 25 WHERE result_limit > 25;
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_request_snapshot;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_request_snapshot CHECK (
			jsonb_typeof(request_snapshot) = 'object' AND octet_length(request_snapshot::text) <= 65536
		);
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_limit;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_limit CHECK (result_limit BETWEEN 1 AND 25);
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_status;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_status CHECK (
			status IN ('queued', 'running', 'cancel_requested', 'completed', 'degraded', 'cancelled')
		);
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_degradation_code;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_degradation_code CHECK (
			degradation_code IS NULL OR degradation_code IN (
				'model_disabled', 'model_unavailable', 'budget_exhausted', 'transient', 'timeout',
				'runner_terminal', 'validation_rejected', 'safety_rejected', 'enhancement_rejected', 'lease_expired', 'no_candidates'
			)
		);
		ALTER TABLE research_jobs DROP CONSTRAINT IF EXISTS chk_research_jobs_failure_class;
		ALTER TABLE research_jobs ADD CONSTRAINT chk_research_jobs_failure_class CHECK (
			failure_class IS NULL OR failure_class IN ('transient', 'terminal', 'safety', 'validation', 'timeout')
		);

		UPDATE research_runs
		SET status = CASE status
			WHEN 'queued' THEN 'running'
			WHEN 'leased' THEN 'running'
			WHEN 'succeeded' THEN 'completed'
			WHEN 'failed' THEN 'degraded'
			ELSE status
		END;
		ALTER TABLE research_runs ALTER COLUMN status SET DEFAULT 'running';
		ALTER TABLE research_runs ADD COLUMN IF NOT EXISTS terminal_telemetry JSONB;
		ALTER TABLE research_runs DROP CONSTRAINT IF EXISTS chk_research_runs_terminal_telemetry;
		ALTER TABLE research_runs ADD CONSTRAINT chk_research_runs_terminal_telemetry CHECK (
			terminal_telemetry IS NULL OR (jsonb_typeof(terminal_telemetry) = 'object' AND octet_length(terminal_telemetry::text) <= 16384)
		);
		ALTER TABLE research_runs DROP CONSTRAINT IF EXISTS chk_research_runs_status;
		ALTER TABLE research_runs ADD CONSTRAINT chk_research_runs_status CHECK (
			status IN ('running', 'completed', 'degraded', 'cancelled', 'timed_out', 'lease_lost')
		);
		ALTER TABLE research_runs DROP CONSTRAINT IF EXISTS chk_research_runs_failure_class;
		ALTER TABLE research_runs ADD CONSTRAINT chk_research_runs_failure_class CHECK (
			failure_class IS NULL OR failure_class IN ('transient', 'terminal', 'safety', 'validation', 'timeout')
		);
		DROP INDEX IF EXISTS idx_research_runs_expired_lease;
		CREATE INDEX idx_research_runs_expired_lease
			ON research_runs(lease_until, id)
			WHERE status = 'running' AND lease_until IS NOT NULL;

		ALTER TABLE source_selection_decisions ADD COLUMN IF NOT EXISTS research_review_id UUID;
		ALTER TABLE source_selection_decisions DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_origin;
		ALTER TABLE source_selection_decisions ADD CONSTRAINT chk_source_selection_decisions_origin CHECK (
			origin IN ('discovery', 'direct_url', 'playlist_explicit', 'research')
		);
		ALTER TABLE source_selection_decisions DROP CONSTRAINT IF EXISTS chk_source_selection_decisions_research_review;
		ALTER TABLE source_selection_decisions ADD CONSTRAINT chk_source_selection_decisions_research_review CHECK (
			(origin = 'research' AND session_id IS NULL AND research_review_id IS NOT NULL)
			OR (origin <> 'research' AND research_review_id IS NULL)
		);
		ALTER TABLE source_selection_decisions DROP CONSTRAINT IF EXISTS fk_source_selection_decisions_research_review;
		ALTER TABLE source_selection_decisions ADD CONSTRAINT fk_source_selection_decisions_research_review
			FOREIGN KEY (research_review_id) REFERENCES research_reviews(id) ON DELETE CASCADE;
		CREATE UNIQUE INDEX IF NOT EXISTS idx_source_selection_decisions_one_per_research_review
			ON source_selection_decisions(research_review_id) WHERE research_review_id IS NOT NULL;

		ALTER TABLE research_revisions ADD COLUMN IF NOT EXISTS kind VARCHAR(16);
		DROP INDEX IF EXISTS uq_research_revisions_terminal_run;
		ALTER TABLE research_revisions DROP COLUMN IF EXISTS is_terminal;
		UPDATE research_revisions
		SET kind = CASE WHEN run_id IS NULL THEN 'baseline' ELSE 'enhancement' END
		WHERE kind IS NULL OR kind NOT IN ('baseline', 'enhancement');
		UPDATE research_revisions
		SET stage = CASE WHEN kind = 'baseline' THEN 'baseline' ELSE 'deep_agent' END
		WHERE stage NOT IN ('baseline', 'direct_judge', 'deep_agent');
		ALTER TABLE research_revisions ALTER COLUMN kind SET NOT NULL;
		ALTER TABLE research_revisions DROP CONSTRAINT IF EXISTS chk_research_revisions_stage;
		ALTER TABLE research_revisions ADD CONSTRAINT chk_research_revisions_stage CHECK (
			stage IN ('baseline', 'direct_judge', 'deep_agent')
		);
		ALTER TABLE research_revisions DROP CONSTRAINT IF EXISTS chk_research_revisions_kind;
		ALTER TABLE research_revisions ADD CONSTRAINT chk_research_revisions_kind CHECK (
			kind IN ('baseline', 'enhancement')
		);
		ALTER TABLE research_revisions DROP CONSTRAINT IF EXISTS chk_research_revisions_kind_run;
		ALTER TABLE research_revisions ADD CONSTRAINT chk_research_revisions_kind_run CHECK (
			(kind = 'baseline' AND run_id IS NULL)
			OR (kind = 'enhancement' AND run_id IS NOT NULL)
		);

		UPDATE research_events
		SET kind = CASE kind
			WHEN 'queued' THEN 'created'
			WHEN 'progress' THEN 'revision_appended'
			WHEN 'revision' THEN 'revision_appended'
			WHEN 'retry_scheduled' THEN 'retried'
			WHEN 'failed' THEN 'degraded'
			ELSE kind
		END;
		ALTER TABLE research_events DROP CONSTRAINT IF EXISTS chk_research_events_kind;
		ALTER TABLE research_events ADD CONSTRAINT chk_research_events_kind CHECK (
			kind IN (
				'created', 'revision_appended', 'claimed', 'lease_renewed', 'lease_recovered', 'degraded',
				'cancel_requested', 'cancelled', 'retried', 'completed', 'reviewed', 'runner_terminal'
			)
		);
		CREATE TRIGGER trg_research_revisions_immutable
			BEFORE UPDATE OR DELETE ON research_revisions
			FOR EACH ROW EXECUTE FUNCTION reject_research_revision_mutation();
	`)
	if err != nil {
		return fmt.Errorf("failed to refresh research schema constraints: %w", err)
	}
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

func (db *DB) refreshTrackAnalysisOverrideRevisionConstraint() error {
	_, err := db.Exec(`
		ALTER TABLE track_analysis DROP CONSTRAINT IF EXISTS chk_track_analysis_manual_override_revision;
		ALTER TABLE track_analysis ADD CONSTRAINT chk_track_analysis_manual_override_revision
			CHECK (manual_override_revision >= 0);
	`)
	if err != nil {
		return fmt.Errorf("failed to refresh track_analysis manual override revision constraint: %w", err)
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

// generatedProjectionProbeSampleLimit bounds the probe to a PK-ordered head sample
// so startup cost stays flat regardless of table size.
const generatedProjectionProbeSampleLimit = 1000

type generatedProjectionProbe struct {
	Table      string
	KeyColumn  string
	Column     string
	Expression string
}

// generatedProjectionProbes must list EVERY GENERATED ALWAYS ... STORED column in
// the schema above; TestGeneratedProjectionProbeCoversEveryGeneratedColumn enforces it.
var generatedProjectionProbes = []generatedProjectionProbe{
	{Table: "track_analysis", KeyColumn: "track_id", Column: "effective_bpm", Expression: "omp_effective_analysis_bpm(summary_json, overrides_json)"},
	{Table: "track_analysis", KeyColumn: "track_id", Column: "effective_camelot", Expression: "omp_effective_analysis_camelot(summary_json, overrides_json)"},
}

type generatedProjectionDriftReport struct {
	Probe            generatedProjectionProbe
	Sampled          int
	Mismatched       int
	FirstMismatchKey sql.NullInt64
	Skipped          bool  // table empty in the sampled range; nothing to compare
	Err              error // probe query failed; never fatal
}

// checkGeneratedProjectionDrift compares the stored value of every registered
// GENERATED ALWAYS ... STORED projection against a fresh evaluation of the same
// expression over a bounded, PK-ordered head sample. It exists because
// PostgreSQL does not recompute stored generated columns when CREATE OR REPLACE
// swaps the underlying function body, so an in-place edit to a frozen omp_*
// function leaves deployed rows silently stale (see the FROZEN PROJECTION
// INTERFACE block above). It returns exactly one report per registered probe, in
// order, and never returns an error: a failed probe is reported via the report's
// Err field so a diagnostic can never abort startup.
func (db *DB) checkGeneratedProjectionDrift(ctx context.Context) []generatedProjectionDriftReport {
	reports := make([]generatedProjectionDriftReport, 0, len(generatedProjectionProbes))
	for _, probe := range generatedProjectionProbes {
		report := generatedProjectionDriftReport{Probe: probe}

		// Every Sprintf input below is a compile-time constant from
		// generatedProjectionProbes -- identifiers and an SQL expression owned by
		// this file. No user data ever reaches this string, and the probe is
		// read-only (SELECT only; it never ALTERs or UPDATEs anything).
		query := fmt.Sprintf(`
			SELECT
				COUNT(*),
				COUNT(*) FILTER (WHERE stored IS DISTINCT FROM recomputed),
				MIN(sample_key) FILTER (WHERE stored IS DISTINCT FROM recomputed)
			FROM (
				SELECT %[2]s AS sample_key, %[3]s AS stored, %[4]s AS recomputed
				FROM %[1]s
				ORDER BY %[2]s
				LIMIT %[5]d
			) AS sample
		`, probe.Table, probe.KeyColumn, probe.Column, probe.Expression, generatedProjectionProbeSampleLimit)

		var sampled, mismatched int
		var firstMismatchKey sql.NullInt64
		if err := db.QueryRowContext(ctx, query).Scan(&sampled, &mismatched, &firstMismatchKey); err != nil {
			report.Err = err
			reports = append(reports, report)
			continue
		}

		report.Sampled = sampled
		report.Mismatched = mismatched
		report.FirstMismatchKey = firstMismatchKey
		// Nothing in the sampled range means nothing to compare; stay quiet rather
		// than reporting a clean result we did not actually observe.
		report.Skipped = sampled == 0
		reports = append(reports, report)
	}
	return reports
}

// logGeneratedProjectionDrift runs checkGeneratedProjectionDrift and reports the
// outcome through the package logger. Clean and empty-table startups stay silent;
// a mismatch is logged loudly with the remediation pointer. Like tryEnableTrigram
// it never returns an error, so it can never abort startup.
func (db *DB) logGeneratedProjectionDrift(ctx context.Context) {
	for _, report := range db.checkGeneratedProjectionDrift(ctx) {
		switch {
		case report.Skipped:
			// Table empty in the sampled range; nothing to say.
		case report.Err != nil:
			log.Printf("db: generated projection drift probe unavailable for %s.%s: %v",
				report.Probe.Table, report.Probe.Column, report.Err)
		case report.Mismatched > 0:
			log.Printf("db: PROJECTION DRIFT: %s.%s differs from a fresh evaluation of %s in %d of %d sampled rows (first %s=%d). A frozen omp_* function body was edited in place; PostgreSQL does not recompute stored generated columns on CREATE OR REPLACE. See the FROZEN PROJECTION INTERFACE block in internal/db/db.go and backend/internal/db/migrations/README.md for the versioned-function upgrade path.",
				report.Probe.Table,
				report.Probe.Column,
				report.Probe.Expression,
				report.Mismatched,
				report.Sampled,
				report.Probe.KeyColumn,
				report.FirstMismatchKey.Int64,
			)
		}
	}
}
