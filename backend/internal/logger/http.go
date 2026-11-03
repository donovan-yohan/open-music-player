package logger

import (
	"context"
	"time"
)

// HTTPCompletion is the entire remote log schema. It contains only values
// projected by the request observer, never request/response objects or errors.
type HTTPCompletion struct {
	RequestID, Method, Route string
	Status                   int
	Bytes                    int64
	Duration                 time.Duration
}

func (l *Logger) HTTPCompleted(ctx context.Context, event HTTPCompletion) {
	level := LevelInfo
	if event.Status >= 500 {
		level = LevelError
	} else if event.Status >= 400 {
		level = LevelWarn
	}
	l.log(ctx, level, "http.request.completed", map[string]interface{}{
		"http.request.method": event.Method, "http.route": event.Route, "http.response.status_code": event.Status,
		"http.response.body.size": event.Bytes, "duration_ms": float64(event.Duration) / float64(time.Millisecond),
	}, nil)
	// Remote completion records are not suppressed by the local LOG_LEVEL.
	if l.httpObserver != nil {
		l.httpObserver(ctx, event)
	}
}
