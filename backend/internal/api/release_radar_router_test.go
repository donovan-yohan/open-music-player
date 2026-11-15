package api

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/discovery"
)

func TestReleaseRadarAuthenticatedRouterAndMembership(t *testing.T) {
	f := &radarWireFixture{user: uuid.MustParse("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")}
	h := NewReleaseRadarHandlers(discovery.NewRadarService(f, f, f), f, true)
	service := auth.NewService(nil, nil, "synthetic-fixture-secret")
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, ReleaseRadarHandlers: h})
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: f.user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte("synthetic-fixture-secret"))
	if err != nil {
		t.Fatal(err)
	}
	request := func(path string, authenticated bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", path, nil)
		if authenticated {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	path := "/api/v1/me/discovery/releases"
	if w := request(path, false); w.Code != 401 || f.calls != 0 {
		t.Fatalf("auth bypass %d", w.Code)
	}
	if w := request(path+"?userId="+uuid.NewString(), true); w.Code != 400 || f.calls != 0 {
		t.Fatalf("actor query admitted %d", w.Code)
	}
	if w := request(path, true); w.Code != 200 || f.calls != 1 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("real route failed %d %s", w.Code, w.Body.String())
	}
	w := request(path+"/33333333-3333-4333-8333-333333333333/membership", true)
	if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal(w.Code, w.Body.String())
	}
	var membership struct {
		RecordingMbid string `json:"recordingMbid"`
		InLibrary     bool   `json:"inLibrary"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &membership); err != nil || membership.InLibrary || membership.RecordingMbid != "33333333-3333-4333-8333-333333333333" {
		t.Fatalf("bad exact membership %+v %v", membership, err)
	}
	for _, raw := range []string{"not-an-id", "00000000-0000-0000-0000-000000000000", "33333333333343338333333333333333"} {
		if w := request(path+"/"+raw+"/membership", true); w.Code != 400 {
			t.Fatalf("malformed %s admitted %d", raw, w.Code)
		}
	}
}
