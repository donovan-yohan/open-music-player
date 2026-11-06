package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// This is SoundQApi.trackDetailsSnapshot's actual field selection, not the
// default Library response or a catalog-specific projection.
const catalogNativeLibraryPath = "/api/v1/library?limit=100&offset=0&sort=added_at&order=desc&fields=id,title,artist,album,duration_ms,is_liked,cover_art_url,artwork_url,mb_verified,has_metadata_override,mb_recording_id,mb_suggestions,codec,bitrate_kbps,sample_rate_hz,channels"

func TestCatalogNativeLibraryReadback(t *testing.T) {
	for _, duration := range []string{"zero", "unknown"} {
		t.Run(duration, func(t *testing.T) {
			database, _ := newPlaylistMixTestDB(t)
			user := seedMixUser(t, database, "native-catalog@example.test")
			recording := uuid.New()
			var track int64
			if err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,album,mb_recording_id,mb_verified,duration_ms) VALUES ('native-catalog','Native catalog fixture','Synthetic artist','Synthetic album',$1,true,NULL) RETURNING id`, recording).Scan(&track); err != nil {
				t.Fatal(err)
			}
			if duration == "zero" {
				if _, err := database.Exec(`UPDATE tracks SET duration_ms=0 WHERE id=$1`, track); err != nil {
					t.Fatal(err)
				}
			}
			secret := uuid.NewString() + uuid.NewString()
			service := auth.NewService(nil, nil, secret)
			router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, LibraryHandlers: NewLibraryHandlers(db.NewTrackRepository(database), db.NewLibraryRepository(database))})
			token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour))}}).SignedString([]byte(secret))
			if err != nil {
				t.Fatal(err)
			}
			request := func(method, path, body string) *httptest.ResponseRecorder {
				t.Helper()
				r := httptest.NewRequest(method, path, strings.NewReader(body))
				r.Header.Set("Authorization", "Bearer "+token)
				r.Header.Set("Content-Type", "application/json")
				w := httptest.NewRecorder()
				router.ServeHTTP(w, r)
				if w.Code != http.StatusOK {
					t.Fatalf("%s %s status=%d want=200 body=%s", method, path, w.Code, w.Body.String())
				}
				return w
			}
			resolve := func(want string, member bool) *httptest.ResponseRecorder {
				t.Helper()
				w := request(http.MethodGet, "/api/v1/catalog/recordings/"+recording.String()+"/resolution", "")
				var body struct {
					Recording  string `json:"recordingMbid"`
					User       string `json:"userId"`
					Status     string `json:"status"`
					Candidates []struct {
						Track    int64 `json:"trackId"`
						Verified bool  `json:"mbVerified"`
						Member   bool  `json:"inLibrary"`
					} `json:"candidates"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if body.Recording != recording.String() || body.User != user.String() || body.Status != want || len(body.Candidates) != 1 || body.Candidates[0].Track != track || !body.Candidates[0].Verified || body.Candidates[0].Member != member {
					t.Fatalf("wrong exact resolution: %s", w.Body.String())
				}
				return w
			}
			t.Run("registered-membership-authenticated-unwired", func(t *testing.T) {
				unwired := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service})
				r := httptest.NewRequest(http.MethodPost, "/api/v1/catalog/recordings/"+recording.String()+"/membership", strings.NewReader(fmt.Sprintf(`{"trackId":%d}`, track)))
				r.Header.Set("Authorization", "Bearer "+token)
				r.Header.Set("Content-Type", "application/json")
				w := httptest.NewRecorder()
				unwired.ServeHTTP(w, r)
				if w.Code != http.StatusServiceUnavailable {
					t.Fatalf("authenticated unwired membership status=%d want=503 body=%s", w.Code, w.Body.String())
				}
			})
			pre := resolve("stored_unowned", false)
			ack := request(http.MethodPost, "/api/v1/catalog/recordings/"+recording.String()+"/membership", fmt.Sprintf(`{"trackId":%d}`, track))
			var membership struct {
				Recording string    `json:"recordingMbid"`
				User      string    `json:"userId"`
				Track     int64     `json:"trackId"`
				Status    string    `json:"status"`
				AddedAt   time.Time `json:"addedAt"`
			}
			if err := json.Unmarshal(ack.Body.Bytes(), &membership); err != nil {
				t.Fatal(err)
			}
			if membership.Recording != recording.String() || membership.User != user.String() || membership.Track != track || membership.Status != "member" || membership.AddedAt.IsZero() {
				t.Fatalf("wrong exact acknowledgement: %s", ack.Body.String())
			}
			post := resolve("owned", true)
			library := request(http.MethodGet, catalogNativeLibraryPath, "")
			var page struct {
				Tracks []map[string]json.RawMessage `json:"tracks"`
				Total  int                          `json:"total"`
				Limit  int                          `json:"limit"`
				Offset int                          `json:"offset"`
			}
			if err := json.Unmarshal(library.Body.Bytes(), &page); err != nil {
				t.Fatal(err)
			}
			if len(page.Tracks) != 1 || page.Total != 1 || page.Limit != 100 || page.Offset != 0 {
				t.Fatalf("native pagination: %s", library.Body.String())
			}
			row := page.Tracks[0]
			for key, want := range map[string]string{"id": fmt.Sprint(track), "mb_recording_id": fmt.Sprintf("%q", recording.String()), "mb_verified": "true", "has_metadata_override": "false", "is_liked": "false", "title": `"Native catalog fixture"`} {
				if string(row[key]) != want {
					t.Fatalf("native required %s=%s want %s: %s", key, row[key], want, library.Body.String())
				}
			}
			if duration == "zero" && string(row["duration_ms"]) != "0" {
				t.Fatal("zero duration lost")
			}
			if duration == "unknown" && row["duration_ms"] != nil {
				t.Fatal("unknown duration must be absent (native defaults to zero), not null")
			}
			// Keep captures in a test-only overlay, not a second serializer.
			_ = pre
			_ = post
		})
	}
}
