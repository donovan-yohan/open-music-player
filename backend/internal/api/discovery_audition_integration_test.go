package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

const auditionSourcePath = "/api/v1/discovery/audition-source"

func TestDiscoveryAuditionIndexHandlesLongLegacySources(t *testing.T) {
	f := newMembershipFixture(t)
	var ready bool
	if err := f.database.QueryRow(`SELECT EXISTS (
		SELECT 1 FROM pg_index WHERE indexrelid = to_regclass('idx_tracks_audition_source') AND indisvalid
	)`).Scan(&ready); err != nil || !ready {
		t.Fatalf("startup did not install the audition source index: valid=%t err=%v", ready, err)
	}
	// Historical track URLs are TEXT and may be much larger than the current
	// Discover request allowance or a btree index tuple. Use distinct segments.
	var key strings.Builder
	key.WriteString("https://soundcloud.com/")
	for i := 0; i < 200; i++ {
		key.WriteString(uuid.NewString())
		key.WriteByte('/')
	}
	var track int64
	if err := f.database.QueryRow(`INSERT INTO tracks (identity_hash,title,source_url,source_type,storage_key,file_size_bytes)
		VALUES ('legacy-long-source','Legacy',$1,'soundcloud','fixture/legacy.mp3',4096) RETURNING id`, key.String()).Scan(&track); err != nil {
		t.Fatal(err)
	}
	if _, err := f.database.Exec(`INSERT INTO user_library (user_id,track_id) VALUES ($1,$2)`, f.user, track); err != nil {
		t.Fatal(err)
	}
	got, err := db.NewLibraryRepository(f.database).ExactStoredSourceInLibrary(context.Background(), f.user, "soundcloud", key.String())
	if err != nil || got != track {
		t.Fatalf("legacy source must match by byte-exact URL: got=%d want=%d err=%v", got, track, err)
	}
}

