package api

import (
	"bytes"
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

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// Resolve real recipient sources, then commit a concurrent replacement before
// the handler reaches plan creation. In particular a clip without stem edits
// must not lose its portable hash merely because saved clips store track IDs.
func TestMixExchangePostgresImportRejectsSourceChangedAfterResolution(t *testing.T) {
	for _, withStems := range []bool{false, true} {
		for _, mutation := range []string{"hash", "ownership", "duration", "duplicate membership", "duplicate hash"} {
			t.Run(fmt.Sprintf("stems=%t/%s", withStems, mutation), func(t *testing.T) {
				database, ctx := newPlaylistMixTestDB(t)
				user := seedMixUser(t, database, "exchange-race@example.test")
				track := seedMixTrack(t, db.NewTrackRepository(database), ctx, "Race source", 20000)
				other := seedMixTrack(t, db.NewTrackRepository(database), ctx, "Other source", 20000)
				hash := exchangeSource().SourceFileHash
				if _, err := database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, hash, track); err != nil {
					t.Fatal(err)
				}
				library := db.NewLibraryRepository(database)
				if _, err := library.AddTrackToLibrary(ctx, user, track); err != nil {
					t.Fatal(err)
				}
				if mutation == "duplicate hash" {
					if _, err := library.AddTrackToLibrary(ctx, user, other); err != nil {
						t.Fatal(err)
					}
				}
				sources := &exchangeMutatingSources{MixExchangeRepository: db.NewMixExchangeRepository(database), afterResolve: func() {
					var err error
					switch mutation {
					case "hash":
						_, err = database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, "sha256:"+strings.Repeat("b", 64), track)
					case "ownership":
						_, err = database.ExecContext(ctx, `DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, user, track)
					case "duration":
						_, err = database.ExecContext(ctx, `UPDATE tracks SET duration_ms=5999 WHERE id=$1`, track)
					case "duplicate membership":
						_, err = database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, hash, other)
						if err == nil {
							_, err = library.AddTrackToLibrary(ctx, user, other)
						}
					case "duplicate hash":
						_, err = database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, hash, other)
					}
					if err != nil {
						t.Fatal(err)
					}
				}}
				document := exchangeFixture(t)
				if !withStems {
					delete(document["clips"].([]any)[0].(map[string]any), "stemEdits")
				}
				w := httptest.NewRecorder()
				NewMixExchangeHandlers(db.NewMixPlanRepository(database), sources).ImportMixPlan(w, authedRequest(user, "POST", "/import", stemContractJSON(t, document)))
				if w.Code != 422 || !strings.Contains(w.Body.String(), `"SOURCE_MISMATCH"`) {
					t.Fatalf("stale source identity admitted: %d %s", w.Code, w.Body.String())
				}
				var count int
				if err := database.QueryRowContext(ctx, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, user).Scan(&count); err != nil || count != 0 {
					t.Fatalf("rejected source race wrote plans: %d %v", count, err)
				}
				wantAccess := 1
				if mutation == "ownership" {
					wantAccess = 0
				} else if strings.HasPrefix(mutation, "duplicate") {
					wantAccess = 2
				}
				if err := database.QueryRowContext(ctx, `SELECT count(*) FROM user_library WHERE user_id=$1`, user).Scan(&count); err != nil || count != wantAccess {
					t.Fatalf("import changed audio access: %d %v", count, err)
				}
			})
		}
	}
}

type exchangeMutatingSources struct {
	*db.MixExchangeRepository
	afterResolve func()
}

func (s *exchangeMutatingSources) FindSourcesByHashes(ctx context.Context, user uuid.UUID, hashes []string) ([]db.MixExchangeSource, error) {
	rows, err := s.MixExchangeRepository.FindSourcesByHashes(ctx, user, hashes)
	if err == nil {
		s.afterResolve()
	}
	return rows, err
}

func TestMixExchangePostgresAuthenticatedRoundTrip(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	owner := seedMixUser(t, database, "exchange-owner@example.test")
	recipient := seedMixUser(t, database, "exchange-recipient@example.test")
	track := seedMixTrack(t, db.NewTrackRepository(database), ctx, "Portable source", 20000)
	hash := "sha256:" + strings.Repeat("a", 64)
	if _, err := database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1, storage_key='private/source.opus' WHERE id=$2`, hash, track); err != nil {
		t.Fatal(err)
	}
	library := db.NewLibraryRepository(database)
	if _, err := library.AddTrackToLibrary(ctx, owner, track); err != nil {
		t.Fatal(err)
	}
	plans := db.NewMixPlanRepository(database)
	editsA, editsB := stemContractDocument(), stemContractDocument()
	editsB["events"] = []any{map[string]any{"channel": "vocals", "atMs": 3500, "gain": 0.4, "rampMs": 8}}
	a, b := stemContractClip("first", editsA), stemContractClip("repeat", editsB)
	for _, clip := range []map[string]any{a, b} {
		clip["trackId"] = track
		clip["tempoPolicy"] = "constantTempoLock"
		clip["pitchMode"] = "followTempo"
		clip["fadeInMs"] = 200
		clip["fadeOutMs"] = 300
	}
	b["timelineStartMs"] = 6000
	create := httptest.NewRecorder()
	NewMixPlanHandlers(plans).CreateMixPlan(create, authedRequest(owner, http.MethodPost, "/mix-plans", stemContractJSON(t, map[string]any{"schemaVersion": 1, "name": "Été — performance", "clips": []any{a, b}})))
	if create.Code != http.StatusCreated {
		t.Fatalf("seed plan: %d %s", create.Code, create.Body.String())
	}
	var original MixPlanResponse
	if err := json.Unmarshal(create.Body.Bytes(), &original); err != nil {
		t.Fatal(err)
	}
	const secret = "mix-exchange-test-secret"
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(nil), AuthService: auth.NewService(nil, nil, secret), MixExchangeHandlers: NewMixExchangeHandlers(plans, db.NewMixExchangeRepository(database))})
	request := func(user uuid.UUID, method, path string, body []byte) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, bytes.NewReader(body))
		if user != uuid.Nil {
			req.Header.Set("Authorization", "Bearer "+signNearbyTestToken(t, user, secret))
		}
		response := httptest.NewRecorder()
		router.ServeHTTP(response, req)
		return response
	}
	exportPath := "/api/v1/mix-plans/" + original.ID.String() + "/export"
	for _, check := range []struct {
		user         uuid.UUID
		method, path string
		status       int
	}{{uuid.Nil, "GET", exportPath, 401}, {recipient, "GET", exportPath, 404}, {uuid.Nil, "POST", "/api/v1/mix-plans/import", 401}} {
		got := request(check.user, check.method, check.path, nil)
		if got.Code != check.status {
			t.Fatalf("auth: %d %s", got.Code, got.Body.String())
		}
	}
	exported := request(owner, "GET", exportPath, nil)
	if exported.Code != 200 {
		t.Fatalf("export: %d %s", exported.Code, exported.Body.String())
	}
	if exported.Header().Get("Content-Type") != "application/json" || exported.Header().Get("Content-Disposition") != `attachment; filename="soundq-mix.json"` {
		t.Fatalf("export headers: %v", exported.Header())
	}
	portable := stemContractObject(t, exported.Body.Bytes())
	if portable["format"] != "soundq-mix" || portable["version"] != float64(1) {
		t.Fatalf("portable envelope: %v", portable)
	}
	for _, private := range []string{`"trackId"`, `"userId"`, `"id"`, `"updatedAt"`, `"createdAt"`, `"storageKey"`, `private/source.opus`, `"url"`, `"token"`} {
		if strings.Contains(exported.Body.String(), private) {
			t.Fatalf("private field/value leaked: %s", private)
		}
	}
	missing := request(recipient, "POST", "/api/v1/mix-plans/import", exported.Body.Bytes())
	if missing.Code != 422 || !strings.Contains(missing.Body.String(), `"MISSING_SOURCES"`) {
		t.Fatalf("missing: %d %s", missing.Code, missing.Body.String())
	}
	missingObject := stemContractObject(t, missing.Body.Bytes())
	missingHashes, ok := missingObject["missingSourceHashes"].([]any)
	if !ok || len(missingHashes) != 1 || missingHashes[0] != hash {
		t.Fatalf("missing sources must be unique caller-provided hashes: %v", missingObject)
	}
	var count int
	if err := database.QueryRowContext(ctx, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, recipient).Scan(&count); err != nil || count != 0 {
		t.Fatalf("rejected import wrote a plan: %d %v", count, err)
	}
	if err := database.QueryRowContext(ctx, `SELECT count(*) FROM user_library WHERE user_id=$1`, recipient).Scan(&count); err != nil || count != 0 {
		t.Fatalf("import granted audio: %d %v", count, err)
	}
	if _, err := library.AddTrackToLibrary(ctx, recipient, track); err != nil {
		t.Fatal(err)
	}
	imported := request(recipient, "POST", "/api/v1/mix-plans/import", exported.Body.Bytes())
	if imported.Code != 201 {
		t.Fatalf("import: %d %s", imported.Code, imported.Body.String())
	}
	var result MixPlanResponse
	if err := json.Unmarshal(imported.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if result.ID == original.ID || result.Version != 1 || !reflect.DeepEqual(original.Clips, result.Clips) {
		t.Fatalf("performance changed: original=%+v imported=%+v", original, result)
	}
	stored, err := plans.GetByIDForUser(ctx, recipient, result.ID)
	if err != nil {
		t.Fatal(err)
	}
	assertStemContractClips(t, stored.Payload, map[string]any{"first": editsA, "repeat": editsB})
	reexported := request(recipient, "GET", "/api/v1/mix-plans/"+result.ID.String()+"/export", nil)
	if reexported.Code != 200 || !reflect.DeepEqual(portable, stemContractObject(t, reexported.Body.Bytes())) {
		t.Fatalf("portable round trip changed: %d %s", reexported.Code, reexported.Body.String())
	}
	if _, err := plans.GetByIDForUser(ctx, owner, result.ID); err != db.ErrMixPlanNotFound {
		t.Fatalf("new owner isolation: %v", err)
	}
	// Rejection stays atomic through the actual HTTP router and database.
	fiveClips := make([]any, 0, 5)
	for i := 0; i < 5; i++ {
		clip := exchangeFixture(t)["clips"].([]any)[0].(map[string]any)
		clip["clipId"], clip["queueItemId"] = fmt.Sprint(i), fmt.Sprint(i)
		fiveClips = append(fiveClips, clip)
	}
	five := request(recipient, "POST", "/api/v1/mix-plans/import", stemContractJSON(t, map[string]any{"format": "soundq-mix", "version": 1, "name": "Invalid five", "clips": fiveClips}))
	if five.Code != 400 {
		t.Fatalf("fifth overlapping instance admitted: %d %s", five.Code, five.Body.String())
	}
	if err := database.QueryRowContext(ctx, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, recipient).Scan(&count); err != nil || count != 1 {
		t.Fatalf("capacity rejection wrote a plan: %d %v", count, err)
	}
	duplicate := seedMixTrack(t, db.NewTrackRepository(database), ctx, "Duplicate byte source", 20000)
	if _, err := database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, hash, duplicate); err != nil {
		t.Fatal(err)
	}
	if _, err := library.AddTrackToLibrary(ctx, recipient, duplicate); err != nil {
		t.Fatal(err)
	}
	ambiguous := request(recipient, "POST", "/api/v1/mix-plans/import", exported.Body.Bytes())
	if ambiguous.Code != 422 || !strings.Contains(ambiguous.Body.String(), "AMBIGUOUS_SOURCE") {
		t.Fatalf("real ambiguous import: %d %s", ambiguous.Code, ambiguous.Body.String())
	}
	if err := database.QueryRowContext(ctx, `SELECT count(*) FROM mix_plans WHERE user_id=$1`, recipient).Scan(&count); err != nil || count != 1 {
		t.Fatalf("ambiguous import wrote a plan: %d %v", count, err)
	}
	if _, err := database.ExecContext(ctx, `UPDATE tracks SET source_file_hash=$1 WHERE id=$2`, "sha256:"+strings.Repeat("b", 64), track); err != nil {
		t.Fatal(err)
	}
	stale := request(owner, "GET", exportPath, nil)
	if stale.Code != 422 {
		t.Fatalf("stale stem identity exported: %d %s", stale.Code, stale.Body.String())
	}
}

func TestMixExchangeExportRefusesUnknownOrMismatchedSavedMetadata(t *testing.T) {
	base := map[string]any{"schemaVersion": 1, "name": "Saved", "clips": []any{stemContractClip("instance", stemContractDocument())}}
	encoded := string(stemContractJSON(t, base))
	mutations := map[string]string{
		"top extension":    strings.Replace(encoded, `"schemaVersion":1`, `"future":true,"schemaVersion":1`, 1),
		"clip extension":   strings.Replace(encoded, `"gainDb"`, `"url":"https://secret.example/","gainDb"`, 1),
		"stem extension":   strings.Replace(encoded, `"channelSet"`, `"future":true,"channelSet"`, 1),
		"duplicate timing": strings.Replace(encoded, `"sourceEndMs":6000`, `"sourceEndMs":6000,"sourceEndMs":5000`, 1),
		"timing alias":     strings.Replace(encoded, `"sourceEndMs"`, `"SourceEndMs"`, 1),
		"nested case":      strings.Replace(encoded, `"atMs"`, `"AtMs"`, 1),
		"null edits":       strings.Replace(encoded, `"stemEdits":{`, `"stemEdits":null,"future":{`, 1),
	}
	for name, body := range mutations {
		t.Run(name, func(t *testing.T) {
			if body == encoded {
				t.Fatal("saved fixture mutation did not apply")
			}
			store := &fakeMixPlanStore{getPlan: &db.MixPlan{Payload: []byte(body)}}
			sources := &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{exchangeSource()}}
			w := httptest.NewRecorder()
			req := authedRequest(uuid.New(), "GET", "/export", nil)
			req.SetPathValue("id", uuid.NewString())
			NewMixExchangeHandlers(store, sources).ExportMixPlan(w, req)
			if w.Code != 422 || sources.calls != 0 {
				t.Fatalf("unknown saved metadata silently dropped: %d %s", w.Code, w.Body.String())
			}
		})
	}
	for _, c := range []struct {
		name   string
		source db.MixExchangeSource
	}{
		{"unknown hash", db.MixExchangeSource{TrackID: 42}},
		{"not owned", exchangeSource()},
		{"stem mismatch", db.MixExchangeSource{TrackID: 42, SourceFileHash: "sha256:" + strings.Repeat("b", 64)}},
		{"beyond source end", db.MixExchangeSource{TrackID: 42, SourceFileHash: exchangeSource().SourceFileHash, DurationMs: sql.NullInt64{Int64: 5999, Valid: true}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			store := &fakeMixPlanStore{getPlan: &db.MixPlan{Payload: []byte(encoded)}}
			w := httptest.NewRecorder()
			req := authedRequest(uuid.New(), "GET", "/export", nil)
			req.SetPathValue("id", uuid.NewString())
			NewMixExchangeHandlers(store, &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{c.source}}).ExportMixPlan(w, req)
			if w.Code != 422 {
				t.Fatalf("unverified source exported: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestMixExchangeImportRemapsRecipientIDsAndPreservesMissingDuration(t *testing.T) {
	for _, duration := range []sql.NullInt64{{}, {Int64: 6000, Valid: true}} {
		t.Run(fmt.Sprint(duration), func(t *testing.T) {
			store := &fakeMixPlanStore{}
			source := exchangeSource()
			source.DurationMs = duration
			sources := &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{source}}
			user := uuid.New()
			w := httptest.NewRecorder()
			NewMixExchangeHandlers(store, sources).ImportMixPlan(w, authedRequest(user, "POST", "/import", stemContractJSON(t, exchangeFixture(t))))
			if w.Code != 201 || store.created == nil || store.created.UserID != user || sources.user != user {
				t.Fatalf("import: %d %s", w.Code, w.Body.String())
			}
			var payload MixPlanPayload
			if err := json.Unmarshal(store.created.Payload, &payload); err != nil {
				t.Fatal(err)
			}
			if len(payload.Clips) != 1 || payload.Clips[0].TrackID != 77 || payload.Clips[0].SourceEndMs != 6000 || payload.Clips[0].TempoPolicy != mixTempoConstantLock {
				t.Fatalf("resolved performance: %+v", payload)
			}
		})
	}
}

type exchangeFakeSources struct {
	store     *fakeMixPlanStore
	createErr error
	rows      []db.MixExchangeSource
	err       error
	user      uuid.UUID
	calls     int
}

func (s *exchangeFakeSources) CreateVerified(ctx context.Context, plan *db.MixPlan, expected []db.MixExchangeSourceExpectation) error {
	if s.createErr != nil {
		return s.createErr
	}
	if s.store == nil || len(expected) == 0 {
		return errors.New("test must explicitly configure the verified create port")
	}
	for _, want := range expected {
		var matches []db.MixExchangeSource
		for _, source := range s.rows {
			if source.SourceFileHash == want.SourceFileHash {
				matches = append(matches, source)
			}
		}
		if len(matches) != 1 || matches[0].TrackID != want.TrackID || (matches[0].DurationMs.Valid && matches[0].DurationMs.Int64 > 0 && matches[0].DurationMs.Int64 < want.SourceEndMs) {
			return db.ErrMixExchangeSourceMismatch
		}
	}
	return s.store.Create(ctx, plan)
}

func (s *exchangeFakeSources) FindSourcesByHashes(_ context.Context, user uuid.UUID, _ []string) ([]db.MixExchangeSource, error) {
	s.user = user
	s.calls++
	return s.rows, s.err
}
func (s *exchangeFakeSources) FindSourcesByTrackIDs(_ context.Context, user uuid.UUID, _ []int64) ([]db.MixExchangeSource, error) {
	s.user = user
	s.calls++
	return s.rows, s.err
}
func exchangeFixture(t *testing.T) map[string]any {
	t.Helper()
	clip := stemContractClip("instance", stemContractDocument())
	delete(clip, "trackId")
	clip["sourceFileHash"] = "sha256:" + strings.Repeat("a", 64)
	clip["pitchMode"] = "followTempo"
	clip["tempoPolicy"] = "constantTempoLock"
	return map[string]any{"format": "soundq-mix", "version": 1, "name": "Portable performance", "clips": []any{clip}}
}
func exchangeSource() db.MixExchangeSource {
	return db.MixExchangeSource{TrackID: 77, SourceFileHash: "sha256:" + strings.Repeat("a", 64), DurationMs: sql.NullInt64{Int64: 20000, Valid: true}}
}

func TestMixExchangeExportRejectsUnsupportedSavedPitchWithoutRewriting(t *testing.T) {
	clip := stemContractClip("instance", stemContractDocument())
	clip["pitchMode"] = "future-granular"
	store := &fakeMixPlanStore{getPlan: &db.MixPlan{Payload: stemContractJSON(t, map[string]any{"schemaVersion": 1, "name": "Future", "clips": []any{clip}})}}
	source := exchangeSource()
	source.TrackID = 42
	h := NewMixExchangeHandlers(store, &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{source}})
	req := authedRequest(uuid.New(), http.MethodGet, "/export", nil)
	req.SetPathValue("id", uuid.NewString())
	w := httptest.NewRecorder()
	h.ExportMixPlan(w, req)
	if w.Code != 422 {
		t.Fatalf("unsupported saved semantics must not be rewritten: %d %s", w.Code, w.Body.String())
	}
}

func TestMixExchangeImportRejectsMalformedMetadataBeforeSourceRead(t *testing.T) {
	base := string(stemContractJSON(t, exchangeFixture(t)))
	cases := map[string]string{
		"duplicate format":      strings.Replace(base, `"format":"soundq-mix"`, `"format":"soundq-mix","format":"soundq-mix"`, 1),
		"format alias":          strings.Replace(base, `"format"`, `"FORMAT"`, 1),
		"clip case alias":       strings.Replace(base, `"gainDb"`, `"GainDb"`, 1),
		"duplicate gain":        strings.Replace(base, `"gainDb":-3.5`, `"gainDb":-3.5,"gainDb":0`, 1),
		"duplicate nested gain": strings.Replace(base, `"gain":0,`, `"gain":0,"gain":1,`, 1),
		"duplicate stem key":    strings.Replace(base, `"channelSet":"stems5-hybrid-v1"`, `"channelSet":"stems5-hybrid-v1","channelSet":"stems5-hybrid-v1"`, 1),
		"nested alias":          strings.Replace(base, `"rampMs"`, `"RampMs"`, 1),
		"unknown top":           strings.Replace(base, `"format"`, `"url":"https://private.example/","format"`, 1),
		"unknown clip":          strings.Replace(base, `"gainDb"`, `"storageKey":"secret","gainDb"`, 1),
		"unknown nested":        strings.Replace(base, `"events"`, `"modelUrl":"https://private.example/","events"`, 1),
		"null required":         strings.Replace(base, `"timelineStartMs":0`, `"timelineStartMs":null`, 1),
		"null stem":             strings.Replace(base, `"stemEdits":{`, `"stemEdits":null,"ignored":{`, 1),
		"missing numeric":       strings.Replace(base, `,"timelineStartMs":0`, ``, 1),
		"null optional":         strings.Replace(base, `"gainDb"`, `"fadeInMs":null,"gainDb"`, 1),
		"trailing JSON":         base + ` {}`,
		"invalid UTF8":          strings.Replace(base, "Portable", string([]byte{0xff}), 1),
		"oversized UTF8 bytes":  strings.Replace(base, "Portable performance", strings.Repeat("é", mixPlanMaxRequestBodyBytes/2), 1),
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			if body == base {
				t.Fatal("malformed fixture mutation did not apply")
			}
			store := &fakeMixPlanStore{}
			sources := &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{exchangeSource()}}
			h := NewMixExchangeHandlers(store, sources)
			w := httptest.NewRecorder()
			h.ImportMixPlan(w, authedRequest(uuid.New(), http.MethodPost, "/import", []byte(body)))
			if w.Code != 400 || store.created != nil || sources.calls != 0 {
				t.Fatalf("malformed request admission: %d %s; writes=%v reads=%d", w.Code, w.Body.String(), store.created != nil, sources.calls)
			}
		})
	}
}

