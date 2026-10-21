package queue

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/download"
)

// Keep the actual download/Redis service; only pause the real GetJob result so
// a queue mutation can commit while GET is assembling its response.
type pausedQueueDownloads struct {
	*download.Service
	pause *queueReadPause
}

func (s *pausedQueueDownloads) GetJob(ctx context.Context, id string) (*download.DownloadJob, error) {
	job, err := s.Service.GetJob(ctx, id)
	if s.pause.armed.CompareAndSwap(true, false) {
		close(s.pause.read)
		select {
		case <-s.pause.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return job, err
}

func TestRedisQueueReadOnlyProjection(t *testing.T) {
	url := isolatedQueueRedis(t)
	ctx := context.Background()
	downloads, err := download.NewService(&download.ServiceConfig{RedisURL: url, WorkerCount: 0}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { downloads.Stop(context.Background()) })
	jobs, err := download.NewQueue(url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = jobs.Close() })
	for _, operation := range []string{"read only", "add", "remove", "clear"} {
		t.Run(operation, func(t *testing.T) {
			s := queueTestService(t, url)
			user := uuid.New()
			job, err := downloads.EnqueueSourceCandidate(ctx, user.String(), download.SourceCandidate{
				CandidateID: "candidate", Provider: "youtube", SourceURL: "https://example.test/song", Title: "song",
			}, nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.EnsureSourceCandidateWithID(ctx, user.String(), "source", SourceCandidate{Title: "song"}, job.ID, "last"); err != nil {
				t.Fatal(err)
			}
			if err := jobs.UpdateTrackID(ctx, job.ID, 42); err != nil {
				t.Fatal(err)
			}
			if err := downloads.UpdateJobProgress(ctx, job.ID, download.StatusComplete, 100); err != nil {
				t.Fatal(err)
			}
			// A short existing TTL makes accidental GET refresh observable.
			if err := s.client.Expire(ctx, s.queueKey(user.String()), time.Hour).Err(); err != nil {
				t.Fatal(err)
			}
			before, err := s.client.Get(ctx, s.queueKey(user.String())).Result()
			if err != nil {
				t.Fatal(err)
			}
			pause := newQueueReadPause()
			h := NewHandlers(s, &pausedQueueDownloads{Service: downloads, pause: pause})
			req := httptest.NewRequest(http.MethodGet, "/api/v1/queue", nil)
			req = req.WithContext(context.WithValue(ctx, auth.UserContextKey, &auth.UserContext{UserID: user}))
			rec := httptest.NewRecorder()
			done := make(chan struct{})
			go func() { defer close(done); h.GetQueue(rec, req) }()
			defer pause.resume()
			select {
			case <-pause.read:
			case <-time.After(10 * time.Second):
				t.Fatal("GET did not reach job projection")
			}
			switch operation {
			case "add":
				_, err = s.AddToQueue(ctx, user.String(), 9, "last")
			case "remove":
				_, err = s.RemoveQueueItem(ctx, user.String(), "source")
			case "clear":
				err = s.ClearQueue(ctx, user.String())
			}
			if err != nil {
				t.Fatal(err)
			}
			pause.resume()
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				t.Fatal("GET did not finish")
			}
			if rec.Code != http.StatusOK {
				t.Fatalf("GET status %d: %s", rec.Code, rec.Body.String())
			}
			var response QueueResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
				t.Fatal(err)
			}
			if len(response.Items) != 1 || response.Items[0].PlaybackState != "playable" ||
				response.Items[0].TrackID == nil || *response.Items[0].TrackID != 42 || !response.Items[0].CanPlay {
				t.Fatalf("GET lost response-only completed-job readiness: %+v", response)
			}
			switch operation {
			case "read only":
				after, err := s.client.Get(ctx, s.queueKey(user.String())).Result()
				if err != nil || after != before {
					t.Fatalf("GET persisted readiness projection: before=%s after=%s err=%v", before, after, err)
				}
				ttl, err := s.client.TTL(ctx, s.queueKey(user.String())).Result()
				if err != nil || ttl > time.Hour || ttl < 59*time.Minute {
					t.Fatalf("GET changed existing TTL: %v %v", ttl, err)
				}
			case "add":
				if got := queueTrackIDs(t, s, user.String()); got != "source,9" {
					t.Fatalf("GET overwrote concurrent add: %q", got)
				}
			case "remove", "clear":
				if got := queueTrackIDs(t, s, user.String()); got != "" {
					t.Fatalf("GET resurrected removed/cleared item: %q", got)
				}
			}
		})
	}
	t.Run("mutation responses retain live readiness without GET persistence", func(t *testing.T) {
		s := queueTestService(t, url)
		user := uuid.New()
		job, err := downloads.EnqueueSourceCandidate(ctx, user.String(), download.SourceCandidate{
			CandidateID: "ready", Provider: "youtube", SourceURL: "https://example.test/ready", Title: "ready",
		}, nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.EnsureSourceCandidateWithID(ctx, user.String(), "ready-source", SourceCandidate{}, job.ID, "last"); err != nil {
			t.Fatal(err)
		}
		if err := jobs.UpdateTrackID(ctx, job.ID, 42); err != nil {
			t.Fatal(err)
		}
		if err := downloads.UpdateJobProgress(ctx, job.ID, download.StatusComplete, 100); err != nil {
			t.Fatal(err)
		}
		h := NewHandlers(s, downloads)
		get := httptest.NewRequest(http.MethodGet, "/api/v1/queue", nil)
		get = get.WithContext(context.WithValue(ctx, auth.UserContextKey, &auth.UserContext{UserID: user}))
		h.GetQueue(httptest.NewRecorder(), get)
		post := httptest.NewRequest(http.MethodPost, "/api/v1/queue/items", strings.NewReader(`{"trackId":9,"position":"last"}`))
		post = post.WithContext(get.Context())
		rec := httptest.NewRecorder()
		h.AddQueueItem(rec, post)
		if rec.Code != http.StatusOK {
			t.Fatalf("add status=%d body=%s", rec.Code, rec.Body.String())
		}
		var response QueueResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if len(response.Items) != 2 || !response.Items[0].CanPlay || response.Items[0].TrackID == nil || *response.Items[0].TrackID != 42 {
			t.Fatalf("mutation response regressed source readiness after read-only GET: %+v", response)
		}
	})
}
