package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

// This is real loopback HTTP, normal Router/Auth/Weekly handlers and durable
// PostgreSQL. Only external MusicBrainz transport is a labeled collaborator.
func TestWeeklyOrdinaryTCPHTTPFeedbackToNextRanking(t *testing.T) {
	f := newWeeklyFixture(t)
	var instant atomic.Int64
	instant.Store(f.now.UnixNano())
	f.router.weeklyHandlers.now = func() time.Time { return time.Unix(0, instant.Load()).UTC() }
	server := httptest.NewServer(f.router)
	t.Cleanup(server.Close)
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true}
	t.Cleanup(transport.CloseIdleConnections)
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second}
	base, e := url.Parse(server.URL)
	if e != nil {
		t.Fatal(e)
	}
	authorization := f.rawRequest("GET", "preferences", nil).Header.Get("Authorization")
	requests := 0
	call := func(method, path string, body any, name string) map[string]any {
		requests++
		t.Helper()
		var b []byte
		if body != nil {
			b, _ = json.Marshal(body)
		}
		request, e := http.NewRequestWithContext(context.Background(), method, server.URL+weeklyRoot+path, bytes.NewReader(b))
		if e != nil {
			t.Fatal(e)
		}
		request.Header.Set("Authorization", authorization)
		request.Header.Set("Content-Type", "application/json")
		response, e := client.Do(request)
		if e != nil {
			t.Fatal(e)
		}
		defer response.Body.Close()
		raw, e := io.ReadAll(io.LimitReader(response.Body, 1800001))
		if e != nil || response.StatusCode != 200 || response.Header.Get("Cache-Control") != "private, no-store" {
			t.Fatal("ordinary TCP response", response.StatusCode, string(raw), e)
		}
		var out map[string]any
		if e = json.Unmarshal(raw, &out); e != nil {
			t.Fatal(e)
		}
		if dir := osWireDir(); dir != "" && name != "" {
			saveWire(t, dir, name, raw)
		}
		return out
	}
	for _, artist := range []string{weeklyArtistA, weeklyArtistB} {
		call("PUT", "preferences", map[string]any{"resource": "artist", "artistMbid": artist, "interested": true, "blocked": false, "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": 0}, "")
	}
	call("PUT", "preferences", map[string]any{"resource": "permission", "permission": "externalCatalogQueries", "enabled": true, "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": 0}, "")
	neutral := call("GET", "weekly", nil, "tcp-weekly-neutral")
	if weeklyIDs(neutral)[0] != weeklyRecordingA {
		t.Fatal("neutral order")
	}
	call("PUT", "feedback/"+weeklyRecordingB, map[string]any{"vote": "up", "mutationId": uuid.NewString(), "expectedRevision": 0, "profileEpoch": neutral["profileEpoch"], "batchId": neutral["batchId"]}, "tcp-feedback-ack")
	current := call("GET", "weekly", nil, "tcp-weekly-current")
	if current["batchId"] != neutral["batchId"] || strings.Join(weeklyIDs(current), ",") != strings.Join(weeklyIDs(neutral), ",") {
		t.Fatal("ordinary HTTP current base reranked")
	}
	instant.Store(f.now.AddDate(0, 0, 7).UnixNano())
	next := call("GET", "weekly", nil, "tcp-weekly-next-up")
	if weeklyIDs(next)[0] != weeklyRecordingB || f.calls.Load() != 2 {
		t.Fatal("ordinary TCP feedback did not reach next generation")
	}
	transport.CloseIdleConnections()
	server.Close()
	conn, e := net.DialTimeout("tcp", base.Host, 100*time.Millisecond)
	if conn != nil {
		conn.Close()
	}
	if e == nil {
		t.Fatal("owned loopback listener not closed")
	}
	if dir := osWireDir(); dir != "" {
		b, _ := json.MarshalIndent(map[string]any{"listener": base.Host, "listenerClosed": true, "clientIdleConnectionsClosed": true, "requests": requests, "collaborator": "synthetic MusicBrainz transport only"}, "", "  ")
		if e = os.WriteFile(filepath.Join(filepath.Dir(dir), "tcp-resource-release.json"), b, 0600); e != nil {
			t.Fatal(e)
		}
	}
}
