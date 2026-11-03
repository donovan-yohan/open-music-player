package observability

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/felixge/httpsnoop"
	"github.com/google/uuid"
	apperrors "github.com/openmusicplayer/backend/internal/errors"
	"github.com/openmusicplayer/backend/internal/logger"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type observationKey struct{}

// HTTP observes a request once. The router sets Request.Pattern from its actual
// ServeMux before entry; absent patterns become a single unknown label. Only
// W3C traceparent/tracestate are extracted. Baggage is never extracted.
func (rt *Runtime) HTTP(next http.Handler) http.Handler {
	return rt.HTTPWithLogger(next, rt.Logger(&logger.Config{Level: logger.LevelInfo}))
}
func (rt *Runtime) HTTPWithLogger(next http.Handler, log *logger.Logger, observers ...func(logger.HTTPCompletion)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Context().Value(observationKey{}) != nil {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		method := safeMethod(r.Method)
		route := Route(r.Pattern)
		ctx := propagation.TraceContext{}.Extract(r.Context(), propagation.HeaderCarrier(r.Header))
		// Tracestate is vendor-supplied free text. Retain only W3C IDs/flags for
		// parentage, not arbitrary vendor state in exported spans.
		parent := trace.SpanContextFromContext(ctx)
		if parent.IsValid() {
			ctx = trace.ContextWithRemoteSpanContext(ctx, parent.WithTraceState(trace.TraceState{}))
		}
		ctx, span := rt.tracer.Start(ctx, method+" "+route, trace.WithSpanKind(trace.SpanKindServer))
		defer span.End()
		// Server-owned ID prevents a client from exfiltrating values through this
		// otherwise high-cardinality correlation field. Legacy middleware reuses it.
		requestID := uuid.NewString()
		ctx = apperrors.WithRequestID(ctx, requestID)
		ctx = context.WithValue(ctx, observationKey{}, true)
		r = r.WithContext(ctx)
		w.Header().Set("X-Request-ID", requestID)
		hijacked := false
		wire := httpsnoop.Wrap(w, httpsnoop.Hooks{Hijack: func(next httpsnoop.HijackFunc) httpsnoop.HijackFunc {
			return func() (net.Conn, *bufio.ReadWriter, error) {
				conn, rw, err := next()
				if err == nil {
					hijacked = true
				}
				return conn, rw, err
			}
		}})
		observed := httpsnoop.CaptureMetrics(next, wire, r)
		// Gorilla writes the 101 handshake directly to the hijacked socket.
		if hijacked && strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			observed.Code = http.StatusSwitchingProtocols
		}
		event := logger.HTTPCompletion{RequestID: requestID, Method: method, Route: route, Status: observed.Code, Bytes: observed.Written, Duration: time.Since(start)}
		attrs := []attribute.KeyValue{attribute.String("http.request.method", method), attribute.String("http.route", route), attribute.Int("http.response.status_code", event.Status)}
		span.SetAttributes(append(attrs, attribute.String("request_id", requestID))...)
		if event.Status >= 500 {
			span.SetStatus(codes.Error, "")
		}
		rt.count.Add(ctx, 1, metric.WithAttributes(attrs...))
		rt.duration.Record(ctx, event.Duration.Seconds(), metric.WithAttributes(attrs...))
		log.HTTPCompleted(ctx, event)
		for _, observe := range observers {
			observe(event)
		}
	})
}

// Route projects trusted mux patterns, never a request path. Unknown redirects,
// 404/405 and preflight requests share one label.
func Route(pattern string) string {
	if pattern == "" {
		return "unknown"
	}
	if _, path, ok := strings.Cut(pattern, " "); ok {
		return path
	}
	return pattern
}
func safeMethod(method string) string {
	switch method {
	case "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE":
		return method
	default:
		return "_OTHER"
	}
}
