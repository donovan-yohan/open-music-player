package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/storage"
)

type fakeAnalyzerStore struct {
	audio []byte
}

func (s fakeAnalyzerStore) GetObject(context.Context, string) (io.ReadCloser, *storage.ObjectInfo, error) {
	return io.NopCloser(bytes.NewReader(s.audio)), nil, nil
}

func TestAnalyzeHTTPReturnsWaveformAndMIRJSON(t *testing.T) {
	bpm := 120.0
	server := &analyzerServer{
		storage:    fakeAnalyzerStore{audio: testWAV(8000, 2)},
		sampleRate: 8000,
		waveformHz: 80,
		mirSlots:   make(chan struct{}, 1),
		analyzeMIR: func(context.Context, string, string, string) (mirAnalysis, error) {
			keyIndex := 9
			return mirAnalysis{
				BPM:                &bpm,
				TempoConfidence:    0.9,
				BeatsMS:            []int{0, 500, 1000, 1500},
				DownbeatsMS:        []int{0},
				DownbeatConfidence: 0.7,
				KeyIndex:           &keyIndex,
				Mode:               "minor",
				KeyConfidence:      0.8,
			}, nil
		},
	}
	body := bytes.NewBufferString(`{"schema_version":1,"track_id":42,"storage_key":"tracks/test.wav","duration_ms":2000}`)
	request := httptest.NewRequest(http.MethodPost, "/analyze", body)
	response := httptest.NewRecorder()

	server.handleAnalyze(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	summary := payload["summary"].(map[string]any)
	if _, ok := summary["waveform"]; !ok {
		t.Fatalf("summary missing waveform: %#v", summary)
	}
	if got := summary["bpm"].(map[string]any)["value"]; got != 120.0 {
		t.Fatalf("BPM = %#v, want 120", got)
	}
}

func TestAnalyzeHTTPReturnsRetryableStatusForMIRFailure(t *testing.T) {
	server := &analyzerServer{
		storage:    fakeAnalyzerStore{audio: testWAV(8000, 2)},
		sampleRate: 8000,
		waveformHz: 80,
		mirSlots:   make(chan struct{}, 1),
		analyzeMIR: func(context.Context, string, string, string) (mirAnalysis, error) {
			return mirAnalysis{}, errors.New("model process exited")
		},
	}
	body := bytes.NewBufferString(`{"schema_version":1,"track_id":42,"storage_key":"tracks/test.wav","duration_ms":2000}`)
	request := httptest.NewRequest(http.MethodPost, "/analyze", body)
	response := httptest.NewRecorder()

	server.handleAnalyze(response, request)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d: %s", response.Code, http.StatusInternalServerError, response.Body.String())
	}
}

