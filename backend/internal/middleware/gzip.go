package middleware

import (
	"compress/gzip"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/felixge/httpsnoop"
)

var gzipWriterPool = sync.Pool{New: func() interface{} { return gzip.NewWriter(io.Discard) }}

// Gzip selects encoding lazily so response-declared streaming is not compressed.
// Flush/ReaderFrom retain their semantics and optional interfaces are preserved.
func Gzip(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") || r.Header.Get("Upgrade") != "" || strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
			next.ServeHTTP(w, r)
			return
		}
		var gz *gzip.Writer
		decided := false
		selectEncoding := func(code int) {
			if decided {
				return
			}
			decided = true
			if strings.HasPrefix(w.Header().Get("Content-Type"), "text/event-stream") || code == http.StatusNoContent || code == http.StatusNotModified || r.Method == "HEAD" {
				return
			}
			gz = gzipWriterPool.Get().(*gzip.Writer)
			gz.Reset(w)
			w.Header().Del("Content-Length")
			w.Header().Set("Content-Encoding", "gzip")
			w.Header().Add("Vary", "Accept-Encoding")
		}
		defer func() {
			if gz != nil {
				_ = gz.Close()
				gzipWriterPool.Put(gz)
			}
		}()
		var wrapped http.ResponseWriter
		wrapped = httpsnoop.Wrap(w, httpsnoop.Hooks{
			WriteHeader: func(next httpsnoop.WriteHeaderFunc) httpsnoop.WriteHeaderFunc {
				return func(code int) {
					if code >= 200 {
						selectEncoding(code)
					}
					next(code)
				}
			},
			Write: func(next httpsnoop.WriteFunc) httpsnoop.WriteFunc {
				return func(data []byte) (int, error) {
					if !decided && w.Header().Get("Content-Type") == "" {
						w.Header().Set("Content-Type", http.DetectContentType(data))
					}
					selectEncoding(http.StatusOK)
					if gz != nil {
						return gz.Write(data)
					}
					return next(data)
				}
			},
			Flush: func(next httpsnoop.FlushFunc) httpsnoop.FlushFunc {
				return func() {
					selectEncoding(http.StatusOK)
					if gz != nil {
						_ = gz.Flush()
					}
					next()
				}
			},
			ReadFrom: func(_ httpsnoop.ReadFromFunc) httpsnoop.ReadFromFunc {
				return func(src io.Reader) (int64, error) { return io.Copy(struct{ io.Writer }{wrapped}, src) }
			},
		})
		next.ServeHTTP(wrapped, r)
	})
}
