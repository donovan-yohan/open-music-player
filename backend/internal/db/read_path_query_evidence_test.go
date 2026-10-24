package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"database/sql/driver"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

// This opt-in harness only accepts an explicitly supplied, unprotected test DB.
// Seed mode truncates through the existing protected-database guards. Repeat
// mode is read-only and refuses an unexpected workload rather than reseeding.
// It captures SQL from the actual repository, not a hand-maintained SQL copy.
type readPathQuery struct {
	SQL  string
	Args []interface{}
}

type readPathCapture struct {
	mu      sync.Mutex
	queries []readPathQuery
}

type readPathDriver struct{ capture *readPathCapture }
type readPathConn struct {
	driver.Conn
	capture *readPathCapture
}

func (d readPathDriver) Open(dsn string) (driver.Conn, error) {
	conn, err := (&pq.Driver{}).Open(dsn)
	if err != nil {
		return nil, err
	}
	return &readPathConn{Conn: conn, capture: d.capture}, nil
}

func (c *readPathConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	values := make([]interface{}, len(args))
	for i := range args {
		values[i] = args[i].Value
	}
	c.capture.mu.Lock()
	c.capture.queries = append(c.capture.queries, readPathQuery{SQL: query, Args: values})
	c.capture.mu.Unlock()
	return c.Conn.(driver.QueryerContext).QueryContext(ctx, query, args)
}

var readPathDriverOnce sync.Once
var readPathQueries readPathCapture

func readPathEvidenceDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	if os.Getenv("OMP_QUERY_EVIDENCE_DIR") == "" {
		t.Skip("opt-in synthetic PostgreSQL read-path evidence; set OMP_QUERY_EVIDENCE_DIR")
	}
	dsn := postgresTestDSN()
	if dsn == "" || os.Getenv(AllowProtectedDBTestsEnv) != "" {
		t.Fatal("an explicit unprotected throwaway DSN is required; guard bypass is forbidden")
	}
	if err := CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("OMP_QUERY_EVIDENCE_SEED") == "1" {
		database, ctx := newPlayEventTestDB(t)
		seedReadPathWorkload(t, database, ctx)
	}
	readPathDriverOnce.Do(func() { sql.Register("read-path-pq", readPathDriver{capture: &readPathQueries}) })
	raw, err := sql.Open("read-path-pq", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &DB{DB: raw}
	ctx := context.Background()
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal(err)
	}
	var tracks, plays int
	if err := database.QueryRowContext(ctx, `SELECT (SELECT count(*) FROM tracks), (SELECT count(*) FROM play_events)`).Scan(&tracks, &plays); err != nil {
		t.Fatal(err)
	}
	if tracks != 10000 || plays != 300000 {
		t.Fatalf("unexpected synthetic workload: tracks=%d plays=%d", tracks, plays)
	}
	return database, ctx
}

var readPathUser = uuid.MustParse("10000000-0000-0000-0000-000000000001")
var readPathOther = uuid.MustParse("20000000-0000-0000-0000-000000000002")

