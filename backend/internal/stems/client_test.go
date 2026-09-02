package stems

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const testManifestBody = `{
	"schema_version": 1,
	"track_id": 123,
	"channel_set": "stems5-hybrid-v1",
	"stem_model_version": "audio-separator-htdemucs-ft-4s-v1+lr4-180",
	"source_file_hash": "sha256:deadbeef",
	"source_storage_key": "tracks/youtube/x.mp3",
	"duration_ms": 210000,
	"artifacts": {"objects": [{"channel": "vocals", "key": "stems/123/audio-separator-htdemucs-ft-4s-v1/vocals.opus", "derivation": "separator"}]},
	"provenance": {"worker": "stemsep-worker", "worker_version": "2026-08-30-1", "inference_provider": {"name":"audio-separator"}}
}`

func newTestClient(t *testing.T, handler http.Handler, authToken string) (*ServiceClient, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	client, err := NewServiceClient(ServiceConfig{
		Enabled:   true,
		BaseURL:   server.URL,
		AuthToken: authToken,
		Timeout:   5 * time.Second,
	})
	if err != nil {
		t.Fatalf("new service client: %v", err)
	}
	if client == nil {
		t.Fatal("service client = nil for an enabled config")
	}
	return client, server
}

func testSeparateRequest() Request {
	return Request{
		TrackID:               123,
		StorageKey:            "tracks/youtube/x.mp3",
		ChannelSet:            ChannelSetStems5Hybrid,
		ExpectedWorker:        WorkerName,
		ExpectedWorkerVersion: WorkerVersion,
	}
}

func TestNewServiceClientDisabledReturnsNil(t *testing.T) {
	client, err := NewServiceClient(ServiceConfig{Enabled: false, BaseURL: "http://stems.local"})
	if err != nil {
		t.Fatalf("err = %v, want nil for a disabled client", err)
	}
	if client != nil {
		t.Fatal("client != nil for a disabled config")
	}
}

func TestNewServiceClientRequiresBaseURLWhenEnabled(t *testing.T) {
	if _, err := NewServiceClient(ServiceConfig{Enabled: true}); err == nil {
		t.Fatal("err = nil, want a missing base URL failure")
	}
	if _, err := NewServiceClient(ServiceConfig{Enabled: true, BaseURL: "stems.local:9000"}); err == nil {
		t.Fatal("err = nil, want a scheme/host validation failure")
	}
}

func TestSeparateSendsContractRequestWithBearerAuth(t *testing.T) {
	var seenAuth, seenPath, seenSchemaHeader string
	var decoded Request
	client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAuth = r.Header.Get("Authorization")
		seenPath = r.URL.Path
		seenSchemaHeader = r.Header.Get("X-OpenMusicPlayer-Stems-Schema")
		_ = json.NewDecoder(r.Body).Decode(&decoded)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, testManifestBody)
	}), "secret-token")

	manifest, err := client.Separate(context.Background(), testSeparateRequest())
	if err != nil {
		t.Fatalf("separate: %v", err)
	}
	if seenAuth != "Bearer secret-token" {
		t.Fatalf("Authorization = %q, want a bearer token", seenAuth)
	}
	if seenPath != "/separate" {
		t.Fatalf("path = %q, want /separate", seenPath)
	}
	if seenSchemaHeader != "1" {
		t.Fatalf("schema header = %q, want 1", seenSchemaHeader)
	}
	if decoded.SchemaVersion != SchemaVersion || decoded.TrackID != 123 || decoded.ChannelSet != ChannelSetStems5Hybrid {
		t.Fatalf("request = %+v, want the schema-versioned contract body", decoded)
	}
	if decoded.ExpectedWorker != WorkerName || decoded.ExpectedWorkerVersion != WorkerVersion {
		t.Fatalf("request identity = %q/%q, want %q/%q", decoded.ExpectedWorker, decoded.ExpectedWorkerVersion, WorkerName, WorkerVersion)
	}
	if manifest.StemModelVersion != StemModelVersionStems5 || manifest.SourceFileHash != "sha256:deadbeef" {
		t.Fatalf("manifest = %+v, want the parsed artifact manifest", manifest)
	}
	worker, workerVersion, err := manifest.ProvenanceIdentity()
	if err != nil {
		t.Fatalf("provenance identity: %v", err)
	}
	if worker != WorkerName || workerVersion != WorkerVersion {
		t.Fatalf("provenance identity = %q/%q, want %q/%q", worker, workerVersion, WorkerName, WorkerVersion)
	}
}

func TestSeparateSurfacesIdentityMismatchAsTypedError(t *testing.T) {
	client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":"expected stemsep-worker 2026-08-03-1, running 2026-01-01-1"}`)
	}), "")

	_, err := client.Separate(context.Background(), testSeparateRequest())
	if !errors.Is(err, ErrWorkerIdentityMismatch) {
		t.Fatalf("error = %v, want ErrWorkerIdentityMismatch", err)
	}
}

