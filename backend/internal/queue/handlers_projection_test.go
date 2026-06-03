package queue

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/download"
)

func TestQueueResponseProjectsDownloadJobStatusesForMobile(t *testing.T) {
	addedAt := time.Date(2026, 6, 3, 4, 0, 0, 0, time.UTC)
	updatedAt := addedAt.Add(30 * time.Second)
	trackID := int64(42)

	state := &QueueState{
		UpdatedAt: updatedAt,
		Items: []QueueItem{
			{
				ID:            "q_queued",
				Position:      0,
				PlaybackState: "pendingDownload",
				DownloadJobID: "job_queued",
				Source:        &SourceCandidate{CandidateID: "yt:1", Provider: "youtube", SourceURL: "https://example.test/1", Title: "Queued Song", Artist: "Artist"},
				AddedAt:       addedAt,
			},
			{
				ID:            "q_downloading",
				Position:      1,
				PlaybackState: "pendingDownload",
				DownloadJobID: "job_downloading",
				Source:        &SourceCandidate{CandidateID: "yt:2", Provider: "youtube", SourceURL: "https://example.test/2", Title: "Downloading Song"},
				AddedAt:       addedAt,
			},
			{
				ID:            "q_processing",
				Position:      2,
				PlaybackState: "pendingDownload",
				DownloadJobID: "job_processing",
				Source:        &SourceCandidate{CandidateID: "yt:3", Provider: "youtube", SourceURL: "https://example.test/3", Title: "Processing Song"},
				AddedAt:       addedAt,
			},
			{
				ID:            "q_uploading",
				Position:      3,
				PlaybackState: "pendingDownload",
				DownloadJobID: "job_uploading",
				Source:        &SourceCandidate{CandidateID: "yt:4", Provider: "youtube", SourceURL: "https://example.test/4", Title: "Uploading Song"},
				AddedAt:       addedAt,
			},
			{
				ID:            "q_playable",
				Position:      4,
				PlaybackState: "pendingDownload",
				DownloadJobID: "job_complete",
				Source:        &SourceCandidate{CandidateID: "yt:5", Provider: "youtube", SourceURL: "https://example.test/5", Title: "Playable Song"},
				AddedAt:       addedAt,
			},
		},
	}

	jobs := map[string]*download.DownloadJob{
		"job_queued":      {ID: "job_queued", Status: download.StatusQueued, Progress: 0},
		"job_downloading": {ID: "job_downloading", Status: download.StatusDownloading, Progress: 37},
		"job_processing":  {ID: "job_processing", Status: download.StatusProcessing, Progress: 61},
		"job_uploading":   {ID: "job_uploading", Status: download.StatusUploading, Progress: 94},
		"job_complete":    {ID: "job_complete", Status: download.StatusComplete, Progress: 100, TrackID: &trackID},
	}

	resp := buildQueueResponse(state, jobs)
	wantStates := []string{"queued", "downloading", "processing", "uploading", "playable"}
	wantProgress := []int{0, 37, 61, 94, 100}
	for i, want := range wantStates {
		item := resp.Items[i]
		if item.PlaybackState != want {
			t.Fatalf("item %d playbackState = %q, want %q", i, item.PlaybackState, want)
		}
		if item.LegacyPlaybackState != want {
			t.Fatalf("item %d playback_state = %q, want %q", i, item.LegacyPlaybackState, want)
		}
		if item.Progress != wantProgress[i] {
			t.Fatalf("item %d progress = %d, want %d", i, item.Progress, wantProgress[i])
		}
		if item.CanPlay != (want == "playable") {
			t.Fatalf("item %d canPlay = %v, want %v", i, item.CanPlay, want == "playable")
		}
	}
	if resp.Items[4].TrackID == nil || *resp.Items[4].TrackID != trackID {
		t.Fatalf("complete job trackId = %v, want %d", resp.Items[4].TrackID, trackID)
	}
}

func TestQueueResponseProjectsFailedJobErrorAndRetryMetadata(t *testing.T) {
	state := &QueueState{
		UpdatedAt: time.Date(2026, 6, 3, 4, 0, 0, 0, time.UTC),
		Items: []QueueItem{{
			ID:            "q_failed",
			Position:      0,
			PlaybackState: "pendingDownload",
			DownloadJobID: "job_failed",
			Source:        &SourceCandidate{CandidateID: "yt:bad", Provider: "youtube", SourceURL: "https://example.test/bad", Title: "Broken"},
			AddedAt:       time.Date(2026, 6, 3, 3, 59, 0, 0, time.UTC),
		}},
	}
	jobs := map[string]*download.DownloadJob{
		"job_failed": {ID: "job_failed", Status: download.StatusFailed, Progress: 42, Error: "yt-dlp failed: nope"},
	}

	resp := buildQueueResponse(state, jobs)
	item := resp.Items[0]
	if item.PlaybackState != "failed" || item.LegacyPlaybackState != "failed" {
		t.Fatalf("failed states = playbackState %q playback_state %q", item.PlaybackState, item.LegacyPlaybackState)
	}
	if item.Error == nil || *item.Error != "yt-dlp failed: nope" {
		t.Fatalf("error = %v, want job error", item.Error)
	}
	if !item.CanRetry {
		t.Fatalf("canRetry = false, want true")
	}
	if item.CanPlay {
		t.Fatalf("canPlay = true, want false")
	}

	body, err := json.Marshal(item)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"queueItemId", "playbackState", "downloadJobId", "progress", "error", "canPlay", "canRetry", "canRemove", "playback_state", "download_job_id"} {
		if !jsonContainsField(body, field) {
			t.Fatalf("marshaled response missing field %q: %s", field, body)
		}
	}
}

