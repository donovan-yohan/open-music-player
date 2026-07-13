package api

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
)

func TestCreateDownloadRejectsNonHTTPUserFacingURLBeforeEnqueue(t *testing.T) {
	handler := NewDownloadHandlers(nil)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/downloads", bytes.NewBufferString(`{"url":"file:///etc/passwd","source_type":"youtube"}`))
	req.Header.Set("Content-Type", "application/json")
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111"),
		Email:  "user@example.test",
	}))
	rec := httptest.NewRecorder()

	handler.CreateDownload(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("CreateDownload file:// status = %d, want %d; body=%s", rec.Code, http.StatusBadRequest, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("INVALID_URL")) {
		t.Fatalf("CreateDownload file:// response should name INVALID_URL, got %s", rec.Body.String())
	}
}

func TestCreateDownloadRejectsHTTPURLBeforeTrustedIngestion(t *testing.T) {
	handler := NewDownloadHandlers(nil)
	rec := httptest.NewRecorder()
	handler.CreateDownload(rec, authenticatedDownloadRequest(`{"url":"http://www.youtube.com/watch?v=plain-http","source_type":"youtube"}`))
	if rec.Code != http.StatusBadRequest || !bytes.Contains(rec.Body.Bytes(), []byte("INVALID_URL")) {
		t.Fatalf("http URL status=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestCreateDownloadCreatesTrustedDecisionAndKeepsResponseFields(t *testing.T) {
	ingestion := &fakeDirectIngestion{}
	handler := NewDownloadHandlers(fakeDirectDownloadService{}, ingestion)
	req := authenticatedDownloadRequest(`{"url":"https://www.youtube.com/watch?v=trusted","source_type":"attacker-controlled","page_metadata":{"title":"Shared title"}}`)
	rec := httptest.NewRecorder()
	handler.CreateDownload(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("CreateDownload status = %d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"job_id":"job-1"`) || !strings.Contains(rec.Body.String(), `"status":"queued"`) || !strings.Contains(rec.Body.String(), `"sourceDecisionId":"`) {
		t.Fatalf("response lost compatibility or decision id: %s", rec.Body.String())
	}
	if ingestion.created == nil || ingestion.created.Candidate.Provider != "youtube" {
		t.Fatalf("candidate was not server-normalized: %+v", ingestion.created)
	}
}

func TestCreateDownloadRejectsUnknownAndOversizedFields(t *testing.T) {
	handler := NewDownloadHandlers(nil)
	for name, body := range map[string]string{
		"unknown":   `{"url":"https://www.youtube.com/watch?v=x","source_type":"youtube","identity":"attacker"}`,
		"oversized": `{"url":"https://www.youtube.com/watch?v=x","page_metadata":{"title":"` + strings.Repeat("x", 501) + `"}}`,
	} {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			handler.CreateDownload(rec, authenticatedDownloadRequest(body))
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestCreateDownloadEnqueueFailureKeepsTrustedAudit(t *testing.T) {
	ingestion := &fakeDirectIngestion{enqueueErr: errors.New("redis unavailable")}
	handler := NewDownloadHandlers(fakeDirectDownloadService{}, ingestion)
	rec := httptest.NewRecorder()
	handler.CreateDownload(rec, authenticatedDownloadRequest(`{"url":"https://soundcloud.com/artist/track"}`))
	if rec.Code != http.StatusInternalServerError || ingestion.created == nil || !ingestion.enqueueCalled {
		t.Fatalf("status/audit = %d/%+v/%v", rec.Code, ingestion.created, ingestion.enqueueCalled)
	}
}

func authenticatedDownloadRequest(body string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/downloads", bytes.NewBufferString(body))
	return req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.MustParse("11111111-1111-1111-1111-111111111111")}))
}

type fakeDirectDownloadService struct{}

func (fakeDirectDownloadService) EnqueueSourceCandidateWithID(_ context.Context, id, userID string, candidate download.SourceCandidate, _ *string) (*download.DownloadJob, error) {
	return &download.DownloadJob{ID: id, UserID: userID, Status: download.StatusQueued, URL: candidate.SourceURL}, nil
}
func (fakeDirectDownloadService) GetJob(context.Context, string) (*download.DownloadJob, error) {
	return nil, errors.New("not found")
}
func (fakeDirectDownloadService) GetUserJobs(context.Context, string) ([]*download.DownloadJob, error) {
	return nil, nil
}

type fakeDirectIngestion struct {
	created       *db.SourceSelectionDownload
	enqueueErr    error
	enqueueCalled bool
}

func (f *fakeDirectIngestion) CreateTrustedDownload(_ context.Context, userID uuid.UUID, origin string, candidate download.SourceCandidate, _ string) (*db.SourceSelectionDownload, error) {
	f.created = &db.SourceSelectionDownload{Decision: &db.SourceSelectionDecision{ID: uuid.New(), UserID: userID, Origin: origin}, Job: &download.DownloadJob{ID: "job-1", UserID: userID.String(), Status: download.StatusQueued}, Candidate: candidate}
	return f.created, nil
}
func (f *fakeDirectIngestion) EnqueueTrustedDownload(_ context.Context, persisted *db.SourceSelectionDownload, _ db.SourceSelectionDownloadEnqueuer) (*download.DownloadJob, error) {
	f.enqueueCalled = true
	if f.enqueueErr != nil {
		return nil, f.enqueueErr
	}
	return persisted.Job, nil
}