func TestSeparateRejectsManifestClaimingAnotherWorkerIdentity(t *testing.T) {
	body := strings.Replace(testManifestBody, `"worker_version": "2026-08-30-1"`, `"worker_version": "1999-01-01-1"`, 1)
	client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, body)
	}), "")

	_, err := client.Separate(context.Background(), testSeparateRequest())
	if !errors.Is(err, ErrWorkerIdentityMismatch) {
		t.Fatalf("error = %v, want ErrWorkerIdentityMismatch for a mismatched manifest", err)
	}
}

func TestSeparateRejectsMalformedAndEmptyResponses(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"malformed json", `{"schema_version": 1,`},
		{"empty body", ""},
		{"missing artifacts", `{"schema_version":1,"channel_set":"stems5-hybrid-v1","provenance":{"worker":"stemsep-worker","worker_version":"2026-08-30-1"}}`},
		{"missing provenance", `{"schema_version":1,"channel_set":"stems5-hybrid-v1","artifacts":{"objects":[]}}`},
		{"channel set mismatch", `{"schema_version":1,"channel_set":"stems4-demucs-v1","stem_model_version":"audio-separator-htdemucs-ft-4s-v1","artifacts":{"objects":[]},"provenance":{"worker":"stemsep-worker","worker_version":"2026-08-30-1"}}`},
		{"missing model version", `{"schema_version":1,"channel_set":"stems5-hybrid-v1","artifacts":{"objects":[]},"provenance":{"worker":"stemsep-worker","worker_version":"2026-08-30-1"}}`},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprint(w, testCase.body)
			}), "")
			if _, err := client.Separate(context.Background(), testSeparateRequest()); err == nil {
				t.Fatal("error = nil, want rejection")
			}
		})
	}
}

func TestSeparateBoundsResponseSize(t *testing.T) {
	client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		oversized := make([]byte, maxStemsResponseBytes+1024)
		for index := range oversized {
			oversized[index] = 'a'
		}
		_, _ = w.Write(oversized)
	}), "")

	_, err := client.Separate(context.Background(), testSeparateRequest())
	if err == nil || !strings.Contains(err.Error(), "byte limit") {
		t.Fatalf("error = %v, want a response size limit failure", err)
	}
}

func TestSeparateHonoursContextCancellation(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}), "")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.Separate(ctx, testSeparateRequest()); !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
}

func TestSeparateHonoursClientTimeout(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	// Cleanups run LIFO, so the handler must be released before Close waits on it.
	t.Cleanup(server.Close)
	t.Cleanup(func() { close(release) })

	client, err := NewServiceClient(ServiceConfig{
		Enabled: true,
		BaseURL: server.URL,
		Timeout: 25 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("new service client: %v", err)
	}
	if _, err := client.Separate(context.Background(), testSeparateRequest()); err == nil {
		t.Fatal("error = nil, want a timeout")
	}
}

func TestSeparateMapsUnsupportedStatuses(t *testing.T) {
	for _, status := range []int{http.StatusUnsupportedMediaType, http.StatusUnprocessableEntity} {
		client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			fmt.Fprint(w, `{"error":"unsupported source"}`)
		}), "")
		if _, err := client.Separate(context.Background(), testSeparateRequest()); !errors.Is(err, ErrUnsupported) {
			t.Fatalf("status %d error = %v, want ErrUnsupported", status, err)
		}
	}
}

func TestInfoValidatesWorkerIdentity(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		wantErr bool
	}{
		{
			name: "healthy",
			body: `{"status":"healthy","worker":"stemsep-worker","worker_version":"2026-08-30-1","channel_set":"stems5-hybrid-v1","stem_model_version":"audio-separator-htdemucs-ft-4s-v1+lr4-180","stem_model_versions":{"stems4-demucs-v1":"audio-separator-htdemucs-ft-4s-v1","stems5-hybrid-v1":"audio-separator-htdemucs-ft-4s-v1+lr4-180"},"inference_provider":"audio-separator","inference_provider_version":"0.47.0","model_family":"demucs","model_name":"htdemucs_ft","model_config_sha256":"69470b8c1bbd674437b51bc9fb491327a10ab0396b702c93389b9cf750016346","model_weight_sha256":{"f7e0c4bc-ba3fe64a.th":"ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066","d12395a8-e57c48e6.th":"e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6","92cfc3b6-ef3bcb9c.th":"ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2","04573f0d-f3cf25b2.th":"f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49"},"output_mapping":{"vocals":"omp-vocals.wav","drums":"omp-drums.wav","bass":"omp-bass.wav","other":"omp-other.wav"},"device":"cpu"}`,
		},
		{
			name:    "missing identity",
			body:    `{"status":"healthy","channel_set":"stems5-hybrid-v1","stem_model_version":"audio-separator-htdemucs-ft-4s-v1+lr4-180"}`,
			wantErr: true,
		},
		{
			name:    "unhealthy",
			body:    `{"status":"degraded","worker":"stemsep-worker","worker_version":"2026-08-30-1","channel_set":"stems5-hybrid-v1","stem_model_version":"audio-separator-htdemucs-ft-4s-v1+lr4-180"}`,
			wantErr: true,
		},
		{
			name:    "missing model identity",
			body:    `{"status":"healthy","worker":"stemsep-worker","worker_version":"2026-08-30-1"}`,
			wantErr: true,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			var seenPath string
			client, _ := newTestClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				seenPath = r.URL.Path
				fmt.Fprint(w, testCase.body)
			}), "")
			info, err := client.Info(context.Background())
			if testCase.wantErr {
				if err == nil {
					t.Fatalf("err = nil, want rejection (info = %+v)", info)
				}
				return
			}
			if err != nil {
				t.Fatalf("info: %v", err)
			}
			if seenPath != "/health" {
				t.Fatalf("path = %q, want /health", seenPath)
			}
			if info.Worker != WorkerName || info.WorkerVersion != WorkerVersion {
				t.Fatalf("info identity = %q/%q, want %q/%q", info.Worker, info.WorkerVersion, WorkerName, WorkerVersion)
			}
			if info.ChannelSet != ChannelSetStems5Hybrid || info.StemModelVersion != StemModelVersionStems5 {
				t.Fatalf("info model identity = %q/%q", info.ChannelSet, info.StemModelVersion)
			}
			if err := ValidateInfo(info); err != nil {
				t.Fatalf("startup validation rejected healthy worker: %v", err)
			}
		})
	}
}

