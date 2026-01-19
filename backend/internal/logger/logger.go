package logger

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Level represents log severity levels
type Level int

const (
	LevelDebug Level = iota
	LevelInfo
	LevelWarn
	LevelError
)

func (l Level) String() string {
	switch l {
	case LevelDebug:
		return "debug"
	case LevelInfo:
		return "info"
	case LevelWarn:
		return "warn"
	case LevelError:
		return "error"
	default:
		return "unknown"
	}
}

// ParseLevel converts a string to a Level
func ParseLevel(s string) Level {
	switch strings.ToLower(s) {
	case "debug":
		return LevelDebug
	case "info":
		return LevelInfo
	case "warn", "warning":
		return LevelWarn
	case "error":
		return LevelError
	default:
		return LevelInfo
	}
}

// Entry represents a structured log entry
type Entry struct {
	Timestamp string                 `json:"timestamp"`
	Level     string                 `json:"level"`
	Component string                 `json:"component,omitempty"`
	Message   string                 `json:"message"`
	RequestID string                 `json:"request_id,omitempty"`
	UserID    string                 `json:"user_id,omitempty"`
	TraceID   string                 `json:"trace_id,omitempty"`
	Fields    map[string]interface{} `json:"fields,omitempty"`
	Error     string                 `json:"error,omitempty"`
}

// Logger is the structured JSON logger
type Logger struct {
	mu        sync.Mutex
	out       io.Writer
	minLevel  Level
	redactor  *Redactor
	component string
}

// Config for logger initialization
type Config struct {
	Output   io.Writer
	Level    Level
	Redactor *Redactor
}

// New creates a new Logger instance
func New(cfg *Config) *Logger {
	out := cfg.Output
	if out == nil {
		out = os.Stdout
	}
	redactor := cfg.Redactor
	if redactor == nil {
		redactor = DefaultRedactor()
	}
	return &Logger{
		out:      out,
		minLevel: cfg.Level,
		redactor: redactor,
	}
}

// Default creates a logger with default settings
func Default() *Logger {
	return New(&Config{
		Output:   os.Stdout,
		Level:    ParseLevel(os.Getenv("LOG_LEVEL")),
		Redactor: DefaultRedactor(),
	})
}

// WithComponent returns a new logger with the component field set
func (l *Logger) WithComponent(component string) *Logger {
	return &Logger{
		out:       l.out,
		minLevel:  l.minLevel,
		redactor:  l.redactor,
		component: component,
	}
}

// contextKey is the type for context keys
type contextKey string

const (
	requestIDKey contextKey = "request_id"
	userIDKey    contextKey = "user_id"
	traceIDKey   contextKey = "trace_id"
)

// WithRequestID adds a request ID to the context
func WithRequestID(ctx context.Context, requestID string) context.Context {
	return context.WithValue(ctx, requestIDKey, requestID)
}

// GetRequestID retrieves the request ID from context
func GetRequestID(ctx context.Context) string {
	if v := ctx.Value(requestIDKey); v != nil {
		return v.(string)
	}
	return ""
}

// WithUserID adds a user ID to the context
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}

// GetUserID retrieves the user ID from context
func GetUserID(ctx context.Context) string {
	if v := ctx.Value(userIDKey); v != nil {
		return v.(string)
	}
	return ""
}

// WithTraceID adds a trace ID to the context
func WithTraceID(ctx context.Context, traceID string) context.Context {
	return context.WithValue(ctx, traceIDKey, traceID)
}

// GetTraceID retrieves the trace ID from context
func GetTraceID(ctx context.Context) string {
	if v := ctx.Value(traceIDKey); v != nil {
		return v.(string)
	}
	return ""
}

