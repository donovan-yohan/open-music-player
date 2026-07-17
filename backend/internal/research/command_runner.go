package research

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	workerRequestSchema  = "omp.agent-search.worker.request.v1"
	workerRevisionSchema = "omp.agent-search.worker.revision.v1"
	workerTerminalSchema = "omp.agent-search.worker.terminal.v1"
)

type WorkerBudgetConfig struct {
	MaxToolCalls, MaxModelCalls, RecursionLimit, MaxCandidatesIn, MaxRecommendations int
	WallClockMs, MaxRequestBytes, MaxResponseBytes, MaxTokensPerCompletion           int
}
type WorkerStageConfig struct{ DirectJudge, DeepAgent bool }

type CommandRunnerConfig struct {
	Command        string
	Args           []string
	Environment    map[string]string
	Budgets        WorkerBudgetConfig
	Stages         WorkerStageConfig
	CancelGrace    time.Duration
	MaxLineBytes   int
	MaxOutputBytes int
	MaxRecords     int
	Now            func() time.Time
}
type CommandRunner struct{ config CommandRunnerConfig }

func defaultWorkerBudgets() WorkerBudgetConfig {
	return WorkerBudgetConfig{MaxToolCalls: 8, MaxModelCalls: 10, RecursionLimit: 12, MaxCandidatesIn: 25, MaxRecommendations: 10, WallClockMs: 180000, MaxRequestBytes: 49152, MaxResponseBytes: 65536, MaxTokensPerCompletion: 4096}
}
func (b WorkerBudgetConfig) valid() bool {
	return b.MaxToolCalls >= 1 && b.MaxToolCalls <= 32 && b.MaxModelCalls >= 1 && b.MaxModelCalls <= 12 && b.RecursionLimit >= 2 && b.RecursionLimit <= 16 && b.MaxCandidatesIn >= 1 && b.MaxCandidatesIn <= 64 && b.MaxRecommendations >= 1 && b.MaxRecommendations <= 10 && b.WallClockMs >= 1000 && b.WallClockMs <= 300000 && b.MaxRequestBytes >= 1024 && b.MaxRequestBytes <= 64*1024 && b.MaxResponseBytes >= 1024 && b.MaxResponseBytes <= 128*1024 && b.MaxTokensPerCompletion >= 64 && b.MaxTokensPerCompletion <= 8192
}
func (b WorkerBudgetConfig) zero() bool { return b == (WorkerBudgetConfig{}) }

func NewCommandRunner(config CommandRunnerConfig) (*CommandRunner, error) {
	if strings.TrimSpace(config.Command) == "" {
		return nil, errors.New("research worker command is required")
	}
	if config.Budgets.zero() {
		config.Budgets = defaultWorkerBudgets()
	}
	if !config.Budgets.valid() {
		return nil, errors.New("research worker budgets invalid")
	}
	if !config.Stages.DirectJudge && !config.Stages.DeepAgent {
		config.Stages = WorkerStageConfig{DirectJudge: true, DeepAgent: true}
	}
	if config.CancelGrace <= 0 {
		config.CancelGrace = 2 * time.Second
	}
	if config.MaxLineBytes <= 0 || config.MaxLineBytes > 64*1024 {
		config.MaxLineBytes = 64 * 1024
	}
	if config.MaxOutputBytes <= 0 || config.MaxOutputBytes > 128*1024 {
		config.MaxOutputBytes = 128 * 1024
	}
	if config.MaxRecords <= 0 || config.MaxRecords > 3 {
		config.MaxRecords = 3
	}
	if config.Now == nil {
		config.Now = time.Now
	}
	return &CommandRunner{config: config}, nil
}

