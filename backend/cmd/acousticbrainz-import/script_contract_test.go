package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The operator-facing wrapper for this loader lives outside the Go module, and
// three of its properties are load-bearing enough that a silent regression
// would only be noticed during a multi-hour bulk import against a real
// database. These tests pin them from the one place in the repo that has a
// test harness at all. See docs/ACOUSTICBRAINZ_IMPORT.md.
const importScriptRelPath = "../../../scripts/acousticbrainz-import.sh"

func readImportScript(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(importScriptRelPath)
	if err != nil {
		t.Fatalf("read %s: %v", importScriptRelPath, err)
	}
	return string(data)
}

func requireBinaries(t *testing.T, names ...string) {
	t.Helper()
	for _, name := range names {
		if _, err := exec.LookPath(name); err != nil {
			t.Skipf("%s not available: %v", name, err)
		}
	}
}

// TestImportScriptPinsDumpDigestsMatchingRunbook keeps the script's pinned
// sha256 constants and the runbook's artifact table from drifting apart. The
// server-supplied `sha256sums` cannot detect a re-cut dump (it is republished
// with the archives), so these literals are the only check that the bytes are
// the ones every number under "Observed run" was measured from.
func TestImportScriptPinsDumpDigestsMatchingRunbook(t *testing.T) {
	script := readImportScript(t)
	runbook, err := os.ReadFile("../../../docs/ACOUSTICBRAINZ_IMPORT.md")
	if err != nil {
		t.Fatalf("read runbook: %v", err)
	}
	doc := string(runbook)

	for _, tc := range []struct {
		constant string
		archive  string
	}{
		{"AB_RHYTHM_SHA256", "acousticbrainz-lowlevel-features-20220623-rhythm.tar.zst"},
		{"AB_TONAL_SHA256", "acousticbrainz-lowlevel-features-20220623-tonal.tar.zst"},
	} {
		re := regexp.MustCompile(tc.constant + `="([0-9a-f]{64})"`)
		match := re.FindStringSubmatch(script)
		if match == nil {
			t.Fatalf("%s is not pinned to a literal sha256 in %s; the fetch gate would fall back to the server's own manifest", tc.constant, importScriptRelPath)
		}
		digest := match[1]
		var pinnedInDoc bool
		for _, line := range strings.Split(doc, "\n") {
			if strings.Contains(line, tc.archive) && strings.Contains(line, digest) {
				pinnedInDoc = true
				break
			}
		}
		if !pinnedInDoc {
			t.Fatalf("%s=%s does not appear on the %s row of the runbook artifact table; script and docs/ACOUSTICBRAINZ_IMPORT.md disagree about which dump is pinned", tc.constant, digest, tc.archive)
		}
	}
}

// TestImportScriptNeverPassesDBPasswordOnArgv pins the credential-handling
// rule: the loader defaults -db-password from OMP_AB_DB_PASSWORD, so the
// wrapper passes it through the environment only. argv is world-readable via
// `ps` and /proc/<pid>/cmdline for as long as a shard runs.
func TestImportScriptNeverPassesDBPasswordOnArgv(t *testing.T) {
	for i, line := range strings.Split(readImportScript(t), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if strings.Contains(line, "-db-password") {
			t.Fatalf("%s:%d passes the DB password on the command line: %q", importScriptRelPath, i+1, strings.TrimSpace(line))
		}
	}
}

// runScriptSnippet sources the wrapper (which defines its helpers without
// dispatching) and runs snippet with a stub curl on PATH.
func runScriptSnippet(t *testing.T, work, snippet string, curlExit string) (string, int, string) {
	t.Helper()
	stubDir := filepath.Join(work, "stub-bin")
	if err := os.MkdirAll(stubDir, 0o755); err != nil {
		t.Fatalf("mkdir stub bin: %v", err)
	}
	curlLog := filepath.Join(work, "curl.log")
	stub := "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"" + curlLog + "\"\nexit " + curlExit + "\n"
	if err := os.WriteFile(filepath.Join(stubDir, "curl"), []byte(stub), 0o755); err != nil {
		t.Fatalf("write curl stub: %v", err)
	}
	scriptPath, err := filepath.Abs(importScriptRelPath)
	if err != nil {
		t.Fatalf("abs script path: %v", err)
	}

	cmd := exec.Command("bash", "-c", "set -euo pipefail\nsource \""+scriptPath+"\"\ncd \""+work+"\"\n"+snippet)
	cmd.Env = append(os.Environ(), "PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	out, err := cmd.CombinedOutput()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run snippet: %v (%s)", err, out)
	}
	logged, _ := os.ReadFile(curlLog)
	return string(out), code, string(logged)
}