func seedReadPathWorkload(t *testing.T, database *DB, ctx context.Context) {
	t.Helper()
	queries := []string{
		`INSERT INTO users(id,email,username,password_hash) VALUES
		('10000000-0000-0000-0000-000000000001','query-owner@example.test','owner','synthetic'),
		('20000000-0000-0000-0000-000000000002','query-other@example.test','other','synthetic')`,
		`INSERT INTO tracks(id,identity_hash,title,artist,album,duration_ms,mb_verified,genre,metadata_json,metadata_provenance,codec,content_type)
		SELECT g,md5(g::text)||md5(g::text),'Track '||lpad(g::text,5,'0'),'Artist '||(g%100),'Album '||(g%500),180000+g,
		g%3=0,CASE WHEN g%5=0 THEN NULL WHEN g%7=0 THEN '' ELSE 'Electronic' END,
		jsonb_build_object('synthetic',true,'provider_id',g),'{"source":"synthetic"}'::jsonb,'opus','audio/ogg'
		FROM generate_series(1,10000) g`,
		`INSERT INTO user_library(user_id,track_id,added_at)
		SELECT '10000000-0000-0000-0000-000000000001'::uuid,g,TIMESTAMPTZ '2026-01-01'+g*INTERVAL '1 second' FROM generate_series(1,9000) g
		UNION ALL SELECT '20000000-0000-0000-0000-000000000002',g,TIMESTAMPTZ '2026-01-01'+g*INTERVAL '1 second' FROM generate_series(5001,10000) g`,
		`INSERT INTO track_analysis(track_id,status,summary_json,overrides_json)
		SELECT g,'analyzed',jsonb_build_object('bpm',120,'camelot','8A','energy',0.7,'beat_grid',jsonb_build_object('beats',jsonb_build_array(0,0.5,1.0)),'waveform',repeat('x',2000)),
		CASE WHEN g%4=0 THEN '{"bpm":128,"camelot":"9A"}'::jsonb ELSE '{}'::jsonb END FROM generate_series(1,10000) g`,
		`INSERT INTO track_metadata_overrides(user_id,track_id,title,artist,album)
		SELECT '10000000-0000-0000-0000-000000000001'::uuid,g,'Renamed '||g,'Edited Artist','Edited Album' FROM generate_series(100,9000,100) g
		UNION ALL SELECT '20000000-0000-0000-0000-000000000002',g,'Other Name '||g,'Other Artist','Other Album' FROM generate_series(5100,10000,100) g`,
		`INSERT INTO track_favorites(user_id,track_id) SELECT '10000000-0000-0000-0000-000000000001'::uuid,g FROM generate_series(10,9000,10) g`,
		// Timestamp buckets exercise deterministic ties. Both tenants share track
		// identities, and some historical tracks are no longer in the caller's library.
		`INSERT INTO play_events(user_id,track_id,played_at,context_type,context_id,skipped)
		SELECT '10000000-0000-0000-0000-000000000001'::uuid,1+(g%10000),NOW()-(g/4)*INTERVAL '1 minute',
		CASE WHEN g%3=0 THEN 'playlist' END,CASE WHEN g%3=0 THEN 'synthetic-playlist' END,g%11=0 FROM generate_series(1,200000) g
		UNION ALL SELECT '20000000-0000-0000-0000-000000000002',1+(g%10000),NOW()-(g/4)*INTERVAL '1 minute','library',NULL,g%7=0 FROM generate_series(1,100000) g`,
		`ANALYZE`,
	}
	for i, query := range queries {
		if _, err := database.ExecContext(ctx, query); err != nil {
			t.Fatalf("seed statement %d: %v", i+1, err)
		}
	}
}

