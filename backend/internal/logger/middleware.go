package logger

import (
	"bytes"
	"io"
	"net/http"
	"strings"
	"time"

	apperrors "github.com/openmusicplayer/backend/internal/errors"
)

// responseWriter wraps http.ResponseWriter to capture status code
type responseWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
	body        *bytes.Buffer
	captureBody bool
}

func newResponseWriter(w http.ResponseWriter, captureBody bool) *responseWriter {
	return &responseWriter{
		ResponseWriter: w,
		status:         http.StatusOK,
		body:           &bytes.Buffer{},
		captureBody:    captureBody,
	}
}

func (rw *responseWriter) WriteHeader(code int) {
	if rw.wroteHeader {
		return
	}
	rw.status = code
	rw.wroteHeader = true
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	if !rw.wroteHeader {
		rw.WriteHeader(http.StatusOK)
	}
	if rw.captureBody {
		rw.body.Write(b)
	}
	return rw.ResponseWriter.Write(b)
}

// LoggingMiddleware logs HTTP requests and responses
func LoggingMiddleware(next http.Handler) http.Handler {
	log := Default().WithComponent("http")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		requestID := apperrors.GetRequestID(r.Context())

		// Don't log health checks
		if r.URL.Path == "/health" {
			next.ServeHTTP(w, r)
			return
		}

		// Don't capture body for streaming endpoints
		captureBody := !strings.HasPrefix(r.URL.Path, "/api/v1/stream/")

		// Wrap response writer
		rw := newResponseWriter(w, captureBody)

		// Log request
		log.Info(r.Context(), "request started", map[string]interface{}{
			"method":     r.Method,
			"path":       r.URL.Path,
			"query":      sanitizeQuery(r.URL.RawQuery),
			"remote_ip":  getClientIP(r),
			"user_agent": r.UserAgent(),
			"request_id": requestID,
		})

		// Process request
		next.ServeHTTP(rw, r)

		// Calculate duration
		duration := time.Since(start)

		// Log response
		fields := map[string]interface{}{
			"method":      r.Method,
			"path":        r.URL.Path,
			"status":      rw.status,
			"duration_ms": duration.Milliseconds(),
			"request_id":  requestID,
		}

		if rw.status >= 400 {
			log.Warn(r.Context(), "request completed with error", fields)
		} else {
			log.Info(r.Context(), "request completed", fields)
		}
	})
}

// sanitizeQuery removes sensitive parameters from query string
func sanitizeQuery(query string) string {
	if query == "" {
		return ""
	}

	sensitiveParams := []string{"token", "password", "secret", "key", "auth"}
	parts := strings.Split(query, "&")
	sanitized := make([]string, 0, len(parts))

	for _, part := range parts {
		keyVal := strings.SplitN(part, "=", 2)
		if len(keyVal) != 2 {
			sanitized = append(sanitized, part)
			continue
		}

		isSensitive := false
		lowerKey := strings.ToLower(keyVal[0])
		for _, s := range sensitiveParams {
			if strings.Contains(lowerKey, s) {
				isSensitive = true
				break
			}
		}

		if isSensitive {
			sanitized = append(sanitized, keyVal[0]+"=[REDACTED]")
		} else {
			sanitized = append(sanitized, part)
		}
	}

	return strings.Join(sanitized, "&")
}

// getClientIP extracts the client IP from the request
func getClientIP(r *http.Request) string {
	// Check X-Forwarded-For header
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		// Return first IP in the list
		ips := strings.Split(xff, ",")
		if len(ips) > 0 {
			return strings.TrimSpace(ips[0])
		}
	}

	// Check X-Real-IP header
	if xri := r.Header.Get("X-Real-IP"); xri != "" {
		return xri
	}

	// Fall back to RemoteAddr
	return r.RemoteAddr
}

// RecoveryMiddleware recovers from panics and logs them
func RecoveryMiddleware(next http.Handler) http.Handler {
	log := Default().WithComponent("recovery")

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				requestID := apperrors.GetRequestID(r.Context())

				log.Error(r.Context(), "panic recovered", map[string]interface{}{
					"panic":      err,
					"request_id": requestID,
					"path":       r.URL.Path,
					"method":     r.Method,
				}, nil)

				// Return internal server error
				apperrors.WriteError(w, requestID, apperrors.InternalError("an unexpected error occurred"))
			}
		}()

		next.ServeHTTP(w, r)
	})
}

// limitReader limits the size of the body that can be read
type limitReader struct {
	r io.Reader
	n int64
}

func (l *limitReader) Read(p []byte) (int, error) {
	if l.n <= 0 {
		return 0, io.EOF
	}
	if int64(len(p)) > l.n {
		p = p[0:l.n]
	}
	n, err := l.r.Read(p)
	l.n -= int64(n)
	return n, err
}