func (r *CommandRunner) Run(ctx context.Context, request RunRequest, sink EnhancementSink) error {
	baseline, err := baselineFromSnapshot(request.Snapshot)
	if err != nil {
		return Validation(errors.New("research baseline unavailable"))
	}
	wire, err := workerRequest(request, baseline, r.config.Budgets, r.config.Stages)
	if err != nil {
		return Validation(errors.New("research worker request invalid"))
	}
	encoded, err := json.Marshal(wire)
	if err != nil || len(encoded) > r.config.Budgets.MaxRequestBytes {
		return Validation(errors.New("research worker request invalid"))
	}
	cmd := exec.Command(r.config.Command, r.config.Args...)
	cmd.Env = childEnvironment(r.config.Environment)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return Transient(errors.New("research worker start failed"))
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return Transient(errors.New("research worker start failed"))
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return Transient(errors.New("research worker start failed"))
	}
	started := r.config.Now()
	if err := cmd.Start(); err != nil {
		return Transient(errors.New("research worker start failed"))
	}
	stderrDone := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, stderr); close(stderrDone) }()
	wait := func() error { err := cmd.Wait(); <-stderrDone; return err }
	terminate := func() {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		timer := time.NewTimer(r.config.CancelGrace)
		done := make(chan struct{})
		go func() { _ = wait(); close(done) }()
		select {
		case <-done:
			if !timer.Stop() {
				<-timer.C
			}
		case <-timer.C:
			_ = cmd.Process.Kill()
			<-done
		}
	}
	if _, err := stdin.Write(append(encoded, '\n')); err != nil {
		_ = stdin.Close()
		terminate()
		return Transient(errors.New("research worker input failed"))
	}
	if err := stdin.Close(); err != nil {
		terminate()
		return Transient(errors.New("research worker input failed"))
	}
	cancelDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			terminate()
		case <-cancelDone:
		}
	}()
	defer close(cancelDone)

	expected := configuredStages(r.config.Stages)
	seenTerminal, records, bytesRead := false, 0, 0
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 1024), r.config.MaxLineBytes)
	for scanner.Scan() {
		if ctx.Err() != nil {
			terminate()
			return ctx.Err()
		}
		line := append([]byte(nil), scanner.Bytes()...)
		records++
		bytesRead += len(line) + 1
		if records > r.config.MaxRecords || bytesRead > r.config.MaxOutputBytes || len(bytes.TrimSpace(line)) == 0 {
			terminate()
			return Validation(errors.New("research worker output invalid"))
		}
		if err := r.handleRecord(ctx, line, request, baseline, sink, &expected, &seenTerminal, started); err != nil {
			terminate()
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
	}
	if scanner.Err() != nil {
		terminate()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return Validation(errors.New("research worker output invalid"))
	}
	processErr := wait()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if processErr != nil || !seenTerminal {
		return Transient(errors.New("research worker ended without terminal record"))
	}
	return nil
}

func configuredStages(config WorkerStageConfig) []RevisionStage {
	stages := make([]RevisionStage, 0, 2)
	if config.DirectJudge {
		stages = append(stages, StageDirectJudge)
	}
	if config.DeepAgent {
		stages = append(stages, StageDeepAgent)
	}
	return stages
}

