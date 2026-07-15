package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/aiassist"
	assistEval "github.com/openmusicplayer/backend/internal/aiassist/eval"
)

func TestRunReplayWritesRedactedJSONL(t *testing.T) {
	output := filepath.Join(t.TempDir(), "aiassist.jsonl")
	secretSentinel := strings.Join([]string{"sk", "test", "THIS-MUST-NOT-APPEAR"}, "-")
	var stdout bytes.Buffer
	err := run(context.Background(), config{
		mode: "replay", output: output, runID: "test-run", apiKey: secretSentinel,
		minPassRate: 1,
	}, &stdout)
	if err != nil {
		t.Fatalf("run() error = %v", err)
	}
	artifact, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(artifact)), "\n")
	if len(lines) != 14 {
		t.Fatalf("JSONL line count = %d, want 14", len(lines))
	}
	if !strings.Contains(lines[0], `"recordType":"case"`) || !strings.Contains(lines[13], `"recordType":"summary"`) {
		t.Fatalf("unexpected JSONL records: first=%s last=%s", lines[0], lines[13])
	}
	if strings.Contains(string(artifact), secretSentinel) {
		t.Fatal("artifact leaked API key")
	}
	if !strings.Contains(stdout.String(), "passed=13/13") {
		t.Fatalf("summary = %q", stdout.String())
	}
}

func TestRunRejectsIncompleteLiveConfig(t *testing.T) {
	err := run(context.Background(), config{mode: "live", output: filepath.Join(t.TempDir(), "out.jsonl"), minPassRate: 1}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "requires base-url") {
		t.Fatalf("live config error = %v", err)
	}
}

func TestRunCaseSelectionWritesSelectedTotals(t *testing.T) {
	output := filepath.Join(t.TempDir(), "selected.jsonl")
	var stdout bytes.Buffer
	err := run(context.Background(), config{
		mode: "replay", output: output, caseFilter: "ipod-touch-official-audio,ambiguous-single-word", caseFilterSet: true, minPassRate: 1,
	}, &stdout)
	if err != nil {
		t.Fatalf("run() error = %v", err)
	}
	artifact, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(artifact)), "\n")
	if len(lines) != 3 || !strings.Contains(lines[2], `"cases":2`) {
		t.Fatalf("selected JSONL = %s", artifact)
	}
	if !strings.Contains(stdout.String(), "passed=2/2") {
		t.Fatalf("summary = %q", stdout.String())
	}
}

func TestRunRejectsEmptyCaseSelection(t *testing.T) {
	err := run(context.Background(), config{mode: "replay", output: filepath.Join(t.TempDir(), "out.jsonl"), caseFilterSet: true, minPassRate: 1}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "case selection is empty") {
		t.Fatalf("empty case selection error = %v", err)
	}
}

func TestWriteRecordRedactsSecretsWithoutBreakingJSON(t *testing.T) {
	var output bytes.Buffer
	record := artifactRecord{
		SchemaVersion: assistEval.RunSchemaVersion,
		RecordType:    "case",
		Case: &assistEval.CaseResult{
			CaseID: "secret", Output: &aiassist.Intent{Kind: aiassist.KindSearch, AssistantText: "Bearer token-value"},
		},
	}
	if err := writeRecord(&output, record, ""); err != nil {
		t.Fatalf("writeRecord() error = %v", err)
	}
	if strings.Contains(output.String(), "token-value") {
		t.Fatalf("secret was not redacted: %s", output.String())
	}
	var decoded map[string]any
	if err := json.Unmarshal(output.Bytes(), &decoded); err != nil {
		t.Fatalf("redacted record is not JSON: %v; %s", err, output.String())
	}
}
