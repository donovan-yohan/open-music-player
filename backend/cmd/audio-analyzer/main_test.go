package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
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
	pcmSamples := 0
	server := &analyzerServer{
		storage:    fakeAnalyzerStore{audio: testWAV(8000, 2)},
		sampleRate: 8000,
		waveformHz: 80,
		spectral:   defaultSpectralConfig(),
		mirSlots:   make(chan struct{}, 1),
		analyzeMIR: func(_ context.Context, _, _, _ string, frameCount, decodedSamples int, _ spectralConfig) (mirAnalysis, error) {
			pcmSamples = decodedSamples
			keyIndex := 9
			result := testSpectralMIR(frameCount)
			result.BPM = &bpm
			result.TempoConfidence = 0.9
			result.BeatsMS = []int{0, 500, 1000, 1500}
			result.DownbeatsMS = []int{0}
			result.DownbeatConfidence = 0.7
			result.KeyIndex = &keyIndex
			result.Mode = "minor"
			result.KeyConfidence = 0.8
			return result, nil
		},
	}
	body := bytes.NewBufferString(`{"schema_version":1,"track_id":42,"storage_key":"tracks/test.wav","duration_ms":2000}`)
	request := httptest.NewRequest(http.MethodPost, "/analyze", body)
	response := httptest.NewRecorder()

	server.handleAnalyze(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if pcmSamples != 16_000 {
		t.Fatalf("MIR PCM samples = %d, want exact decoded count 16000", pcmSamples)
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

func TestAnalyzeHTTPKeepsBasicAnalysisForTinyAudio(t *testing.T) {
	const sampleRate = 8000
	testCases := []struct {
		name        string
		sampleCount int
		durationMs  int
	}{
		{name: "one frame", sampleCount: 1, durationMs: 1},
		{name: "eight milliseconds", sampleCount: 64, durationMs: 8},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			mirCalls := 0
			server := &analyzerServer{
				storage:    fakeAnalyzerStore{audio: testWAVSamples(sampleRate, testCase.sampleCount)},
				sampleRate: sampleRate,
				waveformHz: 80,
				spectral:   defaultSpectralConfig(),
				mirSlots:   make(chan struct{}, 1),
				analyzeMIR: func(_ context.Context, _, _, _ string, frameCount, _ int, _ spectralConfig) (mirAnalysis, error) {
					mirCalls++
					return testSpectralMIR(frameCount), nil
				},
			}
			bodyJSON, err := json.Marshal(map[string]any{
				"schema_version": 1,
				"track_id":       46,
				"storage_key":    "smoke/tiny.wav",
				"duration_ms":    testCase.durationMs,
			})
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/analyze", bytes.NewReader(bodyJSON))
			response := httptest.NewRecorder()

			server.handleAnalyze(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			if mirCalls != 1 {
				t.Fatalf("MIR calls = %d, want 1", mirCalls)
			}
			var payload map[string]any
			if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
				t.Fatal(err)
			}
			summary := payload["summary"].(map[string]any)
			for _, key := range []string{"waveform", "loudness", "true_peak", "duration_sanity"} {
				if _, ok := summary[key]; !ok {
					t.Fatalf("summary missing %q: %#v", key, summary)
				}
			}
			for _, key := range []string{"bpm", "beat_grid", "downbeats", "key", "camelot"} {
				if _, ok := summary[key]; ok {
					t.Fatalf("summary unexpectedly contains %q: %#v", key, summary[key])
				}
			}
		})
	}
}

