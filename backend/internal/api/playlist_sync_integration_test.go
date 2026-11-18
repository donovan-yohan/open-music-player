package api

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
	redislib "github.com/redis/go-redis/v9"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/playlistimport"
	"github.com/openmusicplayer/backend/internal/playlistsync"
	"github.com/openmusicplayer/backend/internal/testutil"
)

type syncFixtureAdapter struct {
	snapshot playlistsync.Snapshot
	err      error
	calls    int
	before   func()
}

func (a *syncFixtureAdapter) Resolve(ctx context.Context, url string) (playlistsync.Snapshot, error) {
	a.calls++
	if a.before != nil {
		a.before()
	}
	return a.snapshot, a.err
}
func syncEntry(id string) playlistsync.Entry {
	return playlistsync.Entry{StableID: id, SourceURL: "https://www.youtube.com/watch?v=" + id, Metadata: playlistsync.EntryMetadata{Title: "Source " + id}}
}

func TestManualSyncPipeline(t *testing.T) {
	dsn := testutil.PostgresTestDSN()
	redisURL := os.Getenv("OMP_MANUAL_SYNC_REDIS_URL")
	if dsn == "" || redisURL == "" {
		t.Skip("explicit PostgreSQL and task-owned manual-sync Redis fixture required")
	}
	database, ctx := manualSyncTestDatabase(t, dsn)
	var err error
	tracks := db.NewTrackRepository(database)
	playlists := db.NewPlaylistRepository(database)
	sources := db.NewPlaylistSourceRepository(database)
	imports := playlistimport.NewImportRepository(database)
	ah := auth.NewService(db.NewUserRepository(database), db.NewTokenRepository(database), "synthetic-sync-secret")
	ownerAuth, e := ah.Register(ctx, "sync-owner@fixture.test", "synthetic-fixture-password", "owner")
	if e != nil {
		t.Fatal(e)
	}
	otherAuth, e := ah.Register(ctx, "sync-other@fixture.test", "synthetic-fixture-password", "other")
	if e != nil {
		t.Fatal(e)
	}
	user := uuid.MustParse(ownerAuth.User.ID)
	other := uuid.MustParse(otherAuth.User.ID)
	tokens := map[uuid.UUID]string{user: ownerAuth.AccessToken, other: otherAuth.AccessToken}
	seed := func(name string) int64 {
		v, _, e := tracks.CreateTrackFromMetadata(ctx, "Artist", name, "Album", 10000)
		if e != nil {
			t.Fatal(e)
		}
		return v.ID
	}
	a, b, m, c := seed("A"), seed("B"), seed("Manual"), seed("C")
	playlist := &db.Playlist{UserID: user, Name: "Source fixture"}
	if err = playlists.Create(ctx, playlist); err != nil {
		t.Fatal(err)
	}
	for _, id := range []int64{a, b, m} {
		if _, err = database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, user, id); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = playlists.AddTracks(ctx, playlist.ID, []int64{m}); err != nil {
		t.Fatal(err)
	}
	binding := &db.PlaylistSourceBinding{PlaylistID: playlist.ID, UserID: user, Provider: "youtube", ProviderPlaylistID: "PLfixture", CanonicalURL: "https://www.youtube.com/playlist?list=PLfixture", SnapshotFingerprint: sql.NullString{String: "initial", Valid: true}}
	if err = sources.ApplyResolvedMapping(ctx, binding, []db.ResolvedPlaylistSourceEntry{{ProviderEntryID: "a", SourceOrder: 0, TrackID: a}, {ProviderEntryID: "b", SourceOrder: 1, TrackID: b}}); err != nil {
		t.Fatal(err)
	}
	adapter := &syncFixtureAdapter{snapshot: playlistsync.Snapshot{Source: playlistsync.Source{Provider: "youtube", PlaylistID: "PLfixture", CanonicalURL: binding.CanonicalURL, Metadata: playlistsync.SourceMetadata{Title: "Fixture"}}, Complete: true, Entries: []playlistsync.Entry{syncEntry("b"), syncEntry("c"), syncEntry("b")}}}
	if redisURL == "" {
		t.Fatal("test-owned Redis fixture required")
	}
	ru, e := url.Parse(redisURL)
	if e != nil || (ru.Hostname() != "127.0.0.1" && ru.Hostname() != "localhost") || ru.Path != "/15" {
		t.Fatal("explicit loopback fixture Redis database 15 required")
	}
	opts, e := redislib.ParseURL(redisURL)
	if e != nil {
		t.Fatal(e)
	}
	redisFixture := redislib.NewClient(opts)
	defer redisFixture.Close()
	if e = redisFixture.FlushDB(ctx).Err(); e != nil {
		t.Fatal(e)
	}
	q, err := download.NewQueue(redisURL)
	if err != nil {
		t.Fatal(err)
	}
	defer q.Close()
	decisions := db.NewSourceSelectionRepository(database)
	config := playlistimport.Config{Store: imports, Playlists: playlists, Tracks: playlistimport.NewTrackSourceRepository(database), Library: db.NewLibraryRepository(database), SourceBindings: sources, SourceAdapter: adapter, Selections: decisions, Ingestion: db.NewSourceSelectionIngestion(database, decisions), Downloader: q}
	service := playlistimport.NewService(config)
	handlers := NewPlaylistImportHandlers(service)
	// Real auth middleware, production Router and synthetic registered accounts.
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(ah), AuthService: ah, PlaylistImportHandlers: handlers, PlaylistHandlers: NewPlaylistHandlers(playlists, tracks), LibraryHandlers: NewLibraryHandlers(tracks, db.NewLibraryRepository(database))})
	requestPath := func(owner uuid.UUID, method, path, body string, want int) []byte {
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer "+tokens[owner])
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("%s %s = %d want %d: %s", method, path, rec.Code, want, rec.Body.String())
		}
		return rec.Body.Bytes()
	}
	request := func(owner uuid.UUID, method, suffix, body string, want int) []byte {
		return requestPath(owner, method, fmt.Sprintf("/api/v1/playlists/%d%s", playlist.ID, suffix), body, want)
	}
	members := func(want ...int64) {
		v, e := playlists.GetByIDWithTracks(ctx, playlist.ID)
		if e != nil {
			t.Fatal(e)
		}
		ids := []int64{}
		for _, v := range v.Tracks {
			ids = append(ids, v.ID)
		}
		if !reflect.DeepEqual(ids, want) {
			t.Fatalf("members=%v want=%v", ids, want)
		}
	}
	export := func(name string, data []byte) {
		if dir := os.Getenv("OMP_SYNC_VECTORS_OUT"); dir != "" {
			if e := os.MkdirAll(dir, 0700); e != nil {
				t.Fatal(e)
			}
			if e := os.WriteFile(filepath.Join(dir, name+".json"), data, 0600); e != nil {
				t.Fatal(e)
			}
		}
	}
	export("detail-before", request(user, "GET", "", "", 200))
	export("rename-ack", request(user, "PUT", "", `{"name":"Renamed fixture","description":"","coverUrl":"","isPublic":false}`, 200))
	export("rename-before", request(user, "GET", "", "", 200))
	export("library-before", requestPath(user, "GET", "/api/v1/library?limit=20&offset=0", "", 200))
	export("eligible", request(user, "GET", "/source-sync", "", 200))
	request(other, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, uuid.NewString(), binding.ID), 403)
	if adapter.calls != 0 {
		t.Fatal("foreign request contacted provider")
	}
	key := uuid.New()
	body := fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, key, binding.ID)
	ack := request(user, "POST", "/source-sync", body, 202)
	export("ack", ack)
	if adapter.calls != 0 {
		t.Fatal("POST enumerated synchronously")
	}
	if !bytes.Equal(ack, request(user, "POST", "/source-sync", body, 202)) {
		t.Fatal("same operation did not recover exact receipt")
	}
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":0}`, key), 409)
	export("reserved", request(user, "GET", "/source-sync?operationId="+key.String(), "", 200))
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	members(b, m)
	var library int
	if err = database.QueryRow(`SELECT COUNT(*) FROM user_library WHERE user_id=$1 AND track_id=$2`, user, a).Scan(&library); err != nil || library != 1 {
		t.Fatal("removed source lost Library membership", err)
	}
	queued, err := q.Dequeue(ctx, time.Millisecond*20)
	if err != nil {
		t.Fatal(err)
	}
	if queued.SourceID != "c" {
		t.Fatalf("wrong acquisition: %+v", queued)
	}
	var downloads int
	database.QueryRow(`SELECT COUNT(*) FROM download_jobs WHERE user_id=$1`, user).Scan(&downloads)
	if downloads != 1 {
		t.Fatalf("downloads=%d", downloads)
	}
	// Process recreation consumes accepted state; it never enumerates again or queues twice.
	service = playlistimport.NewService(config)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	if adapter.calls != 1 {
		t.Fatal("accepted operation re-enumerated")
	}
	export("pending", request(user, "GET", "/source-sync?operationId="+key.String(), "", 200))
	export("detail-pending", request(user, "GET", "", "", 200))
	export("library-pending", requestPath(user, "GET", "/api/v1/library?limit=20&offset=0", "", 200))
	// A newer manual intent accepts source removal while prior acquisition is held.
	adapter.snapshot.Entries = []playlistsync.Entry{syncEntry("b")}
	next := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, next, binding.ID), 202)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	// Real producer vectors for exact superseded recovery and unqualified latest
	// status, even while the source itself has become ineligible.
	if _, err = database.Exec(`UPDATE playlist_source_bindings SET provider='fixture-unavailable' WHERE id=$1`, binding.ID); err != nil {
		t.Fatal(err)
	}
	export("superseded", request(user, "GET", "/source-sync?operationId="+key.String(), "", 200))
	export("current-ineligible", request(user, "GET", "/source-sync", "", 200))
	if _, err = database.Exec(`UPDATE playlist_source_bindings SET provider='youtube' WHERE id=$1`, binding.ID); err != nil {
		t.Fatal(err)
	}
	if err = imports.CompletePlaylistImportItem(ctx, queued.PlaylistImportItemID, c); err != nil {
		t.Fatal(err)
	}
	members(b, m)
	// Genuine legacy completion has no source claim and still appends.
	legacyJob := &playlistimport.ImportJob{ID: uuid.New(), UserID: user, PlaylistID: playlist.ID, SourceURL: binding.CanonicalURL, Status: "importing", MaxItems: 500}
	imports.CreateJob(ctx, legacyJob)
	item := &playlistimport.ImportItem{ImportJobID: legacyJob.ID, SourceIndex: 1, PlaylistPosition: 2, SourceID: "legacy", Status: "queued"}
	imports.CreateItem(ctx, item)
	if err = imports.CompletePlaylistImportItem(ctx, item.ID, c); err != nil {
		t.Fatal(err)
	}
	members(b, m, c)
	// Failure/partial and stale source cannot mutate accepted state.
	for _, mode := range []string{"partial", "private", "stale"} {
		adapter.err = nil
		adapter.snapshot.Complete = true
		adapter.before = nil
		switch mode {
		case "partial":
			adapter.snapshot.Complete = false
		case "private":
			adapter.err = errors.New("synthetic private source")
		case "stale":
			adapter.before = func() {
				database.Exec(`UPDATE playlist_source_bindings SET snapshot_generation=snapshot_generation+1 WHERE id=$1`, binding.ID)
			}
		}
		k := uuid.New()
		request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, k, binding.ID), 202)
		if _, err = service.ProcessNextSync(ctx); err != nil {
			t.Fatal(err)
		}
		members(b, m, c)
		observed, e := service.InspectSync(ctx, user, playlist.ID, k)
		if e != nil || observed.Operation == nil || observed.Operation.Accepted || observed.Operation.Status != "failed" {
			t.Fatal("failed/stale snapshot was accepted", mode, observed, e)
		}
		if mode == "stale" && observed.Operation.ErrorCode != "source_changed" {
			t.Fatal("missing stale-source outcome")
		}
	}
	adapter.before = nil
	adapter.err = nil
	adapter.snapshot.Complete = true
	adapter.snapshot.Entries = []playlistsync.Entry{}
	empty := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, empty, binding.ID), 202)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	members(m, c)
	export("complete", request(user, "GET", "/source-sync?operationId="+empty.String(), "", 200))
	export("detail-after", request(user, "GET", "", "", 200))
	// Eligible pre-binding imports recover owned URL + item evidence, not names.
	legacyPlaylist := &db.Playlist{UserID: user, Name: "Renamed local playlist"}
	if err = playlists.Create(ctx, legacyPlaylist); err != nil {
		t.Fatal(err)
	}
	playlist = legacyPlaylist
	playlists.AddTracks(ctx, playlist.ID, []int64{a, b, m})
	for i, url := range []string{"https://music.youtube.com/playlist?list=PLlegacy&index=2", "https://www.youtube.com/playlist?list=PLlegacy"} {
		j := &playlistimport.ImportJob{ID: uuid.New(), UserID: user, PlaylistID: playlist.ID, SourceURL: url, Status: "complete", MaxItems: 500}
		if err = imports.CreateJob(ctx, j); err != nil {
			t.Fatal(err)
		}
		for n, v := range []struct {
			id    string
			track int64
		}{{"a", a}, {"b", b}} {
			item := &playlistimport.ImportItem{ImportJobID: j.ID, SourceIndex: n + 1, PlaylistPosition: n, SourceID: v.id, SourceURL: "https://www.youtube.com/watch?v=" + v.id, Status: "imported", TrackID: sql.NullInt64{Int64: v.track, Valid: true}}
			if err = imports.CreateItem(ctx, item); err != nil {
				t.Fatal(i, err)
			}
			if err = imports.MarkItemImported(ctx, item.ID, v.track); err != nil {
				t.Fatal(err)
			}
		}
	}
	legacyState, err := service.InspectSync(ctx, user, playlist.ID)
	if err != nil || !legacyState.Eligible || legacyState.BindingID != 0 {
		t.Fatal("legacy eligibility", legacyState, err)
	}
	adapter.snapshot.Source.PlaylistID = "PLlegacy"
	adapter.snapshot.Source.CanonicalURL = "https://www.youtube.com/playlist?list=PLlegacy"
	adapter.snapshot.Entries = []playlistsync.Entry{syncEntry("b"), syncEntry("a")}
	adapter.snapshot.Entries[0].Metadata.Unavailable = true
	legacyKey := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":0}`, legacyKey), 202)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	members(b, a, m)
	legacyState, err = service.InspectSync(ctx, user, playlist.ID)
	if err != nil {
		t.Fatal(err)
	}
	// Complete snapshot with unavailable resolved B keeps B, while failed desired
	// D may be explicitly retried later without conflating unchanged IDs and no work.
	adapter.snapshot.Entries = []playlistsync.Entry{syncEntry("b"), syncEntry("d")}
	adapter.snapshot.Entries[1].Metadata.Unavailable = true
	unavailable := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, unavailable, legacyState.BindingID), 202)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	members(b, m)
	adapter.snapshot.Entries[1].Metadata.Unavailable = false
	retry := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, retry, legacyState.BindingID), 202)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	downloadD, err := q.Dequeue(ctx, time.Second)
	if err != nil || downloadD.SourceID != "d" {
		t.Fatal("desired failed retry", downloadD, err)
	}
	// A foreground acquisition outranks the manual sync background backlog.
	background, err := q.EnqueuePlaylistImportItemWithID(ctx, uuid.NewString(), user.String(), download.SourceCandidate{Provider: "youtube", SourceID: "background", SourceURL: "https://fixture.invalid/background", Metadata: map[string]interface{}{"manualSync": true}}, retry.String(), downloadD.PlaylistImportItemID, playlist.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	foreground, err := q.EnqueuePlaylistImportItemWithID(ctx, uuid.NewString(), user.String(), download.SourceCandidate{Provider: "youtube", SourceID: "foreground", SourceURL: "https://fixture.invalid/foreground"}, retry.String(), downloadD.PlaylistImportItemID, playlist.ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	first, err := q.Dequeue(ctx, time.Second)
	if err != nil || first.ID != foreground.ID {
		t.Fatal("foreground lost queue priority", first, err)
	}
	second, err := q.Dequeue(ctx, time.Second)
	if err != nil || second.ID != background.ID {
		t.Fatal("background lost", second, err)
	}
	// Reorder desired pending D, adopt its exact download, then complete using
	// the real production import writer's current source order.
	adapter.snapshot.Entries = []playlistsync.Entry{syncEntry("d"), syncEntry("b")}
	reorder := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, reorder, legacyState.BindingID), 202)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	d := seed("D")
	if err = imports.CompletePlaylistImportItem(ctx, downloadD.PlaylistImportItemID, d); err != nil {
		t.Fatal(err)
	}
	members(d, b, m)
	if _, err = service.ProcessNextSync(ctx); err != nil {
		t.Fatal(err)
	}
	// Preserve pre-existing binding preferences; manual intent never changes opt-in.
	if _, e = database.Exec(`UPDATE playlist_source_bindings SET sync_enabled=TRUE WHERE id=$1`, legacyState.BindingID); e != nil {
		t.Fatal(e)
	}
	// An explicit unchanged snapshot is a true membership/acquisition no-op.
	beforeBinding, beforeEntries, e := sources.LoadBinding(ctx, user, playlist.ID)
	if e != nil {
		t.Fatal(e)
	}
	var beforeDownloads int
	if e = database.QueryRow(`SELECT COUNT(*) FROM download_jobs WHERE user_id=$1`, user).Scan(&beforeDownloads); e != nil {
		t.Fatal(e)
	}
	unchanged := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, unchanged, legacyState.BindingID), 202)
	if _, e = service.ProcessNextSync(ctx); e != nil {
		t.Fatal(e)
	}
	members(d, b, m)
	unchangedState, e := service.InspectSync(ctx, user, playlist.ID, unchanged)
	if e != nil || unchangedState.Operation == nil {
		t.Fatal(e)
	}
	if op := unchangedState.Operation; op.Added != 0 || op.Removed != 0 || op.Reordered || op.Status != "complete" || op.Generation != beforeBinding.SnapshotGeneration {
		t.Fatal("unchanged operation changed accepted facts", op)
	}
	var afterDownloads int
	database.QueryRow(`SELECT COUNT(*) FROM download_jobs WHERE user_id=$1`, user).Scan(&afterDownloads)
	if afterDownloads != beforeDownloads {
		t.Fatal("unchanged snapshot duplicated acquisition")
	}
	afterBinding, afterEntries, e := sources.LoadBinding(ctx, user, playlist.ID)
	if e == nil && !afterBinding.SyncEnabled {
		t.Fatal("manual sync changed existing periodic preference")
	}
	if e != nil || len(beforeEntries) != len(afterEntries) {
		t.Fatal("unchanged source entry count changed", e)
	}
	for i, v := range beforeEntries {
		a := afterEntries[i]
		if v.ID != a.ID || v.ProviderEntryID != a.ProviderEntryID || v.TrackID != a.TrackID || v.SourceURL != a.SourceURL || v.SourceOrder != a.SourceOrder {
			t.Fatal("unchanged source entry identity/facts changed")
		}
	}
	// Same provider identity can update source URL/availability without rewriting
	// effective track metadata or original audio. Metadata policy remains separate.
	adapter.snapshot.Entries[1].SourceURL += "&feature=source-sync"
	adapter.snapshot.Entries[1].Metadata.Title = "Changed provider title"
	changed := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, changed, legacyState.BindingID), 202)
	if _, e = service.ProcessNextSync(ctx); e != nil {
		t.Fatal(e)
	}
	members(d, b, m)
	var title, sourceURL string
	database.QueryRow(`SELECT title FROM tracks WHERE id=$1`, b).Scan(&title)
	database.QueryRow(`SELECT source_url FROM playlist_source_entries WHERE source_binding_id=$1 AND provider_entry_id='b'`, legacyState.BindingID).Scan(&sourceURL)
	if title != "B" || sourceURL != adapter.snapshot.Entries[1].SourceURL {
		t.Fatal("source content/effective metadata policy violated")
	}
	// The existing composite ownership FK refuses reassignment rather than letting
	// a held source operation acquire another account's playlist. Keep that invariant.
	ownerChange := uuid.New()
	request(user, "POST", "/source-sync", fmt.Sprintf(`{"operationId":%q,"bindingId":%d}`, ownerChange, legacyState.BindingID), 202)
	adapter.before = func() {
		if _, e := database.Exec(`UPDATE playlists SET user_id=$2 WHERE id=$1`, playlist.ID, other); e == nil {
			t.Fatal("composite source owner constraint accepted reassignment")
		}
	}
	if _, e = service.ProcessNextSync(ctx); e != nil {
		t.Fatal(e)
	}
	adapter.before = nil
	members(d, b, m)
	ownerState, e := service.InspectSync(ctx, user, playlist.ID, ownerChange)
	if e != nil || ownerState.Operation == nil || !ownerState.Operation.Accepted {
		t.Fatal("legitimate owner lost after refused rewrite", e)
	}
	// Conflicting historical sources never silently select the latest URL.
	ambiguous := &db.Playlist{UserID: user, Name: "YouTube"}
	playlists.Create(ctx, ambiguous)
	for _, source := range []string{"PLone", "PLtwo"} {
		j := &playlistimport.ImportJob{ID: uuid.New(), UserID: user, PlaylistID: ambiguous.ID, SourceURL: "https://www.youtube.com/playlist?list=" + source, Status: "complete", MaxItems: 500}
		imports.CreateJob(ctx, j)
		imports.CreateItem(ctx, &playlistimport.ImportItem{ImportJobID: j.ID, SourceIndex: 1, SourceID: "a", Status: "imported", TrackID: sql.NullInt64{Int64: a, Valid: true}})
	}
	limited, err := service.InspectSync(ctx, user, ambiguous.ID)
	if err != nil || limited.Eligible || limited.Reason != "relink_required" {
		t.Fatal("ambiguous source was guessed", limited, err)
	}
	var enabled bool
	database.QueryRow(`SELECT sync_enabled FROM playlist_source_bindings WHERE id=$1`, binding.ID).Scan(&enabled)
	if enabled {
		t.Fatal("manual operation enabled periodic sync")
	}
	calls := adapter.calls
	worked, e := service.ProcessNextSync(ctx)
	if e != nil || worked || adapter.calls != calls {
		t.Fatal("stored opt-in alone started periodic source work", e)
	}
}

