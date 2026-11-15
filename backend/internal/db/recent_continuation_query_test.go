package db

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Same synthetic workload and actual-query EXPLAIN oracle as the established
// read-path gate. No full track hydration is permitted for revision calculation.
func TestRecentContinuationBoundsTrackHydration(t *testing.T) {
	database, ctx := readPathEvidenceDB(t)
	repo := NewPlayEventRepository(database)
	for _, offset := range []int{0, 500} {
		_, revision, _, err := repo.RecentPage(ctx, readPathUser, 20, 0, "")
		if err != nil {
			t.Fatal(err)
		}
		readPathQueries.mu.Lock()
		readPathQueries.queries = nil
		readPathQueries.mu.Unlock()
		got, _, more, err := repo.RecentPage(ctx, readPathUser, 20, offset, revision)
		if err != nil || len(got) != 20 || !more {
			t.Fatalf("offset=%d rows=%d more=%t err=%v", offset, len(got), more, err)
		}
		readPathQueries.mu.Lock()
		queries := append([]readPathQuery(nil), readPathQueries.queries...)
		readPathQueries.mu.Unlock()
		if len(queries) != 2 {
			t.Fatalf("expected narrow revision + bounded hydration, got %d", len(queries))
		}
		if strings.Contains(queries[0].SQL, "JOIN tracks") || strings.Contains(queries[0].SQL, "track_analysis") {
			t.Fatal("revision hydrated track payloads")
		}
		query := queries[1]
		if !strings.Contains(query.SQL, "LIMIT $2 OFFSET $3") {
			t.Fatal("aggregate paging disappeared")
		}
		var plan json.RawMessage
		if err := database.QueryRowContext(ctx, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "+query.SQL, query.Args...).Scan(&plan); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(os.Getenv("OMP_QUERY_EVIDENCE_DIR"), fmt.Sprintf("recent-continuation-offset-%d-plan.json", offset)), plan, 0600); err != nil {
			t.Fatal(err)
		}
		var document []struct{ Plan map[string]interface{} }
		if err := json.Unmarshal(plan, &document); err != nil {
			t.Fatal(err)
		}
		var visits float64
		var walk func(map[string]interface{})
		walk = func(node map[string]interface{}) {
			if node["Relation Name"] == "track_analysis" {
				visits += node["Actual Rows"].(float64) * node["Actual Loops"].(float64)
			}
			if children, ok := node["Plans"].([]interface{}); ok {
				for _, child := range children {
					walk(child.(map[string]interface{}))
				}
			}
		}
		walk(document[0].Plan)
		if visits > 20 {
			t.Fatalf("offset=%d analysis hydration=%g want <=20", offset, visits)
		}
		for _, row := range got {
			var summary map[string]interface{}
			if err := json.Unmarshal(row.AnalysisSummary, &summary); err != nil {
				t.Fatal(err)
			}
			if summary["waveform"] != nil || summary["beat_grid"] != nil {
				t.Fatalf("unbounded analysis payload for %d", row.ID)
			}
		}
		t.Logf("offset=%d returned=%d analysis rows hydrated=%g revision query narrow=true", offset, len(got), visits)
	}
}
