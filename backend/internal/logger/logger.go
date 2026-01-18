package logger

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	apperrors "github.com/openmusicplayer/backend/internal/errors"
)

// Level represents the log level
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

// LogEntry represents a structured log entry
type LogEntry struct {
	Timestamp string                 `json:"timestamp"`
	Level     string                 `json:"level"`
	Message   string                 `json:"message"`
	RequestID string                 `json:"request_id,omitempty"`
	Component string                 `json:"component,omitempty"`
	Error     *ErrorDetails          `json:"error,omitempty"`
	Fields    map[string]interface{} `json:"fields,omitempty"`
	Caller    string                 `json:"caller,omitempty"`
}

// ErrorDetails contains structured error information
type ErrorDetails struct {
	Code       string `json:"code,omitempty"`
	Message    string `json:"message"`
	Category   string `json:"category,omitempty"`
	StackTrace string `json:"stack_trace,omitempty"`
}

// Logger provides structured logging
type Logger struct {
	mu        sync.Mutex
	output    io.Writer
	level     Level
	component string
}

// global default logger
var defaultLogger = New(os.Stdout, LevelInfo, "")

// New creates a new logger
func New(output io.Writer, level Level, component string) *Logger {
	return &Logger{
		output:    output,
		level:     level,
		component: component,
	}
}

// SetDefault sets the default logger
func SetDefault(l *Logger) {
	defaultLogger = l
}

// Default returns the default logger
func Default() *Logger {
	return defaultLogger
}

// WithComponent creates a new logger with the specified component name
func (l *Logger) WithComponent(component string) *Logger {
	return &Logger{
		output:    l.output,
		level:     l.level,
		component: component,
	}
}

// log writes a log entry
func (l *Logger) log(ctx context.Context, level Level, msg string, fields map[string]interface{}, err error) {
	if level < l.level {
		return
	}

	entry := LogEntry{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Level:     level.String(),
		Message:   msg,
		RequestID: apperrors.GetRequestID(ctx),
		Component: l.component,
		Fields:    fields,
	}

	// Add caller info for errors
	if level >= LevelError {
		_, file, line, ok := runtime.Caller(2)
		if ok {
			// Shorten file path
			parts := strings.Split(file, "/")
			if len(parts) > 2 {
				file = strings.Join(parts[len(parts)-2:], "/")
			}
			entry.Caller = fmt.Sprintf("%s:%d", file, line)
		}
	}

	// Add error details if present
	if err != nil {
		entry.Error = &ErrorDetails{
			Message: err.Error(),
		}

		if appErr, ok := err.(*apperrors.AppError); ok {
			entry.Error.Code = appErr.Code
			entry.Error.Category = string(appErr.Category)
		}

		// Add stack trace for errors
		if level >= LevelError {
			entry.Error.StackTrace = getStackTrace()
		}
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	data, _ := json.Marshal(entry)
	l.output.Write(data)
	l.output.Write([]byte("\n"))
}

// Debug logs a debug message
func (l *Logger) Debug(ctx context.Context, msg string, fields ...map[string]interface{}) {
	var f map[string]interface{}
	if len(fields) > 0 {
		f = fields[0]
	}
	l.log(ctx, LevelDebug, msg, f, nil)
}

// Info logs an info message
func (l *Logger) Info(ctx context.Context, msg string, fields ...map[string]interface{}) {
	var f map[string]interface{}
	if len(fields) > 0 {
		f = fields[0]
	}
	l.log(ctx, LevelInfo, msg, f, nil)
}

// Warn logs a warning message
func (l *Logger) Warn(ctx context.Context, msg string, fields ...map[string]interface{}) {
	var f map[string]interface{}
	if len(fields) > 0 {
		f = fields[0]
	}
	l.log(ctx, LevelWarn, msg, f, nil)
}

// Error logs an error message
func (l *Logger) Error(ctx context.Context, msg string, err error, fields ...map[string]interface{}) {
	var f map[string]interface{}
	if len(fields) > 0 {
		f = fields[0]
	}
	l.log(ctx, LevelError, msg, f, err)
}

// Package-level convenience functions

func Debug(ctx context.Context, msg string, fields ...map[string]interface{}) {
	defaultLogger.Debug(ctx, msg, fields...)
}

func Info(ctx context.Context, msg string, fields ...map[string]interface{}) {
	defaultLogger.Info(ctx, msg, fields...)
}

func Warn(ctx context.Context, msg string, fields ...map[string]interface{}) {
	defaultLogger.Warn(ctx, msg, fields...)
}

func Error(ctx context.Context, msg string, err error, fields ...map[string]interface{}) {
	defaultLogger.Error(ctx, msg, err, fields...)
}

// getStackTrace returns a stack trace string
func getStackTrace() string {
	buf := make([]byte, 4096)
	n := runtime.Stack(buf, false)
	return string(buf[:n])
}

// RequestLogger returns a logger with request-specific context
func RequestLogger(ctx context.Context, component string) *Logger {
	return defaultLogger.WithComponent(component)
}
