-- Add deterministic/provider/MusicBrainz enrichment provenance fields to tracks.
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_status VARCHAR(50) NOT NULL DEFAULT 'provider';
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_confidence DOUBLE PRECISION;
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_provenance JSONB;
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS cover_art_url TEXT;
ALTER TABLE tracks ADD COLUMN IF NOT EXISTS metadata_user_edited BOOLEAN NOT NULL DEFAULT FALSE;
