package health

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// Status represents the health status of a component
type Status string

const (
	StatusHealthy   Status = "healthy"
	StatusUnhealthy Status = "unhealthy"
	StatusDegraded  Status = "degraded"
)

// ComponentHealth represents the health of a single component
type ComponentHealth struct {
	Status   Status `json:"status"`
	Message  string `json:"message,omitempty"`
	Duration string `json:"duration,omitempty"`
}

// HealthResponse represents the full health check response
type HealthResponse struct {
	Status     Status                     `json:"status"`
	Timestamp  string                     `json:"timestamp"`
	Version    string                     `json:"version,omitempty"`
	Components map[string]ComponentHealth `json:"components,omitempty"`
}

// Checker performs health checks on various components
type Checker struct {
	db           *sql.DB
	redis        *redis.Client
	storageCheck func(ctx context.Context) error
	version      string
	checkTimeout time.Duration
}

// CheckerConfig holds configuration for the health checker
type CheckerConfig struct {
	DB           *sql.DB
	Redis        *redis.Client
	StorageCheck func(ctx context.Context) error
	Version      string
	Timeout      time.Duration
}

// NewChecker creates a new health checker
func NewChecker(cfg *CheckerConfig) *Checker {
	timeout := cfg.Timeout
	if timeout == 0 {
		timeout = 5 * time.Second
	}
	return &Checker{
		db:           cfg.DB,
		redis:        cfg.Redis,
		storageCheck: cfg.StorageCheck,
		version:      cfg.Version,
		checkTimeout: timeout,
	}
}

// CheckDB checks database connectivity
func (c *Checker) CheckDB(ctx context.Context) ComponentHealth {
	start := time.Now()

	if c.db == nil {
		return ComponentHealth{
			Status:  StatusUnhealthy,
			Message: "database not configured",
		}
	}

	ctx, cancel := context.WithTimeout(ctx, c.checkTimeout)
	defer cancel()

	if err := c.db.PingContext(ctx); err != nil {
		return ComponentHealth{
			Status:   StatusUnhealthy,
			Message:  "database ping failed",
			Duration: time.Since(start).String(),
		}
	}

	// Additional check: verify we can query
	var result int
	if err := c.db.QueryRowContext(ctx, "SELECT 1").Scan(&result); err != nil {
		return ComponentHealth{
			Status:   StatusDegraded,
			Message:  "database query failed",
			Duration: time.Since(start).String(),
		}
	}

	return ComponentHealth{
		Status:   StatusHealthy,
		Duration: time.Since(start).String(),
	}
}

// CheckRedis checks Redis connectivity
func (c *Checker) CheckRedis(ctx context.Context) ComponentHealth {
	start := time.Now()

	if c.redis == nil {
		return ComponentHealth{
			Status:  StatusUnhealthy,
			Message: "redis not configured",
		}
	}

	ctx, cancel := context.WithTimeout(ctx, c.checkTimeout)
	defer cancel()

	if err := c.redis.Ping(ctx).Err(); err != nil {
		return ComponentHealth{
			Status:   StatusUnhealthy,
			Message:  "redis ping failed",
			Duration: time.Since(start).String(),
		}
	}

	return ComponentHealth{
		Status:   StatusHealthy,
		Duration: time.Since(start).String(),
	}
}

// CheckStorage checks S3/MinIO connectivity
func (c *Checker) CheckStorage(ctx context.Context) ComponentHealth {
	start := time.Now()

	if c.storageCheck == nil {
		return ComponentHealth{
			Status:  StatusUnhealthy,
			Message: "storage not configured",
		}
	}

	ctx, cancel := context.WithTimeout(ctx, c.checkTimeout)
	defer cancel()

	if err := c.storageCheck(ctx); err != nil {
		return ComponentHealth{
			Status:   StatusUnhealthy,
			Message:  "storage check failed",
			Duration: time.Since(start).String(),
		}
	}

	return ComponentHealth{
		Status:   StatusHealthy,
		Duration: time.Since(start).String(),
	}
}

// Check performs a basic health check (liveness)
func (c *Checker) Check(ctx context.Context) *HealthResponse {
	return &HealthResponse{
		Status:    StatusHealthy,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Version:   c.version,
	}
}

// DeepCheck performs a comprehensive health check (readiness)
func (c *Checker) DeepCheck(ctx context.Context) *HealthResponse {
	response := &HealthResponse{
		Status:     StatusHealthy,
		Timestamp:  time.Now().UTC().Format(time.RFC3339),
		Version:    c.version,
		Components: make(map[string]ComponentHealth),
	}

	// Run checks in parallel
	var wg sync.WaitGroup
	var mu sync.Mutex

	checks := map[string]func(context.Context) ComponentHealth{
		"database": c.CheckDB,
		"redis":    c.CheckRedis,
		"storage":  c.CheckStorage,
	}

	for name, check := range checks {
		wg.Add(1)
		go func(n string, ch func(context.Context) ComponentHealth) {
			defer wg.Done()
			result := ch(ctx)
			mu.Lock()
			response.Components[n] = result
			mu.Unlock()
		}(name, check)
	}

	wg.Wait()

	// Determine overall status
	for _, comp := range response.Components {
		if comp.Status == StatusUnhealthy {
			response.Status = StatusUnhealthy
			break
		} else if comp.Status == StatusDegraded && response.Status == StatusHealthy {
			response.Status = StatusDegraded
		}
	}

	return response
}

// Handler provides HTTP handlers for health endpoints
type Handler struct {
	checker *Checker
}

// NewHandler creates a new health handler
func NewHandler(checker *Checker) *Handler {
	return &Handler{checker: checker}
}

// LivenessHandler handles liveness probe requests
// Used by Kubernetes to determine if the container is alive
func (h *Handler) LivenessHandler(w http.ResponseWriter, r *http.Request) {
	response := h.checker.Check(r.Context())

	w.Header().Set("Content-Type", "application/json")
	if response.Status != StatusHealthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	json.NewEncoder(w).Encode(response)
}

// ReadinessHandler handles readiness probe requests
// Used by Kubernetes to determine if the container is ready to receive traffic
func (h *Handler) ReadinessHandler(w http.ResponseWriter, r *http.Request) {
	response := h.checker.DeepCheck(r.Context())

	w.Header().Set("Content-Type", "application/json")
	if response.Status == StatusUnhealthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	} else if response.Status == StatusDegraded {
		w.WriteHeader(http.StatusOK) // Still accept traffic but degraded
	} else {
		w.WriteHeader(http.StatusOK)
	}
	json.NewEncoder(w).Encode(response)
}

// HealthHandler handles basic health check requests (legacy /health endpoint)
func (h *Handler) HealthHandler(w http.ResponseWriter, r *http.Request) {
	// Check if deep check is requested via query param
	if r.URL.Query().Get("deep") == "true" {
		h.ReadinessHandler(w, r)
		return
	}
	h.LivenessHandler(w, r)
}
