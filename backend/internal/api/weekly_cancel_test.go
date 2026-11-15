package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestWeeklyCanceledGenerationRetainsActualCoverage(t *testing.T) {
	f := newWeeklyFixture(t)
	f.artist(weeklyArtistA)
	f.permission("externalCatalogQueries", true)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f.onProvider = func() { cancel() }
	w := httptest.NewRecorder()
	f.router.ServeHTTP(w, f.rawRequest("GET", "weekly", nil).WithContext(ctx))
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	var p map[string]any
	if e := json.Unmarshal(w.Body.Bytes(), &p); e != nil {
		t.Fatal(e)
	}
	if p["status"] != "stale" || p["batchId"] != nil || p["coverage"].(map[string]any)["providerRequests"] != float64(1) {
		t.Fatal("retired publication erased actual provider request evidence", w.Body.String())
	}
	if dir := osWireDir(); dir != "" {
		saveWire(t, dir, "weekly-canceled", w.Body.Bytes())
	}
	f.onProvider = nil
	f.restart()
	p = f.ok("GET", "weekly", nil, "")
	if p["status"] != "unavailable" || f.calls.Load() != 1 {
		t.Fatal("canceled generation minted retry entitlement")
	}
}
