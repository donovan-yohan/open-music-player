package health

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestChecker_BasicHealth(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		Version: "1.0.0",
		Timeout: 5 * time.Second,
	})

	response := checker.Check(context.Background())

	if response.Status != StatusHealthy {
		t.Errorf("expected status healthy, got %s", response.Status)
	}
	if response.Version != "1.0.0" {
		t.Errorf("expected version 1.0.0, got %s", response.Version)
	}
}

func TestChecker_DeepCheck_AllHealthy(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		StorageCheck: func(ctx context.Context) error {
			return nil
		},
		Version: "1.0.0",
		Timeout: 5 * time.Second,
	})

	response := checker.DeepCheck(context.Background())

	// Without DB and Redis configured, overall status will be unhealthy
	// but storage should be healthy
	if len(response.Components) == 0 {
		t.Error("expected components to be populated")
	}
	if response.Components["storage"].Status != StatusHealthy {
		t.Errorf("expected storage component healthy, got %s", response.Components["storage"].Status)
	}
}

func TestChecker_DeepCheck_StorageUnhealthy(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		StorageCheck: func(ctx context.Context) error {
			return errors.New("storage connection failed")
		},
		Version: "1.0.0",
		Timeout: 5 * time.Second,
	})

	response := checker.DeepCheck(context.Background())

	if response.Status != StatusUnhealthy {
		t.Errorf("expected status unhealthy, got %s", response.Status)
	}
	if response.Components["storage"].Status != StatusUnhealthy {
		t.Errorf("expected storage component unhealthy, got %s", response.Components["storage"].Status)
	}
}

func TestHandler_LivenessHandler(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		Version: "1.0.0",
	})
	handler := NewHandler(checker)

	req := httptest.NewRequest(http.MethodGet, "/health/live", nil)
	w := httptest.NewRecorder()

	handler.LivenessHandler(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", w.Code)
	}

	var response HealthResponse
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if response.Status != StatusHealthy {
		t.Errorf("expected status healthy, got %s", response.Status)
	}
}

func TestHandler_ReadinessHandler_StorageHealthy(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		StorageCheck: func(ctx context.Context) error {
			return nil
		},
		Version: "1.0.0",
	})
	handler := NewHandler(checker)

	req := httptest.NewRequest(http.MethodGet, "/health/ready", nil)
	w := httptest.NewRecorder()

	handler.ReadinessHandler(w, req)

	var response HealthResponse
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	// Storage should be healthy even if overall status is unhealthy (due to missing DB/Redis)
	if response.Components["storage"].Status != StatusHealthy {
		t.Errorf("expected storage component healthy, got %s", response.Components["storage"].Status)
	}
}

func TestHandler_ReadinessHandler_Unhealthy(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		StorageCheck: func(ctx context.Context) error {
			return errors.New("storage down")
		},
		Version: "1.0.0",
	})
	handler := NewHandler(checker)

	req := httptest.NewRequest(http.MethodGet, "/health/ready", nil)
	w := httptest.NewRecorder()

	handler.ReadinessHandler(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("expected status 503, got %d", w.Code)
	}

	var response HealthResponse
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	if response.Status != StatusUnhealthy {
		t.Errorf("expected status unhealthy, got %s", response.Status)
	}
}

func TestHandler_HealthHandler_DeepQuery(t *testing.T) {
	checker := NewChecker(&CheckerConfig{
		StorageCheck: func(ctx context.Context) error {
			return nil
		},
		Version: "1.0.0",
	})
	handler := NewHandler(checker)

	req := httptest.NewRequest(http.MethodGet, "/health?deep=true", nil)
	w := httptest.NewRecorder()

	handler.HealthHandler(w, req)

	var response HealthResponse
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}

	// Deep check should include components
	if len(response.Components) == 0 {
		t.Error("deep check should include components")
	}
}
