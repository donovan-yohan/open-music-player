package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/processor"
)

func TestAnalyzerStartupKeepsOrdinaryWorkIndependentOfPrivateMigrationGate(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	database, tracks, analysis := privateAnalysisFixtureDB(t, ctx)
	peer := openPrivateImportFixtureDB(t, ctx)
	private := fixtureSQLPrivateSource(t, ctx, database, tracks)
	const name, old, current, privateCurrent = "startup-independence", "opaque-older", "opaque-public", "opaque-private"
	oldToken := uuid.New()
	requirePrivateClaim(t, ctx, analysis, private, oldToken, name, old, true)

	newTrack := func() *db.Track {
		t.Helper()
		id := uuid.NewString()
		track := &db.Track{IdentityHash: id, Title: "Synthetic public startup " + id, StorageKey: sql.NullString{String: "fixture/" + id, Valid: true}}
		if err := tracks.Create(ctx, track); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
			defer stop()
			if _, err := database.ExecContext(cleanup, `DELETE FROM tracks WHERE id=$1 AND identity_hash=$2 AND private_owner_id IS NULL`, track.ID, id); err != nil {
				t.Error(err)
			}
		})
		return track
	}
	stale, fresh := newTrack(), newTrack()
	if _, err := database.ExecContext(ctx, `INSERT INTO track_analysis (track_id,status,provenance_json)
		VALUES ($1,'analyzed',jsonb_build_object('analyzer',$2::text,'analyzer_version',$3::text))`, stale.ID, name, old); err != nil {
		t.Fatal(err)
	}

	// Isolate a real refusal at the migration key, without performing DDL
	// that could independently block ordinary reads/writes on tracks.
	lock, err := peer.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = lock.Rollback() }()
	if _, err := lock.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('open_music_player_schema_migrate',0))`); err != nil {
		t.Fatal(err)
	}
	wire := make(chan int64, 4)
	var privateEndpoint atomic.Bool
	client := privateAnalysisStartupClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/health" {
			if privateEndpoint.Load() {
				writePrivateAnalysisHealth(w, name, privateCurrent)
			} else {
				writePrivateAnalysisHealth(w, name, current)
			}
			return
		}
		var req struct {
			TrackID int64  `json:"track_id"`
			Name    string `json:"expected_analyzer"`
			Version string `json:"expected_analyzer_version"`
		}
		if r.Method != http.MethodPost || r.URL.Path != "/analyze" || json.NewDecoder(r.Body).Decode(&req) != nil || req.Name != name || req.Version != current {
			t.Errorf("ordinary analyze wire lacks independent startup identity: %+v", req)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		wire <- req.TrackID
		_, _ = fmt.Fprintf(w, `{"schema_version":1,"summary":{"bpm":123},"provenance":{"analyzer":%q,"analyzer_version":%q}}`, name, current)
	})
	worker := processor.New(&processor.ProcessorConfig{TrackRepo: tracks, AnalysisRepo: analysis, AnalyzerClient: client, RequireAnalyzerIdentity: true})
	defer func() {
		shutdown, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if err := worker.Shutdown(shutdown); err != nil {
			t.Error(err)
		}
	}()
	refused := make(chan error, 1)
	drained := make(chan struct{}, 1)
	var loop sync.WaitGroup
	defer func() { cancel(); loop.Wait() }()
	loop.Go(func() {
		runAnalyzerStartupMaintenance(ctx, 25*time.Millisecond, func() error {
			_, err := reconcileAnalyzerVersion(ctx, client, analysis, tracks, worker)
			return err
		}, func() error {
			_, err := reconcilePrivateAnalyzerVersion(ctx, client, analysis)
			if err != nil {
				select {
				case refused <- err:
				default:
				}
			}
			return err
		}, func() {
			select {
			case drained <- struct{}{}:
			default:
			}
		})
	})
	select {
	case err := <-refused:
		if !strings.Contains(err.Error(), "schema migration in progress") {
			t.Fatalf("private startup did not refuse the held migration key: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("did not witness private admission refusal")
	}
	waitForWire := func(want int64, stage string) {
		t.Helper()
		select {
		case got := <-wire:
			if got != want {
				t.Fatalf("%s: analyzed track %d, want %d", stage, got, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: ordinary analysis did not dispatch while the private migration key was held", stage)
		}
	}
	waitForWire(stale.ID, "public startup repair")
	if ok, err := worker.SchedulePostStoreAnalysis(ctx, fresh, processor.PostStoreDownload); !ok || err != nil {
		t.Fatalf("ordinary post-download analysis was not admitted while the key was held: %t %v", ok, err)
	}
	waitForWire(fresh.ID, "ordinary download")
	if err := worker.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	for _, track := range []*db.Track{stale, fresh} {
		row, err := analysis.GetByTrackID(ctx, track.ID)
		if err != nil || row == nil || row.Status != db.AnalysisStatusAnalyzed {
			t.Fatalf("ordinary analysis did not commit under the held key: track=%d row=%+v err=%v", track.ID, row, err)
		}
		assertFixtureResultIdentity(t, row.ProvenanceJSON, name, current)
	}
	select {
	case <-drained:
		t.Fatal("private drain ran before successful private reconciliation")
	default:
	}
	if err := analysis.MarkAnalyzing(ctx, private.TrackID, fixtureClaimProvenance(oldToken, name, old)); err != nil {
		t.Fatalf("ordinary startup sampled and moved a private fence: %v", err)
	}
	t.Log("ordinary repair and post-download results committed while private startup refused the schema key; existing private claim still usable")
	privateEndpoint.Store(true)
	if err := lock.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-drained:
	case <-ctx.Done():
		t.Fatal("private maintenance did not drain after its retry succeeded")
	}
	requirePrivateClaim(t, ctx, analysis, private, uuid.New(), name, current, false)
	requirePrivateClaim(t, ctx, analysis, private, uuid.New(), name, privateCurrent, true)
	t.Log("private retry sampled after schema key release and committed the new fence before drain")
}
