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
	maxRequestBytes     = 1 << 20
	maxDecodedPCMBytes  = 96 << 20
	maxWaveformSamples  = 32768
	minWaveformSamples  = 64
	defaultBeatInterval = 500
)

type analyzeRequest struct {
	SchemaVersion int    `json:"schema_version"`
	TrackID       int64  `json:"track_id"`
	StorageKey    string `json:"storage_key"`
	SourceURL     string `json:"source_url"`
	SourceType    string `json:"source_type"`
	DurationMs    int    `json:"duration_ms"`
	Title         string `json:"title"`
	Artist        string `json:"artist"`
}

type analyzerServer struct {
	storage    *storage.Client
	authToken  string
	sampleRate int
	waveformHz int
}

type waveformAnalysis struct {
	durationMs  int
	peaks       []float64
	rms         []float64
	low         []float64
	mid         []float64
	high        []float64
	transients  []int
	beats       []int
	downbeats   []int
	silence     []timeRange
	leadingMs   int
	trailingMs  int
	bpm         float64
	energy      float64
	truePeakDb  float64
	loudnessDb  float64
	sampleRate  int
	sampleCount int
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

	server := &analyzerServer{
		storage:    store,
		authToken:  strings.TrimSpace(os.Getenv("ANALYZER_AUTH_TOKEN")),
		sampleRate: envInt("ANALYZER_SAMPLE_RATE", defaultSampleRate),
		waveformHz: envInt("ANALYZER_WAVEFORM_HZ", defaultWaveformHz),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "healthy"})
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

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()

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
	durationMs := declaredDurationMs
	decodedDurationMs := int(math.Round(float64(len(samples)) / float64(sampleRate) * 1000))
	if durationMs <= 0 {
		durationMs = decodedDurationMs
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
	interval := estimateBeatInterval(a.transients)
	if interval <= 0 {
		interval = defaultBeatInterval
	}
	a.bpm = 60000 / float64(interval)
	a.beats = buildBeatGrid(a.durationMs, interval, firstOffset(a.transients, interval))
	a.downbeats = everyNth(a.beats, 4)
	a.silence, a.leadingMs, a.trailingMs = detectSilence(a.rms, a.durationMs)
	return a
}

func buildResponse(req analyzeRequest, a waveformAnalysis) map[string]any {
	summary := map[string]any{
		"bpm": map[string]any{
			"value":      round(a.bpm, 2),
			"confidence": 0.62,
			"provenance": "energy_transients",
		},
		"beat_grid": map[string]any{
			"bpm":        round(a.bpm, 2),
			"offset_ms":  firstOffset(a.beats, defaultBeatInterval),
			"beats_ms":   a.beats,
			"confidence": 0.48,
			"provenance": "energy_transients",
		},
		"downbeats": map[string]any{
			"positions_ms": a.downbeats,
			"confidence":   0.38,
			"provenance":   "every_four_beats",
		},
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
	}
	artifacts := map[string]any{
		"source": map[string]any{
			"storage_key": req.StorageKey,
			"duration_ms": a.durationMs,
			"sample_rate": a.sampleRate,
		},
		"waveform_resolution": "summary_detail",
	}
	provenance := map[string]any{
		"analyzer":         "omp-ffmpeg-analyzer",
		"analyzer_version": "2026-07-08-1",
		"model_versions": map[string]any{
			"waveform": "pcm-rms-v1",
			"tempo":    "transient-grid-v1",
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

func estimateBeatInterval(transients []int) int {
	if len(transients) < 2 {
		return 0
	}
	buckets := map[int]int{}
	for i := 0; i < len(transients); i++ {
		for j := i + 1; j < len(transients); j++ {
			diff := transients[j] - transients[i]
			if diff < 300 {
				continue
			}
			if diff > 900 {
				break
			}
			buckets[(diff/25)*25]++
		}
	}
	bestBucket, bestCount := 0, 0
	for bucket, count := range buckets {
		if count > bestCount || (count == bestCount && math.Abs(float64(bucket-500)) < math.Abs(float64(bestBucket-500))) {
			bestBucket, bestCount = bucket, count
		}
	}
	return bestBucket
}

func buildBeatGrid(durationMs int, intervalMs int, offsetMs int) []int {
	if intervalMs <= 0 {
		intervalMs = defaultBeatInterval
	}
	if offsetMs < 0 || offsetMs >= intervalMs {
		offsetMs = 0
	}
	beats := []int{}
	for ms := offsetMs; ms <= durationMs; ms += intervalMs {
		beats = append(beats, ms)
	}
	return beats
}

func firstOffset(values []int, interval int) int {
	if len(values) == 0 || interval <= 0 {
		return 0
	}
	return values[0] % interval
}

func everyNth(values []int, n int) []int {
	if n <= 0 {
		return nil
	}
	out := []int{}
	for i, value := range values {
		if i%n == 0 {
			out = append(out, value)
		}
	}
	return out
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
