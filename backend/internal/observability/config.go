// Package observability owns process-local OpenTelemetry providers. Nothing is
// installed globally and no exporter is enabled without explicit configuration.
package observability

import (
	"fmt"
	"math"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Config is a resolved, validated SDK policy. Resource values are operator-owned,
// not request-derived. Endpoint is an OTLP/HTTP base URL, never a signal URL.
type Config struct {
	ServiceName, ServiceVersion, InstanceID, Environment          string
	ResourceAttributes                                            map[string]string
	Endpoint                                                      string
	TracesEndpoint, LogsEndpoint, MetricsEndpoint                 string
	Headers                                                       map[string]string
	TracesExporter, LogsExporter, MetricsExporter                 string
	Disabled                                                      bool
	SampleRatio                                                   float64
	ExportTimeout, BatchInterval, MetricInterval, ShutdownTimeout time.Duration
	QueueSize, BatchSize                                          int
}

func DefaultConfig() Config {
	return Config{ServiceName: "soundq-backend", ServiceVersion: "unknown", InstanceID: uuid.NewString(), Environment: "development",
		TracesExporter: "none", LogsExporter: "none", MetricsExporter: "none", SampleRatio: 1,
		ExportTimeout: 3 * time.Second, BatchInterval: time.Second, MetricInterval: 15 * time.Second, ShutdownTimeout: 5 * time.Second, QueueSize: 2048, BatchSize: 256}
}

// ConfigFromEnv supports the standard OTEL service/resource, per-signal exporter,
// OTLP/HTTP endpoint/header/timeout, sampler and SDK-disabled variables. Exporter
// mode defaults to none. Signal-specific endpoints are used verbatim.
func ConfigFromEnv() (Config, error) {
	c := DefaultConfig()
	c.Endpoint = os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	c.TracesEndpoint = os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
	c.LogsEndpoint = os.Getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
	c.MetricsEndpoint = os.Getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
	var err error
	c.ResourceAttributes, err = parsePairs(os.Getenv("OTEL_RESOURCE_ATTRIBUTES"))
	if err != nil {
		return c, fmt.Errorf("invalid OTEL_RESOURCE_ATTRIBUTES")
	}
	if v := c.ResourceAttributes["service.name"]; v != "" {
		c.ServiceName = v
	}
	if v := os.Getenv("OTEL_SERVICE_NAME"); v != "" {
		c.ServiceName = v
	}
	if v := c.ResourceAttributes["service.version"]; v != "" {
		c.ServiceVersion = v
	}
	if v := c.ResourceAttributes["service.instance.id"]; v != "" {
		c.InstanceID = v
	}
	if v := c.ResourceAttributes["deployment.environment.name"]; v != "" {
		c.Environment = v
	}
	for key, dst := range map[string]*string{"OTEL_TRACES_EXPORTER": &c.TracesExporter, "OTEL_LOGS_EXPORTER": &c.LogsExporter, "OTEL_METRICS_EXPORTER": &c.MetricsExporter} {
		if v := os.Getenv(key); v != "" {
			*dst = v
		}
	}
	if v := os.Getenv("OTEL_SDK_DISABLED"); v != "" {
		c.Disabled, err = strconv.ParseBool(v)
		if err != nil {
			return c, fmt.Errorf("invalid OTEL_SDK_DISABLED")
		}
	}
	if v := os.Getenv("OTEL_EXPORTER_OTLP_PROTOCOL"); v != "" && v != "http/protobuf" {
		return c, fmt.Errorf("OTEL_EXPORTER_OTLP_PROTOCOL must be http/protobuf")
	}
	c.Headers, err = parsePairs(os.Getenv("OTEL_EXPORTER_OTLP_HEADERS"))
	if err != nil {
		return c, fmt.Errorf("invalid OTEL_EXPORTER_OTLP_HEADERS")
	}
	sampler := os.Getenv("OTEL_TRACES_SAMPLER")
	switch sampler {
	case "", "traceidratio":
		if v := os.Getenv("OTEL_TRACES_SAMPLER_ARG"); v != "" {
			c.SampleRatio, err = strconv.ParseFloat(v, 64)
			if err != nil {
				return c, fmt.Errorf("invalid OTEL_TRACES_SAMPLER_ARG")
			}
		}
	case "always_on":
		c.SampleRatio = 1
	case "always_off":
		c.SampleRatio = 0
	default:
		return c, fmt.Errorf("OTEL_TRACES_SAMPLER must be traceidratio, always_on or always_off (parent-based sampling is intentionally unsupported)")
	}
	for key, dst := range map[string]*time.Duration{"OTEL_EXPORTER_OTLP_TIMEOUT": &c.ExportTimeout, "OTEL_BSP_SCHEDULE_DELAY": &c.BatchInterval, "OTEL_METRIC_EXPORT_INTERVAL": &c.MetricInterval, "SOUNDQ_OTEL_SHUTDOWN_TIMEOUT_MS": &c.ShutdownTimeout} {
		if v := os.Getenv(key); v != "" {
			n, e := strconv.ParseInt(v, 10, 64)
			if e != nil || n < 1 || n > 60000 {
				return c, fmt.Errorf("%s must be 1..60000 milliseconds", key)
			}
			*dst = time.Duration(n) * time.Millisecond
		}
	}
	for key, dst := range map[string]*int{"OTEL_BSP_MAX_QUEUE_SIZE": &c.QueueSize, "OTEL_BSP_MAX_EXPORT_BATCH_SIZE": &c.BatchSize} {
		if v := os.Getenv(key); v != "" {
			n, e := strconv.Atoi(v)
			if e != nil {
				return c, fmt.Errorf("invalid %s", key)
			}
			*dst = n
		}
	}
	return c, c.validate()
}

func parsePairs(raw string) (map[string]string, error) {
	result := map[string]string{}
	if raw == "" {
		return result, nil
	}
	for _, part := range strings.Split(raw, ",") {
		k, v, ok := strings.Cut(part, "=")
		if !ok || strings.TrimSpace(k) == "" {
			return nil, fmt.Errorf("expected key=value")
		}
		value, err := url.PathUnescape(strings.TrimSpace(v))
		if err != nil {
			return nil, err
		}
		result[strings.TrimSpace(k)] = value
	}
	return result, nil
}

func (c Config) validate() error {
	if c.ServiceName == "" || c.Environment == "" {
		return fmt.Errorf("telemetry service name and environment are required")
	}
	if math.IsNaN(c.SampleRatio) || math.IsInf(c.SampleRatio, 0) || c.SampleRatio < 0 || c.SampleRatio > 1 {
		return fmt.Errorf("trace sample ratio must be 0..1")
	}
	if c.QueueSize < 1 || c.QueueSize > 65536 || c.BatchSize < 1 || c.BatchSize > c.QueueSize {
		return fmt.Errorf("invalid bounded telemetry queue/batch sizes")
	}
	for _, d := range []time.Duration{c.ExportTimeout, c.BatchInterval, c.MetricInterval, c.ShutdownTimeout} {
		if d <= 0 || d > time.Minute {
			return fmt.Errorf("telemetry durations must be positive and at most one minute")
		}
	}
	for _, signal := range []struct{ mode, endpoint string }{{c.TracesExporter, c.TracesEndpoint}, {c.LogsExporter, c.LogsEndpoint}, {c.MetricsExporter, c.MetricsEndpoint}} {
		if signal.mode != "none" && signal.mode != "otlp" {
			return fmt.Errorf("telemetry exporter must be none or otlp")
		}
		if c.Disabled || signal.mode == "none" {
			continue
		}
		endpoint := signal.endpoint
		if endpoint == "" {
			endpoint = c.Endpoint
		}
		u, err := url.Parse(endpoint)
		if err != nil || u == nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("enabled OTLP exporter requires an explicit http(s) endpoint without credentials, query or fragment")
		}
	}
	return nil
}

func (c Config) endpoint(signal, specific string) string {
	if specific != "" {
		return specific
	}
	return strings.TrimRight(c.Endpoint, "/") + "/v1/" + signal
}