func TestValidateInfoFailsClosedOnWorkerDrift(t *testing.T) {
	info := Info{
		Status:                   "healthy",
		Worker:                   WorkerName,
		WorkerVersion:            WorkerVersion,
		ChannelSet:               DefaultChannelSet,
		StemModelVersion:         StemModelVersionStems5,
		StemModelVersions:        map[string]string{ChannelSetStems4Demucs: StemModelVersionStems4, ChannelSetStems5Hybrid: StemModelVersionStems5},
		InferenceProvider:        InferenceProvider,
		InferenceProviderVersion: InferenceProviderVersion,
		ModelFamily:              ModelFamily,
		ModelName:                ModelName,
		ModelConfigSHA256:        ModelConfigSHA256,
		ModelWeightSHA256:        cloneStringMap(expectedModelWeightSHA256),
		OutputMapping:            cloneStringMap(expectedOutputMapping),
		Device:                   ModelDevice,
	}
	if err := ValidateInfo(info); err != nil {
		t.Fatalf("validate healthy info: %v", err)
	}
	info.WorkerVersion = "old"
	if err := ValidateInfo(info); err == nil {
		t.Fatal("worker identity drift passed startup validation")
	}
}

func TestValidateInfoFailsClosedOnModelDrift(t *testing.T) {
	base := Info{
		Status:                   "healthy",
		Worker:                   WorkerName,
		WorkerVersion:            WorkerVersion,
		ChannelSet:               DefaultChannelSet,
		StemModelVersion:         StemModelVersionStems5,
		StemModelVersions:        map[string]string{ChannelSetStems4Demucs: StemModelVersionStems4, ChannelSetStems5Hybrid: StemModelVersionStems5},
		InferenceProvider:        InferenceProvider,
		InferenceProviderVersion: InferenceProviderVersion,
		ModelFamily:              ModelFamily,
		ModelName:                ModelName,
		ModelConfigSHA256:        ModelConfigSHA256,
		ModelWeightSHA256:        cloneStringMap(expectedModelWeightSHA256),
		OutputMapping:            cloneStringMap(expectedOutputMapping),
		Device:                   ModelDevice,
	}
	for _, mutate := range []func(*Info){
		func(info *Info) { info.InferenceProviderVersion = "0.46.0" },
		func(info *Info) { info.ModelConfigSHA256 = "wrong" },
		func(info *Info) { info.ModelWeightSHA256["f7e0c4bc-ba3fe64a.th"] = "wrong" },
		func(info *Info) { info.OutputMapping["vocals"] = "wrong.wav" },
		func(info *Info) { info.Device = "cuda" },
	} {
		info := base
		info.ModelWeightSHA256 = cloneStringMap(base.ModelWeightSHA256)
		info.OutputMapping = cloneStringMap(base.OutputMapping)
		mutate(&info)
		if err := ValidateInfo(info); err == nil {
			t.Fatal("model identity drift passed startup validation")
		}
	}
}

func cloneStringMap(source map[string]string) map[string]string {
	copy := make(map[string]string, len(source))
	for key, value := range source {
		copy[key] = value
	}
	return copy
}

func TestNilServiceClientIsInert(t *testing.T) {
	var client *ServiceClient
	if _, err := client.Separate(context.Background(), testSeparateRequest()); err == nil {
		t.Fatal("Separate on a nil client returned no error")
	}
	if _, err := client.Info(context.Background()); err == nil {
		t.Fatal("Info on a nil client returned no error")
	}
}
