package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/storage"
)

const (
	defaultAddr         = ":18190"
	defaultSampleRate   = 22050
	defaultWaveformHz   = 80
	defaultMIRHelper    = "/app/audio_mir.py"
	defaultBeatModel    = "/app/models/beat_this-final0.ckpt"
	analyzerName        = "omp-mir-analyzer"
	analyzerVersion     = "2026-07-11-3"
	tempoModelVersion   = "beat-this-final0-v1.1.0-audio2frames-postprocessor-dynamic-meter-posterior-v3"
	keyModelVersion     = "librosa-0.11.0-cqt-krumhansl-v1"
	maxRequestBytes     = 1 << 20
	maxMIRResponseBytes = 2 << 20
	maxDecodedPCMBytes  = 96 << 20
	maxWaveformSamples  = 32768
	minWaveformSamples  = 64
)

type analyzeRequest struct {
	SchemaVersion           int    `json:"schema_version"`
	TrackID                 int64  `json:"track_id"`
	StorageKey              string `json:"storage_key"`
	SourceURL               string `json:"source_url"`
	SourceType              string `json:"source_type"`
	DurationMs              int    `json:"duration_ms"`
	Title                   string `json:"title"`
	Artist                  string `json:"artist"`
	ExpectedAnalyzer        string `json:"expected_analyzer"`
	ExpectedAnalyzerVersion string `json:"expected_analyzer_version"`
}

type analyzerServer struct {
	storage    analyzerObjectStore
	authToken  string
	sampleRate int
	waveformHz int
	mirHelper  string
	beatModel  string
	mirSlots   chan struct{}
	analyzeMIR func(context.Context, string, string, string) (mirAnalysis, error)
}

type analyzerObjectStore interface {
	GetObject(ctx context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error)
}

type waveformAnalysis struct {
	durationMs   int
	peaks        []float64
	rms          []float64
	low          []float64
	mid          []float64
	high         []float64
	transients   []int
	beats        []int
	downbeats    []int
	silence      []timeRange
	leadingMs    int
	trailingMs   int
	bpm          float64
	bpmConf      float64
	downbeatConf float64
	keyName      string
	camelot      string
	keyConf      float64
	energy       float64
	truePeakDb   float64
	loudnessDb   float64
	declaredMs   int
	decodedMs    int
	sampleRate   int
	sampleCount  int
}

type mirAnalysis struct {
	BPM                *float64 `json:"bpm"`
	TempoConfidence    float64  `json:"tempo_confidence"`
	BeatsMS            []int    `json:"beats_ms"`
	DownbeatsMS        []int    `json:"downbeats_ms"`
	DownbeatConfidence float64  `json:"downbeat_confidence"`
	KeyIndex           *int     `json:"key_index"`
	Mode               string   `json:"mode"`
	KeyConfidence      float64  `json:"key_confidence"`
}

type timeRange struct {
	StartMs int `json:"start_ms"`
	EndMs   int `json:"end_ms"`
}

