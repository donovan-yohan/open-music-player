package api

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/auth"
)

type libraryDeadlineRecorder struct {
	*httptest.ResponseRecorder
	deadline time.Time
}

func (w *libraryDeadlineRecorder) SetReadDeadline(deadline time.Time) error {
	w.deadline = deadline
	return nil
}

func TestPrivateLibraryResponseBoundsHTTP1UploadBeforeDispatch(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, libraryUploadsPath, strings.NewReader("fixture"))
	recorder := &libraryDeadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	received := false
	privateLibraryResponse(func(w http.ResponseWriter, _ *http.Request) {
		received = true
		if remaining := time.Until(recorder.deadline); remaining <= 0 || remaining > 5*time.Second {
			t.Errorf("pre-dispatch read deadline has %v remaining; want a short, active bound", remaining)
		}
		if w.Header().Get("Connection") != "close" || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Error("upload must retain its private, connection-close response policy")
		}
		w.WriteHeader(http.StatusNoContent)
	}, true)(recorder, req)
	if !received || recorder.Code != http.StatusNoContent || recorder.deadline.IsZero() {
		t.Fatal("dispatch must leave a read deadline in place for HTTP cleanup")
	}
}

func TestPrivateLibraryResponseRefusesUploadWithoutDeadlineSupport(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, libraryUploadsPath, strings.NewReader("fixture"))
	w := httptest.NewRecorder()
	privateLibraryResponse(func(http.ResponseWriter, *http.Request) {
		t.Error("dispatched upload through a writer that cannot bound the body")
	}, true)(w, req)
	if w.Code != http.StatusServiceUnavailable || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("unbounded upload status = %d; want private unavailable response", w.Code)
	}
}

func TestPrivateLibraryUploadDisabledWithoutIntake(t *testing.T) {
	sessions := auth.NewService(nil, nil, "private-upload-test")
	router := NewRouterWithConfig(&RouterConfig{AuthService: sessions, AuthHandlers: auth.NewHandlers(sessions)})
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/api/v1/library/uploads", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("default POST status = %d; want absent", w.Code)
	}
}

func TestPrivateLibraryUploadReadbackRequiresAuthentication(t *testing.T) {
	sessions := auth.NewService(nil, nil, "private-upload-test")
	router := NewRouterWithConfig(&RouterConfig{AuthService: sessions, AuthHandlers: auth.NewHandlers(sessions),
		LibraryUploadHandlers: NewLibraryUploadHandlers(nil, nil, nil, false), ResponseTransforms: true})
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/v1/library/tracks/1", nil))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("exact readback status = %d; want authenticated route", w.Code)
	}
	if w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("ETag") != "" {
		t.Fatal("unauthorized response must not be cacheable")
	}
}

func TestPrivateLibraryUploadManifestOwnsNoAudioReadAhead(t *testing.T) {
	const boundary = "fixture-read-ahead"
	const original = "generated opaque content"
	prefix := fmt.Sprintf("--%s\r\nContent-Disposition: form-data; name=manifest\r\nContent-Type: application/json\r\n\r\n{\"title\":\"accepted\",\"sha256\":\"sha256:%s\",\"byte_length\":%d}\r\n--%s\r\n", boundary, strings.Repeat("a", 64), len(original), boundary)
	remainder := fmt.Sprintf("Content-Disposition: form-data; name=audio\r\nContent-Type: audio/mpeg\r\nContent-Length: %d\r\n\r\n%s\r\n--%s--\r\n", len(original), original, boundary)
	input := bytes.NewBufferString(prefix + remainder)
	manifest, audio, err := readUploadManifest(input, boundary)
	if err != nil || manifest.ByteLength != int64(len(original)) {
		t.Fatalf("strict manifest refused: %v", err)
	}
	if input.String() != remainder {
		t.Fatal("manifest parser consumed the audio part before durable admission")
	}
	raw, err := io.ReadAll(audio)
	if err != nil || string(raw) != original || !audio.complete {
		t.Fatalf("exact tail and EOF were not verified: %v", err)
	}
}
