package processor

import (
	"database/sql"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

// Exercise the actual production dispatch (import repository is wired), not the
// source-repository compatibility fallback. A retired source item stays retired.
func TestManualSyncCompletionCannotResurrectRetiredSource(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	user := uuid.New()
	if _, e := database.Exec(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'fixture','x')`, user, user.String()+"@fixture.test"); e != nil {
		t.Fatal(e)
	}
	tracks := db.NewTrackRepository(database)
	track, _, err := tracks.CreateTrackFromMetadata(ctx, "Fixture", "Retired source", "Album", 10000)
	if err != nil {
		t.Fatal(err)
	}
	playlists := db.NewPlaylistRepository(database)
	playlist := &db.Playlist{UserID: user, Name: "Fixture"}
	if err = playlists.Create(ctx, playlist); err != nil {
		t.Fatal(err)
	}
	source := db.NewPlaylistSourceRepository(database)
	binding := &db.PlaylistSourceBinding{PlaylistID: playlist.ID, UserID: user, Provider: "youtube", ProviderPlaylistID: "PLworker", CanonicalURL: "https://www.youtube.com/playlist?list=PLworker", SnapshotFingerprint: sql.NullString{String: "first", Valid: true}}
	if err = source.ApplyResolvedMapping(ctx, binding, []db.ResolvedPlaylistSourceEntry{{ProviderEntryID: "held", SourceOrder: 0}}); err != nil {
		t.Fatal(err)
	}
	_, entries, err := source.LoadBinding(ctx, user, playlist.ID)
	if err != nil {
		t.Fatal(err)
	}
	repo := playlistimport.NewImportRepository(database)
	job := &playlistimport.ImportJob{ID: uuid.New(), UserID: user, PlaylistID: playlist.ID, SourceURL: binding.CanonicalURL, Status: "importing", MaxItems: 500}
	if err = repo.CreateJob(ctx, job); err != nil {
		t.Fatal(err)
	}
	item := &playlistimport.ImportItem{ImportJobID: job.ID, SourceIndex: 1, SourceID: "held", Status: "queued"}
	if err = repo.CreateItem(ctx, item); err != nil {
		t.Fatal(err)
	}
	if err = repo.AssociateItemSourceEntry(ctx, item.ID, entries[0].ID); err != nil {
		t.Fatal(err)
	}
	binding.SnapshotFingerprint = sql.NullString{String: "empty", Valid: true}
	if err = source.ApplyResolvedMapping(ctx, binding, nil); err != nil {
		t.Fatal(err)
	}
	processor := &Processor{importRepo: repo, playlistSourceRepo: source, playlistRepo: playlists}
	wire := &download.DownloadJob{PlaylistImportItemID: item.ID, PlaylistImportJobID: job.ID.String(), PlaylistID: playlist.ID}
	if err = processor.attachTrackToPlaylistIntent(ctx, wire, track.ID); err != nil {
		t.Fatal(err)
	}
	detail, err := playlists.GetByIDWithTracks(ctx, playlist.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(detail.Tracks) != 0 {
		t.Fatal("retired source membership resurrected")
	}
	var bound bool
	var link sql.NullInt64
	if err = database.QueryRow(`SELECT source_bound,playlist_source_entry_id FROM playlist_import_items WHERE id=$1`, item.ID).Scan(&bound, &link); err != nil || !bound || link.Valid {
		t.Fatal("retirement provenance lost", err)
	}
}