// log writes a log entry at the specified level
func (l *Logger) log(ctx context.Context, level Level, msg string, fields map[string]interface{}, err error) {
	if level < l.minLevel {
		return
	}

	entry := Entry{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Level:     level.String(),
		Component: l.component,
		Message:   l.redactor.Redact(msg),
		RequestID: GetRequestID(ctx),
		UserID:    GetUserID(ctx),
		TraceID:   GetTraceID(ctx),
	}

	if len(fields) > 0 {
		entry.Fields = l.redactor.RedactFields(fields)
	}

	if err != nil {
		entry.Error = l.redactor.Redact(err.Error())
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	data, _ := json.Marshal(entry)
	l.out.Write(data)
	l.out.Write([]byte("\n"))
}

// Debug logs at debug level
func (l *Logger) Debug(ctx context.Context, msg string, fields map[string]interface{}) {
	l.log(ctx, LevelDebug, msg, fields, nil)
}

// Info logs at info level
func (l *Logger) Info(ctx context.Context, msg string, fields map[string]interface{}) {
	l.log(ctx, LevelInfo, msg, fields, nil)
}

// Warn logs at warn level
func (l *Logger) Warn(ctx context.Context, msg string, fields map[string]interface{}) {
	l.log(ctx, LevelWarn, msg, fields, nil)
}

// Error logs at error level
func (l *Logger) Error(ctx context.Context, msg string, fields map[string]interface{}, err error) {
	l.log(ctx, LevelError, msg, fields, err)
}

// Redactor handles sensitive data redaction in logs
type Redactor struct {
	sensitiveKeys     map[string]bool
	sensitivePatterns []*regexp.Regexp
}

// DefaultRedactor creates a redactor with common sensitive patterns
func DefaultRedactor() *Redactor {
	return &Redactor{
		sensitiveKeys: map[string]bool{
			"password":       true,
			"password_hash":  true,
			"secret":         true,
			"token":          true,
			"access_token":   true,
			"refresh_token":  true,
			"api_key":        true,
			"apikey":         true,
			"authorization":  true,
			"auth":           true,
			"credential":     true,
			"private_key":    true,
			"jwt":            true,
			"bearer":         true,
			"session":        true,
			"cookie":         true,
			"credit_card":    true,
			"card_number":    true,
			"cvv":            true,
			"ssn":            true,
			"s3_secret":      true,
			"minio_secret":   true,
			"db_password":    true,
			"redis_password": true,
		},
		sensitivePatterns: []*regexp.Regexp{
			// JWT tokens
			regexp.MustCompile(`eyJ[A-Za-z0-9-_]+\.eyJ[A-Za-z0-9-_]+\.[A-Za-z0-9-_]+`),
			// Bearer tokens
			regexp.MustCompile(`Bearer\s+[A-Za-z0-9-_]+`),
			// Email addresses (partial redaction)
			regexp.MustCompile(`[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}`),
			// Credit card numbers
			regexp.MustCompile(`\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b`),
			// AWS-style access keys
			regexp.MustCompile(`(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}`),
		},
	}
}

// Redact redacts sensitive information from a string
func (r *Redactor) Redact(s string) string {
	result := s
	for _, pattern := range r.sensitivePatterns {
		result = pattern.ReplaceAllString(result, "[REDACTED]")
	}
	return result
}

// RedactFields redacts sensitive fields from a map
func (r *Redactor) RedactFields(fields map[string]interface{}) map[string]interface{} {
	result := make(map[string]interface{})
	for k, v := range fields {
		lowerKey := strings.ToLower(k)
		if r.sensitiveKeys[lowerKey] {
			result[k] = "[REDACTED]"
		} else if str, ok := v.(string); ok {
			result[k] = r.Redact(str)
		} else if nested, ok := v.(map[string]interface{}); ok {
			result[k] = r.RedactFields(nested)
		} else {
			result[k] = v
		}
	}
	return result
}

// IsSensitiveKey checks if a key name is considered sensitive
func (r *Redactor) IsSensitiveKey(key string) bool {
	return r.sensitiveKeys[strings.ToLower(key)]
}

// AddSensitiveKey adds a new sensitive key to the redactor
func (r *Redactor) AddSensitiveKey(key string) {
	r.sensitiveKeys[strings.ToLower(key)] = true
}

// AddSensitivePattern adds a new sensitive pattern to the redactor
func (r *Redactor) AddSensitivePattern(pattern string) error {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return err
	}
	r.sensitivePatterns = append(r.sensitivePatterns, re)
	return nil
}
