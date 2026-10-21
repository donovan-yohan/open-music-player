package api

import (
	"bytes"
	"context"
	"encoding/base64"
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
	"github.com/openmusicplayer/backend/internal/middleware"
)

func connectCode(t *testing.T, rec *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	requireConnectStatus(t, rec, status)
	var result struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil || result.Code != code {
		t.Fatalf("code=%q expected=%q err=%v", result.Code, code, err)
	}
}
func TestConnectFailureStatusCodesRealInfra(t *testing.T) {
	router, service, database, client, token, _ := connectRouterFixture(t)
	secret := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{23}, 32))
	id := uuid.NewString()
	body := fmt.Sprintf(`{"deviceId":%q,"label":"Laptop","platform":"macos","writerSecret":%q}`, id, secret)
	created := connectCall(router, "POST", "/api/v1/me/devices", token, body)
	requireConnectStatus(t, created, 201)
	var result struct {
		Device struct {
			LeaseID string `json:"leaseId"`
		} `json:"device"`
	}
	json.Unmarshal(created.Body.Bytes(), &result)
	connectCode(t, connectCall(router, "POST", "/api/v1/me/devices", token, strings.Replace(body, "Laptop", "Other", 1)), 409, "DEVICE_CONFLICT")
	report := fmt.Sprintf(`{"leaseId":%q,"writerSecret":%q,"sequence":1,"playback":null}`, result.Device.LeaseID, secret)
	requireConnectStatus(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, report), 200)
	changed := strings.Replace(report, `"playback":null`, `"playback":{"sessionId":"s","queueItemId":null,"track":{"trackId":null,"title":"T","artist":"A"},"playing":false,"processingState":"ready","positionMs":0,"durationMs":0,"activeVoiceCount":0}`, 1)
	connectCode(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, changed), 409, "STALE_DEVICE_REPORT")
	rate := connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, strings.Replace(report, `"sequence":1`, `"sequence":2`, 1))
	connectCode(t, rate, 429, "DEVICE_RATE_LIMITED")
	if rate.Header().Get("Retry-After") != "1" {
		t.Fatal("missing rate retry")
	}
	connectCode(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, strings.Replace(report, result.Device.LeaseID, uuid.NewString(), 1)), 410, "DEVICE_GONE")
	connectCode(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, strings.Replace(report, secret, base64.RawURLEncoding.EncodeToString(make([]byte, 32)), 1)), 403, "DEVICE_WRITER_MISMATCH")
	for i := 0; i < 7; i++ {
		requireConnectStatus(t, connectCall(router, "POST", "/api/v1/me/devices", token, strings.Replace(body, id, uuid.NewString(), 1)), 201)
	}
	connectCode(t, connectCall(router, "POST", "/api/v1/me/devices", token, strings.Replace(body, id, uuid.NewString(), 1)), 409, "DEVICE_LIMIT_REACHED")
	client.Close()
	connectCode(t, connectCall(router, "GET", "/api/v1/me/devices", token, ""), 503, "SERVICE_DISABLED")
	database.Close()
	connectCode(t, connectCall(router, "GET", "/api/v1/me/devices", token, ""), 503, "SERVICE_DISABLED")
	_ = service
}

func TestConnectLogoutHidesOldNamespaceRealInfra(t *testing.T) {
	router, service, database, client, token, _ := connectRouterFixture(t)
	secret := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{27}, 32))
	id := uuid.NewString()
	body := fmt.Sprintf(`{"deviceId":%q,"label":"Laptop","platform":"macos","writerSecret":%q}`, id, secret)
	requireConnectStatus(t, connectCall(router, "POST", "/api/v1/me/devices", token, body), 201)
	claims, err := service.ValidateAccessToken(token)
	if err != nil {
		t.Fatal(err)
	}
	owner, err := uuid.Parse(claims.UserID)
	if err != nil {
		t.Fatal(err)
	}
	if err = service.Logout(context.Background(), owner); err != nil {
		t.Fatal(err)
	}
	oldKey := "connect:v1:" + owner.String() + ":0"
	if client.Exists(context.Background(), oldKey).Val() != 1 {
		t.Fatal("expected inaccessible old namespace bounded by TTL")
	}
	var generation int64
	if err = database.QueryRow(`SELECT connect_auth_generation FROM users WHERE id=$1`, owner).Scan(&generation); err != nil || generation != 1 {
		t.Fatalf("generation=%d %v", generation, err)
	}
	fresh, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"user_id": owner.String(), "email": claims.Email, "connectGeneration": generation, "exp": time.Now().Add(time.Hour).Unix()}).SignedString([]byte("connect-api-test-secret"))
	if err != nil {
		t.Fatal(err)
	}
	rec := connectCall(router, "GET", "/api/v1/me/devices", fresh, "")
	requireConnectStatus(t, rec, 200)
	if strings.Contains(rec.Body.String(), id) || !strings.Contains(rec.Body.String(), `"devices":[]`) {
		t.Fatalf("old namespace visible: %s", rec.Body.String())
	}
	requireConnectStatus(t, connectCall(router, "POST", "/api/v1/me/devices", fresh, body), 201)
	requireConnectStatus(t, connectCall(router, "GET", "/api/v1/me/devices", token, ""), 401)
	// Even Redis-off routes must generation-check before reporting availability.
	disabled := middleware.ETag(NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service}))
	connectCode(t, connectCall(disabled, "GET", "/api/v1/me/devices", token, ""), 401, "CONNECT_SESSION_REVOKED")
	connectCode(t, connectCall(disabled, "GET", "/api/v1/me/devices", fresh, ""), 503, "SERVICE_DISABLED")
	// A legacy endpoint still accepts this signed, unexpired access token.
	if rec = connectCall(router, http.MethodPost, "/api/v1/playback/urls", token, "{}"); rec.Code == 401 {
		t.Fatal("legacy endpoint blanket revocation")
	}
}