func TestValidateMIRRuntimeAcceptsReadyHelper(t *testing.T) {
	tempDir := t.TempDir()
	helperPath := filepath.Join(tempDir, "helper.py")
	modelPath := filepath.Join(tempDir, "model.ckpt")
	if err := os.WriteFile(helperPath, []byte("print('{\"status\":\"ready\"}')\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(modelPath, []byte("model"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := validateMIRRuntime(ctx, helperPath, modelPath); err != nil {
		t.Fatalf("validateMIRRuntime() error = %v", err)
	}
}

func TestValidateMIRRuntimeRejectsMissingModel(t *testing.T) {
	tempDir := t.TempDir()
	helperPath := filepath.Join(tempDir, "helper.py")
	if err := os.WriteFile(helperPath, []byte("print('{\"status\":\"ready\"}')\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := validateMIRRuntime(context.Background(), helperPath, filepath.Join(tempDir, "missing.ckpt"))
	if err == nil || !strings.Contains(err.Error(), "beat model unavailable") {
		t.Fatalf("validateMIRRuntime() error = %v, want missing model", err)
	}
}

func TestApplyMIRUsesTrackedBeatGridAndCamelotKey(t *testing.T) {
	const sampleRate = 8000
	samples := sineSamples(sampleRate, 440, 2)
	analysis := analyzeSamples(samples, sampleRate, 2000, 80)
	keyIndex := 9
	err := analysis.applyMIR(mirAnalysis{
		BPM:                float64Ptr(128.04),
		TempoConfidence:    0.91,
		BeatsMS:            []int{0, 469, 938, 1406, 1875, 1875, 2400},
		DownbeatsMS:        []int{0, 1875},
		DownbeatConfidence: 0.88,
		KeyIndex:           &keyIndex,
		Mode:               "minor",
		KeyConfidence:      0.73,
	})
	if err != nil {
		t.Fatalf("applyMIR() error = %v", err)
	}

	if analysis.keyName != "A minor" {
		t.Fatalf("keyName = %q, want A minor", analysis.keyName)
	}
	if analysis.camelot != "8A" {
		t.Fatalf("camelot = %q, want 8A", analysis.camelot)
	}
	if got := analysis.beats; len(got) != 5 || got[len(got)-1] != 1875 {
		t.Fatalf("beats = %v, want sorted, unique in-range markers", got)
	}
	if got := analysis.downbeats; len(got) != 2 || got[1] != 1875 {
		t.Fatalf("downbeats = %v, want model positions", got)
	}
}

func TestAnalyzeSamplesUsesDecodedDurationAsTimingAuthority(t *testing.T) {
	const sampleRate = 8000
	analysis := analyzeSamples(
		sineSamples(sampleRate, 440, 2),
		sampleRate,
		3000,
		80,
	)

	if analysis.durationMs != 2000 || analysis.decodedMs != 2000 {
		t.Fatalf("duration/decoded = %d/%d, want 2000/2000", analysis.durationMs, analysis.decodedMs)
	}
	if analysis.declaredMs != 3000 {
		t.Fatalf("declared = %d, want 3000", analysis.declaredMs)
	}
	if analysis.sampleCount != 160 {
		t.Fatalf("sampleCount = %d, want decoded-duration count 160", analysis.sampleCount)
	}
}

func TestApplyMIRKeepsReliableTempoWithoutDownbeats(t *testing.T) {
	analysis := waveformAnalysis{durationMs: 2000}
	keyIndex := 0
	err := analysis.applyMIR(mirAnalysis{
		BPM:      float64Ptr(120),
		BeatsMS:  []int{0, 500, 1000, 1500},
		KeyIndex: &keyIndex,
		Mode:     "major",
	})
	if err != nil {
		t.Fatalf("applyMIR() error = %v", err)
	}
	if analysis.bpm != 120 || len(analysis.downbeats) != 0 {
		t.Fatalf("analysis = %#v, want BPM without synthetic downbeats", analysis)
	}
}

func TestBuildResponseIncludesDJContractArtifacts(t *testing.T) {
	const sampleRate = 8000
	samples := sineSamples(sampleRate, 440, 2)
	analysis := analyzeSamples(samples, sampleRate, 2000, 80)
	keyIndex := 9
	if err := analysis.applyMIR(mirAnalysis{
		BPM:                float64Ptr(128),
		TempoConfidence:    0.91,
		BeatsMS:            []int{0, 469, 938, 1406, 1875},
		DownbeatsMS:        []int{0, 1875},
		DownbeatConfidence: 0.88,
		KeyIndex:           &keyIndex,
		Mode:               "minor",
		KeyConfidence:      0.73,
	}); err != nil {
		t.Fatalf("applyMIR() error = %v", err)
	}

	response := buildResponse(analyzeRequest{
		StorageKey: "tracks/test/a.wav",
		DurationMs: 2000,
	}, analysis)

	summary := response["summary"].(map[string]any)
	for _, key := range []string{
		"bpm",
		"beat_grid",
		"downbeats",
		"key",
		"camelot",
		"loudness",
		"true_peak",
		"waveform",
		"transients",
		"silence",
		"intro",
		"outro",
		"trim",
		"sections",
		"cue_candidates",
		"duration_sanity",
	} {
		if _, ok := summary[key]; !ok {
			t.Fatalf("summary missing %q: %#v", key, summary)
		}
	}

	artifacts := response["artifacts"].(map[string]any)
	for _, key := range []string{
		"source",
		"waveforms",
		"spectral_bands",
		"beat_grid",
		"markers",
	} {
		if _, ok := artifacts[key]; !ok {
			t.Fatalf("artifacts missing %q: %#v", key, artifacts)
		}
	}

	waveform := artifacts["waveforms"].(map[string]any)
	if _, ok := waveform["overview"]; !ok {
		t.Fatalf("waveforms missing overview: %#v", waveform)
	}
	if _, ok := waveform["detail"]; !ok {
		t.Fatalf("waveforms missing detail: %#v", waveform)
	}

	provenance := response["provenance"].(map[string]any)
	models := provenance["model_versions"].(map[string]any)
	if models["key"] != keyModelVersion {
		t.Fatalf("key model version = %#v", models["key"])
	}
	if models["tempo"] != tempoModelVersion {
		t.Fatalf("tempo model version = %#v", models["tempo"])
	}
}

func TestBuildResponseKeepsWaveformWhenMIRMetadataIsUnavailable(t *testing.T) {
	const sampleRate = 8000
	analysis := analyzeSamples(sineSamples(sampleRate, 440, 2), sampleRate, 2000, 80)
	if err := analysis.applyMIR(mirAnalysis{}); err != nil {
		t.Fatalf("applyMIR() error = %v", err)
	}

	response := buildResponse(analyzeRequest{DurationMs: 2000}, analysis)
	summary := response["summary"].(map[string]any)
	for _, key := range []string{"bpm", "beat_grid", "downbeats", "key", "camelot"} {
		if _, ok := summary[key]; ok {
			t.Fatalf("summary unexpectedly contains %q: %#v", key, summary[key])
		}
	}
	if _, ok := summary["waveform"]; !ok {
		t.Fatalf("summary missing waveform: %#v", summary)
	}
}

func sineSamples(sampleRate int, frequency float64, seconds int) []float64 {
	total := sampleRate * seconds
	samples := make([]float64, total)
	for i := range samples {
		phase := 2 * math.Pi * frequency * float64(i) / float64(sampleRate)
		samples[i] = math.Sin(phase) * 0.65
	}
	return samples
}

func testWAV(sampleRate, seconds int) []byte {
	sampleCount := sampleRate * seconds
	dataSize := sampleCount * 2
	buffer := bytes.NewBuffer(make([]byte, 0, 44+dataSize))
	buffer.WriteString("RIFF")
	_ = binary.Write(buffer, binary.LittleEndian, uint32(36+dataSize))
	buffer.WriteString("WAVEfmt ")
	_ = binary.Write(buffer, binary.LittleEndian, uint32(16))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(1))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(1))
	_ = binary.Write(buffer, binary.LittleEndian, uint32(sampleRate))
	_ = binary.Write(buffer, binary.LittleEndian, uint32(sampleRate*2))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(2))
	_ = binary.Write(buffer, binary.LittleEndian, uint16(16))
	buffer.WriteString("data")
	_ = binary.Write(buffer, binary.LittleEndian, uint32(dataSize))
	for index := range sampleCount {
		sample := int16(math.Sin(2*math.Pi*440*float64(index)/float64(sampleRate)) * 12000)
		_ = binary.Write(buffer, binary.LittleEndian, sample)
	}
	return buffer.Bytes()
}

func float64Ptr(value float64) *float64 {
	return &value
}
