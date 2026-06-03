package config

import (
	"os"
	"testing"
)

func TestLoadPreservesWorkerCountDefaults(t *testing.T) {
	t.Setenv("WORKER_COUNT", "")

	cfg := Load()
	if cfg.WorkerCount != 1 {
		t.Fatalf("WorkerCount = %d, want default 1", cfg.WorkerCount)
	}
}

func TestLoadAllowsExplicitZeroWorkerCount(t *testing.T) {
	t.Setenv("WORKER_COUNT", "0")

	cfg := Load()
	if cfg.WorkerCount != 0 {
		t.Fatalf("WorkerCount = %d, want explicit zero", cfg.WorkerCount)
	}
}

func TestLoadDefaultsMalformedWorkerCount(t *testing.T) {
	t.Setenv("WORKER_COUNT", "nope")

	cfg := Load()
	if cfg.WorkerCount != 1 {
		t.Fatalf("WorkerCount = %d, want default 1 for malformed WORKER_COUNT", cfg.WorkerCount)
	}
}

func TestLoadDefaultsMalformedRedisEnabledToTrue(t *testing.T) {
	t.Setenv("REDIS_ENABLED", "treu")

	cfg := Load()
	if !cfg.RedisEnabled {
		t.Fatal("RedisEnabled = false, want true for malformed REDIS_ENABLED")
	}
}

func TestLoadDefaultsCORSAllowedOriginsWhenUnset(t *testing.T) {
	withUnsetCORSAllowedOrigins(t)

	cfg := Load()
	if cfg.CORSAllowedOrigins != nil {
		t.Fatalf("CORSAllowedOrigins = %#v, want nil for router defaults", cfg.CORSAllowedOrigins)
	}
}

func TestLoadAllowsEmptyCORSAllowedOriginsToDisableHeaders(t *testing.T) {
	t.Setenv("OMP_CORS_ALLOWED_ORIGINS", "")

	cfg := Load()
	if cfg.CORSAllowedOrigins == nil || len(cfg.CORSAllowedOrigins) != 0 {
		t.Fatalf("CORSAllowedOrigins = %#v, want explicit empty slice", cfg.CORSAllowedOrigins)
	}
}

func TestLoadFallsBackToLegacyCORSAllowedOrigins(t *testing.T) {
	withUnsetEnv(t, "OMP_CORS_ALLOWED_ORIGINS")
	t.Setenv("CORS_ALLOWED_ORIGINS", "http://localhost:18145, https://app.example")

	cfg := Load()
	want := []string{"http://localhost:18145", "https://app.example"}
	if len(cfg.CORSAllowedOrigins) != len(want) {
		t.Fatalf("CORSAllowedOrigins = %#v, want %#v", cfg.CORSAllowedOrigins, want)
	}
	for i := range want {
		if cfg.CORSAllowedOrigins[i] != want[i] {
			t.Fatalf("CORSAllowedOrigins = %#v, want %#v", cfg.CORSAllowedOrigins, want)
		}
	}
}

func withUnsetCORSAllowedOrigins(t *testing.T) {
	t.Helper()
	withUnsetEnv(t, "OMP_CORS_ALLOWED_ORIGINS")
	withUnsetEnv(t, "CORS_ALLOWED_ORIGINS")
}

func withUnsetEnv(t *testing.T, key string) {
	t.Helper()
	oldValue, hadValue := os.LookupEnv(key)
	if err := os.Unsetenv(key); err != nil {
		t.Fatalf("unset %s: %v", key, err)
	}
	t.Cleanup(func() {
		if hadValue {
			_ = os.Setenv(key, oldValue)
			return
		}
		_ = os.Unsetenv(key)
	})
}
