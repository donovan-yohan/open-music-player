package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

func TestWeeklyProviderHTTP429503RetainsCooldown(t *testing.T) {
	for _, status := range []int{429, 503} {
		t.Run(map[int]string{429: "429", 503: "503"}[status], func(t *testing.T) {
			f := newWeeklyFixture(t)
			f.artist(weeklyArtistA)
			f.permission("externalCatalogQueries", true)
			f.providerStatus = status
			page := f.ok("GET", "weekly", nil, "")
			if page["status"] != "unavailable" || page["batchId"] != nil || f.calls.Load() != 2 || page["coverage"].(map[string]any)["providerRequests"] != float64(2) {
				t.Fatal("HTTP provider failure misclassified", page, f.calls.Load())
			}
			f.restart()
			page = f.ok("GET", "weekly", nil, "")
			if page["status"] != "unavailable" || f.calls.Load() != 2 {
				t.Fatal("status retry minted fresh attempt")
			}
		})
	}
}
func TestWeeklyStricterCallerDeadlineBoundsProviderAndPreservesUsage(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	f.providerBlock = true
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	started := time.Now()
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, f.rawRequest("GET", "weekly", nil).WithContext(ctx))
	elapsed := time.Since(started)
	if w.Code != 200 || elapsed > 3*time.Second {
		t.Fatal("stricter deadline not honored", elapsed, w.Code, w.Body.String())
	}
	var page map[string]any
	if e := json.Unmarshal(w.Body.Bytes(), &page); e != nil {
		t.Fatal(e)
	}
	if page["status"] != "unavailable" || page["coverage"].(map[string]any)["providerRequests"] != float64(1) || f.calls.Load() != 1 {
		t.Fatal("deadline lost actual dispatch or mislabeled success", page)
	}
	if dir := osWireDir(); dir != "" {
		saveWire(t, dir, "weekly-timeout", w.Body.Bytes())
	}
}
