package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"
)

func TestWeeklyResetPreservesFactualAndOriginalReferences(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	page := f.ok("GET", "weekly", nil, "")
	f.vote(weeklyRecordingA, "up", page["batchId"], "")
	var track, playlist int64
	if e := f.database.QueryRow(`SELECT track_id FROM user_library WHERE user_id=$1 ORDER BY track_id LIMIT 1`, f.user).Scan(&track); e != nil {
		t.Fatal(e)
	}
	f.sql(`UPDATE tracks SET storage_key='synthetic/unopened-original',source_file_hash='synthetic-original-reference' WHERE id=$1`, track)
	f.sql(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,$3)`, f.user, track, f.now)
	f.sql(`INSERT INTO track_favorites(user_id,track_id) VALUES($1,$2)`, f.user, track)
	if e := f.database.QueryRow(`INSERT INTO playlists(user_id,name) VALUES($1,'Synthetic preservation') RETURNING id`, f.user).Scan(&playlist); e != nil {
		t.Fatal(e)
	}
	f.sql(`INSERT INTO playlist_tracks(playlist_id,track_id,position) VALUES($1,$2,0)`, playlist, track)
	f.sql(`INSERT INTO download_jobs(id,user_id,track_id,url,source_type,status) VALUES($1,$2,$3,'https://fixture.invalid/unopened','synthetic','queued')`, uuid.New(), f.user, track)
	tables := []string{"tracks", "user_library", "play_events", "track_favorites", "playlists", "playlist_tracks", "download_jobs", "track_sources"}
	snapshot := func() map[string]string {
		out := map[string]string{}
		for _, table := range tables {
			var b string
			if e := f.database.QueryRow(fmt.Sprintf(`SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb)::text FROM %s t`, table)).Scan(&b); e != nil {
				t.Fatal(e)
			}
			sum := sha256.Sum256([]byte(b))
			out[table] = hex.EncodeToString(sum[:])
		}
		return out
	}
	before := snapshot()
	p := f.ok("GET", "preferences", nil, "")
	f.ok("POST", "preferences/reset", map[string]any{"mutationId": uuid.NewString(), "expectedRevision": p["preferenceRevision"], "profileEpoch": p["profileEpoch"], "scope": "discovery_preferences"}, "")
	after := snapshot()
	for _, table := range tables {
		if before[table] != after[table] {
			t.Fatal("reset changed protected synthetic state", table)
		}
	}
	if dir := os.Getenv("SOUNDQ_WEEKLY_WIRE_DIR"); dir != "" {
		b, _ := json.MarshalIndent(map[string]any{"before": before, "after": after, "identical": true, "scope": "synthetic relational state; original references only, no original bytes opened or deleted"}, "", "  ")
		if e := os.WriteFile(filepath.Join(filepath.Dir(dir), "reset-preservation.json"), b, 0600); e != nil {
			t.Fatal(e)
		}
	}
}
