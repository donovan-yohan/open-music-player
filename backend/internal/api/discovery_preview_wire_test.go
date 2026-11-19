package api

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// Hold the second media write before it reaches the native HTTP writer. The
// caller must see a real prefix with that gate still closed. The decorator
// never flushes and is outside the production router and middleware chain.
type previewTailGate struct {
	http.ResponseWriter
	ctx     context.Context
	held    chan<- struct{}
	release <-chan struct{}
	writes  int
}

func (g *previewTailGate) Unwrap() http.ResponseWriter { return g.ResponseWriter }

func (g *previewTailGate) Write(data []byte) (int, error) {
	g.writes++
	if g.writes == 2 {
		g.held <- struct{}{}
		select {
		case <-g.release:
		case <-g.ctx.Done():
			return 0, g.ctx.Err()
		}
	}
	return g.ResponseWriter.Write(data)
}

func TestDiscoveryPreviewUnauthorizedStalledUploadIsBounded(t *testing.T) {
	cfg, _ := previewRouterConfig(t)
	server := httptest.NewServer(NewRouterWithConfig(&cfg))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	// Go may otherwise drain this incomplete body before sending the refusal.
	if _, err := io.WriteString(conn, "POST "+previewPath+" HTTP/1.1\r\nHost: fixture\r\nContent-Length: 32\r\n\r\n{"); err != nil {
		t.Fatal(err)
	}
	res, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodPost})
	if err != nil {
		t.Fatalf("stalled unauthorized body blocked the response: %v", err)
	}
	assertPreviewError(t, res, http.StatusUnauthorized)
}

func TestDiscoveryPreviewProgressiveWireAndCancellation(t *testing.T) {
	for _, mode := range []string{"complete", "cancel under capacity"} {
		t.Run(mode, func(t *testing.T) {
			cfg, token := mountPreview(t)
			router := NewRouterWithConfig(&cfg)
			const capacity = 4
			held, finished := make(chan struct{}, capacity), make(chan struct{}, capacity)
			release := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("X-Test-Hold-Tail") == "yes" {
					defer func() { finished <- struct{}{} }()
					w = &previewTailGate{ResponseWriter: w, ctx: r.Context(), held: held, release: release}
				}
				router.ServeHTTP(w, r)
			}))
			defer server.Close()
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			await := func(event <-chan struct{}) {
				t.Helper()
				select {
				case <-event:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
			}
			endpoint := server.URL + previewPath
			open := func() (*http.Response, context.CancelFunc, []byte) {
				t.Helper()
				requestCtx, stop := context.WithCancel(ctx)
				t.Cleanup(stop)
				req, err := http.NewRequestWithContext(requestCtx, http.MethodPost, endpoint, strings.NewReader(previewBody(previewSource)))
				if err != nil {
					t.Fatal(err)
				}
				req.Header.Set("Authorization", "Bearer "+token)
				req.Header.Set("Accept-Encoding", "gzip")
				req.Header.Set("X-Test-Hold-Tail", "yes")
				res, err := server.Client().Do(req)
				if err != nil {
					t.Fatalf("wire prefix did not arrive before tail release: %v", err)
				}
				t.Cleanup(func() { res.Body.Close() })
				assertPreviewHeaders(t, res, len(previewStereo), 48000, 36000)
				await(held)
				prefix := make([]byte, 1024)
				if _, err := io.ReadFull(res.Body, prefix); err != nil || !bytes.Equal(prefix, previewStereo[:len(prefix)]) {
					t.Fatalf("missing actual prefix with tail held: %v", err)
				}
				return res, stop, prefix
			}
			first, stop, prefix := open()
			if mode == "complete" {
				close(release)
				tail, err := io.ReadAll(first.Body)
				if err != nil || !bytes.Equal(append(prefix, tail...), previewStereo) {
					t.Fatalf("body did not finish with exact fixture bytes: %v", err)
				}
				await(finished)
				return
			}
			for range capacity - 1 {
				open()
			}
			res, err := requestPreview(ctx, server.Client(), endpoint, token, previewBody(previewSource))
			if err != nil {
				t.Fatal(err)
			}
			assertPreviewError(t, res, http.StatusNotFound)
			stop()
			await(finished) // Server observed cancellation with the tail still held.
			if remainder, err := io.ReadAll(first.Body); err == nil || len(prefix)+len(remainder) >= len(previewStereo) {
				t.Fatalf("canceled transfer completed: bytes=%d err=%v", len(prefix)+len(remainder), err)
			}
			res, err = requestPreview(ctx, server.Client(), endpoint, token, previewBody(previewSource))
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			assertPreviewHeaders(t, res, len(previewStereo), 48000, 36000)
			if got, err := io.ReadAll(res.Body); err != nil || !bytes.Equal(got, previewStereo) {
				t.Fatalf("freed slot did not admit a complete preview: %v", err)
			}
		})
	}
}
