// Command stems-worker is the out-of-process 5-stem separation service.
//
// It is deliberately shaped like cmd/audio-analyzer: the Go process owns HTTP,
// bearer auth, versioned identity, MinIO transfer, and bounded concurrency,
// while a Python helper (stems_dsp.py) owns the model and the DSP. Keeping the
// helper torch-free-importable is what lets the crossover/null-sum/manifest
// contract be tested in a tiny image (see the stems-test Docker stage).
//
// The Postgres track_stems row written by the API server — not this process —
// is the durable status authority. That is what makes a retried POST /separate
// safe: a duplicate delivery re-produces the same artifacts at the same
// content-addressed keys and is rejected by the guarded upsert if the row has
// already moved on.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/storage"
)

const (
	defaultAddr       = ":18290"
	defaultDSPHelper  = "/app/stems_dsp.py"
	workerName        = "stemsep-worker"
	workerVersion     = "2026-08-30-1"
	inferenceProvider = "audio-separator"
	inferenceVersion  = "0.47.0"
	torchVersion      = "2.8.0"
	modelFamily       = "demucs"
	modelName         = "htdemucs_ft"
	modelConfigSHA256 = "69470b8c1bbd674437b51bc9fb491327a10ab0396b702c93389b9cf750016346"
	defaultChannelSet = "stems5-hybrid-v1"

	maxRequestBytes       = 1 << 20
	maxManifestBytes      = 32 << 20
	stemObjectContentType = "audio/opus"
)

// channelSetModelVersions must stay identical to STEM_MODEL_VERSIONS in
// stems_dsp.py; the readiness probe cross-checks them at startup so a helper
// swap cannot silently change the identity this service advertises.
var channelSetModelVersions = map[string]string{
	"stems4-demucs-v1": "audio-separator-htdemucs-ft-4s-v1",
	"stems5-hybrid-v1": "audio-separator-htdemucs-ft-4s-v1+lr4-180",
}

var modelWeightSHA256 = map[string]string{
	"f7e0c4bc-ba3fe64a.th": "ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066",
	"d12395a8-e57c48e6.th": "e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6",
	"92cfc3b6-ef3bcb9c.th": "ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2",
	"04573f0d-f3cf25b2.th": "f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49",
}

var outputMapping = map[string]string{
	"vocals": "omp-vocals.wav",
	"drums":  "omp-drums.wav",
	"bass":   "omp-bass.wav",
	"other":  "omp-other.wav",
}

type separateRequest struct {
	SchemaVersion         int    `json:"schema_version"`
	TrackID               int64  `json:"track_id"`
	StorageKey            string `json:"storage_key"`
	ChannelSet            string `json:"channel_set"`
	ExpectedWorker        string `json:"expected_worker"`
	ExpectedWorkerVersion string `json:"expected_worker_version"`
}

type manifestObject struct {
	Channel    string `json:"channel"`
	Key        string `json:"key"`
	Path       string `json:"path,omitempty"`
	Bytes      int64  `json:"bytes"`
	DurationMs int    `json:"duration_ms"`
	Derivation string `json:"derivation"`
}

type manifestArtifacts struct {
	Objects []manifestObject `json:"objects"`
	Codec   json.RawMessage  `json:"codec"`
	NullSum json.RawMessage  `json:"null_sum,omitempty"`
	Energy  json.RawMessage  `json:"energy"`
}

type separateManifest struct {
	SchemaVersion    int                    `json:"schema_version"`
	TrackID          int64                  `json:"track_id"`
	ChannelSet       string                 `json:"channel_set"`
	StemModelVersion string                 `json:"stem_model_version"`
	SourceStorageKey string                 `json:"source_storage_key"`
	SourceFileHash   string                 `json:"source_file_hash"`
	DurationMs       int                    `json:"duration_ms"`
	SampleRateHz     int                    `json:"sample_rate_hz"`
	Artifacts        manifestArtifacts      `json:"artifacts"`
	Provenance       map[string]interface{} `json:"provenance"`
}

type objectStore interface {
	GetObject(ctx context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error)
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error
}

