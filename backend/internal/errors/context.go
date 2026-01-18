package errors

import (
	"context"

	"github.com/google/uuid"
)

// contextKey is a type for context keys
type contextKey string

const (
	requestIDKey contextKey = "request_id"
)

// GenerateRequestID generates a new unique request ID
func GenerateRequestID() string {
	return uuid.New().String()
}

// WithRequestID adds a request ID to the context
func WithRequestID(ctx context.Context, requestID string) context.Context {
	return context.WithValue(ctx, requestIDKey, requestID)
}

// GetRequestID retrieves the request ID from the context
func GetRequestID(ctx context.Context) string {
	if requestID, ok := ctx.Value(requestIDKey).(string); ok {
		return requestID
	}
	return ""
}

// RequestIDOrGenerate returns the request ID from context or generates a new one
func RequestIDOrGenerate(ctx context.Context) string {
	if requestID := GetRequestID(ctx); requestID != "" {
		return requestID
	}
	return GenerateRequestID()
}
