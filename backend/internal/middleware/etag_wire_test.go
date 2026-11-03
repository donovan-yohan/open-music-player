package middleware

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestETagGzipContentTypeOnWire(t *testing.T) {
	for _, tc := range []struct {
		name, body, contentType, wantType string
		noStore, flush, split, validator  bool
		status                            int
	}{
		{name: "text", body: "ordinary response", wantType: "text/plain; charset=utf-8", validator: true, status: http.StatusOK},
		{name: "html", body: "<!DOCTYPE html><html><body>response</body></html>", wantType: "text/html; charset=utf-8", validator: true, status: http.StatusOK},
		{name: "binary", body: "\x00\x01\x02\x03", wantType: "application/octet-stream", validator: true, status: http.StatusOK},
		{name: "explicit", body: `{"ok":true}`, contentType: "application/json", wantType: "application/json", validator: true, status: http.StatusOK},
		{name: "no-store", body: "private response", wantType: "text/plain; charset=utf-8", noStore: true, status: http.StatusUnauthorized},
		{name: "flush", body: "flushed response", wantType: "text/plain; charset=utf-8", flush: true, split: true, status: http.StatusOK},
		{name: "large", body: strings.Repeat("a", (1<<20)+1), wantType: "text/plain; charset=utf-8", status: http.StatusOK},
		{name: "buffered-large", body: strings.Repeat("b", (1<<20)+1), wantType: "text/plain; charset=utf-8", split: true, status: http.StatusOK},
		{name: "sse", body: "data: response\n\n", contentType: "text/event-stream", wantType: "text/event-stream", flush: true, split: true, status: http.StatusOK},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(Timing(Gzip(ETag(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if tc.contentType != "" {
					w.Header().Set("Content-Type", tc.contentType)
				}
				if tc.noStore {
					w.Header().Set("Cache-Control", "private, no-store")
				}
				// Explicit status must not prevent sniffing the first uncompressed write.
				w.WriteHeader(tc.status)
				if tc.split {
					_, _ = io.WriteString(w, tc.body[:3])
					if tc.flush {
						if err := http.NewResponseController(w).Flush(); err != nil {
							t.Error(err)
						}
					}
					_, _ = io.WriteString(w, tc.body[3:])
					return
				}
				_, _ = io.WriteString(w, tc.body)
			})))))
			defer server.Close()
			client := server.Client()
			client.Timeout = 3 * time.Second
			for _, encoding := range []string{"identity", "gzip"} {
				t.Run(encoding, func(t *testing.T) {
					request := func(etag string) *http.Response {
						t.Helper()
						req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
						if err != nil {
							t.Fatal(err)
						}
						// Explicit selection prevents Go's client from transparently decoding gzip.
						req.Header.Set("Accept-Encoding", encoding)
						if etag != "" {
							req.Header.Set("If-None-Match", etag)
						}
						res, err := client.Do(req)
						if err != nil {
							t.Fatal(err)
						}
						t.Cleanup(func() { res.Body.Close() })
						return res
					}
					res := request("")
					if res.StatusCode != tc.status {
						t.Errorf("status = %d, want %d", res.StatusCode, tc.status)
					}
					if got := res.Header.Get("Content-Type"); got != tc.wantType {
						t.Errorf("Content-Type = %q, want %q", got, tc.wantType)
					}
					compressed := encoding == "gzip" && tc.contentType != "text/event-stream"
					wantEncoding := ""
					if compressed {
						wantEncoding = "gzip"
					}
					if got := res.Header.Get("Content-Encoding"); got != wantEncoding || res.Uncompressed {
						t.Fatalf("Content-Encoding = %q, want %q; transparently decoded = %v", got, wantEncoding, res.Uncompressed)
					}
					raw, err := io.ReadAll(res.Body)
					if err != nil {
						t.Fatal(err)
					}
					body := raw
					if compressed {
						if !bytes.HasPrefix(raw, []byte{0x1f, 0x8b}) {
							t.Fatal("missing gzip wire bytes")
						}
						reader, err := gzip.NewReader(bytes.NewReader(raw))
						if err != nil {
							t.Fatal(err)
						}
						defer reader.Close()
						body, err = io.ReadAll(reader)
						if err != nil {
							t.Fatal(err)
						}
					}
					if !bytes.Equal(body, []byte(tc.body)) {
						t.Fatalf("response bytes differ: got %d bytes, want %d", len(body), len(tc.body))
					}
					etag := res.Header.Get("ETag")
					if (etag != "") != tc.validator {
						t.Errorf("ETag = %q, want validator = %v", etag, tc.validator)
					}
					if tc.noStore && res.Header.Get("Cache-Control") != "private, no-store" {
						t.Error("no-store policy changed")
					}
					if !tc.validator {
						return
					}
					conditional := request(etag)
					data, err := io.ReadAll(conditional.Body)
					if err != nil {
						t.Fatal(err)
					}
					if conditional.StatusCode != http.StatusNotModified || len(data) != 0 || conditional.Header.Get("Content-Encoding") != "" {
						t.Errorf("conditional response: status %d, bytes %d, encoding %q", conditional.StatusCode, len(data), conditional.Header.Get("Content-Encoding"))
					}
				})
			}
		})
	}
}
