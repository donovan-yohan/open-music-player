package errors

import (
	"net/http"
)

const (
	// RequestIDHeader is the HTTP header for request ID
	RequestIDHeader = "X-Request-ID"
)

// RequestIDMiddleware injects a request ID into the context and response headers
func RequestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Check if request ID is provided in header, otherwise generate one
		requestID := r.Header.Get(RequestIDHeader)
		if requestID == "" {
			requestID = GenerateRequestID()
		}

		// Add request ID to context
		ctx := WithRequestID(r.Context(), requestID)

		// Add request ID to response headers
		w.Header().Set(RequestIDHeader, requestID)

		// Continue with updated context
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Handler wraps an http.HandlerFunc with error handling capabilities
type Handler func(w http.ResponseWriter, r *http.Request) error

// HandleFunc converts a Handler to a standard http.HandlerFunc with automatic error handling
func HandleFunc(h Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := h(w, r); err != nil {
			requestID := GetRequestID(r.Context())
			WriteError(w, requestID, err)
		}
	}
}