func main() {
	ctx := context.Background()
	store, err := storage.New(&storage.Config{
		Endpoint:       env("MINIO_ENDPOINT", "localhost:9000"),
		PublicEndpoint: os.Getenv("MINIO_PUBLIC_ENDPOINT"),
		Region:         env("S3_REGION", "us-east-1"),
		AccessKey:      env("MINIO_ACCESS_KEY", "minioadmin"),
		SecretKey:      env("MINIO_SECRET_KEY", "minioadmin"),
		Bucket:         env("MINIO_BUCKET", "audio-files"),
		UseSSL:         envBool("MINIO_USE_SSL", false),
	})
	if err != nil {
		log.Fatalf("storage init failed: %v", err)
	}
	if err := store.Ping(ctx); err != nil {
		log.Fatalf("storage ping failed: %v", err)
	}

	concurrency := clampInt(envInt("ANALYZER_CONCURRENCY", 1), 1, 4)
	server := &analyzerServer{
		storage:    store,
		authToken:  strings.TrimSpace(os.Getenv("ANALYZER_AUTH_TOKEN")),
		sampleRate: envInt("ANALYZER_SAMPLE_RATE", defaultSampleRate),
		waveformHz: envInt("ANALYZER_WAVEFORM_HZ", defaultWaveformHz),
		mirHelper:  env("ANALYZER_MIR_HELPER", defaultMIRHelper),
		beatModel:  env("ANALYZER_BEAT_MODEL", defaultBeatModel),
		mirSlots:   make(chan struct{}, concurrency),
		analyzeMIR: runMIRAnalysis,
	}
	checkCtx, checkCancel := context.WithTimeout(ctx, 60*time.Second)
	defer checkCancel()
	if err := validateMIRRuntime(checkCtx, server.mirHelper, server.beatModel); err != nil {
		log.Fatalf("MIR runtime readiness check failed: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"status":           "healthy",
			"analyzer":         analyzerName,
			"analyzer_version": analyzerVersion,
			"tempo_model":      tempoModelVersion,
			"key_model":        keyModelVersion,
		})
	})
	mux.HandleFunc("/analyze", server.handleAnalyze)

	addr := env("ANALYZER_ADDR", defaultAddr)
	log.Printf("audio analyzer listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func (s *analyzerServer) handleAnalyze(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	if !s.authorized(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
		return
	}
	defer r.Body.Close()

	var req analyzeRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxRequestBytes)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid request JSON"})
		return
	}
	if strings.TrimSpace(req.StorageKey) == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "storage_key is required"})
		return
	}
	expectedAnalyzer := strings.TrimSpace(req.ExpectedAnalyzer)
	expectedVersion := strings.TrimSpace(req.ExpectedAnalyzerVersion)
	if (expectedAnalyzer == "") != (expectedVersion == "") {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "expected analyzer identity requires both name and version"})
		return
	}
	if expectedAnalyzer != "" && (expectedAnalyzer != analyzerName || expectedVersion != analyzerVersion) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "analyzer identity does not match requested version"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	select {
	case s.mirSlots <- struct{}{}:
		defer func() { <-s.mirSlots }()
	case <-ctx.Done():
		writeJSON(w, http.StatusRequestTimeout, map[string]any{"error": ctx.Err().Error()})
		return
	}

	tmpPath, cleanup, err := s.downloadObject(ctx, req.StorageKey)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error()})
		return
	}
	defer cleanup()

	samples, err := decodePCM(ctx, tmpPath, s.sampleRate)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error()})
		return
	}
	analysis := analyzeSamples(samples, s.sampleRate, req.DurationMs, s.waveformHz)
	analyzeMIR := s.analyzeMIR
	if analyzeMIR == nil {
		analyzeMIR = runMIRAnalysis
	}
	mir, err := analyzeMIR(ctx, s.mirHelper, s.beatModel, tmpPath)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if err := analysis.applyMIR(mir); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, buildResponse(req, analysis))
}

func (s *analyzerServer) authorized(r *http.Request) bool {
	if s.authToken == "" {
		return true
	}
	return strings.TrimSpace(r.Header.Get("Authorization")) == "Bearer "+s.authToken
}

func (s *analyzerServer) downloadObject(ctx context.Context, key string) (string, func(), error) {
	reader, _, err := s.storage.GetObject(ctx, key)
	if err != nil {
		return "", func() {}, err
	}
	defer reader.Close()

	tmp, err := os.CreateTemp("", "omp-analyzer-*")
	if err != nil {
		return "", func() {}, err
	}
	path := tmp.Name()
	cleanup := func() { _ = os.Remove(path) }
	if _, err := io.Copy(tmp, reader); err != nil {
		_ = tmp.Close()
		cleanup()
		return "", func() {}, err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return "", func() {}, err
	}
	return path, cleanup, nil
}

func runMIRAnalysis(ctx context.Context, helperPath, modelPath, audioPath string) (mirAnalysis, error) {
	if strings.TrimSpace(helperPath) == "" {
		return mirAnalysis{}, fmt.Errorf("MIR helper path is required")
	}
	if strings.TrimSpace(modelPath) == "" {
		return mirAnalysis{}, fmt.Errorf("beat model path is required")
	}
	cmd := exec.CommandContext(
		ctx,
		"python3",
		helperPath,
		"--model",
		modelPath,
		audioPath,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return mirAnalysis{}, fmt.Errorf("MIR analysis failed: %s", detail)
	}
	if len(output) > maxMIRResponseBytes {
		return mirAnalysis{}, fmt.Errorf("MIR response exceeds %d byte limit", maxMIRResponseBytes)
	}
	var result mirAnalysis
	if err := json.Unmarshal(output, &result); err != nil {
		return mirAnalysis{}, fmt.Errorf("parse MIR response: %w", err)
	}
	return result, nil
}

