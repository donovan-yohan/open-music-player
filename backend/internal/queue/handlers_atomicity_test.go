package queue

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/download"
)

func TestAddQueueItemQueuePersistenceFailureDoesNotEnqueueSourceCandidateDownload(t *testing.T) {
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		t.Skip("REDIS_URL is required for queue/download atomicity integration test")
	}

	ctx := context.Background()
	downloadService, err := download.NewService(&download.ServiceConfig{
		RedisURL:    redisURL,
		WorkerCount: 0,
		MaxRetries:  0,
	}, nil)
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer downloadService.Stop(ctx)

	queueService := &Service{client: redis.NewClient(&redis.Options{Addr: "127.0.0.1:1"})}
	defer queueService.client.Close()

	userID := uuid.New()
	beforeJobs, err := downloadService.GetUserJobs(ctx, userID.String())
	if err != nil {
		t.Fatalf("download jobs before request: %v", err)
	}

	h := NewHandlers(queueService, downloadService)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/queue/items", strings.NewReader(`{
		"position": "last",
		"sourceCandidate": {
			"candidateId": "yt:persist-fail",
			"provider": "youtube",
			"sourceUrl": "https://example.test/watch?v=persist-fail",
			"title": "Persist Fail"
		}
	}`))
	req.Header.Set("Content-Type", "application/json")
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: userID,
		Email:  "user@example.test",
	}))
	rec := httptest.NewRecorder()

	h.AddQueueItem(rec, req)

	afterJobs, err := downloadService.GetUserJobs(ctx, userID.String())
	if err != nil {
		t.Fatalf("download jobs after request: %v", err)
	}
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("AddQueueItem queue persistence failure status = %d, want %d; body=%s", rec.Code, http.StatusInternalServerError, rec.Body.String())
	}
	if len(afterJobs) != len(beforeJobs) {
		t.Fatalf("download job count for user changed from %d to %d when queue persistence failed", len(beforeJobs), len(afterJobs))
	}
}
