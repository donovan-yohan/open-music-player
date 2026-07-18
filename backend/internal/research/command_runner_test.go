package research

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type collectingSink struct {
	appended []RevisionInput
	degraded []Degradation
	terminal []TerminalTelemetry
}

func (s *collectingSink) Append(_ context.Context, input RevisionInput) error {
	s.appended = append(s.appended, input)
	return nil
}
func (s *collectingSink) Terminal(_ context.Context, value TerminalTelemetry) error {
	s.terminal = append(s.terminal, value)
	return nil
}
func (s *collectingSink) Degrade(_ context.Context, value Degradation) error {
	s.degraded = append(s.degraded, value)
	return nil
}

func TestCommandRunnerProjectsURLFreeRequestAndAppendsProgressively(t *testing.T) {
	baseline := baselineForTest(t)
	snapshot := Snapshot{Job: Job{Assignment: VariantAssignment{Variant: VariantDirectStructuredJudge, Cohort: "test"}}, Revisions: []Revision{{Kind: RevisionBaseline, Payload: baseline.Payload}}}
	runner, err := NewCommandRunner(CommandRunnerConfig{Command: os.Args[0], Args: []string{"-test.run=TestCommandRunnerHelperProcess"}, Environment: map[string]string{"PATH": os.Getenv("PATH"), "AGENT_SEARCH_TEST_MODE": "direct-deep", "DATABASE_URL": "must-not-pass", "JWT_SECRET": "must-not-pass"}, Stages: WorkerStageConfig{DirectJudge: true, DeepAgent: true}, CancelGrace: time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	sink := &collectingSink{}
	if err := runner.Run(context.Background(), RunRequest{Snapshot: snapshot, Run: Run{ID: "run-1", JobID: "job-1"}}, sink); err != nil {
		t.Fatal(err)
	}
	if len(sink.appended) != 1 {
		t.Fatalf("appends = %#v", sink.appended)
	}
	for _, input := range sink.appended {
		if strings.Contains(string(input.Payload), "sourceUrl") == false {
			t.Fatal("persisted enhancement lost server-owned URL")
		}
	}
}

func TestCommandRunnerRejectsUnsafeAndUnknownWorkerOutputWithoutLeakingIt(t *testing.T) {
	baseline := baselineForTest(t)
	snapshot := Snapshot{Job: Job{Assignment: VariantAssignment{Variant: VariantDirectStructuredJudge, Cohort: "test"}}, Revisions: []Revision{{Kind: RevisionBaseline, Payload: baseline.Payload}}}
	for _, mode := range []string{"unsafe", "unknown", "oversize"} {
		runner, err := NewCommandRunner(CommandRunnerConfig{Command: os.Args[0], Args: []string{"-test.run=TestCommandRunnerHelperProcess"}, Environment: map[string]string{"PATH": os.Getenv("PATH"), "AGENT_SEARCH_TEST_MODE": mode}, Stages: WorkerStageConfig{DirectJudge: true}, MaxLineBytes: 256, MaxOutputBytes: 512})
		if err != nil {
			t.Fatal(err)
		}
		err = runner.Run(context.Background(), RunRequest{Snapshot: snapshot, Run: Run{ID: "run-1", JobID: "job-1"}}, &collectingSink{})
		if err == nil || strings.Contains(err.Error(), "raw-secret") || strings.Contains(err.Error(), "https://") {
			t.Fatalf("mode %s leaked unsafe worker output: %v", mode, err)
		}
	}
}

func TestDisabledRunnerRecordsTypedModelDisabledOutcome(t *testing.T) {
	sink := &collectingSink{}
	err := (DisabledRunner{}).Run(context.Background(), RunRequest{}, sink)
	if err == nil || degradationFor(err).Code != DegradationModelDisabled || len(sink.degraded) != 0 {
		t.Fatalf("disabled = %v %#v", err, sink)
	}
}

func TestCommandRunnerRejectsZeroStageConfiguration(t *testing.T) {
	if _, err := NewCommandRunner(CommandRunnerConfig{Command: "worker"}); err == nil {
		t.Fatal("zero-stage runner configuration unexpectedly enabled worker stages")
	}
}

func TestCommandRunnerSelectsOnlyPersistedAssignmentStage(t *testing.T) {
	baseline := baselineForTest(t)
	for _, test := range []struct {
		name       string
		assignment VariantAssignment
		want       WorkerStageConfig
		wantCode   DegradationCode
	}{
		{name: "direct never enables deep", assignment: VariantAssignment{Variant: VariantDirectStructuredJudge, Cohort: "test"}, want: WorkerStageConfig{DirectJudge: true}},
		{name: "dark never enables direct", assignment: VariantAssignment{Variant: VariantBoundedAgentDarkLaunch, Cohort: "dark-0100"}, want: WorkerStageConfig{DeepAgent: true}},
		{name: "deterministic never starts child", assignment: VariantAssignment{Variant: VariantDeterministicOnly, Cohort: defaultVariantCohort}, wantCode: DegradationModelDisabled},
	} {
		t.Run(test.name, func(t *testing.T) {
			stages, err := stagesForAssignment(test.assignment, WorkerStageConfig{DirectJudge: true, DeepAgent: true})
			if test.wantCode != "" {
				if err == nil || degradationFor(err).Code != test.wantCode {
					t.Fatalf("stages err = %v", err)
				}
				return
			}
			if err != nil || stages != test.want {
				t.Fatalf("stages = %#v err=%v", stages, err)
			}
			wire, err := workerRequest(RunRequest{Run: Run{ID: "run", JobID: "job"}}, baselinePayloadForTest(t, baseline), defaultWorkerBudgets(), stages)
			if err != nil {
				t.Fatal(err)
			}
			got := wire["stages"].(map[string]bool)
			if got["directJudge"] != test.want.DirectJudge || got["deepAgent"] != test.want.DeepAgent {
				t.Fatalf("worker stages = %#v", got)
			}
		})
	}
}

func baselinePayloadForTest(t *testing.T, input RevisionInput) RevisionPayload {
	t.Helper()
	payload, err := ParseRevisionPayload(input.Payload)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func TestCommandRunnerGoToPythonWorkerContract(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	pythonPath := filepath.Join(root, "agents", "candidate_assembly", "src")
	python := filepath.Join(root, "agents", "candidate_assembly", ".venv", "bin", "python")
	if _, err := os.Stat(python); err != nil {
		if os.IsNotExist(err) {
			t.Skipf("skipping worker contract test: candidate assembly virtualenv not found at %s", python)
		}
		t.Fatalf("stat candidate assembly virtualenv: %v", err)
	}
	baseline := baselineForTest(t)
	snapshot := Snapshot{Job: Job{Assignment: VariantAssignment{Variant: VariantDirectStructuredJudge, Cohort: "test"}}, Revisions: []Revision{{Kind: RevisionBaseline, Payload: baseline.Payload}}}
	runner, err := NewCommandRunner(CommandRunnerConfig{Command: python, Args: []string{"-m", "candidate_assembly.worker_runner"}, Environment: map[string]string{"PATH": os.Getenv("PATH"), "PYTHONPATH": pythonPath}, Stages: WorkerStageConfig{DirectJudge: true}})
	if err != nil {
		t.Fatal(err)
	}
	sink := &collectingSink{}
	err = runner.Run(context.Background(), RunRequest{Snapshot: snapshot, Run: Run{ID: "run:python-contract", JobID: "job:python-contract"}}, sink)
	if degradationFor(err).Code != DegradationModelDisabled || len(sink.terminal) != 1 || sink.terminal[0].ToolCalls != 0 {
		t.Fatalf("worker contract result err=%v terminal=%#v", err, sink.terminal)
	}
}

func TestCommandRunnerHelperProcess(t *testing.T) {
	mode := os.Getenv("AGENT_SEARCH_TEST_MODE")
	if mode == "" {
		return
	}
	request := map[string]any{}
	if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil {
		os.Exit(2)
	}
	encoded, _ := json.Marshal(request)
	if strings.Contains(string(encoded), "sourceUrl") || strings.Contains(string(encoded), "DATABASE_URL") || strings.Contains(string(encoded), "JWT_SECRET") {
		os.Exit(3)
	}
	job, run := request["jobId"].(string), request["runId"].(string)
	if mode == "oversize" {
		_, _ = os.Stdout.WriteString(strings.Repeat("x", 1024) + "\n")
		os.Exit(0)
	}
	if mode == "unsafe" {
		_, _ = os.Stdout.WriteString(`{"schemaVersion":"omp.agent-search.worker.revision.v1","recordType":"revision","jobId":"job-1","runId":"run-1","stage":"direct_judge","result":{"recommendations":[{"candidateId":"youtube:one","rank":1,"confidence":1,"classification":"official_audio","rationale":"https://raw-secret.invalid"}]},"timing":{"latencyMs":1}}` + "\n")
		os.Exit(0)
	}
	candidate := "youtube:one"
	if mode == "unknown" {
		candidate = "unknown"
	}
	stages, _ := request["stages"].(map[string]any)
	requested := make([]string, 0, 1)
	if direct, _ := stages["directJudge"].(bool); direct {
		requested = append(requested, "direct_judge")
	}
	if deep, _ := stages["deepAgent"].(bool); deep {
		requested = append(requested, "deep_agent")
	}
	for _, stage := range requested {
		_, _ = os.Stdout.WriteString(workerRevisionJSON(job, run, stage, candidate) + "\n")
	}
	_, _ = os.Stdout.WriteString(workerTerminalJSON(job, run, "completed", len(requested)) + "\n")
	os.Exit(0)
}

func workerRevisionJSON(job, run, stage, candidate string) string {
	return `{"schemaVersion":"omp.agent-search.worker.revision.v1","recordType":"revision","jobId":"` + job + `","runId":"` + run + `","stage":"` + stage + `","result":{"schemaVersion":"omp.agent-search.assembly.v1","arm":"` + stage + `","interpretedIntent":{"searchQueries":[],"platformPreference":[],"desiredKinds":[],"durationTargetMs":null,"notes":""},"recommendations":[{"candidateId":"` + candidate + `","rank":1,"confidence":1,"classification":"official_audio","rationale":"grounded","evidence":[],"warnings":[]}],"unresolved":[],"trace":[],"budgetSpent":{"toolCalls":0,"modelCalls":0,"elapsedMs":0},"provenance":{"orchestrator":"worker","model":"","toolTransport":"none","jsonMode":null,"notes":null}},"timing":{"latencyMs":1,"toolCalls":0,"modelAttempts":[]}}`
}

func workerTerminalJSON(job, run, outcome string, revisions int) string {
	return `{"schemaVersion":"omp.agent-search.worker.terminal.v1","recordType":"terminal","jobId":"` + job + `","runId":"` + run + `","outcome":"` + outcome + `","revisionsEmitted":` + strconv.Itoa(revisions) + `,"degradations":[],"timing":{"toolCalls":0,"modelAttempts":[]}}`
}