func (r *CommandRunner) handleRecord(ctx context.Context, raw []byte, request RunRequest, baseline RevisionPayload, sink EnhancementSink, expected *[]RevisionStage, seenTerminal *bool, started time.Time) error {
	if bytes.Contains(bytes.ToLower(raw), []byte("http://")) || bytes.Contains(bytes.ToLower(raw), []byte("https://")) || secretLikeText.Match(raw) {
		return Safety(errors.New("research worker output unsafe"))
	}
	var envelope workerEnvelope
	if err := decodeEnvelope(raw, &envelope); err != nil || envelope.JobID != request.Run.JobID || envelope.RunID != request.Run.ID || *seenTerminal {
		return Validation(errors.New("research worker output invalid"))
	}
	switch envelope.RecordType {
	case "revision":
		var record workerRevisionRecord
		if err := decodeStrict(raw, &record); err != nil || record.SchemaVersion != workerRevisionSchema || len(*expected) == 0 || record.Stage != (*expected)[0] || !validWorkerRevision(record) {
			return Validation(errors.New("research worker revision invalid"))
		}
		payload, err := workerRevisionPayload(record, baseline, r.config.Now().Sub(started).Milliseconds(), len(*expected) == 2 && record.Stage == StageDirectJudge)
		if err != nil {
			return Validation(errors.New("research worker revision invalid"))
		}
		encoded, err := payload.Marshal()
		if err != nil {
			return Validation(errors.New("research worker revision invalid"))
		}
		if err := sink.Append(ctx, RevisionInput{ID: newResearchID(), Payload: encoded}); err != nil {
			return Validation(errors.New("research enhancement rejected"))
		}
		*expected = (*expected)[1:]
		return nil
	case "terminal":
		var terminal workerTerminalRecord
		emitted := len(configuredStages(r.config.Stages)) - len(*expected)
		if err := decodeStrict(raw, &terminal); err != nil || terminal.SchemaVersion != workerTerminalSchema || !validWorkerTerminal(terminal, request, emitted, *expected) {
			return Validation(errors.New("research worker terminal invalid"))
		}
		telemetry := terminal.telemetry()
		if err := sink.Terminal(ctx, telemetry); err != nil {
			return err
		}
		*seenTerminal = true
		return terminal.runnerError()
	default:
		return Validation(errors.New("research worker record invalid"))
	}
}

func decodeStrict(raw []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("trailing json")
	}
	return nil
}

func decodeEnvelope(raw []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("trailing json")
	}
	return nil
}

type workerEnvelope struct {
	SchemaVersion string `json:"schemaVersion"`
	RecordType    string `json:"recordType"`
	JobID         string `json:"jobId"`
	RunID         string `json:"runId"`
}
type workerIntent struct {
	SearchQueries      []string `json:"searchQueries"`
	PlatformPreference []string `json:"platformPreference"`
	DesiredKinds       []string `json:"desiredKinds"`
	DurationTargetMs   *int     `json:"durationTargetMs"`
	Notes              string   `json:"notes"`
}
type workerEvidence struct {
	Tool string `json:"tool"`
	Ref  string `json:"ref"`
}
type workerRecommendation struct {
	CandidateID    string           `json:"candidateId"`
	Rank           int              `json:"rank"`
	Confidence     float64          `json:"confidence"`
	Rationale      string           `json:"rationale"`
	Classification *string          `json:"classification"`
	Evidence       []workerEvidence `json:"evidence"`
	Warnings       []string         `json:"warnings"`
}
type workerTrace struct {
	Step        int    `json:"step"`
	Tool        string `json:"tool"`
	ArgsDigest  string `json:"argsDigest"`
	ResultCount int    `json:"resultCount"`
	ElapsedMs   int    `json:"elapsedMs"`
}
type workerBudgetSpent struct {
	ToolCalls  int `json:"toolCalls"`
	ModelCalls int `json:"modelCalls"`
	ElapsedMs  int `json:"elapsedMs"`
}
type workerProvenance struct {
	Orchestrator  string   `json:"orchestrator"`
	Model         string   `json:"model"`
	ToolTransport string   `json:"toolTransport"`
	JSONMode      *bool    `json:"jsonMode"`
	Notes         []string `json:"notes"`
}
type workerAssemblyError struct {
	Code    string  `json:"code"`
	Message string  `json:"message"`
	Detail  *string `json:"detail"`
}
type workerAssemblyResult struct {
	SchemaVersion     string                 `json:"schemaVersion"`
	Arm               string                 `json:"arm"`
	InterpretedIntent workerIntent           `json:"interpretedIntent"`
	Recommendations   []workerRecommendation `json:"recommendations"`
	Unresolved        []string               `json:"unresolved"`
	Trace             []workerTrace          `json:"trace"`
	BudgetSpent       workerBudgetSpent      `json:"budgetSpent"`
	Provenance        workerProvenance       `json:"provenance"`
	Error             *workerAssemblyError   `json:"error"`
}
type workerStageTiming struct {
	LatencyMs     int64                `json:"latencyMs"`
	ToolCalls     int                  `json:"toolCalls"`
	ModelAttempts []workerModelAttempt `json:"modelAttempts"`
}
type workerRevisionRecord struct {
	SchemaVersion string               `json:"schemaVersion"`
	RecordType    string               `json:"recordType"`
	JobID         string               `json:"jobId"`
	RunID         string               `json:"runId"`
	Stage         RevisionStage        `json:"stage"`
	Result        workerAssemblyResult `json:"result"`
	Timing        workerStageTiming    `json:"timing"`
}
type workerModelAttempt struct {
	Stage      RevisionStage `json:"stage"`
	Attempt    int           `json:"attempt"`
	DurationMs int64         `json:"durationMs"`
	Repair     bool          `json:"repair"`
	Status     string        `json:"status"`
}
type workerTiming struct {
	ProcessStartupToRequestAcceptedMs *int64               `json:"processStartupToRequestAcceptedMs"`
	RequestAcceptedToDirectFirstMs    *int64               `json:"requestAcceptedToDirectFirstRevisionMs"`
	RequestAcceptedToFinalMs          *int64               `json:"requestAcceptedToFinalMs"`
	ToolCalls                         int                  `json:"toolCalls"`
	ModelAttempts                     []workerModelAttempt `json:"modelAttempts"`
}
type workerDegradation struct {
	Stage string `json:"stage"`
	Code  string `json:"code"`
}
type workerTerminalRecord struct {
	SchemaVersion    string              `json:"schemaVersion"`
	RecordType       string              `json:"recordType"`
	JobID            string              `json:"jobId"`
	RunID            string              `json:"runId"`
	Outcome          string              `json:"outcome"`
	RevisionsEmitted int                 `json:"revisionsEmitted"`
	Degradations     []workerDegradation `json:"degradations"`
	Timing           workerTiming        `json:"timing"`
}

