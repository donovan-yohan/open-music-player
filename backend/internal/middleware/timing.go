package middleware

import (
	"log"
	"net/http"
	"time"
)

// Timing returns a middleware that logs request timing and adds Server-Timing headers.
// This enables performance monitoring in browser DevTools and server logs.
func Timing(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		// Create a response writer wrapper to capture status code
		wrapped := &statusResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		// Handle the request
		next.ServeHTTP(wrapped, r)

		// Calculate duration
		duration := time.Since(start)

		// Add Server-Timing header for browser DevTools
		w.Header().Set("Server-Timing", formatServerTiming(duration))

		// Log slow requests (>500ms)
		if duration > 500*time.Millisecond {
			log.Printf("[SLOW] %s %s took %v (status: %d)",
				r.Method, r.URL.Path, duration, wrapped.statusCode)
		}
	})
}

// statusResponseWriter wraps http.ResponseWriter to capture the status code
type statusResponseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (w *statusResponseWriter) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}

func formatServerTiming(d time.Duration) string {
	ms := float64(d.Nanoseconds()) / 1e6
	return "total;dur=" + formatFloat(ms)
}

func formatFloat(f float64) string {
	// Simple float formatting without importing strconv
	intPart := int(f)
	fracPart := int((f - float64(intPart)) * 100)

	result := itoa(intPart)
	if fracPart > 0 {
		result += "." + itoa(fracPart)
	}
	return result
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var result []byte
	for n > 0 {
		result = append([]byte{byte('0' + n%10)}, result...)
		n /= 10
	}
	return string(result)
}
