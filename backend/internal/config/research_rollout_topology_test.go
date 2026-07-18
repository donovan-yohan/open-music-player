package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestResearchWorkerComposeProfileIsOptInAndOpaque(t *testing.T) {
	for _, name := range []string{"docker-compose.yml", "docker-compose.local-low-memory.yml"} {
		t.Run(name, func(t *testing.T) {
			contents, err := os.ReadFile(filepath.Join(repositoryRoot(t), name))
			if err != nil {
				t.Fatalf("read %s: %v", name, err)
			}
			worker := composeServiceBlock(t, string(contents), "research-worker", "postgres")
			for _, required := range []string{
				"profiles:\n      - research-worker",
				"RESEARCH_WORKER_ENABLED: \"true\"",
				"RESEARCH_COMMAND: candidate-assembly-worker",
				"RESEARCH_DEEP_AGENT_ENABLED: ${RESEARCH_DEEP_AGENT_ENABLED:-false}",
				"RESEARCH_DEEP_AGENT_DARK_LAUNCH_ENABLED: ${RESEARCH_DEEP_AGENT_DARK_LAUNCH_ENABLED:-false}",
				"RESEARCH_DEEP_AGENT_COHORT_BPS: ${RESEARCH_DEEP_AGENT_COHORT_BPS:-0}",
				"REDIS_ENABLED: \"false\"",
				"WORKER_COUNT: \"0\"",
				"restart: unless-stopped",
				"healthcheck:",
			} {
				if !strings.Contains(worker, required) {
					t.Errorf("research-worker missing %q", required)
				}
			}
			for _, forbidden := range []string{"JWT_SECRET:", "OMP_AGENT_SERVICE_TOKEN:", "FIRECRAWL_API_KEY:"} {
				if strings.Contains(worker, forbidden) {
					t.Errorf("research-worker must not receive %s", forbidden)
				}
			}

			backend := composeServiceBlock(t, string(contents), "backend", "analyzer")
			for _, required := range []string{
				"RESEARCH_ENABLED: ${RESEARCH_ENABLED:-false}",
				"RESEARCH_WORKER_ENABLED: \"false\"",
				"RESEARCH_DEEP_AGENT_WEB_ENABLED: ${RESEARCH_DEEP_AGENT_WEB_ENABLED:-false}",
			} {
				if !strings.Contains(backend, required) {
					t.Errorf("backend missing safe rollout config %q", required)
				}
			}
		})
	}
}

func TestResearchWorkerImagePackagesExistingWorkerCommand(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join(repositoryRoot(t), "Dockerfile.research-worker"))
	if err != nil {
		t.Fatalf("read Dockerfile.research-worker: %v", err)
	}
	for _, required := range []string{
		"COPY agents/candidate_assembly/pyproject.toml agents/candidate_assembly/uv.lock ./",
		"COPY agents/candidate_assembly/ ./",
		"uv sync --frozen --extra live --no-dev",
		"PATH=/opt/candidate-assembly/.venv/bin:$PATH",
		"ENTRYPOINT [\"/app/server\"]",
	} {
		if !strings.Contains(string(contents), required) {
			t.Errorf("Dockerfile.research-worker missing %q", required)
		}
	}
}

func composeServiceBlock(t *testing.T, contents, service, nextService string) string {
	t.Helper()
	start := strings.Index(contents, "  "+service+":\n")
	if start < 0 {
		t.Fatalf("missing compose service %q", service)
	}
	block := contents[start:]
	if end := strings.Index(block, "\n  "+nextService+":\n"); end >= 0 {
		return block[:end]
	}
	return block
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
}
