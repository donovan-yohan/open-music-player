package preview

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestOnDemandPreviewUsesSelectedSourceAndExistingWire(t *testing.T) {
	data, err := os.ReadFile("../api/testdata/discover-preview-48000.mp3")
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{
		"https://www.youtube.com/watch?v=SQPreview01",
		"https://music.youtube.com/watch?v=SQPreview01",
		"https://soundcloud.com/sq-fixture/generated-preview",
		"https://api.soundcloud.com/tracks/123",
	} {
		t.Run(key, func(t *testing.T) {
			calls := 0
			c := &Catalog{active: make(chan struct{}, maxConcurrent), fetch: func(_ context.Context, source string) ([]byte, error) {
				calls++
				if source != key {
					t.Fatalf("got source %q, want exact selected %q", source, key)
				}
				return data, nil
			}}
			r := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/preview", strings.NewReader(`{"url":"`+key+`"}`))
			w := &previewWriteObservation{ResponseRecorder: httptest.NewRecorder()}
			started := time.Now()
			c.ServeHTTP(w, r)
			if w.Code != http.StatusOK || !w.Flushed || !bytes.Equal(w.Body.Bytes(), data) || calls != 1 ||
				w.Header().Get("Content-Type") != "audio/mpeg" || w.Header().Get("Content-Length") != "13056" ||
				w.Header().Get("X-SoundQ-Preview-Sample-Rate") != "48000" || w.Header().Get("X-SoundQ-Preview-Frames") != "36000" ||
				w.flushedBytes != prefixBytes || w.deadline.Before(started.Add(transferTimeout)) {
				t.Fatalf("wrong preview response: %d, %v, %d bytes, %d fetches", w.Code, w.Header(), w.Body.Len(), calls)
			}
		})
	}
}

func TestOnDemandPreviewRefusesUntrustedKeysBeforeFetch(t *testing.T) {
	c := &Catalog{active: make(chan struct{}, maxConcurrent), fetch: func(context.Context, string) ([]byte, error) {
		t.Fatal("noncanonical source reached fetcher")
		return nil, nil
	}}
	for _, key := range []string{
		"http://www.youtube.com/watch?v=SQPreview01",
		"https://www.youtube.com/watch?v=SQPreview01&list=playlist",
		"https://youtu.be/SQPreview01",
		"https://www.youtube.com@localhost/watch?v=SQPreview01",
		"https://api.soundcloud.com/tracks/123?secret_token=test",
		"https://soundcloud.com/sq-fixture/sets/sample",
	} {
		w := requestClip(c, `{"url":"`+key+`"}`)
		if w.Code != http.StatusNotFound || w.Body.String() != "preview unavailable\n" {
			t.Errorf("got %d %q for noncanonical source", w.Code, w.Body.String())
		}
	}
}

func TestOnDemandPreviewNeverPublishesInvalidAudioOrRawFailure(t *testing.T) {
	for _, tc := range []struct {
		data []byte
		err  error
	}{
		{data: []byte("not MPEG audio")},
		{data: make([]byte, maxClipBytes+1)},
		{err: errors.New("private upstream diagnostics")},
	} {
		c := &Catalog{active: make(chan struct{}, maxConcurrent), fetch: func(context.Context, string) ([]byte, error) {
			return tc.data, tc.err
		}}
		w := requestClip(c, `{"url":"https://www.youtube.com/watch?v=SQPreview01"}`)
		if w.Code != http.StatusNotFound || w.Body.String() != "preview unavailable\n" || w.Flushed || w.Header().Get("X-SoundQ-Preview-Frames") != "" {
			t.Fatalf("unsafe response: %d %v %q", w.Code, w.Header(), w.Body.String())
		}
	}
}

func TestOnDemandPreviewCancellationReleasesAdmission(t *testing.T) {
	const body = `{"url":"https://www.youtube.com/watch?v=SQPreview01"}`
	started := make(chan struct{})
	done := make(chan struct{})
	c := &Catalog{active: make(chan struct{}, 1), fetch: func(ctx context.Context, _ string) ([]byte, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	r := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/preview", strings.NewReader(body)).WithContext(ctx)
	w := httptest.NewRecorder()
	go func() {
		defer close(done)
		c.ServeHTTP(w, r)
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("request never reached acquisition")
	}
	if busy := requestClip(c, body); busy.Code != http.StatusServiceUnavailable || busy.Body.String() != "preview busy\n" {
		t.Fatalf("busy request was not refused: %d %q", busy.Code, busy.Body.String())
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("canceled request did not settle")
	}
	if w.Body.Len() != 0 || w.Flushed || len(c.active) != 0 {
		t.Fatal("canceled response published or retained its admission")
	}
}

type previewWriteObservation struct {
	*httptest.ResponseRecorder
	flushedBytes int
	deadline     time.Time
}

func (w *previewWriteObservation) SetWriteDeadline(at time.Time) error {
	w.deadline = at
	return nil
}

func (w *previewWriteObservation) Flush() {
	w.flushedBytes = w.Body.Len()
	w.ResponseRecorder.Flush()
}

func requestClip(c *Catalog, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/api/v1/discovery/preview", strings.NewReader(body))
	w := httptest.NewRecorder()
	c.ServeHTTP(w, r)
	return w
}
