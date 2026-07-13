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

func TestLoadMetadataLLMDisabledByDefault(t *testing.T) {
	for _, key := range []string{"METADATA_LLM_ENABLED", "METADATA_LLM_BASE_URL", "METADATA_LLM_MODEL", "METADATA_LLM_TIMEOUT_MS", "OLLAMA_BASE_URL", "OLLAMA_MODEL"} {
		withUnsetEnv(t, key)
	}
	cfg := Load()
	if cfg.MetadataLLMEnabled {
		t.Fatal("MetadataLLMEnabled = true with no config, want disabled")
	}
	if cfg.MetadataLLMBaseURL != "http://localhost:11434" {
		t.Fatalf("MetadataLLMBaseURL = %q, want local Ollama default", cfg.MetadataLLMBaseURL)
	}
	if cfg.MetadataLLMTimeout != 5*time.Second {
		t.Fatalf("MetadataLLMTimeout = %s, want default 5s", cfg.MetadataLLMTimeout)
	}
}

func TestLoadMetadataLLMExplicitEnable(t *testing.T) {
	t.Setenv("METADATA_LLM_ENABLED", "true")
	t.Setenv("METADATA_LLM_BASE_URL", "http://ollama.example:11434")
	t.Setenv("METADATA_LLM_MODEL", "llama3.1")
	t.Setenv("METADATA_LLM_TIMEOUT_MS", "1200")

	cfg := Load()
	if !cfg.MetadataLLMEnabled {
		t.Fatal("MetadataLLMEnabled = false despite explicit enable")
	}
	if cfg.MetadataLLMBaseURL != "http://ollama.example:11434" || cfg.MetadataLLMModel != "llama3.1" {
		t.Fatalf("metadata LLM config not loaded: base=%q model=%q", cfg.MetadataLLMBaseURL, cfg.MetadataLLMModel)
	}
	if cfg.MetadataLLMTimeout != 1200*time.Millisecond {
		t.Fatalf("MetadataLLMTimeout = %s, want 1200ms", cfg.MetadataLLMTimeout)
	}
}

func TestLoadSourceQualityLLMDisabledByDefault(t *testing.T) {
	withUnsetSourceQualityLLMEnv(t)

	cfg := Load()
	if cfg.SourceQualityLLMEnabled {
		t.Fatal("SourceQualityLLMEnabled = true with no config, want disabled")
	}
	if cfg.SourceQualityLLMBaseURL != "http://localhost:11434" {
		t.Fatalf("SourceQualityLLMBaseURL = %q, want local Ollama default", cfg.SourceQualityLLMBaseURL)
	}
	if cfg.SourceQualityLLMModel != "source-quality-judge" {
		t.Fatalf("SourceQualityLLMModel = %q, want source-quality-judge", cfg.SourceQualityLLMModel)
	}
	if cfg.SourceQualityLLMTimeout != 1500*time.Millisecond {
		t.Fatalf("SourceQualityLLMTimeout = %s, want default 1500ms", cfg.SourceQualityLLMTimeout)
	}
	if cfg.SourceQualityLLMAPIKey != "" {
		t.Fatal("SourceQualityLLMAPIKey should be empty when OLLAMA_API_KEY is unset")
	}
}

func TestLoadSourceQualityLLMUsesExplicitValuesAndCarriesOptionalAPIKey(t *testing.T) {
	withUnsetSourceQualityLLMEnv(t)
	t.Setenv("SOURCE_QUALITY_LLM_ENABLED", "true")
	t.Setenv("SOURCE_QUALITY_LLM_BASE_URL", "http://source-quality.example:11434")
	t.Setenv("SOURCE_QUALITY_LLM_MODEL", "quality-model")
	t.Setenv("SOURCE_QUALITY_LLM_TIMEOUT_MS", "1200")
	t.Setenv("OLLAMA_API_KEY", "source-quality-secret")

	cfg := Load()
	if !cfg.SourceQualityLLMEnabled {
		t.Fatal("SourceQualityLLMEnabled = false despite explicit enable")
	}
	if cfg.SourceQualityLLMBaseURL != "http://source-quality.example:11434" || cfg.SourceQualityLLMModel != "quality-model" {
		t.Fatalf("source-quality LLM config not loaded: base=%q model=%q", cfg.SourceQualityLLMBaseURL, cfg.SourceQualityLLMModel)
	}
	if cfg.SourceQualityLLMTimeout != 1200*time.Millisecond {
		t.Fatalf("SourceQualityLLMTimeout = %s, want 1200ms", cfg.SourceQualityLLMTimeout)
	}
	if cfg.SourceQualityLLMAPIKey == "" {
		t.Fatal("optional Ollama API key was not retained")
	}
}

