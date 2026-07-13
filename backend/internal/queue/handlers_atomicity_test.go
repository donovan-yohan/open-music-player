package queue

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAddQueueItemQueuePersistenceFailureDoesNotEnqueueSourceCandidateDownload(t *testing.T) {
	service := &fakeQueueHandlerService{state: &QueueState{Items: []QueueItem{}}}
	downloads := &fakeQueueDownloadService{}
	decision := sourceDecisionForQueue(t, sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=persist-fail", ""))
	repo := &fakeSourceDecisionRepository{
		decision:  decision,
		attachErr: errors.New("queue intent persistence failed"),
	}
	h := NewHandlersWithSourceSelections(service, downloads, nil, repo, &fakeDurableDownloadJobStore{})
	req := queueDecisionRequest(`{
		"position": "last",
		"sourceDecisionId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	}`)
	rec := httptest.NewRecorder()

	h.AddQueueItem(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("AddQueueItem queue persistence failure status = %d, want %d; body=%s", rec.Code, http.StatusInternalServerError, rec.Body.String())
	}
	if len(downloads.enqueued) != 0 {
		t.Fatalf("download enqueue count changed to %d when queue intent persistence failed", len(downloads.enqueued))
	}
}
