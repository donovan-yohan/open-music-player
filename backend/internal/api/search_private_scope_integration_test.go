package api

import (
	"context"
	"crypto/md5"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/search"
)

func TestGlobalSearchPrivateScope(t *testing.T) {
	// Never seed private rows through an ordinary integration DSN.
	database := privateFenceTestDB(t)
	if !database.TrigramEnabled {
		t.Fatal("pg_trgm is required to test the production fuzzy fallback")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	owner, foreign := uuid.New(), uuid.New()
	userIDs := pq.Array([]uuid.UUID{owner, foreign})
	var trackHashes []string
	// Register before seeding; this runs before the fixture pool closes and
	// uses its own deadline even if the test fails or its context is canceled.
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), privateFenceSQLTimeout)
		defer cancel()
		tx, err := database.BeginTx(cleanupCtx, nil)
		if err != nil {
			t.Errorf("begin search fixture cleanup: %v", err)
			return
		}
		defer tx.Rollback()
		hashes := pq.Array(trackHashes)
		// Track deletion cascades to memberships and overrides. Private tracks
		// must be deleted before their users (private_owner_id restricts deletion).
		if _, err := tx.ExecContext(cleanupCtx, `DELETE FROM tracks WHERE identity_hash = ANY($1)`, hashes); err != nil {
			t.Errorf("delete search fixture tracks: %v", err)
			return
		}
		if _, err := tx.ExecContext(cleanupCtx, `DELETE FROM users WHERE id = ANY($1)`, userIDs); err != nil {
			t.Errorf("delete search fixture users: %v", err)
			return
		}
		if err := tx.Commit(); err != nil {
			t.Errorf("commit search fixture cleanup: %v", err)
			return
		}
		var remaining bool
		if err := database.QueryRowContext(cleanupCtx, `SELECT EXISTS (SELECT 1 FROM tracks WHERE identity_hash = ANY($1))
			OR EXISTS (SELECT 1 FROM users WHERE id = ANY($2))`, hashes, userIDs).Scan(&remaining); err != nil || remaining {
			t.Errorf("verify search fixture cleanup: rows remain=%v, err=%v", remaining, err)
		}
	})
	for _, id := range []uuid.UUID{owner, foreign} {
		if _, err := database.ExecContext(ctx, `INSERT INTO users (id, email, username, password_hash)
			VALUES ($1, $2, 'user', 'x')`, id, id.String()+"@example.test"); err != nil {
			t.Fatalf("seed search fixture user: %v", err)
		}
	}
	secret := uuid.NewString() + uuid.NewString()
	service := auth.NewService(nil, nil, secret)
	tracks, library := db.NewTrackRepository(database), db.NewLibraryRepository(database)
	overrides := db.NewTrackMetadataOverrideRepository(database)
	server := httptest.NewServer(NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(service), AuthService: service,
		SearchHandlers:  search.NewHandlersWithMetadataOverrides(tracks, overrides),
		LibraryHandlers: NewLibraryHandlers(tracks, library), ResponseTransforms: true,
	}))
	defer server.Close()
	tokens := make(map[uuid.UUID]string)
	for _, account := range []uuid.UUID{owner, foreign} {
		token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{
			UserID: account.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))},
		}).SignedString([]byte(secret))
		if err != nil {
			t.Fatal(err)
		}
		tokens[account] = token
	}

	type wire struct {
		status                   int
		body, contentType, cache string
		etag                     string
	}
	get := func(t *testing.T, account uuid.UUID, path, etag string) wire {
		t.Helper()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		if token := tokens[account]; token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if etag != "" {
			req.Header.Set("If-None-Match", etag)
		}
		res, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		return wire{res.StatusCode, string(body), res.Header.Get("Content-Type"), res.Header.Get("Cache-Control"), res.Header.Get("ETag")}
	}
	ok := func(t *testing.T, path string, got wire, body string) {
		t.Helper()
		want := wire{200, body, "application/json", "private, max-age=0, must-revalidate", fmt.Sprintf(`"%x"`, md5.Sum([]byte(body)))}
		if got != want {
			t.Errorf("%s: got status=%d type=%q cache=%q etag=%q body=%s; want %s", path, got.status, got.contentType, got.cache, got.etag, got.body, body)
		}
	}

	const (
		sharedArt   = "https://fixture.invalid/shared-art"
		privateArt  = "https://fixture.invalid/zz-private-art"
		sharedEdit  = "Ownercorrected"
		privateEdit = "Ownerconfidential"
	)
	type fixtureTrack struct {
		id   int64
		name string
	}
	newTrackHash := func() string {
		hash := uuid.NewString()
		// Remember attempted writes, not just inserts that returned successfully.
		trackHashes = append(trackHashes, hash)
		return hash
	}
	seedShared := func(t *testing.T, name string) fixtureTrack {
		t.Helper()
		var id int64
		if err := database.QueryRowContext(ctx, `INSERT INTO tracks(identity_hash,title,artist,album,cover_art_url)
			VALUES($1,$2,$2,$2,$3) RETURNING id`, newTrackHash(), name, sharedArt).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return fixtureTrack{id, name}
	}
	reserve := func(t *testing.T) int64 {
		t.Helper()
		var id int64
		if err := database.QueryRowContext(ctx, `SELECT nextval(pg_get_serial_sequence('tracks', 'id'))`).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	seedPrivate := func(t *testing.T, id int64, name string) {
		t.Helper()
		if _, err := database.ExecContext(ctx, `INSERT INTO tracks(id,identity_hash,title,artist,album,cover_art_url,private_owner_id,storage_key,source_file_hash,file_size_bytes)
			VALUES($1,$2,$3,$3,$3,$4,$5,$6,$7,128)`, id, newTrackHash(), name, privateArt, owner, uuid.NewString(), "sha256:"+strings.ReplaceAll(uuid.NewString()+uuid.NewString(), "-", "")); err != nil {
			t.Fatal(err)
		}
	}
	add := func(t *testing.T, account uuid.UUID, id int64) {
		t.Helper()
		if _, err := library.AddTrackToLibrary(ctx, account, id); err != nil {
			t.Fatal(err)
		}
	}
	edit := func(t *testing.T, id int64, title string) {
		t.Helper()
		if _, err := overrides.Set(ctx, owner, id, db.TrackMetadataOverrideInput{Title: &title}); err != nil {
			t.Fatal(err)
		}
	}

	// True absent/present comparison on one disposable DB: reserve the older
	// numeric IDs, but insert no private rows until after every clean read.
	ftsCollisionID, fuzzyCollisionID := reserve(t), reserve(t)
	fts := []fixtureTrack{seedShared(t, "Quorvex Middle"), seedShared(t, "Quorvex Southern")}
	fuzzy := []fixtureTrack{seedShared(t, "Radiohead"), seedShared(t, "Radioheadz")}
	shadow := []fixtureTrack{seedShared(t, "Komputer")}
	add(t, owner, fts[0].id)
	edit(t, fts[0].id, sharedEdit)
	add(t, foreign, fts[1].id)

	// Fuzzy cases use a single term, identical in title/artist/album. Verify
	// their shared controls cannot match prefix FTS but do qualify for pg_trgm.
	for _, row := range append(append([]fixtureTrack(nil), fuzzy...), shadow...) {
		query := "Radiohede"
		if row.id == shadow[0].id {
			query = "Komputor"
		}
		var matchFTS, matchTrigram bool
		if err := database.QueryRowContext(ctx, `SELECT to_tsvector('english', title) @@ to_tsquery('english', $2 || ':*'), similarity(title, $2) >= 0.3 FROM tracks WHERE id=$1`, row.id, query).Scan(&matchFTS, &matchTrigram); err != nil || matchFTS || !matchTrigram {
			t.Fatalf("fixture %q against %q: FTS=%v trigram=%v err=%v", row.name, query, matchFTS, matchTrigram, err)
		}
	}

	type check struct {
		label   string
		account uuid.UUID
		path    string
		body    string
		before  wire
	}
	var checks []check
	for _, a := range []struct {
		name string
		id   uuid.UUID
	}{{"owner", owner}, {"foreign", foreign}} {
		for _, c := range []struct {
			name, query string
			rows        []fixtureTrack
		}{
			{"full_text", "Quorvex", fts},
			{"trigram", "Radiohede", fuzzy},
			{"private_exact_cannot_shadow_shared_fuzzy", "Komputor", shadow},
			{"private_only_full_text", "Obscuranta", nil},
			{"private_only_trigram", "Obscuranto", nil},
			{"no_matches", "Xyzzwhork", nil},
		} {
			for _, page := range []struct{ limit, offset int }{{20, 0}, {1, 0}, {1, 1}, {1, 2}} {
				var recordings, artists, releases []string
				end := min(len(c.rows), page.offset+page.limit)
				for _, row := range c.rows[min(page.offset, end):end] {
					title, override := row.name, ""
					if a.id == owner && row.id == fts[0].id {
						title, override = sharedEdit, `,"hasMetadataOverride":true`
					}
					recordings = append(recordings, fmt.Sprintf(`{"id":%d,"title":%q,"artist":%q,"album":%q,"coverArtUrl":%q%s}`, row.id, title, row.name, row.name, sharedArt, override))
					artists = append(artists, fmt.Sprintf(`{"name":%q,"trackCount":1}`, row.name))
					releases = append(releases, fmt.Sprintf(`{"id":%d,"name":%q,"artist":%q,"coverArtUrl":%q,"trackCount":1}`, row.id, row.name, row.name, sharedArt))
				}
				total := len(c.rows)
				if len(recordings) == 0 {
					// Keep the existing window-count behavior on exhausted pages.
					total = 0
				}
				paging := "?q=" + url.QueryEscape(c.query)
				if page.limit != 20 {
					paging += fmt.Sprintf("&limit=%d&offset=%d", page.limit, page.offset)
				}
				for _, section := range []struct {
					path string
					rows []string
				}{{"/recordings", recordings}, {"/artists", artists}, {"/releases", releases}, {"", nil}} {
					body := fmt.Sprintf("{\"data\":[%s],\"total\":%d,\"limit\":%d,\"offset\":%d}\n", strings.Join(section.rows, ","), total, page.limit, page.offset)
					if section.path == "" {
						body = fmt.Sprintf("{\"tracks\":[%s],\"artists\":[%s],\"albums\":[%s],\"query\":%q}\n", strings.Join(recordings, ","), strings.Join(artists, ","), strings.Join(releases, ","), c.query)
					}
					route := strings.TrimPrefix(section.path, "/")
					if route == "" {
						route = "unified"
					}
					label := fmt.Sprintf("%s/%s/%s/limit_%d_offset_%d", a.name, c.name, route, page.limit, page.offset)
					checks = append(checks, check{label: label, account: a.id, path: "/api/v1/search" + section.path + paging, body: body})
				}
			}
		}
	}
	for i := range checks {
		p := &checks[i]
		p.before = get(t, p.account, p.path, "")
		ok(t, p.path, p.before, p.body)
	}
	if t.Failed() {
		t.Fatal("shared-only fixture did not establish the expected search wire")
	}

	// Older same-group tracks would change MIN(id), MAX(cover_art_url) and
	// trackCount. New groups and higher-ranked tracks would move page windows.
	seedPrivate(t, ftsCollisionID, fts[1].name)
	seedPrivate(t, fuzzyCollisionID, fuzzy[1].name)
	for _, name := range []string{"Quorvex Alpine", "Radiohed", "Komputor"} {
		seedPrivate(t, reserve(t), name)
	}
	privateID := reserve(t)
	seedPrivate(t, privateID, "Obscuranta")
	add(t, owner, privateID)
	edit(t, privateID, privateEdit)

	for _, p := range checks {
		t.Run(p.label, func(t *testing.T) {
			after := get(t, p.account, p.path, "")
			if after != p.before {
				t.Errorf("private insertion changed %s: before=%s after=%s", p.path, p.before.body, after.body)
			}
			conditional := get(t, p.account, p.path, p.before.etag)
			if conditional.status != http.StatusNotModified || conditional.body != "" {
				t.Errorf("%s with clean ETag: got status=%d body=%s; want bodyless 304", p.path, conditional.status, conditional.body)
			}
			if !t.Failed() {
				t.Logf("wire %s status=%d type=%q cache=%q etag=%s conditional=%d body=%s", p.path, after.status, after.contentType, after.cache, after.etag, conditional.status, after.body)
			}
		})
	}

	t.Run("library_search_is_still_membership_and_override_scoped", func(t *testing.T) {
		path := "/api/v1/library?fields=id,title,has_metadata_override&q="
		for _, c := range []struct {
			user        uuid.UUID
			query, rows string
			total       int
		}{
			{owner, sharedEdit, fmt.Sprintf(`{"has_metadata_override":true,"id":%d,"title":%q}`, fts[0].id, sharedEdit), 1},
			{foreign, "Quorvex", fmt.Sprintf(`{"has_metadata_override":false,"id":%d,"title":%q}`, fts[1].id, fts[1].name), 1},
			{owner, "Obscuranta", fmt.Sprintf(`{"has_metadata_override":true,"id":%d,"title":%q}`, privateID, privateEdit), 1},
			{owner, privateEdit, fmt.Sprintf(`{"has_metadata_override":true,"id":%d,"title":%q}`, privateID, privateEdit), 1},
			{foreign, "Obscuranta", "", 0},
			{foreign, privateEdit, "", 0},
		} {
			body := fmt.Sprintf("{\"limit\":50,\"offset\":0,\"total\":%d,\"tracks\":[%s]}\n", c.total, c.rows)
			got := get(t, c.user, path+c.query, "")
			ok(t, path+c.query, got, body)
			if got.body == body {
				t.Logf("Library wire %s status=%d body=%s", path+c.query, got.status, got.body)
			}
		}
	})

	t.Run("authentication_and_query_validation_unchanged", func(t *testing.T) {
		for _, route := range []string{"", "/recordings", "/artists", "/releases"} {
			path := "/api/v1/search" + route
			if w := get(t, uuid.Nil, path+"?q=Quorvex", ""); w.status != http.StatusUnauthorized {
				t.Errorf("anonymous %s got %d, want 401", path, w.status)
			}
			if w := get(t, owner, path, ""); w.status != http.StatusBadRequest || w.body != "{\"code\":\"VALIDATION_ERROR\",\"message\":\"query parameter 'q' is required\"}\n" {
				t.Errorf("missing q on %s: got %d %s", path, w.status, w.body)
			}
		}
	})
}
