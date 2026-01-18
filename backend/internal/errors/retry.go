package errors

import (
	"context"
	"math"
	"math/rand"
	"net"
	"net/http"
	"strings"
	"time"
)

// RetryConfig holds configuration for retry behavior
type RetryConfig struct {
	MaxRetries     int
	InitialBackoff time.Duration
	MaxBackoff     time.Duration
	BackoffFactor  float64
	Jitter         bool
}

// DefaultRetryConfig returns a sensible default configuration
func DefaultRetryConfig() *RetryConfig {
	return &RetryConfig{
		MaxRetries:     3,
		InitialBackoff: 1 * time.Second,
		MaxBackoff:     30 * time.Second,
		BackoffFactor:  2.0,
		Jitter:         true,
	}
}

// MusicBrainzRetryConfig returns configuration optimized for MusicBrainz API
func MusicBrainzRetryConfig() *RetryConfig {
	return &RetryConfig{
		MaxRetries:     3,
		InitialBackoff: 1 * time.Second,  // MB has rate limit of 1 req/sec
		MaxBackoff:     10 * time.Second,
		BackoffFactor:  2.0,
		Jitter:         true,
	}
}

// StorageRetryConfig returns configuration optimized for S3/MinIO operations
func StorageRetryConfig() *RetryConfig {
	return &RetryConfig{
		MaxRetries:     5,
		InitialBackoff: 500 * time.Millisecond,
		MaxBackoff:     30 * time.Second,
		BackoffFactor:  2.0,
		Jitter:         true,
	}
}

// DownloadRetryConfig returns configuration optimized for yt-dlp downloads
func DownloadRetryConfig() *RetryConfig {
	return &RetryConfig{
		MaxRetries:     3,
		InitialBackoff: 2 * time.Second,
		MaxBackoff:     60 * time.Second,
		BackoffFactor:  2.0,
		Jitter:         true,
	}
}

// RetryableFunc is a function that can be retried
type RetryableFunc func(ctx context.Context) error

// Retry executes the given function with retry logic
func Retry(ctx context.Context, cfg *RetryConfig, fn RetryableFunc) error {
	if cfg == nil {
		cfg = DefaultRetryConfig()
	}

	var lastErr error

	for attempt := 0; attempt <= cfg.MaxRetries; attempt++ {
		// Check context before each attempt
		if ctx.Err() != nil {
			return ctx.Err()
		}

		// Execute the function
		err := fn(ctx)
		if err == nil {
			return nil
		}

		lastErr = err

		// Check if error is retryable
		if !isRetryableError(err) {
			return err
		}

		// Don't wait after the last attempt
		if attempt == cfg.MaxRetries {
			break
		}

		// Calculate backoff with exponential increase
		backoff := calculateRetryBackoff(attempt, cfg)

		// Wait for backoff duration or context cancellation
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
	}

	return lastErr
}

// RetryWithResult executes a function that returns a value with retry logic
func RetryWithResult[T any](ctx context.Context, cfg *RetryConfig, fn func(ctx context.Context) (T, error)) (T, error) {
	if cfg == nil {
		cfg = DefaultRetryConfig()
	}

	var zero T
	var lastErr error
	var result T

	for attempt := 0; attempt <= cfg.MaxRetries; attempt++ {
		if ctx.Err() != nil {
			return zero, ctx.Err()
		}

		var err error
		result, err = fn(ctx)
		if err == nil {
			return result, nil
		}

		lastErr = err

		if !isRetryableError(err) {
			return zero, err
		}

		if attempt == cfg.MaxRetries {
			break
		}

		backoff := calculateRetryBackoff(attempt, cfg)

		select {
		case <-ctx.Done():
			return zero, ctx.Err()
		case <-time.After(backoff):
		}
	}

	return zero, lastErr
}

// calculateRetryBackoff calculates the backoff duration for a given attempt
func calculateRetryBackoff(attempt int, cfg *RetryConfig) time.Duration {
	backoff := float64(cfg.InitialBackoff) * math.Pow(cfg.BackoffFactor, float64(attempt))

	if time.Duration(backoff) > cfg.MaxBackoff {
		backoff = float64(cfg.MaxBackoff)
	}

	// Add jitter (±25%)
	if cfg.Jitter {
		jitter := backoff * 0.25 * (rand.Float64()*2 - 1)
		backoff = backoff + jitter
	}

	return time.Duration(backoff)
}

// isRetryableError determines if an error should be retried
func isRetryableError(err error) bool {
	if err == nil {
		return false
	}

	// Check for context errors - don't retry
	if err == context.Canceled || err == context.DeadlineExceeded {
		return false
	}

	// Check for AppError with retryable flag
	if appErr, ok := err.(*AppError); ok {
		return IsRetryable(appErr)
	}

	// Check for network errors
	if netErr, ok := err.(net.Error); ok {
		return netErr.Temporary() || netErr.Timeout()
	}

	// Check for common retryable error messages
	errStr := strings.ToLower(err.Error())
	retryablePatterns := []string{
		"connection refused",
		"connection reset",
		"timeout",
		"temporary failure",
		"service unavailable",
		"too many requests",
		"rate limit",
		"503",
		"502",
		"504",
		"429",
	}

	for _, pattern := range retryablePatterns {
		if strings.Contains(errStr, pattern) {
			return true
		}
	}

	return false
}

// HTTPRetryableStatus returns true if the HTTP status code is retryable
func HTTPRetryableStatus(statusCode int) bool {
	switch statusCode {
	case http.StatusTooManyRequests,      // 429
		http.StatusInternalServerError,   // 500
		http.StatusBadGateway,            // 502
		http.StatusServiceUnavailable,    // 503
		http.StatusGatewayTimeout:        // 504
		return true
	default:
		return false
	}
}
