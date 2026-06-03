package api

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
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