func validateMIRRuntime(ctx context.Context, helperPath, modelPath string) error {
	for label, path := range map[string]string{
		"MIR helper": helperPath,
		"beat model": modelPath,
	} {
		if strings.TrimSpace(path) == "" {
			return fmt.Errorf("%s path is required", label)
		}
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("%s unavailable at %s: %w", label, path, err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("%s at %s is not a regular file", label, path)
		}
	}

	cmd := exec.CommandContext(ctx, "python3", helperPath, "--check", "--model", modelPath)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return fmt.Errorf("MIR helper check failed: %s", detail)
	}
	var status struct {
		Status          string `json:"status"`
		Analyzer        string `json:"analyzer"`
		AnalyzerVersion string `json:"analyzer_version"`
		TempoModel      string `json:"tempo_model"`
		KeyModel        string `json:"key_model"`
	}
	if err := json.Unmarshal(output, &status); err != nil {
		return fmt.Errorf("parse MIR helper check: %w", err)
	}
	if status.Status != "ready" {
		return fmt.Errorf("MIR helper reported status %q", status.Status)
	}
	if status.Analyzer != analyzerName || status.AnalyzerVersion != analyzerVersion {
		return fmt.Errorf("MIR helper analyzer identity %q@%q does not match %q@%q", status.Analyzer, status.AnalyzerVersion, analyzerName, analyzerVersion)
	}
	if status.TempoModel != tempoModelVersion || status.KeyModel != keyModelVersion {
		return fmt.Errorf("MIR helper model identity tempo=%q key=%q does not match tempo=%q key=%q", status.TempoModel, status.KeyModel, tempoModelVersion, keyModelVersion)
	}
	return nil
}

func decodePCM(ctx context.Context, path string, sampleRate int) ([]float64, error) {
	if sampleRate <= 0 {
		sampleRate = defaultSampleRate
	}
	cmd := exec.CommandContext(
		ctx,
		"ffmpeg",
		"-hide_banner",
		"-nostdin",
		"-loglevel",
		"error",
		"-i",
		path,
		"-vn",
		"-ac",
		"1",
		"-ar",
		strconv.Itoa(sampleRate),
		"-f",
		"f32le",
		"pipe:1",
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(stdout, int64(maxDecodedPCMBytes)+1))
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, err
	}
	if len(data) > maxDecodedPCMBytes {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return nil, fmt.Errorf("decoded PCM too large: exceeded %d bytes", maxDecodedPCMBytes)
	}
	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("ffmpeg decode failed: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("ffmpeg decoded no audio samples")
	}
	samples := make([]float64, 0, len(data)/4)
	for i := 0; i+4 <= len(data); i += 4 {
		sample := math.Float32frombits(binary.LittleEndian.Uint32(data[i : i+4]))
		if math.IsNaN(float64(sample)) || math.IsInf(float64(sample), 0) {
			sample = 0
		}
		samples = append(samples, float64(sample))
	}
	if len(samples) == 0 {
		return nil, fmt.Errorf("decoded PCM had no complete float samples")
	}
	return samples, nil
}

