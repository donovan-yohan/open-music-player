package middleware

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"io"
	"net/http"
	"strings"

	"github.com/felixge/httpsnoop"
)

// ETag buffers only small ordinary GET responses. Upgrade, explicit SSE,
// response-declared SSE, Flush and responses over 1 MiB bypass validators.
// No streaming response waits for handler completion to deliver early bytes.
func ETag(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.Header.Get("Upgrade") != "" || strings.Contains(r.Header.Get("Accept"), "text/event-stream") || strings.HasPrefix(r.URL.Path, "/api/v1/ws/") {
			next.ServeHTTP(w, r)
			return
		}
		var buf bytes.Buffer
		status := http.StatusOK
		committed := false
		streaming := false
		startStream := func() {
			if streaming {
				return
			}
			streaming = true
			w.Header().Del("ETag")
			w.WriteHeader(status)
			if buf.Len() > 0 {
				_, _ = w.Write(buf.Bytes())
				buf.Reset()
			}
		}
		var wrapped http.ResponseWriter
		wrapped = httpsnoop.Wrap(w, httpsnoop.Hooks{
			WriteHeader: func(next httpsnoop.WriteHeaderFunc) httpsnoop.WriteHeaderFunc {
				return func(code int) {
					if streaming {
						next(code)
						return
					}
					if code < 100 || code > 999 {
						next(code)
						return
					}
					if code < 200 {
						next(code)
						return
					}
					if !committed {
						status = code
						committed = true
					}
				}
			},
			Write: func(next httpsnoop.WriteFunc) httpsnoop.WriteFunc {
				return func(data []byte) (int, error) {
					if streaming {
						return next(data)
					}
					committed = true
					if strings.HasPrefix(w.Header().Get("Content-Type"), "text/event-stream") || buf.Len()+len(data) > 1<<20 {
						startStream()
						return next(data)
					}
					return buf.Write(data)
				}
			},
			Flush: func(next httpsnoop.FlushFunc) httpsnoop.FlushFunc { return func() { startStream(); next() } },
			ReadFrom: func(_ httpsnoop.ReadFromFunc) httpsnoop.ReadFromFunc {
				return func(src io.Reader) (int64, error) { return io.Copy(struct{ io.Writer }{wrapped}, src) }
			},
		})
		next.ServeHTTP(wrapped, r)
		if streaming {
			return
		}
		for _, directive := range strings.Split(w.Header().Get("Cache-Control"), ",") {
			if strings.EqualFold(strings.TrimSpace(directive), "no-store") {
				w.Header().Del("ETag")
				w.WriteHeader(status)
				_, _ = w.Write(buf.Bytes())
				return
			}
		}
		hash := md5.Sum(buf.Bytes())
		etag := `"` + hex.EncodeToString(hash[:]) + `"`
		if r.Header.Get("If-None-Match") == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", etag)
		w.Header().Set("Cache-Control", "private, max-age=0, must-revalidate")
		w.WriteHeader(status)
		_, _ = w.Write(buf.Bytes())
	})
}
