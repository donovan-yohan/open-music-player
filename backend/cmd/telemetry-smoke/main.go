// telemetry-smoke emits real requests through the production API router without
// database/Redis/MinIO. It is a finite synthetic producer, not a server mode.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/metrics"
	"github.com/openmusicplayer/backend/internal/observability"
)

func run() error {
	c, err := observability.ConfigFromEnv()
	if err != nil {
		return err
	}
	rt, err := observability.New(context.Background(), c)
	if err != nil {
		return err
	}
	defer rt.Shutdown(context.Background())
	router := api.NewRouterWithConfig(&api.RouterConfig{Telemetry: rt, Logger: rt.Logger(&logger.Config{Level: logger.LevelInfo}), ResponseTransforms: true, Metrics: metrics.New()})
	server := httptest.NewServer(router)
	defer server.Close()
	client := &http.Client{Timeout: 3 * time.Second}
	canary := "SOUNDQ_SYNTHETIC_PRIVACY_CANARY"
	results := []map[string]interface{}{}
	for _, input := range []struct {
		method, path string
		status       int
	}{{"GET", "/health", 200}, {"PUT", "/api/v1/tracks/" + canary + "/metadata-override?url=https://signed.invalid?X-Amz-Signature=" + canary, 401}, {"GET", "/" + canary, 404}} {
		req, _ := http.NewRequestWithContext(context.Background(), input.method, server.URL+input.path, strings.NewReader(canary))
		req.Header.Set("X-Request-ID", canary)
		req.Header.Set("X-Trace-ID", canary)
		req.Header.Set("Authorization", canary)
		req.Header.Set("Baggage", "secret="+canary)
		req.Header.Set("X-Synthetic-Privacy-Test", canary)
		res, err := client.Do(req)
		if err != nil {
			return err
		}
		_, err = io.Copy(io.Discard, res.Body)
		res.Body.Close()
		if err != nil {
			return err
		}
		if res.StatusCode != input.status {
			return fmt.Errorf("%s request returned %d, want %d", input.method, res.StatusCode, input.status)
		}
		results = append(results, map[string]interface{}{"method": input.method, "status": res.StatusCode, "request_id": res.Header.Get("X-Request-ID")})
	}
	server.Close()
	if err := rt.Shutdown(context.Background()); err != nil {
		return fmt.Errorf("telemetry drain: %w", err)
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]interface{}{"synthetic": true, "service": c.ServiceName, "environment": c.Environment, "instance": c.InstanceID, "requests": results, "telemetry_drained": true})
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
