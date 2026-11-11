package middleware

import (
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/felixge/httpsnoop"
)

// Timing measures time to the first response operation, not total handler or
// transfer time. Total duration belongs to the canonical request observation.
func Timing(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		set := false
		setTiming := func() {
			if !set {
				set = true
				w.Header().Set("Server-Timing", formatServerTiming(time.Since(start)))
			}
		}
		wrapped := httpsnoop.Wrap(w, httpsnoop.Hooks{
			WriteHeader: func(next httpsnoop.WriteHeaderFunc) httpsnoop.WriteHeaderFunc {
				return func(code int) {
					if code >= 200 && code <= 999 {
						setTiming()
					}
					next(code)
				}
			},
			Write: func(next httpsnoop.WriteFunc) httpsnoop.WriteFunc {
				return func(data []byte) (int, error) { setTiming(); return next(data) }
			},
			Flush: func(next httpsnoop.FlushFunc) httpsnoop.FlushFunc { return func() { setTiming(); next() } },
			ReadFrom: func(next httpsnoop.ReadFromFunc) httpsnoop.ReadFromFunc {
				return func(src io.Reader) (int64, error) { setTiming(); return next(src) }
			},
		})
		next.ServeHTTP(wrapped, r)
	})
}
func formatServerTiming(d time.Duration) string {
	return "first_response;dur=" + strconv.FormatFloat(float64(d)/float64(time.Millisecond), 'f', 2, 64)
}
