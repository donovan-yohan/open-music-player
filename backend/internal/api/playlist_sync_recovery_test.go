package api

import (
	"context"
	"database/sql"
	"net/url"
	"os"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/playlistimport"
	"github.com/openmusicplayer/backend/internal/playlistsync"
	"github.com/openmusicplayer/backend/internal/testutil"
)

// Real SQL decisions, import adoption, Redis and production boot/lifecycle owner.
// Only audio acquisition is synthetic; it never opens the provider or files.
func TestManualSyncBootRecovery(t *testing.T) {
	for _, tc := range []struct {
		name                                     string
		manual, adopt, missing, retire, priority bool
	}{
		{"adopt_retained", true, true, false, false, false},
		{"adopt_missing", true, true, true, false, false},
		{"adopt_retired_missing", true, true, true, true, false},
		{"single_manual_missing_priority", true, false, true, false, true},
		{"foreground_adopt_missing", false, true, true, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dsn := testutil.PostgresTestDSN()
			redisURL := os.Getenv("OMP_MANUAL_SYNC_REDIS_URL")
			if dsn == "" || redisURL == "" {
				t.Skip("explicit owned SQL/Redis fixtures required")
			}
			u, e := url.Parse(redisURL)
			if e != nil || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost") || u.Path != "/15" {
				t.Fatal("owned loopback Redis database 15 required")
			}
			database, ctx := manualSyncTestDatabase(t, dsn)
			q, e := download.NewQueue(redisURL)
			if e != nil {
				t.Fatal(e)
			}
			defer q.Close()
			if e = q.Client().FlushDB(ctx).Err(); e != nil {
				t.Fatal(e)
			}
			owner := uuid.New()
			if _, e = database.Exec(`INSERT INTO users(id,email,username,password_hash)VALUES($1,$2,'recovery','synthetic')`, owner, owner.String()+"@fixture.test"); e != nil {
				t.Fatal(e)
			}
			tracks := db.NewTrackRepository(database)
			library := db.NewLibraryRepository(database)
			playlists := db.NewPlaylistRepository(database)
			sources := db.NewPlaylistSourceRepository(database)
			imports := playlistimport.NewImportRepository(database)
			x, _, e := tracks.CreateTrackFromMetadata(ctx, "Fixture", "Known", "Album", 10000)
			if e != nil {
				t.Fatal(e)
			}
			if _, e = library.AddTrackToLibrary(ctx, owner, x.ID); e != nil {
				t.Fatal(e)
			}
			sourceTracks := playlistimport.NewTrackSourceRepository(database)
			if e = sourceTracks.UpsertTrackSource(ctx, x.ID, "youtube", "x", "https://www.youtube.com/watch?v=x"); e != nil {
				t.Fatal(e)
			}
			p := &db.Playlist{UserID: owner, Name: "Recovery fixture"}
			if e = playlists.Create(ctx, p); e != nil {
				t.Fatal(e)
			}
			binding := &db.PlaylistSourceBinding{PlaylistID: p.ID, UserID: owner, Provider: "youtube", ProviderPlaylistID: "PLrecover", CanonicalURL: "https://www.youtube.com/playlist?list=PLrecover", SnapshotFingerprint: sql.NullString{String: "initial", Valid: true}}
			if e = sources.ApplyResolvedMapping(ctx, binding, []db.ResolvedPlaylistSourceEntry{{ProviderEntryID: "x", TrackID: x.ID, SourceOrder: 0}}); e != nil {
				t.Fatal(e)
			}
			adapter := &syncFixtureAdapter{snapshot: playlistsync.Snapshot{Source: playlistsync.Source{Provider: "youtube", PlaylistID: "PLrecover", CanonicalURL: binding.CanonicalURL}, Complete: true, Entries: []playlistsync.Entry{syncEntry("held"), syncEntry("x")}}}
			decisions := db.NewSourceSelectionRepository(database)
			cfg := playlistimport.Config{Store: imports, Playlists: playlists, Tracks: sourceTracks, Library: library, SourceBindings: sources, SourceAdapter: adapter, Selections: decisions, Ingestion: db.NewSourceSelectionIngestion(database, decisions), Downloader: q}
			service := playlistimport.NewService(cfg)
			syncNow := func() {
				t.Helper()
				if _, e := service.StartSync(ctx, owner, p.ID, binding.ID, uuid.New()); e != nil {
					t.Fatal(e)
				}
				if _, e := service.ProcessNextSync(ctx); e != nil {
					t.Fatal(e)
				}
			}
			if tc.manual {
				syncNow()
			} else {
				if _, e = service.StartImport(ctx, owner, playlistimport.ImportRequest{URL: binding.CanonicalURL, PlaylistID: &p.ID}); e != nil {
					t.Fatal(e)
				}
			}
			original, e := q.Dequeue(ctx, time.Second)
			if e != nil {
				t.Fatal(e)
			}
			if original.SourceID != "held" {
				t.Fatal("unexpected acquisition", original.SourceID)
			}
			life := db.NewSourceSelectionDownloadLifecycle(database)
			original.Status = download.StatusDownloading
			if e = life.Sync(ctx, original); e != nil {
				t.Fatal(e)
			}
			if e = q.UpdateStatus(ctx, original.ID, download.StatusDownloading, 10, ""); e != nil {
				t.Fatal(e)
			}
			if tc.adopt {
				adapter.snapshot.Entries = []playlistsync.Entry{syncEntry("x"), syncEntry("held")}
				syncNow()
			}
			var observers int
			if e = database.QueryRow(`SELECT COUNT(*) FROM playlist_import_items WHERE download_job_id=$1`, original.ID).Scan(&observers); e != nil {
				t.Fatal(e)
			}
			if tc.adopt && observers != 2 {
				t.Fatalf("adoption not reached: observers=%d", observers)
			}
			if tc.missing {
				if e = q.Client().FlushDB(ctx).Err(); e != nil {
					t.Fatal(e)
				}
			}
			selected := make(chan download.DownloadJob, 2)
			release := make(chan struct{})
			var calls atomic.Int32
			worker := func(ctx context.Context, job *download.DownloadJob, _ func(int)) error {
				calls.Add(1)
				selected <- *job
				select {
				case <-release:
				case <-ctx.Done():
					return ctx.Err()
				}
				track, _, err := tracks.CreateTrackFromMetadata(ctx, "Fixture", "Recovered", "Album", 10000)
				if err != nil {
					return err
				}
				if _, err = library.AddTrackToLibrary(ctx, owner, track.ID); err != nil {
					return err
				}
				if err = imports.CompletePlaylistImportItem(ctx, job.PlaylistImportItemID, track.ID); err != nil {
					return err
				}
				job.TrackID = &track.ID
				return nil
			}
			count := 1
			if tc.priority {
				count = 0
			}
			boot, e := download.NewService(&download.ServiceConfig{RedisURL: redisURL, WorkerCount: count, JobTimeout: 10 * time.Second}, worker, life)
			if e != nil {
				t.Fatal(e)
			}
			defer func() {
				select {
				case <-release:
				default:
					close(release)
				}
				stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if e := boot.Stop(stop); e != nil {
					t.Error(e)
				}
			}()
			// Recover twice, then use the actual server RecoverAndStart boundary.
			for i := 0; i < 2; i++ {
				n, err := life.RecoverWithPlayback(ctx, boot, nil, 10)
				if err != nil || n != 1 {
					t.Fatalf("boot recovery must return one canonical download: n=%d err=%v", n, err)
				}
			}
			if n, err := life.RecoverAndStart(ctx, boot, nil, 10); err != nil || n != 1 {
				t.Fatalf("RecoverAndStart: n=%d err=%v", n, err)
			}
			assertOwner := func(got *download.DownloadJob) {
				t.Helper()
				if got.ID != original.ID || got.UserID != original.UserID || got.PlaylistImportItemID != original.PlaylistImportItemID || got.PlaylistImportJobID != original.PlaylistImportJobID || got.PlaylistID != original.PlaylistID || got.PlaylistPosition != original.PlaylistPosition {
					t.Fatal("recovery changed canonical acquisition custody")
				}
				if (got.Metadata["manualSync"] == true) != tc.manual {
					t.Fatal("durable acquisition priority changed")
				}
			}
			if tc.priority {
				foreground, err := q.EnqueueCandidate(ctx, owner.String(), download.SourceCandidate{Provider: "youtube", SourceID: "foreground", SourceURL: "https://fixture.invalid/foreground"}, nil)
				if err != nil {
					t.Fatal(err)
				}
				first, err := q.Dequeue(ctx, time.Second)
				if err != nil || first.ID != foreground.ID {
					t.Fatal("recovered background work displaced genuine foreground admission", err)
				}
				second, err := q.Dequeue(ctx, time.Second)
				if err != nil {
					t.Fatal(err)
				}
				assertOwner(second)
				return
			}
			var got download.DownloadJob
			select {
			case got = <-selected:
			case <-time.After(3 * time.Second):
				t.Fatal("recovered real worker never started")
			}
			assertOwner(&got)
			for _, key := range []string{"download:queue", "download:queue:manual-sync"} {
				n, err := q.Client().LLen(ctx, key).Result()
				if err != nil || n != 0 {
					t.Fatal("recovery enqueued a duplicate", n, err)
				}
			}
			if tc.retire {
				adapter.snapshot.Entries = []playlistsync.Entry{syncEntry("x")}
				syncNow()
			}
			close(release)
			deadline := time.Now().Add(3 * time.Second)
			var completed *download.DownloadJob
			for time.Now().Before(deadline) {
				completed, e = q.GetJob(ctx, original.ID)
				if e == nil && completed.IsTerminal() {
					break
				}
				time.Sleep(5 * time.Millisecond)
			}
			if completed == nil || completed.Status != download.StatusComplete || calls.Load() != 1 {
				t.Fatalf("canonical worker completion: status=%v calls=%d err=%v", completed, calls.Load(), e)
			}
			detail, e := playlists.GetByIDWithTracks(ctx, p.ID)
			if e != nil {
				t.Fatal(e)
			}
			ids := []int64{}
			for _, v := range detail.Tracks {
				ids = append(ids, v.ID)
			}
			want := []int64{x.ID}
			if !tc.retire {
				if tc.adopt {
					want = append(want, *completed.TrackID)
				} else {
					want = []int64{*completed.TrackID, x.ID}
				}
			}
			if !reflect.DeepEqual(ids, want) {
				t.Fatal("recovered completion ignored current source desire/order", ids, want)
			}
			var status string
			if e = database.QueryRow(`SELECT status FROM download_jobs WHERE id=$1`, original.ID).Scan(&status); e != nil || status != "complete" {
				t.Fatal("actual lifecycle did not commit completion", status, e)
			}
		})
	}
}