func TestDiscoveryAuditionSourceUsesOnlyExactStoredLibraryAudio(t *testing.T) {
	f := newMembershipFixture(t)
	other := seedMixUser(t, f.database, "audition-other@example.test")
	more := func(id, source, provider string, owner *uuid.UUID, member uuid.UUID, stored bool) int64 {
		t.Helper()
		var trackID int64
		key := ""
		if stored {
			key = "fixture/" + id + ".mp3"
		}
		err := f.database.QueryRow(`INSERT INTO tracks
			(identity_hash,title,source_url,source_type,storage_key,file_size_bytes,source_file_hash,mb_recording_id,duration_ms,private_owner_id)
			VALUES ($1,'Same title',$2,$3,$4,812345,$5,$6,245000,$7) RETURNING id`,
			id, source, provider, key, "sha256:"+strings.Repeat("b", 64), f.recording, owner).Scan(&trackID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = f.database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES ($1,$2)`, member, trackID); err != nil {
			t.Fatal(err)
		}
		return trackID
	}
	exact := more("audition-exact", previewSource, "youtube", nil, f.user, true)
	// An identical metadata match and a cross-account duplicate cannot substitute.
	more("audition-foreign-copy", previewSource, "youtube", nil, other, true)
	foreign := "https://www.youtube.com/watch?v=SQForeign01"
	more("audition-foreign", foreign, "youtube", nil, other, true)
	private := "https://www.youtube.com/watch?v=SQPrivate01"
	more("audition-private", private, "youtube", &f.user, f.user, true)
	missing := "https://www.youtube.com/watch?v=SQNoAudio01"
	more("audition-no-audio", missing, "youtube", nil, f.user, false)
	ambiguous := "https://www.youtube.com/watch?v=SQAmbiguo01"
	more("audition-a", ambiguous, "youtube", nil, f.user, true)
	more("audition-b", ambiguous, "youtube", nil, f.user, true)
	alias := "https://www.youtube.com/watch?v=SQAliasOnly"
	if _, err := f.database.Exec(`INSERT INTO track_sources(track_id,provider,source_id,source_url) VALUES ($1,'youtube','SQAliasOnly',$2)`, exact, alias); err != nil {
		t.Fatal(err)
	}
	cloud := more("audition-cloud", previewSoundCloud, "soundcloud", nil, f.user, true)
	// Matching URL with contradictory provider storage provenance is not usable.
	wrongProvider := "https://www.youtube.com/watch?v=SQWrongProv"
	more("audition-wrong-provider", wrongProvider, "soundcloud", nil, f.user, true)
	objects := &fakePlaybackStorage{info: map[string]*storage.ObjectInfo{
		"fixture/audition-exact.mp3": {ContentType: "audio/mpeg", Size: 812345},
	}}
	f.router = NewRouterWithConfig(&RouterConfig{
		AuthHandlers: f.router.authHandlers, AuthService: f.router.authService, LibraryHandlers: f.router.libraryHandlers,
		PlaybackHandlers: NewPlaybackHandlers(db.NewTrackRepository(f.database), db.NewLibraryRepository(f.database), objects),
	})

	call := func(path, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		f.router.ServeHTTP(w, r)
		return w
	}
	readMembership := func() string {
		t.Helper()
		var s string
		if err := f.database.QueryRow(`SELECT jsonb_agg(to_jsonb(ul) ORDER BY user_id,track_id)::text FROM user_library ul`).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	before, members := membershipSnapshot(t, f.database), readMembership()
	token := f.token(f.user)
	for _, tc := range []struct {
		name, path, body, bearer string
		status                   int
		trackID                  int64
	}{
		{"authenticated exact YouTube", auditionSourcePath, previewBody(previewSource), token, 200, exact},
		{"authenticated exact SoundCloud", auditionSourcePath, previewBody(previewSoundCloud), token, 200, cloud},
		{"no bearer", auditionSourcePath, previewBody(previewSource), "", 401, 0},
		{"foreign membership", auditionSourcePath, previewBody(foreign), token, 404, 0},
		{"own private upload is not provider audio", auditionSourcePath, previewBody(private), token, 404, 0},
		{"no stored audio", auditionSourcePath, previewBody(missing), token, 404, 0},
		{"ambiguous own exact assets", auditionSourcePath, previewBody(ambiguous), token, 404, 0},
		{"secondary alias does not bind stored audio", auditionSourcePath, previewBody(alias), token, 404, 0},
		{"provider mismatch", auditionSourcePath, previewBody(wrongProvider), token, 404, 0},
		{"no cross-surface host fallback", auditionSourcePath, previewBody(strings.Replace(previewSource, "www.youtube.com", "music.youtube.com", 1)), token, 404, 0},
		{"no tracking alias", auditionSourcePath, previewBody(previewSource + "&si=alias"), token, 404, 0},
		{"duplicate input", auditionSourcePath, `{"url":"` + foreign + `","url":"` + previewSource + `"}`, token, 400, 0},
		{"no alternate owner", auditionSourcePath, `{"url":"` + previewSource + `","ownerId":"` + other.String() + `"}`, token, 400, 0},
		{"no query", auditionSourcePath + "?", previewBody(previewSource), token, 400, 0},
		{"bounded request", auditionSourcePath, strings.Repeat(" ", 8193) + previewBody(previewSource), token, 400, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := call(tc.path, tc.body, tc.bearer)
			if w.Code != tc.status || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("status=%d cache=%q want status=%d private no-store: %s", w.Code, w.Header().Get("Cache-Control"), tc.status, w.Body.String())
			}
			if tc.status == 404 && w.Body.String() != "{\"code\":\"AUDIO_UNAVAILABLE\",\"message\":\"stored audition source is unavailable\"}\n" {
				t.Fatalf("lookup refusal discloses details: %s", w.Body.String())
			}
			if tc.status == 200 {
				var result map[string]int64
				if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || len(result) != 1 || result["trackId"] != tc.trackID {
					t.Fatalf("unexpected source result: %s", w.Body.String())
				}
			}
		})
	}
	if got := membershipSnapshot(t, f.database); !reflect.DeepEqual(before, got) || readMembership() != members {
		t.Fatal("audition lookup wrote durable state")
	}
	if len(objects.statKeys) != 0 || len(objects.presignKeys) != 0 {
		t.Fatal("source lookup must not authorize or open media")
	}
	const playbackPath = "/api/v1/playback/urls"
	playbackBody := fmt.Sprintf(`{"trackIds":[%d]}`, exact)
	if w := call(playbackPath, playbackBody, token); w.Code != 200 ||
		!reflect.DeepEqual(objects.presignKeys, []string{"fixture/audition-exact.mp3"}) {
		t.Fatalf("ordinary playback could not grant the exact source: %d %s", w.Code, w.Body.String())
	}
	if _, err := f.database.Exec(`DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, f.user, exact); err != nil {
		t.Fatal(err)
	}
	if w := call(auditionSourcePath, previewBody(previewSource), token); w.Code != 404 {
		t.Fatalf("removed membership still resolves: %d %s", w.Code, w.Body.String())
	}
	if w := call(playbackPath, playbackBody, token); w.Code != 404 || len(objects.statKeys) != 1 || len(objects.presignKeys) != 1 {
		t.Fatalf("a previously resolved ID bypassed playback membership: %d %s", w.Code, w.Body.String())
	}
}