func TestLoadSourceQualityLLMFallsBackToOllamaValues(t *testing.T) {
	withUnsetSourceQualityLLMEnv(t)
	t.Setenv("OLLAMA_BASE_URL", "http://ollama.example:11434")
	t.Setenv("OLLAMA_MODEL", "shared-ollama-model")

	cfg := Load()
	if cfg.SourceQualityLLMBaseURL != "http://ollama.example:11434" {
		t.Fatalf("SourceQualityLLMBaseURL = %q, want OLLAMA_BASE_URL fallback", cfg.SourceQualityLLMBaseURL)
	}
	if cfg.SourceQualityLLMModel != "shared-ollama-model" {
		t.Fatalf("SourceQualityLLMModel = %q, want OLLAMA_MODEL fallback", cfg.SourceQualityLLMModel)
	}
}

func TestLoadSourceQualityLLMDefaultsInvalidTimeout(t *testing.T) {
	for _, value := range []string{"nope", "0", "-1"} {
		t.Run(value, func(t *testing.T) {
			withUnsetSourceQualityLLMEnv(t)
			t.Setenv("SOURCE_QUALITY_LLM_TIMEOUT_MS", value)

			cfg := Load()
			if cfg.SourceQualityLLMTimeout != 1500*time.Millisecond {
				t.Fatalf("SourceQualityLLMTimeout = %s, want default 1500ms for %q", cfg.SourceQualityLLMTimeout, value)
			}
		})
	}
}

func TestLoadAnalyzerDisabledByDefault(t *testing.T) {
	for _, key := range []string{"ANALYZER_ENABLED", "ANALYZER_BASE_URL", "ANALYZER_AUTH_TOKEN", "ANALYZER_TIMEOUT_MS", "ANALYZER_CONCURRENCY"} {
		withUnsetEnv(t, key)
	}
	cfg := Load()
	if cfg.AnalyzerEnabled {
		t.Fatal("AnalyzerEnabled = true with no config, want disabled")
	}
	if cfg.AnalyzerTimeout != 90*time.Second {
		t.Fatalf("AnalyzerTimeout = %s, want default 90s", cfg.AnalyzerTimeout)
	}
	if cfg.AnalyzerConcurrency != 1 {
		t.Fatalf("AnalyzerConcurrency = %d, want default 1", cfg.AnalyzerConcurrency)
	}
}

func TestLoadAnalyzerEnabledWhenBaseURLConfigured(t *testing.T) {
	withUnsetEnv(t, "ANALYZER_ENABLED")
	t.Setenv("ANALYZER_BASE_URL", "http://analyzer.local:18190")
	t.Setenv("ANALYZER_AUTH_TOKEN", "secret-token")
	t.Setenv("ANALYZER_TIMEOUT_MS", "2500")
	t.Setenv("ANALYZER_CONCURRENCY", "3")

	cfg := Load()
	if !cfg.AnalyzerEnabled {
		t.Fatal("AnalyzerEnabled = false with base URL, want enabled")
	}
	if cfg.AnalyzerBaseURL != "http://analyzer.local:18190" || cfg.AnalyzerAuthToken != "secret-token" {
		t.Fatalf("analyzer config not loaded: base=%q token=%q", cfg.AnalyzerBaseURL, cfg.AnalyzerAuthToken)
	}
	if cfg.AnalyzerTimeout != 2500*time.Millisecond {
		t.Fatalf("AnalyzerTimeout = %s, want 2500ms", cfg.AnalyzerTimeout)
	}
	if cfg.AnalyzerConcurrency != 3 {
		t.Fatalf("AnalyzerConcurrency = %d, want 3", cfg.AnalyzerConcurrency)
	}
}

func TestLoadClampsAnalyzerConcurrency(t *testing.T) {
	t.Setenv("ANALYZER_CONCURRENCY", "99")

	cfg := Load()

	if cfg.AnalyzerConcurrency != 4 {
		t.Fatalf("AnalyzerConcurrency = %d, want cap 4", cfg.AnalyzerConcurrency)
	}
}

func TestLoadAnalyzerRespectsExplicitDisable(t *testing.T) {
	t.Setenv("ANALYZER_ENABLED", "false")
	t.Setenv("ANALYZER_BASE_URL", "http://analyzer.local:18190")

	cfg := Load()
	if cfg.AnalyzerEnabled {
		t.Fatal("AnalyzerEnabled = true despite ANALYZER_ENABLED=false")
	}
}

func withUnsetCORSAllowedOrigins(t *testing.T) {
	t.Helper()
	withUnsetEnv(t, "OMP_CORS_ALLOWED_ORIGINS")
	withUnsetEnv(t, "CORS_ALLOWED_ORIGINS")
}

func withUnsetSourceQualityLLMEnv(t *testing.T) {
	t.Helper()
	for _, key := range []string{
		"SOURCE_QUALITY_LLM_ENABLED",
		"SOURCE_QUALITY_LLM_BASE_URL",
		"SOURCE_QUALITY_LLM_MODEL",
		"SOURCE_QUALITY_LLM_TIMEOUT_MS",
		"OLLAMA_BASE_URL",
		"OLLAMA_MODEL",
		"OLLAMA_API_KEY",
	} {
		withUnsetEnv(t, key)
	}
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