// separateFunc runs the DSP helper. It is a field so tests can drive the whole
// HTTP + upload path without torch, ffmpeg, or a checkpoint.
type separateFunc func(ctx context.Context, audioPath, outDir string, trackID int64, channelSet string) (*separateManifest, error)

type stemsServer struct {
	storage   objectStore
	authToken string
	dspHelper string
	slots     chan struct{}
	separate  separateFunc
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

	// Keep this new provider/model bag serialized until representative three-track
	// CPU RSS and realtime-factor evidence justifies a higher limit.
	concurrency := 1
	server := &stemsServer{
		storage:   store,
		authToken: strings.TrimSpace(os.Getenv("STEMS_AUTH_TOKEN")),
		dspHelper: env("STEMS_DSP_HELPER", defaultDSPHelper),
		slots:     make(chan struct{}, concurrency),
	}
	server.separate = server.runDSPHelper

	checkCtx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	if err := validateDSPRuntime(checkCtx, server.dspHelper); err != nil {
		log.Fatalf("stems DSP runtime readiness check failed: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, healthPayload())
	})
	mux.HandleFunc("/separate", server.handleSeparate)

	addr := env("STEMS_ADDR", defaultAddr)
	log.Printf("stems worker listening on %s (concurrency %d)", addr, concurrency)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func healthPayload() map[string]any {
	return map[string]any{
		"status":                     "healthy",
		"worker":                     workerName,
		"worker_version":             workerVersion,
		"channel_set":                defaultChannelSet,
		"channel_sets":               []string{"stems4-demucs-v1", "stems5-hybrid-v1"},
		"stem_model_version":         channelSetModelVersions[defaultChannelSet],
		"stem_model_versions":        channelSetModelVersions,
		"inference_provider":         inferenceProvider,
		"inference_provider_version": inferenceVersion,
		"torch_version":              torchVersion,
		"model_family":               modelFamily,
		"model_name":                 modelName,
		"model_config_sha256":        modelConfigSHA256,
		"model_weight_sha256":        modelWeightSHA256,
		"output_mapping":             outputMapping,
		"device":                     "cpu",
	}
}

func (s *stemsServer) handleSeparate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
		return
	}
	if !s.authorized(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
		return
	}
	defer r.Body.Close()

	var req separateRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxRequestBytes)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid request JSON"})
		return
	}
	if strings.TrimSpace(req.StorageKey) == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "storage_key is required"})
		return
	}
	if req.TrackID <= 0 {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "track_id must be positive"})
		return
	}
	channelSet := strings.TrimSpace(req.ChannelSet)
	if channelSet == "" {
		channelSet = defaultChannelSet
	}
	modelVersion, ok := channelSetModelVersions[channelSet]
	if !ok {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "unknown channel_set"})
		return
	}

	// Identity handshake mirrors the analyzer: both halves or neither, and a
	// mismatch is a 409 so the caller's guarded upsert never stores a result
	// produced by a worker version it did not ask for.
	expectedWorker := strings.TrimSpace(req.ExpectedWorker)
	expectedVersion := strings.TrimSpace(req.ExpectedWorkerVersion)
	if (expectedWorker == "") != (expectedVersion == "") {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "expected worker identity requires both name and version"})
		return
	}
	if expectedWorker != "" && (expectedWorker != workerName || expectedVersion != workerVersion) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "worker identity does not match requested version"})
		return
	}

	ctx := r.Context()
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	case <-ctx.Done():
		writeJSON(w, http.StatusRequestTimeout, map[string]any{"error": ctx.Err().Error()})
		return
	}

	audioPath, sourceHash, cleanupAudio, err := s.downloadObject(ctx, req.StorageKey)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error()})
		return
	}
	defer cleanupAudio()

	outDir, err := os.MkdirTemp("", "omp-stems-out-")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	defer os.RemoveAll(outDir)

	manifest, err := s.separate(ctx, audioPath, outDir, req.TrackID, channelSet)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	if manifest.ChannelSet != channelSet || manifest.StemModelVersion != modelVersion {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"error": fmt.Sprintf(
				"helper returned identity %s/%s, expected %s/%s",
				manifest.ChannelSet, manifest.StemModelVersion, channelSet, modelVersion,
			),
		})
		return
	}

	if err := s.uploadObjects(ctx, manifest); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}

	manifest.TrackID = req.TrackID
	manifest.SourceStorageKey = req.StorageKey
	manifest.SourceFileHash = sourceHash
	if manifest.Provenance == nil {
		manifest.Provenance = map[string]interface{}{}
	}
	manifest.Provenance["worker"] = workerName
	manifest.Provenance["worker_version"] = workerVersion
	if expectedWorker != "" {
		manifest.Provenance["expected_worker"] = expectedWorker
		manifest.Provenance["expected_worker_version"] = expectedVersion
	}
	manifest.Provenance["source"] = map[string]interface{}{
		"storage_key": req.StorageKey,
		"file_hash":   sourceHash,
	}

	writeJSON(w, http.StatusOK, manifest)
}