func analyzeSamples(samples []float64, sampleRate int, declaredDurationMs int, waveformHz int) waveformAnalysis {
	if waveformHz <= 0 {
		waveformHz = defaultWaveformHz
	}
	decodedDurationMs := int(math.Round(float64(len(samples)) / float64(sampleRate) * 1000))
	durationMs := decodedDurationMs
	if durationMs <= 0 {
		durationMs = declaredDurationMs
	}
	target := clampInt(int(math.Ceil(float64(durationMs)*float64(waveformHz)/1000)), minWaveformSamples, maxWaveformSamples)
	if target > len(samples) {
		target = max(1, len(samples))
	}

	a := waveformAnalysis{
		durationMs:  max(1, durationMs),
		peaks:       make([]float64, target),
		rms:         make([]float64, target),
		low:         make([]float64, target),
		mid:         make([]float64, target),
		high:        make([]float64, target),
		declaredMs:  declaredDurationMs,
		decodedMs:   decodedDurationMs,
		sampleRate:  sampleRate,
		sampleCount: target,
	}

	var lowState, prev float64
	var maxPeak, maxRMS, maxLow, maxMid, maxHigh float64
	for i := 0; i < target; i++ {
		start := i * len(samples) / target
		end := (i + 1) * len(samples) / target
		if end <= start {
			end = min(len(samples), start+1)
		}
		var peak, sum, lowSum, midSum, highSum float64
		for _, sample := range samples[start:end] {
			abs := math.Abs(sample)
			peak = math.Max(peak, abs)
			sum += sample * sample
			lowState = lowState*0.992 + sample*0.008
			highComponent := sample - prev
			midComponent := sample - lowState - highComponent*0.35
			lowSum += lowState * lowState
			midSum += midComponent * midComponent
			highSum += highComponent * highComponent
			prev = sample
		}
		n := float64(max(1, end-start))
		a.peaks[i] = peak
		a.rms[i] = math.Sqrt(sum / n)
		a.low[i] = math.Sqrt(lowSum / n)
		a.mid[i] = math.Sqrt(midSum / n)
		a.high[i] = math.Sqrt(highSum / n)
		maxPeak = math.Max(maxPeak, a.peaks[i])
		maxRMS = math.Max(maxRMS, a.rms[i])
		maxLow = math.Max(maxLow, a.low[i])
		maxMid = math.Max(maxMid, a.mid[i])
		maxHigh = math.Max(maxHigh, a.high[i])
	}

	normalize(a.peaks, maxPeak)
	normalize(a.rms, maxRMS)
	normalize(a.low, maxLow)
	normalize(a.mid, maxMid)
	normalize(a.high, maxHigh)
	roundAll(a.peaks)
	roundAll(a.rms)
	roundAll(a.low)
	roundAll(a.mid)
	roundAll(a.high)

	a.truePeakDb = db(maxPeak)
	a.loudnessDb = db(mean(a.rms))
	a.energy = clamp(mean(a.rms)*1.15, 0, 1)
	a.transients = detectTransients(a.rms, a.peaks, a.durationMs)
	a.silence, a.leadingMs, a.trailingMs = detectSilence(a.rms, a.durationMs)
	return a
}

func (a *waveformAnalysis) applyMIR(mir mirAnalysis) error {
	a.beats = normalizeMarkers(mir.BeatsMS, a.durationMs)
	a.downbeats = normalizeMarkers(mir.DownbeatsMS, a.durationMs)
	if mir.BPM != nil {
		if !isFiniteInRange(*mir.BPM, 30, 300) {
			return fmt.Errorf("MIR analysis returned invalid BPM %.4f", *mir.BPM)
		}
		if len(a.beats) < 4 {
			return fmt.Errorf("MIR beat grid has fewer than four in-range beats")
		}
		a.bpm = *mir.BPM
		a.bpmConf = clamp(mir.TempoConfidence, 0, 1)
	}
	if len(a.downbeats) > 0 {
		a.downbeatConf = clamp(mir.DownbeatConfidence, 0, 1)
	}
	if mir.KeyIndex == nil {
		if strings.TrimSpace(mir.Mode) != "" {
			return fmt.Errorf("MIR analysis returned key mode without key index")
		}
		return nil
	}
	keyIndex := *mir.KeyIndex
	if keyIndex < 0 || keyIndex >= len(keyNames) {
		return fmt.Errorf("MIR analysis returned invalid key index %d", keyIndex)
	}
	mode := strings.ToLower(strings.TrimSpace(mir.Mode))
	if mode != "major" && mode != "minor" {
		return fmt.Errorf("MIR analysis returned invalid key mode %q", mir.Mode)
	}
	a.keyName = fmt.Sprintf("%s %s", keyNames[keyIndex], mode)
	a.camelot = camelotFor(keyIndex, mode)
	a.keyConf = clamp(mir.KeyConfidence, 0, 1)
	return nil
}

func normalizeMarkers(values []int, durationMs int) []int {
	markers := make([]int, 0, len(values))
	for _, value := range values {
		if value < 0 || value > durationMs {
			continue
		}
		markers = append(markers, value)
	}
	sort.Ints(markers)
	unique := markers[:0]
	for _, value := range markers {
		if len(unique) == 0 || unique[len(unique)-1] != value {
			unique = append(unique, value)
		}
	}
	return unique
}

