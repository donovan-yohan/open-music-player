package main

import "testing"

func TestServerTelemetryConfigurationFailsBeforeDependencies(t *testing.T) {
	t.Setenv("OTEL_TRACES_EXPORTER", "otlp")
	t.Setenv("OTEL_SDK_DISABLED", "false")
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")
	t.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "")
	// No database fixture is needed: invalid telemetry must fail before opening
	// any DB/cache/worker, and runServer returns so initialized owners can defer.
	if code := runServer(); code != 1 {
		t.Fatalf("invalid telemetry exit %d", code)
	}
}