func validWorkerAttempt(value workerModelAttempt) bool {
	return (value.Stage == StageDirectJudge || value.Stage == StageDeepAgent) && value.Attempt > 0 && value.DurationMs >= 0 && (value.Status == "success" || value.Status == "parse_error" || value.Status == "transport_error")
}
func validWorkerRevision(value workerRevisionRecord) bool {
	if value.RecordType != "revision" || !safeRequiredID(value.JobID) || !safeRequiredID(value.RunID) || value.Result.SchemaVersion != "omp.agent-search.assembly.v1" || !safeRequiredText(value.Result.Arm, 128) || value.Result.Error != nil || value.Timing.LatencyMs < 0 || value.Timing.ToolCalls < 0 || len(value.Timing.ModelAttempts) > 12 || len(value.Result.Recommendations) > 10 {
		return false
	}
	for index, recommendation := range value.Result.Recommendations {
		if !safeRequiredID(recommendation.CandidateID) || recommendation.Rank != index+1 || recommendation.Confidence < 0 || recommendation.Confidence > 1 || !safeText(recommendation.Rationale, 240) || recommendation.Classification == nil || !safeRequiredText(*recommendation.Classification, 64) || len(recommendation.Evidence) > 8 || len(recommendation.Warnings) > 12 {
			return false
		}
	}
	for _, attempt := range value.Timing.ModelAttempts {
		if !validWorkerAttempt(attempt) {
			return false
		}
	}
	return true
}
func validWorkerTerminal(value workerTerminalRecord, request RunRequest, emitted int, remaining []RevisionStage) bool {
	if value.RecordType != "terminal" || value.JobID != request.Run.JobID || value.RunID != request.Run.ID || value.RevisionsEmitted != emitted || value.RevisionsEmitted < 0 || value.RevisionsEmitted > 2 {
		return false
	}
	if value.Timing.ToolCalls < 0 || len(value.Timing.ModelAttempts) > 24 {
		return false
	}
	for _, timing := range []*int64{value.Timing.ProcessStartupToRequestAcceptedMs, value.Timing.RequestAcceptedToDirectFirstMs, value.Timing.RequestAcceptedToFinalMs} {
		if timing != nil && *timing < 0 {
			return false
		}
	}
	for _, attempt := range value.Timing.ModelAttempts {
		if !validWorkerAttempt(attempt) {
			return false
		}
	}
	for _, d := range value.Degradations {
		if (d.Stage != "direct_judge" && d.Stage != "deep_agent" && d.Stage != "protocol") || !knownWorkerDegradation(d.Code) {
			return false
		}
	}
	switch value.Outcome {
	case "completed":
		return len(value.Degradations) == 0 && len(remaining) == 0
	case "degraded":
		return len(value.Degradations) > 0
	case "unavailable":
		return value.RevisionsEmitted == 0 && len(value.Degradations) > 0
	case "cancelled":
		return len(value.Degradations) > 0
	default:
		return false
	}
}
func knownWorkerDegradation(code string) bool {
	switch code {
	case "MODEL_DISABLED", "MODEL_UNAVAILABLE", "MODEL_CONFIG_ERROR", "MODEL_FAILURE", "STRUCTURED_OUTPUT_ERROR", "VALIDATION_FAILED", "BUDGET_EXCEEDED", "CANCELLED", "INVALID_REQUEST":
		return true
	}
	return false
}
func (t workerTerminalRecord) telemetry() TerminalTelemetry {
	attempts := make([]TerminalModelAttempt, 0, len(t.Timing.ModelAttempts))
	for _, attempt := range t.Timing.ModelAttempts {
		attempts = append(attempts, TerminalModelAttempt{Stage: attempt.Stage, Attempt: attempt.Attempt, DurationMs: attempt.DurationMs, Repair: attempt.Repair, Status: attempt.Status})
	}
	return TerminalTelemetry{ProcessStartupToRequestAcceptedMs: t.Timing.ProcessStartupToRequestAcceptedMs, RequestAcceptedToDirectFirstMs: t.Timing.RequestAcceptedToDirectFirstMs, RequestAcceptedToFinalMs: t.Timing.RequestAcceptedToFinalMs, ToolCalls: t.Timing.ToolCalls, ModelAttempts: attempts}
}
func (t workerTerminalRecord) runnerError() error {
	switch t.Outcome {
	case "completed":
		return nil
	case "cancelled":
		return context.Canceled
	case "unavailable", "degraded":
		for _, d := range t.Degradations {
			return TypedDegradation(workerDegradationToPublic(d.Code))
		}
	}
	return Validation(errors.New("research worker terminal invalid"))
}
func workerDegradationToPublic(code string) Degradation {
	switch code {
	case "MODEL_DISABLED", "MODEL_CONFIG_ERROR":
		return PublicDegradation(DegradationModelDisabled)
	case "MODEL_UNAVAILABLE", "MODEL_FAILURE":
		return PublicDegradation(DegradationModelUnavailable)
	case "BUDGET_EXCEEDED":
		return PublicDegradation(DegradationBudgetExhausted)
	case "STRUCTURED_OUTPUT_ERROR", "VALIDATION_FAILED", "INVALID_REQUEST":
		return PublicDegradation(DegradationValidationRejected)
	default:
		return PublicDegradation(DegradationRunnerTerminal)
	}
}