func isFiniteInRange(value, minValue, maxValue float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && value >= minValue && value <= maxValue
}

func buildResponse(req analyzeRequest, a waveformAnalysis) map[string]any {
	overviewPeaks := downsample(a.peaks, 512)
	overviewRMS := downsample(a.rms, 512)
	overviewLow := downsample(a.low, 512)
	overviewMid := downsample(a.mid, 512)
	overviewHigh := downsample(a.high, 512)
	trimStartMs := a.leadingMs
	trimEndMs := max(trimStartMs, a.durationMs-a.trailingMs)
	introEndMs := defaultCueBoundaryMs(a, true)
	outroStartMs := defaultCueBoundaryMs(a, false)

	summary := map[string]any{
		"energy": map[string]any{
			"value":      round(a.energy, 4),
			"confidence": 0.72,
			"provenance": "rms",
		},
		"loudness": map[string]any{
			"integrated_lufs": round(a.loudnessDb, 2),
			"confidence":      0.42,
			"provenance":      "rms_proxy",
		},
		"true_peak": map[string]any{
			"dbtp":       round(a.truePeakDb, 2),
			"confidence": 0.72,
			"provenance": "pcm_peak",
		},
		"waveform": map[string]any{
			"sample_count": a.sampleCount,
			"peaks":        a.peaks,
			"rms":          a.rms,
			"resolutions": []map[string]any{
				{
					"name":              "overview",
					"samples_per_pixel": max(1, int(math.Ceil(float64(a.sampleCount)/float64(max(1, len(overviewPeaks)))))),
					"sample_count":      len(overviewPeaks),
					"artifact_ref":      "waveforms.overview",
				},
				{
					"name":              "detail",
					"samples_per_pixel": 1,
					"sample_count":      a.sampleCount,
					"artifact_ref":      "waveforms.detail",
				},
			},
			"spectral_bands": map[string]any{
				"low":  map[string]any{"sample_count": a.sampleCount, "values": a.low},
				"mid":  map[string]any{"sample_count": a.sampleCount, "values": a.mid},
				"high": map[string]any{"sample_count": a.sampleCount, "values": a.high},
			},
			"confidence": 0.74,
			"provenance": "ffmpeg_pcm",
		},
		"transients": map[string]any{
			"count":              len(a.transients),
			"density_per_second": round(float64(len(a.transients))/(float64(a.durationMs)/1000), 3),
			"strongest_ms":       a.transients,
			"confidence":         0.58,
			"provenance":         "rms_local_maxima",
		},
		"silence": map[string]any{
			"leading_ms":  a.leadingMs,
			"trailing_ms": a.trailingMs,
			"ranges":      a.silence,
			"confidence":  0.64,
			"provenance":  "rms_threshold",
		},
		"intro": map[string]any{
			"start_ms":   trimStartMs,
			"end_ms":     introEndMs,
			"confidence": 0.45,
			"provenance": "beat_grid_proxy",
		},
		"outro": map[string]any{
			"start_ms":   outroStartMs,
			"end_ms":     trimEndMs,
			"confidence": 0.45,
			"provenance": "beat_grid_proxy",
		},
		"trim": map[string]any{
			"start_ms":   trimStartMs,
			"end_ms":     trimEndMs,
			"confidence": 0.64,
			"provenance": "silence_threshold",
		},
		"sections": []map[string]any{
			{
				"label":      "intro",
				"start_ms":   trimStartMs,
				"end_ms":     introEndMs,
				"confidence": 0.45,
				"provenance": "beat_grid_proxy",
			},
			{
				"label":      "outro",
				"start_ms":   outroStartMs,
				"end_ms":     trimEndMs,
				"confidence": 0.45,
				"provenance": "beat_grid_proxy",
			},
		},
		"cue_candidates": []map[string]any{
			{
				"kind":       "mix_in",
				"start_ms":   introEndMs,
				"confidence": 0.45,
				"provenance": "beat_grid_proxy",
			},
			{
				"kind":       "mix_out",
				"start_ms":   outroStartMs,
				"confidence": 0.45,
				"provenance": "beat_grid_proxy",
			},
		},
		"duration_sanity": map[string]any{
			"declared_ms": a.declaredMs,
			"decoded_ms":  a.decodedMs,
			"delta_ms":    a.decodedMs - a.declaredMs,
			"confidence":  durationSanityConfidence(a.declaredMs, a.decodedMs),
			"provenance":  "ffmpeg_decode",
		},
	}
	if a.bpm > 0 {
		summary["bpm"] = map[string]any{
			"value":      round(a.bpm, 2),
			"confidence": round(a.bpmConf, 3),
			"provenance": tempoModelVersion,
		}
		summary["beat_grid"] = map[string]any{
			"bpm":        round(a.bpm, 2),
			"offset_ms":  firstOffset(a.beats, max(1, int(math.Round(60000/a.bpm)))),
			"beats_ms":   a.beats,
			"confidence": round(a.bpmConf, 3),
			"provenance": tempoModelVersion,
		}
	}
	if len(a.downbeats) > 0 {
		summary["downbeats"] = map[string]any{
			"positions_ms": a.downbeats,
			"confidence":   round(a.downbeatConf, 3),
			"provenance":   tempoModelVersion,
		}
	}
	if a.keyName != "" {
		summary["key"] = map[string]any{
			"value":      a.keyName,
			"confidence": round(a.keyConf, 3),
			"provenance": keyModelVersion,
		}
	}
	if a.camelot != "" {
		summary["camelot"] = map[string]any{
			"value":      a.camelot,
			"confidence": round(a.keyConf, 3),
			"provenance": keyModelVersion,
		}
	}
	artifacts := map[string]any{
		"source": map[string]any{
			"storage_key": req.StorageKey,
			"duration_ms": a.durationMs,
			"sample_rate": a.sampleRate,
		},
		"waveforms": map[string]any{
			"overview": map[string]any{
				"sample_rate_hz": max(1, len(overviewPeaks)*1000/max(1, a.durationMs)),
				"peaks":          overviewPeaks,
				"rms":            overviewRMS,
			},
			"detail": map[string]any{
				"sample_rate_hz": max(1, a.sampleCount*1000/max(1, a.durationMs)),
				"peaks":          a.peaks,
				"rms":            a.rms,
			},
		},
		"spectral_bands": map[string]any{
			"overview": map[string]any{
				"low":  overviewLow,
				"mid":  overviewMid,
				"high": overviewHigh,
			},
			"detail": map[string]any{
				"low":  a.low,
				"mid":  a.mid,
				"high": a.high,
			},
		},
		"beat_grid": map[string]any{
			"beats_ms":     a.beats,
			"downbeats_ms": a.downbeats,
		},
		"markers": map[string]any{
			"silence_ranges": a.silence,
			"transients_ms":  a.transients,
		},
		"waveform_resolution": "multi_resolution",
	}
	provenance := map[string]any{
		"analyzer":         analyzerName,
		"analyzer_version": analyzerVersion,
		"model_versions": map[string]any{
			"waveform": "pcm-rms-v1",
			"tempo":    tempoModelVersion,
			"downbeat": tempoModelVersion,
			"key":      keyModelVersion,
			"sections": "beat-grid-proxy-v1",
		},
	}
	return map[string]any{
		"schema_version": analyzer.SchemaVersion,
		"summary":        summary,
		"artifacts":      artifacts,
		"provenance":     provenance,
	}
}

