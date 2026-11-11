package observability

import (
	"context"
	"errors"
	"sync"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	otellog "go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/metric"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"

	"github.com/openmusicplayer/backend/internal/logger"
)

// Runtime owns all three SDK providers, bounded queues and cleanup. Construct
// once, share across routers, stop accepting requests before Shutdown.
type Runtime struct {
	cfg           Config
	resource      map[string]string
	traces        *sdktrace.TracerProvider
	logs          *sdklog.LoggerProvider
	metrics       *sdkmetric.MeterProvider
	tracer        trace.Tracer
	completionLog otellog.Logger
	count         metric.Int64Counter
	duration      metric.Float64Histogram
	shutdownOnce  sync.Once
	shutdownErr   error
}

func New(ctx context.Context, c Config) (rt *Runtime, err error) {
	if err = c.validate(); err != nil {
		return nil, err
	}
	rt = &Runtime{cfg: c, resource: map[string]string{}}
	for k, v := range c.ResourceAttributes {
		rt.resource[k] = v
	}
	for k, v := range map[string]string{"service.name": c.ServiceName, "service.version": c.ServiceVersion, "service.instance.id": c.InstanceID, "deployment.environment.name": c.Environment} {
		rt.resource[k] = v
	}
	attrs := make([]attribute.KeyValue, 0, len(rt.resource))
	for k, v := range rt.resource {
		attrs = append(attrs, attribute.String(k, v))
	}
	res := resource.NewSchemaless(attrs...)
	defer func() {
		if err != nil {
			_ = rt.Shutdown(context.Background())
		}
	}()
	// Not ParentBased: incoming sampled flags never override server policy.
	traceOpts := []sdktrace.TracerProviderOption{sdktrace.WithResource(res), sdktrace.WithSampler(sdktrace.TraceIDRatioBased(c.SampleRatio))}
	if !c.Disabled && c.TracesExporter == "otlp" {
		exp, e := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(c.endpoint("traces", c.TracesEndpoint)), otlptracehttp.WithHeaders(c.Headers), otlptracehttp.WithTimeout(c.ExportTimeout), otlptracehttp.WithRetry(otlptracehttp.RetryConfig{Enabled: false}))
		if e != nil {
			return rt, e
		}
		traceOpts = append(traceOpts, sdktrace.WithBatcher(exp, sdktrace.WithMaxQueueSize(c.QueueSize), sdktrace.WithMaxExportBatchSize(c.BatchSize), sdktrace.WithBatchTimeout(c.BatchInterval), sdktrace.WithExportTimeout(c.ExportTimeout)))
	}
	rt.traces = sdktrace.NewTracerProvider(traceOpts...)
	rt.tracer = rt.traces.Tracer("soundq/http")
	logOpts := []sdklog.LoggerProviderOption{sdklog.WithResource(res)}
	if !c.Disabled && c.LogsExporter == "otlp" {
		exp, e := otlploghttp.New(ctx, otlploghttp.WithEndpointURL(c.endpoint("logs", c.LogsEndpoint)), otlploghttp.WithHeaders(c.Headers), otlploghttp.WithTimeout(c.ExportTimeout), otlploghttp.WithRetry(otlploghttp.RetryConfig{Enabled: false}))
		if e != nil {
			return rt, e
		}
		logOpts = append(logOpts, sdklog.WithProcessor(sdklog.NewBatchProcessor(exp, sdklog.WithMaxQueueSize(c.QueueSize), sdklog.WithExportMaxBatchSize(c.BatchSize), sdklog.WithExportInterval(c.BatchInterval), sdklog.WithExportTimeout(c.ExportTimeout))))
	}
	rt.logs = sdklog.NewLoggerProvider(logOpts...)
	rt.completionLog = rt.logs.Logger("soundq/http")
	metricOpts := []sdkmetric.Option{sdkmetric.WithResource(res), sdkmetric.WithCardinalityLimit(2048)}
	if !c.Disabled && c.MetricsExporter == "otlp" {
		exp, e := otlpmetrichttp.New(ctx, otlpmetrichttp.WithEndpointURL(c.endpoint("metrics", c.MetricsEndpoint)), otlpmetrichttp.WithHeaders(c.Headers), otlpmetrichttp.WithTimeout(c.ExportTimeout), otlpmetrichttp.WithRetry(otlpmetrichttp.RetryConfig{Enabled: false}))
		if e != nil {
			return rt, e
		}
		metricOpts = append(metricOpts, sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exp, sdkmetric.WithInterval(c.MetricInterval), sdkmetric.WithTimeout(c.ExportTimeout))))
	}
	rt.metrics = sdkmetric.NewMeterProvider(metricOpts...)
	meter := rt.metrics.Meter("soundq/http")
	rt.count, err = meter.Int64Counter("http.server.request.count", metric.WithUnit("{request}"))
	if err != nil {
		return rt, err
	}
	rt.duration, err = meter.Float64Histogram("http.server.request.duration", metric.WithUnit("s"), metric.WithExplicitBucketBoundaries(.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10, 30))
	return rt, err
}

