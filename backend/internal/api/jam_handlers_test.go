package api

import (
	"bytes"
	"context"
	"github.com/openmusicplayer/backend/internal/jam"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestJamStrictBody(t *testing.T) {
	valid := `{"requestId":"00000000-0000-4000-8000-000000000001","catalogItemId":"00000000-0000-4000-8000-000000000002","expectedVersion":1}`
	for _, body := range []string{strings.Replace(valid, `"expectedVersion":1`, `"expectedVersion":1,"expectedVersion":2`, 1), strings.Replace(valid, "expectedVersion", "ExpectedVersion", 1), strings.Replace(valid, `"expectedVersion":1`, `"expectedVersion":null`, 1), strings.Replace(valid, `"expectedVersion":1`, `"expectedVersion":1,"status":"queued"`, 1), valid + ` {}`, string([]byte{123, 34, 120, 34, 58, 34, 255, 34, 125}), strings.Repeat(" ", 2048) + valid} {
		r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
		w := httptest.NewRecorder()
		var in jam.RequestInput
		if jamDecode(w, r, &in, 2048) == nil {
			t.Fatalf("accepted %s", body)
		}
	}
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(valid))
	w := httptest.NewRecorder()
	var in jam.RequestInput
	if e := jamDecode(w, r, &in, 2048); e != nil {
		t.Fatal(e)
	}
}

type jamRecordingLimiter struct {
	calls []jam.LimitInput
	err   error
}

func (l *jamRecordingLimiter) Allow(_ context.Context, in jam.LimitInput) error {
	l.calls = append(l.calls, in)
	return l.err
}
func TestJamLimiterUsesRemoteAddrNotForwardedAndFailClosed(t *testing.T) {
	l := &jamRecordingLimiter{err: jam.ErrUnavailable}
	h := NewJamHandlers(&jam.Repository{}, l, nil, nil)
	m := http.NewServeMux()
	h.RegisterGuestRoutes(m)
	r := httptest.NewRequest("GET", "/api/v1/guest/jams/00000000-0000-4000-8000-000000000001", nil)
	r.RemoteAddr = "192.0.2.17:1234"
	r.Header.Set("X-Forwarded-For", "203.0.113.5")
	w := httptest.NewRecorder()
	m.ServeHTTP(w, r)
	if w.Code != 503 || len(l.calls) != 1 || l.calls[0].RemoteIP != "192.0.2.17" {
		t.Fatalf("failclosed/source=%d %+v", w.Code, l.calls)
	}
}
func TestJamStrictRejectsInvalidUTF8EvenInKnownString(t *testing.T) {
	raw := append([]byte(`{"joinToken":"`), byte(255))
	raw = append(raw, []byte(`","memberSecret":"s","displayName":"A","requestId":"00000000-0000-4000-8000-000000000001"}`)...)
	r := httptest.NewRequest("POST", "/", bytes.NewReader(raw))
	var in jam.JoinInput
	if e := jamDecode(httptest.NewRecorder(), r, &in, 2048); e == nil {
		t.Fatal("invalid UTF8 silently replaced")
	}
}
func TestJamRejectsQueriesBeforeCapabilityWork(t *testing.T) {
	l := &jamRecordingLimiter{}
	h := NewJamHandlers(&jam.Repository{}, l, nil, nil)
	m := http.NewServeMux()
	h.RegisterGuestRoutes(m)
	r := httptest.NewRequest("GET", "/api/v1/guest/jams/00000000-0000-4000-8000-000000000001?invite=not-allowed", nil)
	w := httptest.NewRecorder()
	m.ServeHTTP(w, r)
	if w.Code != 400 || len(l.calls) != 0 {
		t.Fatalf("query accepted=%d", w.Code)
	}
}
func TestJamHostWriterIsDefaultDenied(t *testing.T) {
	h := NewJamHandlers(&jam.Repository{}, nil, nil, nil)
	mux := http.NewServeMux()
	h.RegisterHostRoutes(mux)
	r := httptest.NewRequest("POST", "/api/v1/jams", strings.NewReader(`{}`))
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != 503 {
		t.Fatalf("missing dependencies=%d", w.Code)
	}
}
func TestJamDisabledAndSecretSafeHeaders(t *testing.T) {
	h := NewJamHandlers(nil, nil, nil, nil)
	mux := http.NewServeMux()
	h.RegisterGuestRoutes(mux)
	r := httptest.NewRequest("GET", "/api/v1/guest/jams/00000000-0000-4000-8000-000000000001", nil)
	r.Header.Set("Authorization", "Bearer "+jam.NewSecret())
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != 503 || w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Referrer-Policy") != "no-referrer" || strings.Contains(w.Body.String(), "Bearer") {
		t.Fatalf("disabled=%d %v %s", w.Code, w.Header(), w.Body.String())
	}
}
