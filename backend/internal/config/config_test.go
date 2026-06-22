package config

import (
	"os"
	"testing"
	"time"
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

func TestLoadAIAssistDisabledByDefault(t *testing.T) {
	for _, key := range []string{"AI_ASSIST_ENABLED", "AI_ASSIST_BASE_URL", "AI_ASSIST_API_KEY", "AI_ASSIST_MODEL", "AI_ASSIST_TIMEOUT_MS"} {
		withUnsetEnv(t, key)
	}
	cfg := Load()
	if cfg.AIAssistEnabled {
		t.Fatal("AIAssistEnabled = true with no config, want disabled")
	}
	if cfg.AIAssistTimeout != 8*time.Second {
		t.Fatalf("AIAssistTimeout = %s, want default 8s", cfg.AIAssistTimeout)
	}
}

func TestLoadAIAssistEnabledWhenFullyConfigured(t *testing.T) {
	withUnsetEnv(t, "AI_ASSIST_ENABLED")
	t.Setenv("AI_ASSIST_BASE_URL", "https://api.example/v1")
	t.Setenv("AI_ASSIST_API_KEY", "sk-secret")
	t.Setenv("AI_ASSIST_MODEL", "test-model")
	t.Setenv("AI_ASSIST_TIMEOUT_MS", "1500")

	cfg := Load()
	if !cfg.AIAssistEnabled {
		t.Fatal("AIAssistEnabled = false with full config, want enabled")
	}
	if cfg.AIAssistBaseURL != "https://api.example/v1" || cfg.AIAssistModel != "test-model" {
		t.Fatalf("AI assist config not loaded: %#v", cfg.AIAssistBaseURL)
	}
	if cfg.AIAssistTimeout != 1500*time.Millisecond {
		t.Fatalf("AIAssistTimeout = %s, want 1500ms", cfg.AIAssistTimeout)
	}
}

func TestLoadAIAssistStaysDisabledWhenPartiallyConfigured(t *testing.T) {
	withUnsetEnv(t, "AI_ASSIST_ENABLED")
	withUnsetEnv(t, "AI_ASSIST_MODEL")
	t.Setenv("AI_ASSIST_BASE_URL", "https://api.example/v1")
	t.Setenv("AI_ASSIST_API_KEY", "sk-secret")

	cfg := Load()
	if cfg.AIAssistEnabled {
		t.Fatal("AIAssistEnabled = true with missing model, want disabled")
	}
}

func TestLoadAIAssistRespectsExplicitDisable(t *testing.T) {
	t.Setenv("AI_ASSIST_ENABLED", "false")
	t.Setenv("AI_ASSIST_BASE_URL", "https://api.example/v1")
	t.Setenv("AI_ASSIST_API_KEY", "sk-secret")
	t.Setenv("AI_ASSIST_MODEL", "test-model")

	cfg := Load()
	if cfg.AIAssistEnabled {
		t.Fatal("AIAssistEnabled = true despite AI_ASSIST_ENABLED=false")
	}
}

func TestLoadAIAssistDefaultsMalformedTimeout(t *testing.T) {
	t.Setenv("AI_ASSIST_TIMEOUT_MS", "nope")
	cfg := Load()
	if cfg.AIAssistTimeout != 8*time.Second {
		t.Fatalf("AIAssistTimeout = %s, want default 8s for malformed value", cfg.AIAssistTimeout)
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
