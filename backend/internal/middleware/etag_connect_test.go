package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestETagHonorsNoStore(t *testing.T) {
	handler := ETag(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		w.WriteHeader(401)
		w.Write([]byte("private"))
	}))
	first := httptest.NewRecorder()
	handler.ServeHTTP(first, httptest.NewRequest("GET", "/api/v1/me/devices", nil))
	if first.Header().Get("ETag") != "" || first.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("cached private response: %v", first.Header())
	}
	req := httptest.NewRequest("GET", "/api/v1/me/devices", nil)
	req.Header.Set("If-None-Match", `"2c17c6393771ee3048ae34d6b380c5ec"`)
	second := httptest.NewRecorder()
	handler.ServeHTTP(second, req)
	if second.Code != 401 || second.Body.String() != "private" {
		t.Fatalf("conditional private response: %d %q", second.Code, second.Body.String())
	}
}
