package observability

import (
	"testing"
	"time"
)

func TestConfigFromEnv(t *testing.T) {
	for _, key := range []string{"OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES", "OTEL_TRACES_EXPORTER", "OTEL_LOGS_EXPORTER", "OTEL_METRICS_EXPORTER", "OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_TIMEOUT", "OTEL_EXPORTER_OTLP_PROTOCOL", "OTEL_TRACES_SAMPLER", "OTEL_TRACES_SAMPLER_ARG", "OTEL_SDK_DISABLED", "OTEL_BSP_MAX_QUEUE_SIZE", "OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "OTEL_BSP_SCHEDULE_DELAY", "OTEL_METRIC_EXPORT_INTERVAL", "SOUNDQ_OTEL_SHUTDOWN_TIMEOUT_MS"} {
		t.Setenv(key, "")
	}
	c, err := ConfigFromEnv()
	if err != nil || c.TracesExporter != "none" || c.LogsExporter != "none" || c.MetricsExporter != "none" {
		t.Fatalf("unsafe default %+v %v", c, err)
	}
	t.Setenv("OTEL_SERVICE_NAME", "soundq-override")
	t.Setenv("OTEL_RESOURCE_ATTRIBUTES", "service.name=ignored,service.version=test-v,service.instance.id=test-i,deployment.environment.name=production,custom.tag=encoded%20value")
	t.Setenv("OTEL_TRACES_EXPORTER", "otlp")
	t.Setenv("OTEL_LOGS_EXPORTER", "otlp")
	t.Setenv("OTEL_METRICS_EXPORTER", "otlp")
	if _, err := ConfigFromEnv(); err == nil {
		t.Fatal("implicit localhost exporter forbidden")
	}
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318/prefix")
	t.Setenv("OTEL_TRACES_SAMPLER", "traceidratio")
	t.Setenv("OTEL_TRACES_SAMPLER_ARG", "0.25")
	t.Setenv("OTEL_EXPORTER_OTLP_TIMEOUT", "150")
	c, err = ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if c.ServiceName != "soundq-override" || c.ServiceVersion != "test-v" || c.Environment != "production" || c.InstanceID != "test-i" || c.SampleRatio != .25 || c.ExportTimeout != 150*time.Millisecond {
		t.Fatalf("resolved %+v", c)
	}
	if c.endpoint("traces", "") != "http://localhost:4318/prefix/v1/traces" {
		t.Fatal("base endpoint lost prefix")
	}
	for _, v := range []string{"NaN", "Inf", "-0.1", "1.1", "secret"} {
		t.Setenv("OTEL_TRACES_SAMPLER_ARG", v)
		if _, err := ConfigFromEnv(); err == nil {
			t.Fatalf("accepted sample ratio %s", v)
		}
	}
	t.Setenv("OTEL_TRACES_SAMPLER_ARG", "1")
	for _, v := range []string{"grpc", "http/json"} {
		t.Setenv("OTEL_EXPORTER_OTLP_PROTOCOL", v)
		if _, err := ConfigFromEnv(); err == nil {
			t.Fatalf("accepted protocol %s", v)
		}
	}
	t.Setenv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")
	t.Setenv("OTEL_SDK_DISABLED", "true")
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
	if _, err := ConfigFromEnv(); err != nil {
		t.Fatalf("disabled requires endpoint: %v", err)
	}
}

func TestConfigRejectsUnsafeEndpointsAndLimits(t *testing.T) {
	// Synthetic invalid endpoint fixtures, not operator credentials.
	for _, endpoint := range []string{"", "://bad", "ftp://collector", "http://user:dummy-secret@collector", "http://collector?secret=value", "http://collector#secret"} {
		c := DefaultConfig()
		c.TracesExporter = "otlp"
		c.Endpoint = endpoint
		if err := c.validate(); err == nil {
			t.Fatalf("accepted endpoint %q", endpoint)
		}
	}
	c := DefaultConfig()
	c.TracesExporter = "otlp"
	c.TracesEndpoint = "https://collector/custom/traces"
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	if c.endpoint("traces", c.TracesEndpoint) != c.TracesEndpoint {
		t.Fatal("signal endpoint was rewritten")
	}
	c.QueueSize = 1
	c.BatchSize = 2
	if err := c.validate(); err == nil {
		t.Fatal("unbounded batch")
	}
}
