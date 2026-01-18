package middleware

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"net/http"
	"strings"
)

// etagResponseWriter captures the response for ETag calculation
type etagResponseWriter struct {
	http.ResponseWriter
	buf        *bytes.Buffer
	statusCode int
	written    bool
}

func (w *etagResponseWriter) Write(b []byte) (int, error) {
	if !w.written {
		w.written = true
	}
	return w.buf.Write(b)
}

func (w *etagResponseWriter) WriteHeader(code int) {
	w.statusCode = code
}

// ETag returns a middleware that adds ETag headers for GET requests
// and handles If-None-Match conditional requests.
func ETag(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Only apply ETag to GET requests
		if r.Method != http.MethodGet {
			next.ServeHTTP(w, r)
			return
		}

		// Skip ETag for streaming and WebSocket endpoints
		if strings.HasPrefix(r.URL.Path, "/api/v1/stream/") ||
			strings.HasPrefix(r.URL.Path, "/api/v1/ws/") {
			next.ServeHTTP(w, r)
			return
		}

		// Create a buffer to capture the response
		buf := &bytes.Buffer{}
		wrapped := &etagResponseWriter{
			ResponseWriter: w,
			buf:            buf,
			statusCode:     http.StatusOK,
		}

		// Handle the request
		next.ServeHTTP(wrapped, r)

		// Calculate ETag from response body
		hash := md5.Sum(buf.Bytes())
		etag := `"` + hex.EncodeToString(hash[:]) + `"`

		// Check If-None-Match header
		ifNoneMatch := r.Header.Get("If-None-Match")
		if ifNoneMatch == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}

		// Write ETag header and response
		w.Header().Set("ETag", etag)
		w.Header().Set("Cache-Control", "private, max-age=0, must-revalidate")
		w.WriteHeader(wrapped.statusCode)
		w.Write(buf.Bytes())
	})
}