func detectTransients(rms []float64, peaks []float64, durationMs int) []int {
	if len(rms) < 3 {
		return nil
	}
	threshold := math.Max(mean(rms)*1.45, 0.18)
	type hit struct {
		ms    int
		score float64
	}
	hits := []hit{}
	for i := 1; i < len(rms)-1; i++ {
		if rms[i] < threshold || peaks[i] < 0.20 {
			continue
		}
		if rms[i] >= rms[i-1]*1.08 && rms[i] > rms[i+1]*1.03 {
			hits = append(hits, hit{
				ms:    i * durationMs / len(rms),
				score: rms[i]*0.7 + peaks[i]*0.3,
			})
		}
	}
	sort.Slice(hits, func(i, j int) bool { return hits[i].score > hits[j].score })
	if len(hits) > 256 {
		hits = hits[:256]
	}
	out := make([]int, len(hits))
	for i, hit := range hits {
		out[i] = hit.ms
	}
	sort.Ints(out)
	return out
}

var keyNames = []string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

func camelotFor(key int, mode string) string {
	major := []string{"8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"}
	minor := []string{"5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"}
	if mode == "minor" {
		return minor[key%12]
	}
	return major[key%12]
}

func downsample(values []float64, maxSamples int) []float64 {
	if len(values) <= maxSamples || maxSamples <= 0 {
		return append([]float64(nil), values...)
	}
	out := make([]float64, maxSamples)
	for i := range out {
		start := i * len(values) / maxSamples
		end := (i + 1) * len(values) / maxSamples
		if end <= start {
			end = min(len(values), start+1)
		}
		peak := 0.0
		for _, value := range values[start:end] {
			peak = math.Max(peak, value)
		}
		out[i] = round(peak, 4)
	}
	return out
}

