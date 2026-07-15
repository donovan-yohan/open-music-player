// Command aiassist-eval runs the versioned aiassist corpus in replay or live
// mode and writes one JSON object per line for durable, machine-readable review.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/aiassist"
	assistEval "github.com/openmusicplayer/backend/internal/aiassist/eval"
)

// Keep JSON delimiters out of the match so redaction cannot invalidate a line.
var artifactSecretPattern = regexp.MustCompile(`(?i)(?:\bbearer\s+[^\s"\\]+|\bsk-[a-z0-9_-]{8,}|\bapi[_-]?key\s*[:=]\s*[^\s"\\]+)`)

type config struct {
	mode           string
	baseURL        string
	apiKey         string
	model          string
	output         string
	timeout        time.Duration
	runTimeout     time.Duration
	caseFilter     string
	caseFilterSet  bool
	minPassRate    float64
	runID          string
	promptRevision string
}

const defaultRunTimeout = 2 * time.Minute

type artifactRecord struct {
	SchemaVersion       string                 `json:"schemaVersion"`
	RecordType          string                 `json:"recordType"`
	CorpusSchemaVersion string                 `json:"corpusSchemaVersion"`
	Run                 assistEval.RunMetadata `json:"run"`
	Case                *assistEval.CaseResult `json:"case,omitempty"`
	Totals              *assistEval.Totals     `json:"totals,omitempty"`
	StartedAt           time.Time              `json:"startedAt,omitempty"`
	FinishedAt          time.Time              `json:"finishedAt,omitempty"`
}

func main() {
	cfg := parseConfig()
	if err := run(context.Background(), cfg, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "ai-assist eval: FAIL: %v\n", err)
		os.Exit(1)
	}
}

func parseConfig() config {
	cfg := config{}
	defaultRunID := "aiassist-" + time.Now().UTC().Format("20060102T150405Z")
	defaultOutput := filepath.Join(os.TempDir(), defaultRunID+".jsonl")
	defaultCaseFilter, caseFilterSet := os.LookupEnv("AI_ASSIST_EVAL_CASE")
	flag.StringVar(&cfg.mode, "mode", envDefault("AI_ASSIST_EVAL_MODE", "replay"), "eval mode: replay or live")
	flag.StringVar(&cfg.baseURL, "base-url", envDefault("AI_ASSIST_EVAL_BASE_URL", os.Getenv("AI_ASSIST_BASE_URL")), "OpenAI-compatible API base URL (live mode)")
	flag.StringVar(&cfg.apiKey, "api-key", envDefault("AI_ASSIST_EVAL_API_KEY", os.Getenv("AI_ASSIST_API_KEY")), "OpenAI-compatible API key (live mode; never written)")
	flag.StringVar(&cfg.model, "model", envDefault("AI_ASSIST_EVAL_MODEL", os.Getenv("AI_ASSIST_MODEL")), "model identifier (live mode)")
	flag.StringVar(&cfg.output, "output", envDefault("AI_ASSIST_EVAL_OUTPUT", defaultOutput), "JSONL artifact path, or - for stdout")
	flag.DurationVar(&cfg.timeout, "timeout", envDuration("AI_ASSIST_EVAL_TIMEOUT", 8*time.Second), "per-case live request timeout")
	flag.DurationVar(&cfg.runTimeout, "run-timeout", envDuration("AI_ASSIST_EVAL_RUN_TIMEOUT", defaultRunTimeout), "whole-eval timeout")
	flag.StringVar(&cfg.caseFilter, "case", defaultCaseFilter, "comma-separated case IDs")
	flag.Float64Var(&cfg.minPassRate, "min-pass-rate", envFloat("AI_ASSIST_EVAL_MIN_PASS_RATE", 1), "required pass rate from 0 through 1")
	flag.StringVar(&cfg.runID, "run-id", envDefault("AI_ASSIST_EVAL_RUN_ID", defaultRunID), "artifact run identifier")
	flag.StringVar(&cfg.promptRevision, "prompt-revision", os.Getenv("AI_ASSIST_EVAL_PROMPT_REVISION"), "override corpus prompt revision in artifact metadata")
	flag.Parse()
	flag.CommandLine.Visit(func(value *flag.Flag) {
		if value.Name == "case" {
			caseFilterSet = true
		}
	})
	cfg.caseFilterSet = caseFilterSet
	return cfg
}