func TestAnalyzeHTTPReturnsRetryableStatusForMIRFailure(t *testing.T) {
	server := &analyzerServer{
		storage:    fakeAnalyzerStore{audio: testWAV(8000, 2)},
		sampleRate: 8000,
		waveformHz: 80,
		spectral:   defaultSpectralConfig(),
		mirSlots:   make(chan struct{}, 1),
		analyzeMIR: func(context.Context, string, string, string, int, int, spectralConfig) (mirAnalysis, error) {
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

func TestAnalyzeHTTPRejectsMismatchedExpectedAnalyzerIdentity(t *testing.T) {
	server := &analyzerServer{}
	body := bytes.NewBufferString(`{"schema_version":1,"track_id":42,"storage_key":"tracks/test.wav","expected_analyzer":"omp-mir-analyzer","expected_analyzer_version":"old-version"}`)
	request := httptest.NewRequest(http.MethodPost, "/analyze", body)
	response := httptest.NewRecorder()

	server.handleAnalyze(response, request)

	if response.Code != http.StatusConflict {
		t.Fatalf("status = %d, want %d: %s", response.Code, http.StatusConflict, response.Body.String())
	}
}

func TestValidateMIRRuntimeAcceptsReadyHelper(t *testing.T) {
	tempDir := t.TempDir()
	helperPath := filepath.Join(tempDir, "helper.py")
	modelPath := filepath.Join(tempDir, "model.ckpt")
	ready := fmt.Sprintf(
		`{"status":"ready","analyzer":%q,"analyzer_version":%q,"tempo_model":%q,"key_model":%q,"spectral_provenance":%q,"spectral_channel_set":%q}`,
		analyzerName,
		analyzerVersion,
		tempoModelVersion,
		keyModelVersion,
		spectralModelVersion,
		spectralChannelSet,
	)
	if err := os.WriteFile(helperPath, []byte("print("+fmt.Sprintf("%q", ready)+")\n"), 0o600); err != nil {
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
	if err := os.WriteFile(helperPath, []byte("print('{}')\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := validateMIRRuntime(context.Background(), helperPath, filepath.Join(tempDir, "missing.ckpt"))
	if err == nil || !strings.Contains(err.Error(), "beat model unavailable") {
		t.Fatalf("validateMIRRuntime() error = %v, want missing model", err)
	}
}

func TestValidateMIRRuntimeRejectsMismatchedModelIdentity(t *testing.T) {
	tempDir := t.TempDir()
	helperPath := filepath.Join(tempDir, "helper.py")
	modelPath := filepath.Join(tempDir, "model.ckpt")
	output := fmt.Sprintf(
		`{"status":"ready","analyzer":%q,"analyzer_version":%q,"tempo_model":"wrong-tempo","key_model":%q,"spectral_provenance":%q,"spectral_channel_set":%q}`,
		analyzerName,
		analyzerVersion,
		keyModelVersion,
		spectralModelVersion,
		spectralChannelSet,
	)
	if err := os.WriteFile(helperPath, []byte("print("+fmt.Sprintf("%q", output)+")\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(modelPath, []byte("model"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := validateMIRRuntime(context.Background(), helperPath, modelPath)
	if err == nil || !strings.Contains(err.Error(), "model identity") {
		t.Fatalf("validateMIRRuntime() error = %v, want model identity mismatch", err)
	}
}

func TestValidateMIRRuntimeRejectsMismatchedSpectralIdentity(t *testing.T) {
	for _, test := range []struct {
		name       string
		provenance string
		channelSet string
	}{
		{name: "provenance", provenance: "wrong-provenance", channelSet: spectralChannelSet},
		{name: "channel_set", provenance: spectralModelVersion, channelSet: "wrong-channel-set"},
	} {
		t.Run(test.name, func(t *testing.T) {
			tempDir := t.TempDir()
			helperPath := filepath.Join(tempDir, "helper.py")
			modelPath := filepath.Join(tempDir, "model.ckpt")
			output := fmt.Sprintf(
				`{"status":"ready","analyzer":%q,"analyzer_version":%q,"tempo_model":%q,"key_model":%q,"spectral_provenance":%q,"spectral_channel_set":%q}`,
				analyzerName,
				analyzerVersion,
				tempoModelVersion,
				keyModelVersion,
				test.provenance,
				test.channelSet,
			)
			if err := os.WriteFile(helperPath, []byte("print("+fmt.Sprintf("%q", output)+")\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(modelPath, []byte("model"), 0o600); err != nil {
				t.Fatal(err)
			}

			err := validateMIRRuntime(context.Background(), helperPath, modelPath)
			if err == nil || !strings.Contains(err.Error(), "spectral identity") {
				t.Fatalf("validateMIRRuntime() error = %v, want spectral identity mismatch", err)
			}
		})
	}
}

func TestApplyMIRUsesTrackedBeatGridAndCamelotKey(t *testing.T) {
	const sampleRate = 8000
	samples := sineSamples(sampleRate, 440, 2)
	analysis := analyzeSamples(samples, sampleRate, 2000, 80)
	keyIndex := 9
	mir := testSpectralMIR(analysis.sampleCount)
	mir.BPM = float64Ptr(128.04)
	mir.TempoConfidence = 0.91
	mir.BeatsMS = []int{0, 469, 938, 1406, 1875, 1875, 2400}
	mir.DownbeatsMS = []int{0, 1875}
	mir.DownbeatConfidence = 0.88
	mir.KeyIndex = &keyIndex
	mir.Mode = "minor"
	mir.KeyConfidence = 0.73
	err := analysis.applyMIR(mir)
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
	mir := testSpectralMIR(0)
	mir.BPM = float64Ptr(120)
	mir.BeatsMS = []int{0, 500, 1000, 1500}
	mir.KeyIndex = &keyIndex
	mir.Mode = "major"
	err := analysis.applyMIR(mir)
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
	mir := testSpectralMIR(analysis.sampleCount)
	mir.BPM = float64Ptr(128)
	mir.TempoConfidence = 0.91
	mir.BeatsMS = []int{0, 469, 938, 1406, 1875}
	mir.DownbeatsMS = []int{0, 1875}
	mir.DownbeatConfidence = 0.88
	mir.KeyIndex = &keyIndex
	mir.Mode = "minor"
	mir.KeyConfidence = 0.73
	if err := analysis.applyMIR(mir); err != nil {
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
		"meter",
		"downbeat_phase",
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
	meter := summary["meter"].(map[string]any)
	phase := summary["downbeat_phase"].(map[string]any)
	if meter["beats_per_bar"] != nil || meter["confidence"] != nil {
		t.Fatalf("uncalibrated meter was fabricated: %#v", meter)
	}
	if phase["index"] != nil || phase["confidence"] != nil {
		t.Fatalf("uncalibrated phase was fabricated: %#v", phase)
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
	summaryWaveform := summary["waveform"].(map[string]any)
	if _, ok := summaryWaveform["peaks"]; ok {
		t.Fatal("summary double-ships detail peaks")
	}
	if _, ok := summaryWaveform["rms"]; ok {
		t.Fatal("summary double-ships detail RMS")
	}
	legacy := summaryWaveform["spectral_bands"].(map[string]any)
	if _, ok := legacy["low"].(map[string]any)["values"]; ok {
		t.Fatal("summary double-ships legacy spectral detail")
	}
	channels := summaryWaveform["channels"].(map[string]any)
	if channels["channel_set"] != spectralChannelSet || channels["audio_ref"] != nil {
		t.Fatalf("channels identity/audio_ref = %#v", channels)
	}
	values := channels["values"].(map[string]any)
	var sharedScalar any
	for _, name := range []string{"low", "mid", "high"} {
		descriptor := values[name].(map[string]any)
		if _, ok := descriptor["values"]; ok {
			t.Fatalf("%s descriptor contains detail array: %#v", name, descriptor)
		}
		normalization := descriptor["normalization"].(map[string]any)
		if normalization["kind"] != "shared_peak" {
			t.Fatalf("%s normalization = %#v", name, normalization)
		}
		if sharedScalar == nil {
			sharedScalar = normalization["scalar"]
		} else if normalization["scalar"] != sharedScalar {
			t.Fatalf("%s scalar = %#v, want shared %#v", name, normalization["scalar"], sharedScalar)
		}
		if descriptor["provenance"] != spectralModelVersion {
			t.Fatalf("%s provenance = %#v", name, descriptor["provenance"])
		}
	}
	channelArtifacts := artifacts["channels"].(map[string]any)
	if channelArtifacts["channel_set"] != spectralChannelSet {
		t.Fatalf("artifact channel set = %#v", channelArtifacts["channel_set"])
	}
	for _, tier := range []string{"overview", "detail"} {
		tierValues := channelArtifacts[tier].(map[string]any)
		for _, name := range []string{"low", "mid", "high"} {
			if len(tierValues[name].([]float64)) == 0 {
				t.Fatalf("artifact channels.%s.%s is empty", tier, name)
			}
		}
	}
	for _, tier := range []string{"overview", "detail"} {
		tierValues := waveform[tier].(map[string]any)
		minima := tierValues["minima"].([]float64)
		maxima := tierValues["maxima"].([]float64)
		if len(minima) == 0 || len(maxima) != len(minima) {
			t.Fatalf("%s signed extrema lengths = %d/%d", tier, len(minima), len(maxima))
		}
		if minima[0] >= 0 || maxima[0] <= 0 {
			t.Fatalf("%s extrema lost sign: min=%v max=%v", tier, minima[0], maxima[0])
		}
	}

	provenance := response["provenance"].(map[string]any)
	models := provenance["model_versions"].(map[string]any)
	if models["key"] != keyModelVersion {
		t.Fatalf("key model version = %#v", models["key"])
	}
	if models["tempo"] != tempoModelVersion {
		t.Fatalf("tempo model version = %#v", models["tempo"])
	}
	if models["waveform"] != "spectral-v2" || models["spectral"] != spectralModelVersion {
		t.Fatalf("spectral provenance versions = %#v", models)
	}
}

func TestApplyMIRRejectsSpectralGridMismatch(t *testing.T) {
	analysis := analyzeSamples(sineSamples(8000, 440, 1), 8000, 1000, 80)
	mir := testSpectralMIR(analysis.sampleCount)
	mir.SpectralBands["high"] = mir.SpectralBands["high"][:analysis.sampleCount-1]

	err := analysis.applyMIR(mir)

	if err == nil || !strings.Contains(err.Error(), "high") || !strings.Contains(err.Error(), "want 80") {
		t.Fatalf("applyMIR() error = %v, want exact shared-grid rejection", err)
	}
}

func TestSignedOverviewReducersPreserveOneSidedExtrema(t *testing.T) {
	minima := downsampleMin([]float64{0.2, 0.4, 0.1, 0.3}, 2)
	maxima := downsampleSignedMax([]float64{-0.4, -0.2, -0.3, -0.1}, 2)

	if !sameFloats(minima, []float64{0.2, 0.1}) {
		t.Fatalf("positive minima = %v, want true minima", minima)
	}
	if !sameFloats(maxima, []float64{-0.2, -0.1}) {
		t.Fatalf("negative maxima = %v, want true maxima", maxima)
	}
}

func TestBuildResponseKeepsWaveformWhenMIRMetadataIsUnavailable(t *testing.T) {
	const sampleRate = 8000
	analysis := analyzeSamples(sineSamples(sampleRate, 440, 2), sampleRate, 2000, 80)
	if err := analysis.applyMIR(testSpectralMIR(analysis.sampleCount)); err != nil {
		t.Fatalf("applyMIR() error = %v", err)
	}

	response := buildResponse(analyzeRequest{DurationMs: 2000}, analysis)
	summary := response["summary"].(map[string]any)
	for _, key := range []string{"bpm", "beat_grid", "downbeats", "key", "camelot"} {
		if _, ok := summary[key]; ok {
			t.Fatalf("summary unexpectedly contains %q: %#v", key, summary[key])
		}
	}
	if summary["meter"].(map[string]any)["beats_per_bar"] != nil ||
		summary["downbeat_phase"].(map[string]any)["index"] != nil {
		t.Fatalf("missing MIR metadata fabricated meter/phase: %#v", summary)
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
	return testWAVSamples(sampleRate, sampleRate*seconds)
}

func testWAVSamples(sampleRate, sampleCount int) []byte {
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

func testSpectralMIR(frameCount int) mirAnalysis {
	channel := make([]float64, frameCount)
	for index := range channel {
		channel[index] = float64(index+1) / float64(max(1, frameCount))
	}
	return mirAnalysis{
		SpectralBands: map[string][]float64{
			"low":  append([]float64(nil), channel...),
			"mid":  append([]float64(nil), channel...),
			"high": append([]float64(nil), channel...),
		},
		SpectralNormalization: 2.8,
		SpectralProvenance:    spectralModelVersion,
		SpectralChannelSet:    spectralChannelSet,
	}
}

func sameFloats(got, want []float64) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
