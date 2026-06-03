package config

import "testing"

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