func TestMixExchangeImportGeometryAndStemAdmissionBeforeWrite(t *testing.T) {
	cases := map[string]func(map[string]any){
		"format":        func(d map[string]any) { d["format"] = "other" },
		"version":       func(d map[string]any) { d["version"] = 2 },
		"name byte cap": func(d map[string]any) { d["name"] = strings.Repeat("é", 128) },
		"hash":          func(d map[string]any) { d["clips"].([]any)[0].(map[string]any)["sourceFileHash"] = "sha256:short" },
		"stem source mismatch": func(d map[string]any) {
			d["clips"].([]any)[0].(map[string]any)["sourceFileHash"] = "sha256:" + strings.Repeat("b", 64)
		},
		"fade geometry": func(d map[string]any) {
			c := d["clips"].([]any)[0].(map[string]any)
			c["fadeInMs"] = 3000
			c["fadeOutMs"] = 2000
		},
		"pitch": func(d map[string]any) { d["clips"].([]any)[0].(map[string]any)["pitchMode"] = "unknown" },
		"tempo": func(d map[string]any) { d["clips"].([]any)[0].(map[string]any)["tempoPolicy"] = "unknown" },
		"invalid event gain": func(d map[string]any) {
			d["clips"].([]any)[0].(map[string]any)["stemEdits"].(map[string]any)["events"].([]any)[0].(map[string]any)["gain"] = 1.1
		},
		"five overlap": func(d map[string]any) {
			clips := []any{}
			for i := 0; i < 5; i++ {
				c := exchangeFixture(t)["clips"].([]any)[0].(map[string]any)
				c["clipId"] = fmt.Sprint(i)
				c["queueItemId"] = fmt.Sprint(i)
				clips = append(clips, c)
			}
			d["clips"] = clips
		},
		"duplicate queue": func(d map[string]any) {
			c := exchangeFixture(t)["clips"].([]any)[0].(map[string]any)
			c["clipId"] = "other"
			d["clips"] = append(d["clips"].([]any), c)
		},
		"duplicate clip": func(d map[string]any) {
			c := exchangeFixture(t)["clips"].([]any)[0].(map[string]any)
			c["queueItemId"] = "other"
			d["clips"] = append(d["clips"].([]any), c)
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			d := exchangeFixture(t)
			mutate(d)
			store := &fakeMixPlanStore{}
			sources := &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{exchangeSource()}}
			w := httptest.NewRecorder()
			NewMixExchangeHandlers(store, sources).ImportMixPlan(w, authedRequest(uuid.New(), "POST", "/import", stemContractJSON(t, d)))
			if w.Code != 400 || store.created != nil || sources.calls != 0 {
				t.Fatalf("invalid performance admitted: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestMixExchangeImportVerifiedCreateFailureDoesNotWrite(t *testing.T) {
	for _, test := range []struct {
		name   string
		err    error
		status int
		code   string
	}{
		{"changed source", fmt.Errorf("wrapped: %w", db.ErrMixExchangeSourceMismatch), 422, "SOURCE_MISMATCH"},
		{"database failure", errors.New("private database detail"), 500, "INTERNAL_ERROR"},
	} {
		t.Run(test.name, func(t *testing.T) {
			store := &fakeMixPlanStore{}
			sources := &exchangeFakeSources{store: store, rows: []db.MixExchangeSource{exchangeSource()}, createErr: test.err}
			w := httptest.NewRecorder()
			NewMixExchangeHandlers(store, sources).ImportMixPlan(w, authedRequest(uuid.New(), "POST", "/import", stemContractJSON(t, exchangeFixture(t))))
			if w.Code != test.status || !strings.Contains(w.Body.String(), test.code) || strings.Contains(w.Body.String(), "private database detail") || store.created != nil || sources.calls != 1 {
				t.Fatalf("verified create failure: %d %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestMixExchangeImportSourceResolutionFailureDoesNotWrite(t *testing.T) {
	source := exchangeSource()
	short := source
	short.DurationMs.Int64 = 5999
	cases := []struct {
		name   string
		rows   []db.MixExchangeSource
		err    error
		status int
		code   string
	}{
		{"missing", nil, nil, 422, "MISSING_SOURCES"},
		{"ambiguous", []db.MixExchangeSource{source, source}, nil, 422, "AMBIGUOUS_SOURCE"},
		{"known source end", []db.MixExchangeSource{short}, nil, 422, "SOURCE_MISMATCH"},
		{"lookup error", nil, errors.New("private database detail"), 500, "INTERNAL_ERROR"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			store := &fakeMixPlanStore{}
			sources := &exchangeFakeSources{store: store, rows: c.rows, err: c.err}
			user := uuid.New()
			w := httptest.NewRecorder()
			NewMixExchangeHandlers(store, sources).ImportMixPlan(w, authedRequest(user, "POST", "/import", stemContractJSON(t, exchangeFixture(t))))
			if w.Code != c.status || !strings.Contains(w.Body.String(), c.code) || strings.Contains(w.Body.String(), "private database detail") || store.created != nil || sources.user != user {
				t.Fatalf("source admission: %d %s", w.Code, w.Body.String())
			}
		})
	}
}
