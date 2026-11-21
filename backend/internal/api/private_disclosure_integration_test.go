package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/jam"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

type disclosureProvider struct{ queries []string }

func (p *disclosureProvider) SearchTracks(_ context.Context, q string, limit, offset int, _ bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	p.queries = append(p.queries, q)
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Limit: limit, Offset: offset}, nil
}

func TestPrivateDisclosureImportPrerequisites(t *testing.T) {
	database := privateFenceTestDB(t)
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	owner := seedMixUser(t, database, uuid.NewString()+"@example.test")
	other := seedMixUser(t, database, uuid.NewString()+"@example.test")
	track := func(title, artist string, scope, mbArtist, recording *uuid.UUID, hash string) int64 {
		t.Helper()
		var id int64
		err := database.QueryRowContext(ctx, `INSERT INTO tracks(identity_hash,title,artist,duration_ms,mb_recording_id,mb_artist_id,mb_verified,private_owner_id,storage_key,source_file_hash,file_size_bytes)
   VALUES ($1,$2,$3,20000,$4,$5,$5::uuid IS NOT NULL,$6,$7,$8,128) RETURNING id`, uuid.NewString(), title, artist, recording, mbArtist, scope, uuid.NewString(), hash).Scan(&id)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	exec := func(query string, args ...any) {
		t.Helper()
		if _, err := database.ExecContext(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	count := func(t *testing.T, want int, query string, args ...any) {
		t.Helper()
		var got int
		if err := database.QueryRowContext(ctx, query, args...).Scan(&got); err != nil || got != want {
			t.Errorf("persisted count %d want %d: %v (%s)", got, want, err, query)
		}
	}
	library, tracks, plays := db.NewLibraryRepository(database), db.NewTrackRepository(database), db.NewPlayEventRepository(database)
	playlists, plans := db.NewPlaylistRepository(database), db.NewMixPlanRepository(database)
	week := db.NewWeeklyRepository(database)
	now := time.Now().UTC()
	radarProvider, weeklyProvider := &disclosureProvider{}, &disclosureProvider{}
	radar := NewReleaseRadarHandlers(discovery.NewRadarService(plays, library, radarProvider), library, true)
	radar.now = func() time.Time { return now }
	weeklyHandler := NewWeeklyHandlers(week, weeklyProvider)
	weeklyHandler.now = func() time.Time { return now }
	secret := uuid.NewString() + uuid.NewString()
	service := auth.NewService(nil, nil, secret)
	router := NewRouterWithConfig(&RouterConfig{
		AuthService: service, AuthHandlers: auth.NewHandlers(service), LibraryHandlers: NewLibraryHandlers(tracks, library),
		PlayEventHandlers: NewPlayEventHandlers(plays, tracks), PlaylistHandlers: NewPlaylistHandlers(playlists, tracks),
		AnalysisHandlers: NewAnalysisHandlers(db.NewAnalysisRepository(database), library),
		MatcherHandlers:  matcher.NewHandler(nil, tracks), MixPlanHandlers: NewMixPlanHandlers(plans),
		MixExchangeHandlers: NewMixExchangeHandlers(plans, db.NewMixExchangeRepository(database)),
		WeeklyHandlers:      weeklyHandler, ReleaseRadarHandlers: radar,
	})
	tokens := map[uuid.UUID]string{owner: signNearbyTestToken(t, owner, secret), other: signNearbyTestToken(t, other, secret)}
	req := func(user uuid.UUID, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "/api/v1"+path, strings.NewReader(body)).WithContext(ctx)
		r.Header.Set("Authorization", "Bearer "+tokens[user])
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	status := func(t *testing.T, w *httptest.ResponseRecorder, want int) {
		t.Helper()
		if w.Code != want {
			t.Errorf("HTTP %d want %d: %s", w.Code, want, w.Body)
		}
	}
	const privateTitle = "Private disclosure fixture title"
	const privateArtist = "Private disclosure fixture artist"
	sharedArtist, hiddenArtist, sharedRecording, hiddenRecording := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	sharedHash, privateHash := "sha256:"+strings.Repeat("a", 64), "sha256:"+strings.Repeat("b", 64)
	shared := track("Shared disclosure fixture", "Shared artist", nil, &sharedArtist, &sharedRecording, sharedHash)
	hidden := track(privateTitle, privateArtist, &owner, &hiddenArtist, &hiddenRecording, privateHash)
	exec(`INSERT INTO track_analysis(track_id, status) VALUES ($1, 'analyzed')`, hidden)
	for _, id := range []int64{shared, hidden} {
		if _, err := library.AddTrackToLibrary(ctx, owner, id); err != nil {
			t.Fatal(err)
		}
	}
	const absent int64 = 9223372036854775807
	t.Run("numeric_writes_and_owned_library", func(t *testing.T) {
		for _, route := range []struct{ name, path, body string }{
			{"like", "/library/tracks/%d/like", ""}, {"play", "/me/plays", `{"trackId":%d}`}, {"skip", "/plays/skip", `{"trackId":%d}`},
		} {
			t.Run(route.name, func(t *testing.T) {
				send := func(user uuid.UUID, id int64) *httptest.ResponseRecorder {
					if route.body == "" {
						return req(user, "POST", fmt.Sprintf(route.path, id), "")
					}
					return req(user, "POST", route.path, fmt.Sprintf(route.body, id))
				}
				missing, foreign := send(other, absent), send(other, hidden)
				if missing.Code != 404 || foreign.Code != missing.Code || foreign.Body.String() != missing.Body.String() {
					t.Errorf("foreign differs from absent: %d %s vs %d %s", foreign.Code, foreign.Body, missing.Code, missing.Body)
				}
				status(t, send(owner, hidden), 201)
				status(t, send(other, shared), 201)
			})
		}
		count(t, 0, `SELECT count(*) FROM track_favorites WHERE user_id=$1 AND track_id=$2`, other, hidden)
		count(t, 0, `SELECT count(*) FROM play_events WHERE user_id=$1 AND track_id=$2`, other, hidden)
		count(t, 1, `SELECT count(*) FROM track_favorites WHERE user_id=$1 AND track_id=$2`, owner, hidden)
		count(t, 2, `SELECT count(*) FROM play_events WHERE user_id=$1 AND track_id=$2`, owner, hidden)
		for _, user := range []uuid.UUID{owner, other} {
			w := req(user, "GET", "/library?fields=id,title", "")
			status(t, w, 200)
			var page LibraryListResponse
			if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil {
				t.Fatal(err)
			}
			if user == owner {
				if page.Total != 2 || len(page.Tracks) != 2 || !strings.Contains(w.Body.String(), privateTitle) {
					t.Errorf("owner Library: %s", w.Body)
				}
			} else if page.Total != 0 || len(page.Tracks) != 0 {
				t.Errorf("foreign Library: %s", w.Body)
			}
		}
	})
	t.Run("numeric_matching_already_shared_only", func(t *testing.T) {
		for _, action := range []struct{ path, body string }{{"match", `{}`}, {"confirm-match", fmt.Sprintf(`{"recordingMbid":%q}`, hiddenRecording)}, {"link-mb", fmt.Sprintf(`{"mb_recording_id":%q}`, hiddenRecording)}} {
			for _, user := range []uuid.UUID{owner, other} {
				missing := req(user, "POST", fmt.Sprintf("/tracks/%d/%s", absent, action.path), action.body)
				private := req(user, "POST", fmt.Sprintf("/tracks/%d/%s", hidden, action.path), action.body)
				if missing.Code != 404 || private.Code != missing.Code || private.Body.String() != missing.Body.String() {
					t.Errorf("%s: %d %s vs %d %s", action.path, private.Code, private.Body, missing.Code, missing.Body)
				}
			}
		}
	})
	t.Run("url_ingest_cannot_claim_a_private_source", func(t *testing.T) {
		var identity string
		if err := database.QueryRowContext(ctx, `SELECT identity_hash FROM tracks WHERE id=$1`, hidden).Scan(&identity); err != nil {
			t.Fatal(err)
		}
		if _, err := tracks.GetByIdentityHash(ctx, identity); !errors.Is(err, db.ErrTrackNotFound) {
			t.Errorf("URL ingest identity lookup found a private row: %v", err)
		}
		sources := playlistimport.NewTrackSourceRepository(database)
		const source = "https://example.test/synthetic-source"
		if err := sources.UpsertTrackSource(ctx, hidden, "synthetic", "private", source); !errors.Is(err, db.ErrTrackNotFound) {
			t.Errorf("provider association for private track: %v", err)
		}
		count(t, 0, `SELECT count(*) FROM track_sources WHERE track_id=$1`, hidden)
		// An inconsistent provider association is still not a reusable source.
		exec(`INSERT INTO track_sources(track_id,provider,source_id,source_url) VALUES ($1,'synthetic','private',$2) ON CONFLICT DO NOTHING`, hidden, source)
		if _, err := sources.FindTrackBySource(ctx, "synthetic", "private", source); !errors.Is(err, db.ErrTrackNotFound) {
			t.Errorf("private URL reuse: %v", err)
		}
		if err := sources.UpsertTrackSource(ctx, shared, "synthetic", "shared", source); err != nil {
			t.Fatal(err)
		}
		if found, err := sources.FindTrackBySource(ctx, "synthetic", "shared", source); err != nil || found.ID != shared {
			t.Errorf("shared URL reuse: %+v %v", found, err)
		}
	})
	t.Run("playlist_and_jam_attachments", func(t *testing.T) {
		ownerList, otherList := &db.Playlist{UserID: owner, Name: "Owned playlist"}, &db.Playlist{UserID: other, Name: "Peer playlist"}
		for _, p := range []*db.Playlist{ownerList, otherList} {
			if err := playlists.Create(ctx, p); err != nil {
				t.Fatal(err)
			}
		}
		add := func(user uuid.UUID, p int64, ids ...int64) *httptest.ResponseRecorder {
			b, _ := json.Marshal(map[string]any{"trackIds": ids})
			return req(user, "POST", fmt.Sprintf("/playlists/%d/tracks", p), string(b))
		}
		status(t, add(other, otherList.ID, shared, hidden), 400)
		count(t, 0, `SELECT count(*) FROM playlist_tracks WHERE playlist_id=$1`, otherList.ID)
		// The response echoes the first unavailable caller-provided ID. A later
		// absent row must not expose whether an earlier foreign private ID exists.
		foreignFirst := add(other, otherList.ID, hidden, absent)
		status(t, foreignFirst, 400)
		if got := decodePlaylistError(t, foreignFirst); got.Message != fmt.Sprintf("track not found: %d", hidden) {
			t.Errorf("later absent ID disclosed earlier private existence: %+v", got)
		}
		status(t, add(other, otherList.ID, shared), 200)
		status(t, add(owner, ownerList.ID, hidden), 200)
		ownerPath := fmt.Sprintf("/playlists/%d", ownerList.ID)
		own := req(owner, "GET", ownerPath, "")
		status(t, own, 200)
		if !strings.Contains(own.Body.String(), privateTitle) {
			t.Errorf("owner playlist lost private track: %s", own.Body)
		}
		status(t, req(owner, "PUT", ownerPath, `{"name":"Publish private content","isPublic":true}`), 409)
		count(t, 1, `SELECT count(*) FROM playlists WHERE id=$1 AND NOT is_public`, ownerList.ID)
		publicPath := fmt.Sprintf("/playlists/%d", otherList.ID)
		status(t, req(other, "PUT", publicPath, `{"name":"Publish shared content","isPublic":true}`), 200)
		count(t, 1, `SELECT count(*) FROM playlists WHERE id=$1 AND is_public`, otherList.ID)
		publicOwner := &db.Playlist{UserID: owner, Name: "Public playlist", IsPublic: true}
		if err := playlists.Create(ctx, publicOwner); err != nil {
			t.Fatal(err)
		}
		status(t, add(owner, publicOwner.ID, hidden), 400)
		count(t, 0, `SELECT count(*) FROM playlist_tracks WHERE playlist_id=$1`, publicOwner.ID)
		status(t, req(other, "GET", ownerPath, ""), 403)
		count(t, 0, `SELECT count(*) FROM playlist_tracks WHERE playlist_id=$1 AND track_id=$2`, otherList.ID, hidden)
		repo := jam.NewRepository(database.DB)
		jamOwner := jam.Owner{UserID: owner}
		in := jam.CreateInput{JamID: uuid.New(), Proof: jam.Proof{HostDeviceID: uuid.New(), LeaseID: uuid.New(), WriterSecret: jam.NewSecret()}, TrackIDs: []int64{hidden}}
		if _, err := repo.Create(ctx, jamOwner, in); !errors.Is(err, jam.ErrDenied) {
			t.Errorf("private Jam create: %v", err)
		}
		count(t, 0, `SELECT count(*) FROM jams WHERE id=$1`, in.JamID)
		in.JamID = uuid.New()
		in.TrackIDs = []int64{shared}
		snap, err := repo.Create(ctx, jamOwner, in)
		if err != nil || len(snap.Catalog) != 1 || snap.Catalog[0].Title != "Shared disclosure fixture" {
			t.Fatalf("shared Jam create: %+v %v", snap, err)
		}
	})
	t.Run("jam_guest_heartbeat_does_not_publish_unbound_private_playback", func(t *testing.T) {
		repo := jam.NewRepository(database.DB)
		checkHost := func(host uuid.UUID, private bool) {
			t.Helper()
			// Use a separate private-bearing host so the catalog test's attempted
			// create cannot hide this defect behind an active-Jam conflict.
			if private {
				track(privateTitle, privateArtist, &host, nil, nil, privateHash)
			}
			if _, err := library.AddTrackToLibrary(ctx, host, shared); err != nil {
				t.Fatal(err)
			}
			actor := jam.Owner{UserID: host}
			in := jam.CreateInput{JamID: uuid.New(), Proof: jam.Proof{HostDeviceID: uuid.New(), LeaseID: uuid.New(), WriterSecret: jam.NewSecret()}, TrackIDs: []int64{shared}}
			if _, err := repo.Create(ctx, actor, in); err != nil {
				t.Fatal(err)
			}
			invite, err := repo.RotateInvite(ctx, actor, in.JamID, in.Proof)
			if err != nil {
				t.Fatal(err)
			}
			member := jam.JoinInput{JoinToken: invite.JoinToken, MemberSecret: jam.NewSecret(), RequestID: uuid.New(), DisplayName: "Synthetic guest"}
			if _, err := repo.Join(ctx, in.JamID, member); err != nil {
				t.Fatal(err)
			}
			label := "Shared host playback"
			if private {
				label = privateTitle
			}
			beat := jam.HeartbeatInput{Proof: in.Proof, HostSequence: 1, NowPlaying: &jam.NowPlaying{Title: label, Artist: "Metadata supplied by the old client", DurationMS: 20000, Playing: true}}
			if _, err := repo.Heartbeat(ctx, actor, in.JamID, beat); err != nil {
				t.Fatal(err)
			}
			guest, err := repo.GuestSnapshot(ctx, in.JamID, member.MemberSecret)
			if err != nil || guest.State != "open" || len(guest.Catalog) != 1 {
				t.Fatalf("guest lost shared session: %+v %v", guest, err)
			}
			if private {
				if guest.NowPlaying != nil {
					t.Errorf("legacy heartbeat published unbound private playback: %+v", guest.NowPlaying)
				}
				count(t, 1, `SELECT count(*) FROM jams WHERE id=$1 AND state->'nowPlaying' = 'null'::jsonb`, in.JamID)
			} else if guest.NowPlaying == nil || guest.NowPlaying.Title != label {
				t.Errorf("shared-only legacy playback changed: %+v", guest.NowPlaying)
			}
		}
		checkHost(seedMixUser(t, database, uuid.NewString()+"@example.test"), true)
		checkHost(seedMixUser(t, database, uuid.NewString()+"@example.test"), false)
	})
	t.Run("discovery_prelimit_counts_and_export", func(t *testing.T) {
		unresolvedShared := track("Shared unlinked", "Shared", nil, nil, nil, "sha256:"+strings.Repeat("c", 64))
		unresolvedPrivate := track("Private unlinked", "Private", &owner, nil, nil, "sha256:"+strings.Repeat("d", 64))
		// Capture a shared baseline after removing events from the numeric subtest;
		// separately seed the owner-only rows with strictly newer timestamps.
		exec(`DELETE FROM play_events WHERE user_id=$1 AND track_id=$2`, owner, hidden)
		for _, id := range []int64{unresolvedShared, unresolvedPrivate} {
			if _, err := library.AddTrackToLibrary(ctx, owner, id); err != nil {
				t.Fatal(err)
			}
		}
		exec(`INSERT INTO play_events (user_id,track_id,played_at) VALUES ($1,$2,$4),($1,$3,$4)`, owner, shared, unresolvedShared, now.Add(-time.Hour))
		exec(`INSERT INTO play_events (user_id,track_id,played_at) VALUES ($1,$2,$4),($1,$3,$4)`, owner, hidden, unresolvedPrivate, now.Add(-time.Minute))
		got, err := plays.RecentArtistSeeds(ctx, owner, now.Add(-24*time.Hour), now, 1)
		want := db.RadarSeeds{Artists: []uuid.UUID{sharedArtist}, Available: 1, Events: 2, UnresolvedTracks: 1, UnlinkedLibraryTracks: 1}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("Radar cap/counters: %+v want %+v: %v", got, want, err)
		}
		history, err := week.History(ctx, owner, now)
		labels := map[string]string{sharedArtist.String(): "Shared artist"}
		if err != nil || history.Unresolved != 1 || !reflect.DeepEqual(history.Short, labels) || !reflect.DeepEqual(history.Long, labels) {
			t.Errorf("Weekly history: %+v %v", history, err)
		}
		eligibility, err := week.Eligibility(ctx, owner, []string{sharedRecording.String(), hiddenRecording.String()}, now)
		publicOnly := map[string]bool{sharedRecording.String(): true}
		if err != nil || eligibility.UnresolvedOwned != 1 || !reflect.DeepEqual(eligibility.Owned, publicOnly) || !reflect.DeepEqual(eligibility.Recent, publicOnly) {
			t.Errorf("Weekly eligibility: %+v %v", eligibility, err)
		}
		owned, err := library.OwnedRecordingIDs(ctx, owner, []uuid.UUID{sharedRecording, hiddenRecording})
		if err != nil || !reflect.DeepEqual(owned, map[uuid.UUID]bool{sharedRecording: true}) {
			t.Errorf("Radar membership: %+v %v", owned, err)
		}
		p := req(owner, "GET", "/me/discovery/preferences", "")
		status(t, p, 200)
		var prefs struct {
			ProfileEpoch *int64 `json:"profileEpoch"`
		}
		if err := json.Unmarshal(p.Body.Bytes(), &prefs); err != nil || prefs.ProfileEpoch == nil {
			t.Fatalf("profile epoch: %s (%v)", p.Body, err)
		}
		put := func(artist uuid.UUID) *httptest.ResponseRecorder {
			return req(owner, "PUT", "/me/discovery/preferences", fmt.Sprintf(`{"resource":"artist","artistMbid":%q,"interested":true,"blocked":false,"expectedRevision":0,"profileEpoch":%d,"mutationId":%q}`, artist, *prefs.ProfileEpoch, uuid.New()))
		}
		status(t, put(hiddenArtist), 404)
		status(t, put(sharedArtist), 200)
		for _, name := range []string{"externalCatalogQueries", "learningFromServerHistory"} {
			status(t, req(owner, "PUT", "/me/discovery/preferences", fmt.Sprintf(`{"resource":"permission","permission":%q,"enabled":true,"expectedRevision":0,"profileEpoch":%d,"mutationId":%q}`, name, *prefs.ProfileEpoch, uuid.New())), 200)
		}
		status(t, req(owner, "GET", "/me/discovery/weekly", ""), 200)
		radarWire := req(owner, "GET", "/me/discovery/releases", "")
		status(t, radarWire, 200)
		for _, p := range []*disclosureProvider{radarProvider, weeklyProvider} {
			if len(p.queries) != 1 || !strings.Contains(p.queries[0], "arid:"+sharedArtist.String()) || strings.Contains(p.queries[0], hiddenArtist.String()) || strings.Contains(p.queries[0], privateArtist) {
				t.Errorf("provider dispatch not limited to the shared seed: %v", p.queries)
			}
		}
		if strings.Contains(radarWire.Body.String(), hiddenArtist.String()) {
			t.Errorf("Radar returned a private artist: %s", radarWire.Body)
		}
		x := req(owner, "GET", "/me/discovery/preferences/export", "")
		status(t, x, 200)
		if strings.Contains(x.Body.String(), privateArtist) || strings.Contains(x.Body.String(), hiddenArtist.String()) || !strings.Contains(x.Body.String(), sharedArtist.String()) || x.Header().Get("Cache-Control") != "private, no-store" {
			t.Errorf("Weekly export: %s (%v)", x.Body, x.Header())
		}
	})
	t.Run("portable_mix_only_shared", func(t *testing.T) {
		var publicDocument string
		for _, spec := range []struct {
			id   int64
			want int
		}{{shared, 200}, {hidden, 422}} {
			clip := stemContractClip("source", stemContractDocument())
			delete(clip, "stemEdits")
			clip["trackId"] = spec.id
			clip["pitchMode"] = "followTempo"
			clip["tempoPolicy"] = "constantTempoLock"
			b := stemContractJSON(t, map[string]any{"schemaVersion": 1, "name": "Owner session", "clips": []any{clip}})
			made := req(owner, "POST", "/mix-plans", string(b))
			status(t, made, 201)
			var saved MixPlanResponse
			if err := json.Unmarshal(made.Body.Bytes(), &saved); err != nil || saved.ID == uuid.Nil {
				t.Fatalf("plan: %s (%v)", made.Body, err)
			}
			path := "/mix-plans/" + saved.ID.String() + "/export"
			ex := req(owner, "GET", path, "")
			status(t, ex, spec.want)
			status(t, req(other, "GET", path, ""), 404)
			if strings.Contains(ex.Body.String(), privateHash) {
				t.Error("private source digest exported")
			}
			if spec.id == shared {
				publicDocument = ex.Body.String()
				if !strings.Contains(publicDocument, sharedHash) {
					t.Errorf("public source missing: %s", ex.Body)
				}
			}
		}
		status(t, req(owner, http.MethodPost, "/mix-plans/import", strings.ReplaceAll(publicDocument, sharedHash, privateHash)), 422)
		collision := track("Private collision", "Private", &owner, nil, nil, sharedHash)
		if _, err := library.AddTrackToLibrary(ctx, owner, collision); err != nil {
			t.Fatal(err)
		}
		status(t, req(owner, http.MethodPost, "/mix-plans/import", publicDocument), 201)
		plan := db.MixPlan{UserID: owner, SchemaVersion: 1, Name: "Invalid portable source", Payload: json.RawMessage(`{}`), Summary: json.RawMessage(`{}`)}
		err := db.NewMixExchangeRepository(database).CreateVerified(ctx, &plan, []db.MixExchangeSourceExpectation{{TrackID: hidden, SourceFileHash: privateHash, SourceEndMs: 6000}})
		if !errors.Is(err, db.ErrMixExchangeSourceMismatch) || plan.ID != uuid.Nil {
			t.Errorf("portable commit accepted owner private source: %+v %v", plan, err)
		}
		count(t, 3, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, owner)
		count(t, 0, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, other)
	})
	t.Run("inconsistent_membership_and_history_are_not_grants", func(t *testing.T) {
		if _, err := library.AddTrackToLibrary(ctx, other, shared); err != nil {
			t.Fatal(err)
		}
		if err := plays.RecordPlay(ctx, other, shared, "library", ""); err != nil {
			t.Fatal(err)
		}
		paths := []string{
			"/library?fields=id,title&limit=1", "/me/plays/history?limit=1", "/me/plays/recent?limit=1",
			"/me/plays/recent?continuation=true&limit=1&offset=0", "/me/plays/top?limit=1", "/me/plays/top?limit=1&ownedOnly=true",
		}
		before := make([]string, len(paths))
		beforeSkips, err := plays.ListSkipStats(ctx, other, 1)
		if err != nil {
			t.Fatal(err)
		}
		beforeSkipCount, err := plays.CountRecentSkips(ctx, other, time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		for i, route := range paths {
			w := req(other, "GET", route, "")
			status(t, w, 200)
			before[i] = w.Body.String()
			if !strings.Contains(before[i], "Shared disclosure fixture") {
				t.Fatalf("no shared positive row on %s: %s", route, before[i])
			}
		}
		// Simulate an inconsistent row without leaving the backstop disabled for
		// other transactions. This is only on the independently attested fixture.
		tx, err := database.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer func() {
			if err := tx.Rollback(); err != nil && !errors.Is(err, sql.ErrTxDone) {
				t.Error(err)
			}
		}()
		for _, stmt := range []struct {
			query string
			args  []any
		}{
			{query: `ALTER TABLE user_library DISABLE TRIGGER trg_user_library_visible_track`},
			{query: `INSERT INTO user_library(user_id, track_id, added_at) VALUES ($1, $2, NOW() + interval '1 hour')`, args: []any{other, hidden}},
			{query: `ALTER TABLE user_library ENABLE TRIGGER trg_user_library_visible_track`},
			{query: `INSERT INTO play_events(user_id, track_id) SELECT $1, $2 FROM generate_series(1, 4)`, args: []any{other, hidden}},
			{query: `INSERT INTO play_events(user_id, track_id, skipped) VALUES ($1, $2, true)`, args: []any{other, hidden}},
		} {
			if _, err := tx.ExecContext(ctx, stmt.query, stmt.args...); err != nil {
				t.Fatal(err)
			}
		}
		if err := tx.Commit(); err != nil {
			t.Fatal(err)
		}
		count(t, 1, `SELECT count(*) FROM user_library WHERE user_id=$1 AND track_id=$2`, other, hidden)
		count(t, 5, `SELECT count(*) FROM play_events WHERE user_id=$1 AND track_id=$2`, other, hidden)
		if got, err := plays.ListSkipStats(ctx, other, 1); err != nil || !reflect.DeepEqual(got, beforeSkips) {
			t.Errorf("foreign skip/play stats changed: %+v vs %+v: %v", got, beforeSkips, err)
		}
		if got, err := plays.CountRecentSkips(ctx, other, time.Hour); err != nil || got != beforeSkipCount {
			t.Errorf("foreign recent skip count changed: %d vs %d: %v", got, beforeSkipCount, err)
		}
		for i, route := range paths {
			w := req(other, "GET", route, "")
			if w.Code != 200 || w.Body.String() != before[i] {
				t.Errorf("foreign state changed %s: %d %s (want %s)", route, w.Code, w.Body, before[i])
			}
		}
		analysis := fmt.Sprintf("/tracks/%d/analysis", hidden)
		w, missing := req(other, "GET", analysis, ""), req(other, "GET", fmt.Sprintf("/tracks/%d/analysis", absent), "")
		if w.Code != missing.Code || w.Body.String() != missing.Body.String() {
			t.Errorf("foreign analysis differs from absent: %d %s vs %d %s", w.Code, w.Body, missing.Code, missing.Body)
		}
		status(t, req(owner, "GET", analysis, ""), 200)
	})
}