func TestReadPathQueryEvidence(t *testing.T) {
	database, ctx := readPathEvidenceDB(t)
	out := os.Getenv("OMP_QUERY_EVIDENCE_DIR")
	if err := os.MkdirAll(out, 0700); err != nil {
		t.Fatal(err)
	}
	library := NewLibraryRepository(database)
	plays := NewPlayEventRepository(database)
	type scenario struct {
		name string
		run  func() (interface{}, int, error)
	}
	scenarios := []scenario{
		{"library_added", func() (interface{}, int, error) {
			rows, total, err := library.GetUserLibrary(ctx, readPathUser, LibraryQueryOptions{Limit: 50})
			if err == nil && total != 9000 {
				return nil, 0, fmt.Errorf("total=%d", total)
			}
			return rows, len(rows), err
		}},
		{"library_edited_filter", func() (interface{}, int, error) {
			rows, total, err := library.GetUserLibrary(ctx, readPathUser, LibraryQueryOptions{Limit: 20, Search: "Renamed", Artist: "Edited Artist", Liked: true, SortBy: "title"})
			if err == nil && total != 90 {
				return nil, 0, fmt.Errorf("filtered total=%d", total)
			}
			return rows, len(rows), err
		}},
		{"recent", func() (interface{}, int, error) {
			rows, err := plays.RecentlyPlayed(ctx, readPathUser, 50, 0)
			return rows, len(rows), err
		}},
		{"recent_offset", func() (interface{}, int, error) {
			rows, err := plays.RecentlyPlayed(ctx, readPathUser, 50, 500)
			return rows, len(rows), err
		}},
		{"top", func() (interface{}, int, error) {
			rows, err := plays.TopTracks(ctx, readPathUser, 30, 50)
			return rows, len(rows), err
		}},
		{"history", func() (interface{}, int, error) {
			rows, err := plays.PlayHistory(ctx, readPathUser, 50, 0)
			return rows, len(rows), err
		}},
	}
	var receipts []map[string]interface{}
	for _, sc := range scenarios {
		if only := os.Getenv("OMP_QUERY_EVIDENCE_ONLY"); only != "" && !strings.HasPrefix(sc.name, only) {
			continue
		}
		readPathQueries.mu.Lock()
		readPathQueries.queries = nil
		readPathQueries.mu.Unlock()
		rows, count, err := sc.run() // untimed warmup and SQL capture
		if err != nil {
			t.Fatal(sc.name, err)
		}
		want := 50
		if sc.name == "library_edited_filter" {
			want = 20
		}
		if count != want {
			t.Fatalf("%s rows=%d want=%d", sc.name, count, want)
		}
		readPathQueries.mu.Lock()
		captured := append([]readPathQuery(nil), readPathQueries.queries...)
		readPathQueries.mu.Unlock()
		encoded, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(encoded)
		if err := os.WriteFile(filepath.Join(out, sc.name+"-results.json"), encoded, 0600); err != nil {
			t.Fatal(err)
		}
		var milliseconds []float64
		for i := 0; i < 5; i++ {
			start := time.Now()
			got, n, err := sc.run()
			elapsed := float64(time.Since(start).Nanoseconds()) / 1e6
			if err != nil || n != want {
				t.Fatalf("%s run %d rows=%d error=%v", sc.name, i, n, err)
			}
			b, err := json.Marshal(got)
			if err != nil {
				t.Fatal(err)
			}
			if sha256.Sum256(b) != sum {
				t.Fatalf("%s unstable results", sc.name)
			}
			milliseconds = append(milliseconds, elapsed)
		}
		if os.Getenv("OMP_QUERY_EVIDENCE_PLANS") == "1" {
			for i, q := range captured {
				var plan json.RawMessage
				if err := database.QueryRowContext(ctx, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "+q.SQL, q.Args...).Scan(&plan); err != nil {
					t.Fatal(sc.name, err)
				}
				base := filepath.Join(out, fmt.Sprintf("%s-query-%d", sc.name, i+1))
				if err := os.WriteFile(base+".sql", []byte(q.SQL), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(base+"-plan.json", plan, 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(base+"-args.json", mustReadPathJSON(t, q.Args), 0600); err != nil {
					t.Fatal(err)
				}
			}
		}
		receipts = append(receipts, map[string]interface{}{"scenario": sc.name, "rows": count, "sql_operations_per_call": len(captured), "warmup_operations": 1, "measured_operations": 5, "errors": 0, "sha256": hex.EncodeToString(sum[:]), "latency_ms": milliseconds})
	}
	if err := os.WriteFile(filepath.Join(out, "receipt.json"), mustReadPathJSON(t, receipts), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestRecentlyPlayedBoundsTrackHydration(t *testing.T) {
	database, ctx := readPathEvidenceDB(t)
	repo := NewPlayEventRepository(database)
	for _, user := range []uuid.UUID{readPathUser, readPathOther} {
		for _, offset := range []int{0, 500} {
			readPathQueries.mu.Lock()
			readPathQueries.queries = nil
			readPathQueries.mu.Unlock()
			got, err := repo.RecentlyPlayed(ctx, user, 50, offset)
			if err != nil {
				t.Fatal(err)
			}
			readPathQueries.mu.Lock()
			query := readPathQueries.queries[0]
			readPathQueries.mu.Unlock()
			// Independent narrow reference: skip filtering, per-track maximum,
			// stable timestamp/identity ties, offset and caller-owned membership.
			expected, err := database.QueryContext(ctx, `SELECT p.track_id, MAX(p.played_at),
			EXISTS(SELECT 1 FROM user_library l WHERE l.user_id=$1 AND l.track_id=p.track_id)
			FROM play_events p WHERE p.user_id=$1 AND NOT p.skipped
			GROUP BY p.track_id ORDER BY MAX(p.played_at) DESC,p.track_id DESC LIMIT 50 OFFSET $2`, user, offset)
			if err != nil {
				t.Fatal(err)
			}
			defer expected.Close()
			i := 0
			for expected.Next() {
				var id int64
				var at time.Time
				var member bool
				if err := expected.Scan(&id, &at, &member); err != nil {
					t.Fatal(err)
				}
				if i >= len(got) || got[i].ID != id || !got[i].LastPlayedAt.Equal(at) || got[i].InLibrary != member {
					t.Fatalf("user=%s offset=%d row=%d mismatch", user, offset, i)
				}
				var metadata map[string]interface{}
				if err := json.Unmarshal(got[i].MetadataJSON, &metadata); err != nil {
					t.Fatal(err)
				}
				if got[i].Title != fmt.Sprintf("Track %05d", id) || got[i].HasMetadataOverride || metadata["synthetic"] != true {
					t.Fatalf("canonical metadata changed for %d", id)
				}
				var summary map[string]interface{}
				if err := json.Unmarshal(got[i].AnalysisSummary, &summary); err != nil {
					t.Fatal(err)
				}
				bpm := float64(120)
				camelot := "8A"
				if id%4 == 0 {
					bpm = 128
					camelot = "9A"
				}
				if summary["bpm"].(map[string]interface{})["value"] != bpm || summary["camelot"].(map[string]interface{})["value"] != camelot || summary["waveform"] != nil {
					t.Fatalf("compact effective analysis changed for %d: %s", id, got[i].AnalysisSummary)
				}
				i++
			}
			if err := expected.Err(); err != nil {
				t.Fatal(err)
			}
			expected.Close()
			if i != 50 || len(got) != i {
				t.Fatalf("rows=%d expected=%d", len(got), i)
			}
			var plan json.RawMessage
			if err := database.QueryRowContext(ctx, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "+query.SQL, query.Args...).Scan(&plan); err != nil {
				t.Fatal(err)
			}
			name := fmt.Sprintf("hydration-%s-offset-%d-plan.json", user, offset)
			if err := os.WriteFile(filepath.Join(os.Getenv("OMP_QUERY_EVIDENCE_DIR"), name), plan, 0600); err != nil {
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
			if visits > 50 {
				t.Errorf("user=%s offset=%d: analysis rows hydrated=%g, want at most returned page (50)", user, offset, visits)
			}
		}
	}
}

func TestRecentlyPlayedPageBeforeHydrationSemantics(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	user := seedPlayUser(t, database, "page-owner@example.test")
	other := seedPlayUser(t, database, "page-other@example.test")
	trackRepo := NewTrackRepository(database)
	first := seedPlayTrack(t, trackRepo, ctx, "Artist", "First")
	second := seedPlayTrack(t, trackRepo, ctx, "Artist", "Second")
	skipOnly := seedPlayTrack(t, trackRepo, ctx, "Artist", "Skipped")
	at := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	insertPlayAt(t, database, user, first, at)
	insertPlayAt(t, database, user, first, at.Add(-time.Hour))
	insertPlayAt(t, database, user, second, at) // tie: larger track id first
	insertSkipAt(t, database, user, skipOnly, at.Add(time.Hour))
	insertPlayAt(t, database, other, skipOnly, at.Add(2*time.Hour))
	if _, err := database.ExecContext(ctx, `INSERT INTO user_library(user_id,track_id) VALUES ($1,$3),($2,$4)`, user, other, second, first); err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, `INSERT INTO track_analysis(track_id,status,summary_json,overrides_json) VALUES ($1,'analyzed','{"bpm":120}','{"bpm":128}')`, second); err != nil {
		t.Fatal(err)
	}
	repo := NewPlayEventRepository(database)
	cases := []struct {
		name          string
		limit, offset int
		ids           []int64
	}{
		{"first_tied_page", 1, 0, []int64{second}},
		{"second_tied_page", 1, 1, []int64{first}},
		{"default_and_negative_offset", 0, -1, []int64{second, first}},
		{"capped_limit", 101, 0, []int64{second, first}},
		{"past_end", 10, 2, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rows, err := repo.RecentlyPlayed(ctx, user, tc.limit, tc.offset)
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != len(tc.ids) {
				t.Fatalf("rows=%d want=%d", len(rows), len(tc.ids))
			}
			for i, id := range tc.ids {
				if rows[i].ID != id || !rows[i].LastPlayedAt.Equal(at) || rows[i].InLibrary != (id == second) {
					t.Fatalf("row=%+v want id=%d", rows[i], id)
				}
				if id == first && (rows[i].AnalysisStatus.Valid || string(rows[i].AnalysisSummary) != "{}") {
					t.Fatalf("missing analysis changed: %+v", rows[i])
				}
			}
		})
	}
}

func mustReadPathJSON(t *testing.T, value interface{}) []byte {
	t.Helper()
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return data
}