func TestGetQueueHandlerProjectsLiveDownloadJobState(t *testing.T) {
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6380"
	}

	queueService, err := NewService(redisURL)
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queueService.Close()

	downloadService, err := download.NewService(&download.ServiceConfig{RedisURL: redisURL, WorkerCount: 0}, nil)
	if err != nil {
		t.Skipf("Redis not available for downloads: %v", err)
	}
	defer downloadService.Stop(context.Background())

	userID := uuid.New()
	candidate := SourceCandidate{
		CandidateID:  "yt:live",
		Provider:     "youtube",
		SourceURL:    "https://example.test/live",
		Title:        "Live Projection",
		Artist:       "Queue Tester",
		Downloadable: true,
	}
	job, err := downloadService.EnqueueSourceCandidate(context.Background(), userID.String(), download.SourceCandidate{
		CandidateID: candidate.CandidateID,
		Provider:    candidate.Provider,
		SourceURL:   candidate.SourceURL,
		Title:       candidate.Title,
		Artist:      candidate.Artist,
	}, nil)
	if err != nil {
		t.Fatalf("enqueue source candidate: %v", err)
	}
	if _, err := queueService.AddSourceCandidate(context.Background(), userID.String(), candidate, job.ID, "last"); err != nil {
		t.Fatalf("add source queue item: %v", err)
	}
	if err := downloadService.UpdateJobProgress(context.Background(), job.ID, download.StatusDownloading, 37); err != nil {
		t.Fatalf("update job progress: %v", err)
	}

	h := NewHandlers(queueService, downloadService)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/queue", nil)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: userID, Email: "queue@example.test"}))
	rec := httptest.NewRecorder()

	h.GetQueue(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/queue = %d, body %s", rec.Code, rec.Body.String())
	}
	var resp QueueResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Items) != 1 {
		t.Fatalf("items len = %d, want 1", len(resp.Items))
	}
	item := resp.Items[0]
	if item.PlaybackState != "downloading" || item.LegacyPlaybackState != "downloading" {
		t.Fatalf("states = playbackState %q playback_state %q, want downloading", item.PlaybackState, item.LegacyPlaybackState)
	}
	if item.Progress != 37 {
		t.Fatalf("progress = %d, want 37", item.Progress)
	}
	if item.CanPlay {
		t.Fatalf("canPlay = true, want false for downloading item")
	}
	if item.DownloadJobID == nil || *item.DownloadJobID != job.ID {
		t.Fatalf("downloadJobId = %v, want %s", item.DownloadJobID, job.ID)
	}
}

func TestAddQueueItemRejectsNonHTTPSourceCandidateBeforeEnqueue(t *testing.T) {
	h := NewHandlers(nil)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/queue/items", strings.NewReader(`{
		"sourceCandidate": {
			"provider": "youtube",
			"sourceUrl": "file:///etc/passwd",
			"title": "bad local file"
		}
	}`))
	req.Header.Set("Content-Type", "application/json")
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111"),
		Email:  "user@example.test",
	}))
	rec := httptest.NewRecorder()

	h.AddQueueItem(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("AddQueueItem file:// status = %d, want %d; body=%s", rec.Code, http.StatusBadRequest, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "INVALID_SOURCE_URL") {
		t.Fatalf("AddQueueItem file:// response should name INVALID_SOURCE_URL, got %s", rec.Body.String())
	}
}

func TestAddQueueItemRejectsInvalidSourceCandidatePositionBeforeEnqueue(t *testing.T) {
	redisURL := os.Getenv("REDIS_URL")
	if redisURL == "" {
		redisURL = "redis://localhost:6380"
	}
	queueService, err := NewService(redisURL)
	if err != nil {
		t.Skipf("Redis not available: %v", err)
	}
	defer queueService.Close()
	downloadService, err := download.NewService(&download.ServiceConfig{RedisURL: redisURL, WorkerCount: 0, MaxRetries: 0, JobTimeout: time.Second}, func(context.Context, *download.DownloadJob, func(int)) error {
		return nil
	})
	if err != nil {
		t.Skipf("download service Redis not available: %v", err)
	}
	defer downloadService.Stop(context.Background())

	ctx := context.Background()
	userID := uuid.MustParse("22222222-2222-2222-2222-222222222222")
	beforeJobs, err := downloadService.GetUserJobs(ctx, userID.String())
	if err != nil {
		t.Fatalf("download jobs before request: %v", err)
	}
	h := NewHandlers(queueService, downloadService)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/queue/items", strings.NewReader(`{
		"position": "definitely-not-a-position",
		"sourceCandidate": {
			"provider": "youtube",
			"sourceUrl": "https://example.test/watch?v=1",
			"title": "bad position"
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
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("AddQueueItem invalid position status = %d, want %d; body=%s", rec.Code, http.StatusBadRequest, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "INVALID_POSITION") {
		t.Fatalf("AddQueueItem invalid position response should name INVALID_POSITION, got %s", rec.Body.String())
	}
	if len(afterJobs) != len(beforeJobs) {
		t.Fatalf("download job count for user changed from %d to %d for invalid queue position", len(beforeJobs), len(afterJobs))
	}
}

func jsonContainsField(body []byte, field string) bool {
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		return false
	}
	_, ok := decoded[field]
	return ok
}
