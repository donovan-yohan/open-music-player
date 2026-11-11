package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/jam"
)

// TestJamAcquisitionBrowser serves the real embedded guest and SQL/Redis HTTP
// handlers to a real browser. Provider/worker outputs and host authorization are
// explicitly synthetic; this is not native admission or real-provider proof.
// There is no production control route. All fixture controls exist only here.
func TestJamAcquisitionBrowser(t *testing.T) {
	manifest := os.Getenv("JAM_BROWSER_MANIFEST")
	if manifest == "" {
		t.Skip("set JAM_BROWSER_MANIFEST for a bounded, owned loopback browser journey")
	}
	if !filepath.IsAbs(manifest) || filepath.Dir(manifest) == os.TempDir() {
		t.Fatal("manifest requires its own private absolute directory")
	}
	if _, err := os.Stat(manifest); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("refusing an existing manifest")
	}
	repo, owner, proof, mux := jamIntegration(t)
	ctx := context.Background()
	provider := &jamSyntheticProvider{}
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{provider}})
	lifecycle := db.NewSourceSelectionDownloadLifecycle(&db.DB{DB: repo.DB})
	service, err := download.NewService(&download.ServiceConfig{RedisURL: "redis://" + os.Getenv("JAM_TEST_REDIS") + "/0", WorkerCount: 0}, nil, lifecycle)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Queue().Close() })
	repo.Downloads = &jamLostPublisher{service: service, lose: true}
	id := uuid.New()
	if _, err = repo.Create(ctx, owner, jam.CreateInput{JamID: id, Proof: proof, TrackIDs: []int64{1}, AllowOutsideDiscovery: true}); err != nil {
		t.Fatal(err)
	}
	invite, err := repo.RotateInvite(ctx, owner, id, proof)
	if err != nil {
		t.Fatal(err)
	}
	control := jam.NewSecret()
	mux.HandleFunc("/fixture/observations", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+control {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		var jobs, decisions int
		if e := repo.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM download_jobs`).Scan(&jobs); e != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if e := repo.DB.QueryRowContext(r.Context(), `SELECT count(*) FROM source_selection_decisions`).Scan(&decisions); e != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		jamReply(w, http.StatusOK, map[string]any{"jobs": jobs, "decisions": decisions, "providerCalls": provider.calls.Load()})
	})
	mux.HandleFunc("POST /fixture/complete", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+control {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		view, e := repo.HostSnapshot(r.Context(), owner, id)
		if e != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		for _, request := range view.HostRequests {
			if request.DownloadJobID == uuid.Nil || request.Status != "importing" {
				continue
			}
			job, e := service.GetJob(r.Context(), request.DownloadJobID.String())
			if e == nil {
				_, e = repo.DB.ExecContext(r.Context(), `INSERT INTO tracks(id,identity_hash,title,artist,storage_key,duration_ms) VALUES(2,'jam-browser-synthetic','Afterglow (live, synthetic)','Synthetic artist','synthetic-no-media',181000) ON CONFLICT(id) DO NOTHING`)
			}
			if e == nil {
				_, e = repo.DB.ExecContext(r.Context(), `INSERT INTO user_library(user_id,track_id) VALUES($1,2) ON CONFLICT DO NOTHING`, owner.UserID)
			}
			if e == nil {
				track := int64(2)
				job.TrackID = &track
				e = lifecycle.Complete(r.Context(), job)
			}
			if e != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			jamReply(w, http.StatusOK, map[string]string{"boundary": "synthetic worker/storage; no audio or native insertion"})
			return
		}
		w.WriteHeader(http.StatusConflict)
	})
	server := httptest.NewServer(mux)
	defer server.Close()
	t.Cleanup(func() {
		view, _ := repo.HostSnapshot(ctx, owner, id)
		for _, request := range view.HostRequests {
			if request.DownloadJobID != uuid.Nil {
				job := request.DownloadJobID.String()
				service.Queue().Client().LRem(ctx, "download:queue", 0, job)
				service.Queue().Client().Del(ctx, "download:job:"+job)
				service.Queue().Client().ZRem(ctx, "download:user:"+owner.UserID.String(), job)
			}
		}
		_ = os.Remove(manifest)
	})
	data, err := json.Marshal(map[string]any{"url": server.URL + "/join#jamId=" + id.String() + "&invite=" + invite.JoinToken, "origin": server.URL, "jamId": id, "owner": owner.UserID, "proof": proof, "control": control, "stopFile": manifest + ".stop"})
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(manifest, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Log("owned loopback browser fixture ready; authority stays in private manifest")
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	end := time.After(12 * time.Minute)
	sequence := int64(0)
	for {
		select {
		case <-end:
			return
		case <-ticker.C:
			if _, e := os.Stat(manifest + ".stop"); e == nil {
				_ = os.Remove(manifest + ".stop")
				return
			}
			sequence++
			_, e := repo.Heartbeat(ctx, owner, id, jam.HeartbeatInput{Proof: proof, HostSequence: sequence})
			if e != nil && !errors.Is(e, jam.ErrDenied) {
				t.Fatal("fixture host heartbeat failed")
			}
		}
	}
}