// Same guarded fresh-database pattern as ordinary playlist integration tests;
// never TRUNCATE the configured database shared by other Go packages.
func manualSyncTestDatabase(t *testing.T, dsn string) (*db.DB, context.Context) {
	t.Helper()
	u, err := playlistMixDatabaseURL(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(u.Path, "_test") {
		t.Fatal("explicit test-named PostgreSQL URL required")
	}
	admin, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })
	var marked bool
	if err = admin.QueryRow(`SELECT to_regclass('public.omp_environment') IS NOT NULL`).Scan(&marked); err != nil {
		t.Fatal(err)
	}
	if marked {
		if err = (&db.DB{DB: admin}).CheckDatabaseNotProtected(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	name := "sync_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err = admin.Exec("CREATE DATABASE " + pq.QuoteIdentifier(name) + " TEMPLATE template0"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, e := admin.ExecContext(ctx, "DROP DATABASE "+pq.QuoteIdentifier(name)); e != nil {
			t.Error(e)
		}
	})
	u.Path = "/" + name
	peerDSN := u.String()
	if err = db.CheckDSNNotProtected(peerDSN); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("postgres", peerDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { raw.Close() })
	database := &db.DB{DB: raw}
	if err = database.CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err = database.Migrate(); err != nil {
		t.Fatal(err)
	}
	return database, context.Background()
}