func (s *stemsServer) authorized(r *http.Request) bool {
	if s.authToken == "" {
		return true
	}
	return strings.TrimSpace(r.Header.Get("Authorization")) == "Bearer "+s.authToken
}

// downloadObject streams the source object to a temp file and hashes it in the
// same pass. The hash is the staleness key for track_stems: if the track is
// re-downloaded, the stored stems no longer describe the source.
func (s *stemsServer) downloadObject(ctx context.Context, key string) (string, string, func(), error) {
	reader, _, err := s.storage.GetObject(ctx, key)
	if err != nil {
		return "", "", func() {}, err
	}
	defer reader.Close()

	tmp, err := os.CreateTemp("", "omp-stems-src-*")
	if err != nil {
		return "", "", func() {}, err
	}
	path := tmp.Name()
	cleanup := func() { _ = os.Remove(path) }

	digest := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, digest), reader); err != nil {
		_ = tmp.Close()
		cleanup()
		return "", "", func() {}, err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return "", "", func() {}, err
	}
	return path, "sha256:" + hex.EncodeToString(digest.Sum(nil)), cleanup, nil
}

func (s *stemsServer) uploadObjects(ctx context.Context, manifest *separateManifest) error {
	for index := range manifest.Artifacts.Objects {
		obj := &manifest.Artifacts.Objects[index]
		if strings.TrimSpace(obj.Path) == "" {
			return fmt.Errorf("helper did not emit a local path for channel %q", obj.Channel)
		}
		if strings.TrimSpace(obj.Key) == "" {
			return fmt.Errorf("helper did not emit an object key for channel %q", obj.Channel)
		}
		file, err := os.Open(obj.Path)
		if err != nil {
			return fmt.Errorf("open stem %s: %w", obj.Channel, err)
		}
		info, err := file.Stat()
		if err != nil {
			_ = file.Close()
			return fmt.Errorf("stat stem %s: %w", obj.Channel, err)
		}
		err = s.storage.PutObject(ctx, obj.Key, file, info.Size(), stemObjectContentType)
		_ = file.Close()
		if err != nil {
			return fmt.Errorf("upload stem %s: %w", obj.Channel, err)
		}
		obj.Bytes = info.Size()
		// Local scratch paths must never reach the API server or the database.
		obj.Path = ""
	}
	return nil
}

func (s *stemsServer) runDSPHelper(ctx context.Context, audioPath, outDir string, trackID int64, channelSet string) (*separateManifest, error) {
	if strings.TrimSpace(s.dspHelper) == "" {
		return nil, fmt.Errorf("stems DSP helper path is required")
	}
	cmd := exec.CommandContext(
		ctx,
		"python3",
		s.dspHelper,
		"--out-dir", outDir,
		"--track-id", strconv.FormatInt(trackID, 10),
		"--channel-set", channelSet,
		audioPath,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return nil, fmt.Errorf("stem separation failed: %s", detail)
	}
	if len(stdout) > maxManifestBytes {
		return nil, fmt.Errorf("stems manifest exceeds %d byte limit", maxManifestBytes)
	}
	var manifest separateManifest
	if err := json.Unmarshal(stdout, &manifest); err != nil {
		return nil, fmt.Errorf("stems manifest is not valid JSON: %w", err)
	}
	if len(manifest.Artifacts.Objects) == 0 {
		return nil, fmt.Errorf("stems manifest contains no artifacts")
	}
	return &manifest, nil
}