func workerRevisionPayload(record workerRevisionRecord, baseline RevisionPayload, elapsed int64, direct bool) (RevisionPayload, error) {
	recommendations := make([]Recommendation, 0, len(record.Result.Recommendations))
	for _, value := range record.Result.Recommendations {
		recommendations = append(recommendations, Recommendation{CandidateID: value.CandidateID, Rank: value.Rank, Confidence: value.Confidence, Rationale: value.Rationale, Classification: *value.Classification, Warnings: append([]string(nil), value.Warnings...), EvidenceRefs: []string{value.CandidateID}})
	}
	provenance := Provenance{Source: "candidate_assembly_worker", WorkerSchemaVersion: workerRevisionSchema}
	if direct {
		provenance.SpawnToFirstRevisionMs = elapsed
	} else {
		provenance.SpawnToFinalMs = elapsed
	}
	payload := RevisionPayload{SchemaVersion: RevisionPayloadSchemaVersion, Stage: record.Stage, Query: baseline.Query, Candidates: baseline.Candidates, Recommendations: recommendations, Provenance: provenance, Timing: SafeTiming{WorkerInferenceMs: record.Timing.LatencyMs}}
	if err := ValidateRevisionPayload(payload, true); err != nil {
		return RevisionPayload{}, err
	}
	return payload, nil
}
func baselineFromSnapshot(snapshot Snapshot) (RevisionPayload, error) {
	for _, revision := range snapshot.Revisions {
		payload, err := ParseRevisionPayload(revision.Payload)
		if err == nil && payload.Stage == StageBaseline {
			return payload, nil
		}
	}
	return RevisionPayload{}, errors.New("missing baseline")
}
func workerRequest(request RunRequest, baseline RevisionPayload, budgets WorkerBudgetConfig, stages WorkerStageConfig) (map[string]any, error) {
	candidates, err := WorkerProjection(baseline.Candidates)
	if err != nil {
		return nil, err
	}
	if len(candidates) == 0 || len(candidates) > budgets.MaxCandidatesIn {
		return nil, ErrInvalidRevision
	}
	return map[string]any{"schemaVersion": workerRequestSchema, "jobId": request.Run.JobID, "runId": request.Run.ID, "query": baseline.Query, "limit": min(min(10, len(baseline.Recommendations)), budgets.MaxRecommendations), "candidates": candidates, "catalog": []any{}, "metadata": map[string]any{}, "budgets": map[string]any{"maxToolCalls": budgets.MaxToolCalls, "maxModelCalls": budgets.MaxModelCalls, "recursionLimit": budgets.RecursionLimit, "maxCandidatesIn": budgets.MaxCandidatesIn, "maxRecommendations": budgets.MaxRecommendations, "wallClockMs": budgets.WallClockMs, "maxRequestBytes": budgets.MaxRequestBytes, "maxResponseBytes": budgets.MaxResponseBytes, "maxTokensPerCompletion": budgets.MaxTokensPerCompletion}, "stages": map[string]bool{"directJudge": stages.DirectJudge, "deepAgent": stages.DeepAgent}}, nil
}
func childEnvironment(input map[string]string) []string {
	allowed := map[string]bool{"PATH": true, "HOME": true, "LANG": true, "LC_ALL": true, "TZ": true, "PYTHONPATH": true, "VIRTUAL_ENV": true, "OMP_CANDIDATE_WORKER_LIVE": true, "AGENT_SEARCH_BASE_URL": true, "AGENT_SEARCH_API_KEY": true, "AGENT_SEARCH_MODEL": true, "AGENT_SEARCH_TIMEOUT_S": true, "AGENT_SEARCH_RUN_TIMEOUT_S": true, "AGENT_SEARCH_TEST_MODE": true, "OMP_SOURCEQUALITY_HELPER": true}
	output := make([]string, 0, len(input))
	for key, value := range input {
		if allowed[key] {
			output = append(output, key+"="+value)
		}
	}
	return output
}

type DisabledRunner struct{}

func (DisabledRunner) Run(ctx context.Context, _ RunRequest, sink EnhancementSink) error {
	return TypedDegradation(PublicDegradation(DegradationModelDisabled))
}