// TestImportScriptFetchArtifactIsRerunnable pins `fetch` idempotence, which the
// script's own help text promises for every subcommand. A completed archive
// must not be re-downloaded, and a `curl -C -` resume against an
// already-complete file (origin answers 416, curl exits 22) must not abort the
// run before the checksum gate. Real transport failures must still propagate.
func TestImportScriptFetchArtifactIsRerunnable(t *testing.T) {
	requireBinaries(t, "bash", "sha256sum")

	// sha256 of "dump-bytes\n".
	const body = "dump-bytes\n"
	const digest = "7c9ffcbb9c5f5c9f4a9de3f9db4a70dbe8bc2fd5adfd0ff7f8a3f3ff3b6cf1a3"

	t.Run("already complete file is not re-downloaded", func(t *testing.T) {
		work := t.TempDir()
		if err := os.WriteFile(filepath.Join(work, "artifact.tar.zst"), []byte(body), 0o644); err != nil {
			t.Fatalf("seed artifact: %v", err)
		}
		// Compute the real digest inside the shell so the test never encodes a
		// stale constant.
		snippet := `want="$(sha256sum artifact.tar.zst | cut -d' ' -f1)"
fetch_artifact artifact.tar.zst "$want"`
		out, code, curlLog := runScriptSnippet(t, work, snippet, "22")
		if code != 0 {
			t.Fatalf("fetch_artifact on a complete file exited %d, want 0\n%s", code, out)
		}
		if curlLog != "" {
			t.Fatalf("curl was invoked for an artifact that already matches the pinned digest: %q", curlLog)
		}
	})

	t.Run("curl exit 22 from a resumed complete file is tolerated", func(t *testing.T) {
		work := t.TempDir()
		snippet := `fetch_artifact artifact.tar.zst ` + digest
		out, code, curlLog := runScriptSnippet(t, work, snippet, "22")
		if code != 0 {
			t.Fatalf("fetch_artifact exited %d on curl's 416/exit-22, want 0 so the checksum gate still runs\n%s", code, out)
		}
		if !strings.Contains(curlLog, "artifact.tar.zst") {
			t.Fatalf("curl was not invoked for a missing artifact: %q", curlLog)
		}
	})

	t.Run("real curl failures still propagate", func(t *testing.T) {
		work := t.TempDir()
		snippet := `fetch_artifact artifact.tar.zst ` + digest
		out, code, _ := runScriptSnippet(t, work, snippet, "6")
		if code == 0 {
			t.Fatalf("fetch_artifact swallowed curl exit 6 (could not resolve host)\n%s", out)
		}
	})
}

// TestImportScriptRefusesRemoteDBHost pins the locality guard: snapshot, verify
// and scope reach the database with `docker exec` on the local daemon, while
// the loader connects over TCP to OMP_AB_DB_HOST. With a remote host those are
// different databases and the before/after census guard silently passes on the
// wrong one.
func TestImportScriptRefusesRemoteDBHost(t *testing.T) {
	requireBinaries(t, "bash")

	work := t.TempDir()
	stubDir := filepath.Join(work, "stub-bin")
	if err := os.MkdirAll(stubDir, 0o755); err != nil {
		t.Fatalf("mkdir stub bin: %v", err)
	}
	dockerLog := filepath.Join(work, "docker.log")
	stub := "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"" + dockerLog + "\"\n"
	if err := os.WriteFile(filepath.Join(stubDir, "docker"), []byte(stub), 0o755); err != nil {
		t.Fatalf("write docker stub: %v", err)
	}

	cmd := exec.Command("bash", importScriptRelPath, "snapshot")
	cmd.Env = append(os.Environ(),
		"PATH="+stubDir+string(os.PathListSeparator)+os.Getenv("PATH"),
		"OMP_AB_DB_HOST=db.invalid.example.test",
	)
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("snapshot succeeded with a remote OMP_AB_DB_HOST; the census would describe the local database instead\n%s", out)
	}
	if !strings.Contains(string(out), "is remote") {
		t.Fatalf("snapshot failed without naming the remote-host cause: %s", out)
	}
	if _, statErr := os.Stat(dockerLog); statErr == nil {
		logged, _ := os.ReadFile(dockerLog)
		t.Fatalf("docker was still invoked despite the remote-host guard: %q", logged)
	}
}