func validateDSPRuntime(ctx context.Context, helperPath string) error {
	if strings.TrimSpace(helperPath) == "" {
		return fmt.Errorf("stems DSP helper path is required")
	}
	if _, err := os.Stat(helperPath); err != nil {
		return fmt.Errorf("stems DSP helper not found at %s: %w", filepath.Clean(helperPath), err)
	}
	cmd := exec.CommandContext(ctx, "python3", helperPath, "--check")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.Output()
	if err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = err.Error()
		}
		return fmt.Errorf("stems DSP helper check failed: %s", detail)
	}
	var identity struct {
		Worker            string            `json:"worker"`
		WorkerVersion     string            `json:"worker_version"`
		StemModelVersions map[string]string `json:"stem_model_versions"`
		InferenceProvider string            `json:"inference_provider"`
		InferenceVersion  string            `json:"inference_provider_version"`
		ModelFamily       string            `json:"model_family"`
		ModelName         string            `json:"model_name"`
		ModelConfigSHA256 string            `json:"model_config_sha256"`
		ModelWeightSHA256 map[string]string `json:"model_weight_sha256"`
		OutputMapping     map[string]string `json:"output_mapping"`
		Device            string            `json:"device"`
		Ffmpeg            bool              `json:"ffmpeg"`
	}
	if err := json.Unmarshal(stdout, &identity); err != nil {
		return fmt.Errorf("stems DSP helper identity is not valid JSON: %w", err)
	}
	if identity.Worker != workerName || identity.WorkerVersion != workerVersion {
		return fmt.Errorf(
			"stems DSP helper identity %s/%s does not match service identity %s/%s",
			identity.Worker, identity.WorkerVersion, workerName, workerVersion,
		)
	}
	if identity.InferenceProvider != inferenceProvider || identity.InferenceVersion != inferenceVersion {
		return fmt.Errorf("stems DSP helper inference provider %q/%q does not match %q/%q", identity.InferenceProvider, identity.InferenceVersion, inferenceProvider, inferenceVersion)
	}
	if identity.ModelFamily != modelFamily || identity.ModelName != modelName || identity.Device != "cpu" {
		return fmt.Errorf("stems DSP helper model family/name/device %q/%q/%q does not match %q/%q/cpu", identity.ModelFamily, identity.ModelName, identity.Device, modelFamily, modelName)
	}
	if identity.ModelConfigSHA256 != modelConfigSHA256 {
		return fmt.Errorf("stems DSP helper model config sha256 %q does not match the pinned value", identity.ModelConfigSHA256)
	}
	if len(identity.ModelWeightSHA256) != len(modelWeightSHA256) || len(identity.OutputMapping) != len(outputMapping) {
		return fmt.Errorf("stems DSP helper reports incomplete model hashes or output mapping")
	}
	for filename, expectedHash := range modelWeightSHA256 {
		if identity.ModelWeightSHA256[filename] != expectedHash {
			return fmt.Errorf("stems DSP helper model hash for %s does not match pinned value", filename)
		}
	}
	for channel, filename := range outputMapping {
		if identity.OutputMapping[channel] != filename {
			return fmt.Errorf("stems DSP helper output mapping for %s does not match pinned value", channel)
		}
	}
	for set, version := range channelSetModelVersions {
		if identity.StemModelVersions[set] != version {
			return fmt.Errorf(
				"stems DSP helper reports %s=%q, service expects %q",
				set, identity.StemModelVersions[set], version,
			)
		}
	}
	if !identity.Ffmpeg {
		return fmt.Errorf("ffmpeg is not available to the stems DSP helper")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
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