// Logger emits JSON stdout with resource identity. Only the typed HTTP completion
// method has an export observer. Ordinary Info/Error never reach OTLP.
func (rt *Runtime) Logger(cfg *logger.Config) *logger.Logger {
	copy := *cfg
	copy.Resource = rt.resource
	copy.HTTPObserver = rt.observeCompletion
	return logger.New(&copy)
}

func (rt *Runtime) observeCompletion(ctx context.Context, event logger.HTTPCompletion) {
	var record otellog.Record
	record.SetTimestamp(time.Now())
	record.SetObservedTimestamp(time.Now())
	record.SetBody(otellog.StringValue("http.request.completed"))
	record.SetSeverity(otellog.SeverityInfo)
	record.SetSeverityText("INFO")
	if event.Status >= 500 {
		record.SetSeverity(otellog.SeverityError)
		record.SetSeverityText("ERROR")
	} else if event.Status >= 400 {
		record.SetSeverity(otellog.SeverityWarn)
		record.SetSeverityText("WARN")
	}
	record.AddAttributes(otellog.String("request_id", event.RequestID), otellog.String("http.request.method", event.Method), otellog.String("http.route", event.Route), otellog.Int("http.response.status_code", event.Status), otellog.Int64("http.response.body.size", event.Bytes), otellog.Float64("duration_ms", float64(event.Duration)/float64(time.Millisecond)))
	rt.completionLog.Emit(ctx, record)
}

// ForceFlush is useful before an explicit readback. Shutdown also drains all
// providers. Neither operation may run past the configured aggregate budget.
func (rt *Runtime) ForceFlush(ctx context.Context) error { return rt.finish(ctx, false) }
func (rt *Runtime) Shutdown(ctx context.Context) error {
	rt.shutdownOnce.Do(func() { rt.shutdownErr = rt.finish(ctx, true) })
	return rt.shutdownErr
}
func (rt *Runtime) finish(ctx context.Context, shutdown bool) error {
	ctx, cancel := context.WithTimeout(ctx, rt.cfg.ShutdownTimeout)
	defer cancel()
	var errs []error
	// Drain concurrently so one unavailable signal cannot starve the other two.
	calls := []func(context.Context) error{}
	if rt.traces != nil {
		if shutdown {
			calls = append(calls, rt.traces.Shutdown)
		} else {
			calls = append(calls, rt.traces.ForceFlush)
		}
	}
	if rt.logs != nil {
		if shutdown {
			calls = append(calls, rt.logs.Shutdown)
		} else {
			calls = append(calls, rt.logs.ForceFlush)
		}
	}
	if rt.metrics != nil {
		if shutdown {
			calls = append(calls, rt.metrics.Shutdown)
		} else {
			calls = append(calls, rt.metrics.ForceFlush)
		}
	}
	results := make(chan error, len(calls))
	for _, call := range calls {
		go func(f func(context.Context) error) { results <- f(ctx) }(call)
	}
	for range calls {
		select {
		case err := <-results:
			errs = append(errs, err)
		case <-ctx.Done():
			return errors.Join(append(errs, ctx.Err())...)
		}
	}
	return errors.Join(errs...)
}
