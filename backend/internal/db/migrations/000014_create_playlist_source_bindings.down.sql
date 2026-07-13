DROP INDEX IF EXISTS idx_playlist_import_items_source_entry;
ALTER TABLE IF EXISTS playlist_import_items DROP COLUMN IF EXISTS playlist_source_entry_id;
DROP TABLE IF EXISTS playlist_source_entries;
DROP TABLE IF EXISTS playlist_source_bindings;
DROP INDEX IF EXISTS idx_playlists_id_user;
