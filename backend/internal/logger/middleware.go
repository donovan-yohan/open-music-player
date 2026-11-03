package logger

import (
	"net/http"

	"time"

	"github.com/felixge/httpsnoop"

	apperrors "github.com/openmusicplayer/backend/internal/errors"
)

// LoggingMiddleware retains local completion logging without buffering bodies.
func LoggingMiddleware(next http.Handler) http.Handler {
	log := Default().WithComponent("http")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		m := httpsnoop.CaptureMetrics(next, w, r)
		log.Info(r.Context(), "request completed", map[string]interface{}{
			"method": r.Method, "route": r.Pattern, "status": m.Code,
			"duration_ms": time.Since(start).Milliseconds(), "bytes": m.Written,
		})
	})
}

// RecoveryMiddleware recovers from panics and logs them
func RecoveryMiddleware(next http.Handler) http.Handler {
	return RecoveryMiddlewareWithLogger(Default().WithComponent("recovery"), next)
}

func RecoveryMiddlewareWithLogger(log *Logger, next http.Handler) http.Handler {
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