func defaultCueBoundaryMs(a waveformAnalysis, intro bool) int {
	if len(a.downbeats) == 0 {
		if intro {
			return min(a.durationMs, max(a.leadingMs, 16000))
		}
		return max(0, a.durationMs-max(a.trailingMs, 16000))
	}
	if intro {
		target := a.leadingMs + 16000
		for _, ms := range a.downbeats {
			if ms >= target {
				return min(ms, a.durationMs)
			}
		}
		return min(a.durationMs, target)
	}
	target := a.durationMs - a.trailingMs - 16000
	last := max(0, target)
	for _, ms := range a.downbeats {
		if ms > target {
			break
		}
		last = ms
	}
	return max(0, min(last, a.durationMs))
}

func durationSanityConfidence(declaredMs int, decodedMs int) float64 {
	if declaredMs <= 0 || decodedMs <= 0 {
		return 0.5
	}
	delta := math.Abs(float64(decodedMs - declaredMs))
	if delta <= 100 {
		return 0.99
	}
	ratio := delta / math.Max(float64(declaredMs), float64(decodedMs))
	return round(clamp(1-ratio*5, 0.25, 0.95), 3)
}

func firstOffset(values []int, interval int) int {
	if len(values) == 0 || interval <= 0 {
		return 0
	}
	return values[0] % interval
}

func detectSilence(rms []float64, durationMs int) ([]timeRange, int, int) {
	ranges := []timeRange{}
	start := -1
	threshold := 0.025
	for i, value := range rms {
		if value <= threshold {
			if start == -1 {
				start = i
			}
			continue
		}
		if start != -1 {
			ranges = appendSilenceRange(ranges, start, i, len(rms), durationMs)
			start = -1
		}
	}
	if start != -1 {
		ranges = appendSilenceRange(ranges, start, len(rms), len(rms), durationMs)
	}
	leading, trailing := 0, 0
	if len(ranges) > 0 && ranges[0].StartMs == 0 {
		leading = ranges[0].EndMs
	}
	if len(ranges) > 0 && ranges[len(ranges)-1].EndMs >= durationMs-50 {
		trailing = durationMs - ranges[len(ranges)-1].StartMs
	}
	return ranges, leading, trailing
}

func appendSilenceRange(ranges []timeRange, startFrame, endFrame, totalFrames, durationMs int) []timeRange {
	startMs := startFrame * durationMs / max(1, totalFrames)
	endMs := endFrame * durationMs / max(1, totalFrames)
	if endMs-startMs < 250 {
		return ranges
	}
	return append(ranges, timeRange{StartMs: startMs, EndMs: endMs})
}

func normalize(values []float64, maxValue float64) {
	if maxValue <= 0 {
		return
	}
	for i := range values {
		values[i] = clamp(values[i]/maxValue, 0, 1)
	}
}

func roundAll(values []float64) {
	for i, value := range values {
		values[i] = round(value, 4)
	}
}

func mean(values []float64) float64 {
	if len(values) == 0 {
		return 0
	}
	var total float64
	for _, value := range values {
		total += value
	}
	return total / float64(len(values))
}

func db(value float64) float64 {
	if value <= 0 {
		return -120
	}
	return 20 * math.Log10(value)
}

func round(value float64, places int) float64 {
	scale := math.Pow10(places)
	return math.Round(value*scale) / scale
}

func clamp(value float64, minValue float64, maxValue float64) float64 {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func clampInt(value int, minValue int, maxValue int) int {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func min(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a int, b int) int {
	if a > b {
		return a
	}
	return b
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func env(key string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func envInt(key string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
}

func envBool(key string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return fallback
	}
	return parsed
}