func run(ctx context.Context, cfg config, stdout io.Writer) error {
	mode := strings.ToLower(strings.TrimSpace(cfg.mode))
	if mode != "replay" && mode != "live" {
		return fmt.Errorf("mode must be replay or live")
	}
	if cfg.minPassRate < 0 || cfg.minPassRate > 1 {
		return fmt.Errorf("min-pass-rate must be between 0 and 1")
	}
	if cfg.runTimeout == 0 {
		cfg.runTimeout = defaultRunTimeout
	}
	if cfg.runTimeout < 0 {
		return fmt.Errorf("run-timeout must be greater than 0")
	}
	corpus, err := assistEval.LoadEmbeddedCorpus()
	if err != nil {
		return err
	}
	promptRevision := strings.TrimSpace(cfg.promptRevision)
	if promptRevision == "" {
		promptRevision = corpus.PromptRevision
	}
	var caseIDs []string
	if cfg.caseFilterSet || strings.TrimSpace(cfg.caseFilter) != "" {
		caseIDs, err = assistEval.ParseCaseIDs(cfg.caseFilter)
		if err != nil {
			return err
		}
	}
	selectedCorpus, err := assistEval.SelectCases(corpus, mode, caseIDs)
	if err != nil {
		return err
	}
	metadata := assistEval.RunMetadata{
		RunID: strings.TrimSpace(cfg.runID), Model: strings.TrimSpace(cfg.model), PromptRevision: promptRevision, Mode: mode,
	}
	var client aiassist.Client
	if mode == "replay" {
		client, err = assistEval.NewReplayClient(corpus)
		if err != nil {
			return err
		}
		if metadata.Model == "" {
			metadata.Model = "replay"
		}
	} else {
		if strings.TrimSpace(cfg.baseURL) == "" || strings.TrimSpace(cfg.apiKey) == "" || strings.TrimSpace(cfg.model) == "" {
			return fmt.Errorf("live mode requires base-url, api-key, and model")
		}
		client = aiassist.NewClient(aiassist.Config{
			Enabled: true, BaseURL: cfg.baseURL, APIKey: cfg.apiKey, Model: cfg.model, Timeout: cfg.timeout,
		})
		if client == nil {
			return fmt.Errorf("live mode aiassist client is not configured")
		}
	}

	runCtx, cancel := context.WithTimeout(ctx, cfg.runTimeout)
	defer cancel()
	report := assistEval.Evaluate(runCtx, selectedCorpus, client, metadata)
	if err := writeJSONL(cfg.output, report, cfg.apiKey); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "ai-assist eval: mode=%s passed=%d/%d pass_rate=%.3f safety_failures=%d artifact=%s\n",
		mode, report.Totals.Passed, report.Totals.Cases, report.Totals.PassRate, report.Totals.SafetyFailures, cfg.output)
	if report.Totals.SafetyFailures != 0 {
		return errors.New("one or more safety graders failed")
	}
	if report.Totals.PassRate < cfg.minPassRate {
		return fmt.Errorf("pass rate %.3f is below required %.3f", report.Totals.PassRate, cfg.minPassRate)
	}
	return nil
}

func writeJSONL(path string, report assistEval.Report, apiKey string) (err error) {
	var writer io.Writer
	var closer io.Closer
	if path == "-" {
		writer = os.Stdout
	} else {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return fmt.Errorf("create artifact directory: %w", err)
		}
		file, err := os.Create(path)
		if err != nil {
			return fmt.Errorf("create artifact: %w", err)
		}
		writer, closer = file, file
	}
	if closer != nil {
		defer func() {
			if closeErr := closer.Close(); err == nil && closeErr != nil {
				err = closeErr
			}
		}()
	}
	for index := range report.Cases {
		record := artifactRecord{
			SchemaVersion: assistEval.RunSchemaVersion, RecordType: "case", CorpusSchemaVersion: report.CorpusSchemaVersion,
			Run: report.Run, Case: &report.Cases[index],
		}
		if err := writeRecord(writer, record, apiKey); err != nil {
			return err
		}
	}
	summary := artifactRecord{
		SchemaVersion: assistEval.RunSchemaVersion, RecordType: "summary", CorpusSchemaVersion: report.CorpusSchemaVersion,
		Run: report.Run, Totals: &report.Totals, StartedAt: report.StartedAt, FinishedAt: report.FinishedAt,
	}
	return writeRecord(writer, summary, apiKey)
}

func writeRecord(writer io.Writer, value artifactRecord, apiKey string) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode artifact record: %w", err)
	}
	if apiKey != "" {
		raw = bytes.ReplaceAll(raw, []byte(apiKey), []byte("[REDACTED]"))
	}
	raw = artifactSecretPattern.ReplaceAll(raw, []byte("[REDACTED]"))
	if _, err := writer.Write(append(raw, '\n')); err != nil {
		return fmt.Errorf("write artifact record: %w", err)
	}
	return nil
}

func envDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envFloat(key string, fallback float64) float64 {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	var parsed float64
	if _, err := fmt.Sscan(value, &parsed); err != nil {
		return fallback
	}
	return parsed
}
