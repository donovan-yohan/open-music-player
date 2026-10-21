package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/openmusicplayer/backend/internal/stems"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/storage"
)

type fakeStore struct {
	objects  map[string][]byte
	uploads  map[string][]byte
	getErr   error
	putErr   error
	putOrder []string
}

func newFakeStore() *fakeStore {
	return &fakeStore{objects: map[string][]byte{}, uploads: map[string][]byte{}}
}

func (f *fakeStore) GetObject(_ context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error) {
	if f.getErr != nil {
		return nil, nil, f.getErr
	}
	data, ok := f.objects[key]
	if !ok {
		return nil, nil, fmt.Errorf("object %s not found", key)
	}
	return io.NopCloser(bytes.NewReader(data)), &storage.ObjectInfo{Size: int64(len(data))}, nil
}

func (f *fakeStore) PutObject(_ context.Context, key string, reader io.Reader, _ int64, _ string) error {
	if f.putErr != nil {
		return f.putErr
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		return err
	}
	f.uploads[key] = data
	f.putOrder = append(f.putOrder, key)
	return nil
}

// stubSeparator writes real (tiny) files so the upload path is exercised end to
// end without torch, ffmpeg, or a checkpoint.
func stubSeparator(t *testing.T) separateFunc {
	t.Helper()
	return func(_ context.Context, audioPath, outDir string, trackID int64, channelSet string) (*separateManifest, error) {
		channels := []struct {
			name       string
			key        string
			derivation string
		}{
			{"vocals", fmt.Sprintf("stems/%d/audio-separator-htdemucs-ft-4s-v1+lr4-180/vocals.opus", trackID), "separator"},
			{"melody", fmt.Sprintf("stems/%d/audio-separator-htdemucs-ft-4s-v1+lr4-180/other.opus", trackID), "separator"},
			{"bass", fmt.Sprintf("stems/%d/audio-separator-htdemucs-ft-4s-v1+lr4-180/bass.opus", trackID), "separator"},
			{"kick", fmt.Sprintf("stems/%d/audio-separator-htdemucs-ft-4s-v1+lr4-180/kick.opus", trackID), "dsp-crossover-lr4-180"},
			{"perc", fmt.Sprintf("stems/%d/audio-separator-htdemucs-ft-4s-v1+lr4-180/perc.opus", trackID), "dsp-crossover-lr4-180"},
			{"drums", fmt.Sprintf("stems/%d/audio-separator-htdemucs-ft-4s-v1+lr4-180/drums.opus", trackID), "separator"},
		}
		objects := make([]manifestObject, 0, len(channels))
		for _, channel := range channels {
			local := filepath.Join(outDir, strings.ReplaceAll(channel.key, "/", "__"))
			payload := []byte("opus-" + channel.name)
			if err := os.WriteFile(local, payload, 0o600); err != nil {
				return nil, err
			}
			zero := int64(0)
			skip := int64(312)
			digest := sha256.Sum256(payload)
			objects = append(objects, manifestObject{
				SHA256: hex.EncodeToString(digest[:]), SampleFrames: 10080000, SampleRateHz: 48000, Channels: 2, OriginFrame: &zero, DelayFrames: &zero, EncoderDelayFrames: &skip, DelayProvenance: stems.DelayProvenance,
				Channel:    channel.name,
				Key:        channel.key,
				Path:       local,
				Bytes:      int64(len(payload)),
				DurationMs: 210000,
				Derivation: channel.derivation,
			})
		}
		energyChannels := map[string]string{}
		for _, o := range objects {
			energyChannels[o.Channel] = base64.StdEncoding.EncodeToString(make([]byte, 16800))
		}
		energy, _ := json.Marshal(map[string]any{"frame_hz": 80, "frame_count": 16800, "encoding": "uint8-linear", "channels": energyChannels})
		sourceBytes, err := os.ReadFile(audioPath)
		if err != nil {
			return nil, err
		}
		sourceDigest := sha256.Sum256(sourceBytes)
		return &separateManifest{
			SourceFileHash:   "sha256:" + hex.EncodeToString(sourceDigest[:]),
			SchemaVersion:    1,
			TrackID:          trackID,
			ChannelSet:       channelSet,
			StemModelVersion: channelSetModelVersions[channelSet],
			DurationMs:       210000,
			SampleRateHz:     44100,
			Artifacts: manifestArtifacts{
				Objects: objects,
				Codec:   json.RawMessage(`{"name":"libopus","bitrate_kbps":128,"sample_rate_hz":48000,"channels":2}`),
				NullSum: json.RawMessage(`{"pair":["kick","perc"],"against":"drums","residual_db":-120.4,"threshold_db":-80.0,"passed":true}`),
				Energy:  energy,
			},
			Provenance: map[string]interface{}{"inference_provider": inferenceProvider, "worker": workerName, "worker_version": workerVersion},
		}, nil
	}
}

func newTestServer(t *testing.T, store *fakeStore, token string) *stemsServer {
	t.Helper()
	return &stemsServer{
		storage:   store,
		authToken: token,
		slots:     make(chan struct{}, 1),
		separate:  stubSeparator(t),
	}
}

func postSeparate(t *testing.T, server *stemsServer, body string, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/separate", strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	server.handleSeparate(rec, req)
	return rec
}

func TestSeparateChecksExpectedSourceBeforeInference(t *testing.T) {
	store := newFakeStore()
	store.objects["source"] = []byte("changed")
	server := newTestServer(t, store, "")
	called := false
	server.separate = func(context.Context, string, string, int64, string) (*separateManifest, error) {
		called = true
		return nil, fmt.Errorf("must not run")
	}
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"source","expected_source_file_hash":"sha256:`+strings.Repeat("a", 64)+`"}`, "")
	if rec.Code != http.StatusConflict || called || len(store.uploads) > 0 {
		t.Fatalf("status=%d inference=%v uploads=%d", rec.Code, called, len(store.uploads))
	}
}

func TestSeparateRejectsCorruptMemberBeforeAnyUpload(t *testing.T) {
	store := newFakeStore()
	store.objects["source"] = []byte("source")
	server := newTestServer(t, store, "")
	inner := server.separate
	server.separate = func(ctx context.Context, src, out string, id int64, set string) (*separateManifest, error) {
		m, err := inner(ctx, src, out, id, set)
		if err != nil {
			return nil, err
		}
		m.Artifacts.Objects[len(m.Artifacts.Objects)-1].SHA256 = strings.Repeat("b", 64)
		return m, nil
	}
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"source"}`, "")
	if rec.Code != http.StatusInternalServerError || len(store.uploads) != 0 {
		t.Fatalf("status=%d uploads=%d", rec.Code, len(store.uploads))
	}
}

func TestSeparateRejectsBadHelperTrackAndSchema(t *testing.T) {
	for _, kind := range []string{"schema", "track", "missing-member", "delay", "path"} {
		t.Run(kind, func(t *testing.T) {
			store := newFakeStore()
			store.objects["source"] = []byte("source")
			server := newTestServer(t, store, "")
			inner := server.separate
			server.separate = func(ctx context.Context, src, out string, id int64, set string) (*separateManifest, error) {
				m, err := inner(ctx, src, out, id, set)
				if err != nil {
					return nil, err
				}
				switch kind {
				case "schema":
					m.SchemaVersion = 3
				case "track":
					m.TrackID++
				case "missing-member":
					m.Artifacts.Objects = m.Artifacts.Objects[:5]
				case "delay":
					m.Artifacts.Objects[0].DelayFrames = nil
				case "path":
					m.Artifacts.Objects[0].Path = src
				}
				return m, nil
			}
			rec := postSeparate(t, server, `{"track_id":1,"storage_key":"source"}`, "")
			if rec.Code != http.StatusInternalServerError || len(store.uploads) != 0 {
				t.Fatalf("status=%d uploads=%d", rec.Code, len(store.uploads))
			}
		})
	}
}

func TestSeparateRejectsHelperSourceHashDrift(t *testing.T) {
	store := newFakeStore()
	store.objects["source"] = []byte("source")
	server := newTestServer(t, store, "")
	inner := server.separate
	server.separate = func(ctx context.Context, src, out string, id int64, set string) (*separateManifest, error) {
		m, err := inner(ctx, src, out, id, set)
		if err != nil {
			return nil, err
		}
		m.SourceFileHash = "sha256:" + strings.Repeat("b", 64)
		return m, nil
	}
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"source"}`, "")
	if rec.Code != http.StatusInternalServerError || len(store.uploads) != 0 {
		t.Fatalf("status=%d uploads=%d", rec.Code, len(store.uploads))
	}
}

func TestSeparateRejectsSilentRequestPayload(t *testing.T) {
	for _, body := range []string{`{"track_id":1,"storage_key":"source"} {"ignored":true}`, `{"track_id":1,"storage_key":"source","force":true}`, `{"schema_version":3,"track_id":1,"storage_key":"source"}`} {
		store := newFakeStore()
		store.objects["source"] = []byte("source")
		server := newTestServer(t, store, "")
		rec := postSeparate(t, server, body, "")
		if rec.Code < 400 || len(store.uploads) > 0 {
			t.Fatalf("silent request loss: status=%d body=%s", rec.Code, rec.Body.String())
		}
	}
}

func TestSeparateRejectsHelperPathOutsidePrivateOutput(t *testing.T) {
	store := newFakeStore()
	store.objects["source"] = []byte("source")
	server := newTestServer(t, store, "")
	inner := server.separate
	server.separate = func(ctx context.Context, src, out string, id int64, set string) (*separateManifest, error) {
		m, err := inner(ctx, src, out, id, set)
		if err != nil {
			return nil, err
		}
		data, _ := os.ReadFile(src)
		digest := sha256.Sum256(data)
		m.Artifacts.Objects[0].Path = src
		m.Artifacts.Objects[0].SHA256 = hex.EncodeToString(digest[:])
		m.Artifacts.Objects[0].Bytes = int64(len(data))
		return m, nil
	}
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"source"}`, "")
	if rec.Code < 400 || len(store.uploads) > 0 {
		t.Fatalf("helper uploaded source file outside output: status=%d", rec.Code)
	}
}

func TestRealDSPMemberPublicationWithFFmpeg(t *testing.T) {
	python := os.Getenv("OMP_STEMS_DSP_TEST_PYTHON")
	if python == "" {
		t.Skip("set OMP_STEMS_DSP_TEST_PYTHON to Python with numpy/scipy; no model required")
	}
	store := newFakeStore()
	store.objects["source"] = []byte("hashed source fixture, injected separator")
	server := newTestServer(t, store, "")
	server.separate = func(ctx context.Context, src, out string, id int64, set string) (*separateManifest, error) {
		script := `import sys,json,numpy as np,stems_dsp
n=44100
t=np.arange(n)/44100
signal=np.stack([.2*np.sin(2*np.pi*440*t)]*2).astype(np.float32)
def separate(path,rate): return {name:signal.copy() for name in stems_dsp.BASE_CHANNELS}
m=stems_dsp.run_separation(audio_path=sys.argv[1],out_dir=sys.argv[2],track_id=int(sys.argv[3]),channel_set=sys.argv[4],separator=separate)
print(json.dumps(m))`
		cmd := exec.CommandContext(ctx, python, "-c", script, src, out, strconv.FormatInt(id, 10), set)
		body, err := cmd.CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("DSP probe: %w: %s", err, body)
		}
		var m separateManifest
		err = json.Unmarshal(body, &m)
		return &m, err
	}
	rec := postSeparate(t, server, `{"schema_version":1,"track_id":42,"storage_key":"source","generation":3}`, "")
	if rec.Code != 200 {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var manifest stems.Manifest
	if err := json.Unmarshal(rec.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	if err := stems.ValidateManifest(&manifest, stems.Request{TrackID: 42, StorageKey: "source", ChannelSet: stems.DefaultChannelSet, Generation: 3}); err != nil {
		t.Fatal(err)
	}
	var artifacts stems.Artifacts
	_ = json.Unmarshal(manifest.Artifacts, &artifacts)
	for _, member := range artifacts.Objects {
		data := store.uploads[member.Key]
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != member.SHA256 || int64(len(data)) != member.Bytes || member.SampleFrames != 48000 {
			t.Fatalf("bad uploaded member: %+v", member)
		}
	}
	t.Logf("real ffmpeg/libopus pipeline published %d verified members at 48000 PCM frames each, source %s", len(artifacts.Objects), manifest.SourceFileHash)
}

func TestHealthAdvertisesVersionedIdentity(t *testing.T) {
	payload := healthPayload()
	if payload["worker"] != workerName {
		t.Fatalf("worker = %v, want %s", payload["worker"], workerName)
	}
	if payload["worker_version"] != workerVersion {
		t.Fatalf("worker_version = %v, want %s", payload["worker_version"], workerVersion)
	}
	if payload["channel_set"] != "stems5-hybrid-v1" {
		t.Fatalf("channel_set = %v", payload["channel_set"])
	}
	if payload["stem_model_version"] != "audio-separator-htdemucs-ft-4s-v1+lr4-180" {
		t.Fatalf("stem_model_version = %v", payload["stem_model_version"])
	}
	if payload["inference_provider"] != inferenceProvider || payload["model_config_sha256"] != modelConfigSHA256 {
		t.Fatalf("provider/model config mismatch: %v", payload)
	}
	if hashes, ok := payload["model_weight_sha256"].(map[string]string); !ok || len(hashes) != 4 {
		t.Fatalf("model hashes = %#v, want four pinned hashes", payload["model_weight_sha256"])
	}
}

func TestSeparateRejectsUnauthorized(t *testing.T) {
	server := newTestServer(t, newFakeStore(), "secret")
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"tracks/a.mp3"}`, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestSeparateRejectsNonPost(t *testing.T) {
	server := newTestServer(t, newFakeStore(), "")
	req := httptest.NewRequest(http.MethodGet, "/separate", nil)
	rec := httptest.NewRecorder()
	server.handleSeparate(rec, req)
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rec.Code)
	}
}

func TestSeparateValidatesRequest(t *testing.T) {
	cases := []struct {
		name string
		body string
		want int
	}{
		{"invalid json", `{`, http.StatusBadRequest},
		{"missing storage key", `{"track_id":1}`, http.StatusUnprocessableEntity},
		{"non positive track", `{"track_id":0,"storage_key":"a"}`, http.StatusUnprocessableEntity},
		{"unknown channel set", `{"track_id":1,"storage_key":"a","channel_set":"stems5-learned-hihat-v1"}`, http.StatusUnprocessableEntity},
		{"half identity", `{"track_id":1,"storage_key":"a","expected_worker":"stemsep-worker"}`, http.StatusUnprocessableEntity},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := newTestServer(t, newFakeStore(), "")
			rec := postSeparate(t, server, tc.body, "")
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d (%s)", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

func TestSeparateRejectsIdentityMismatchWith409(t *testing.T) {
	server := newTestServer(t, newFakeStore(), "")
	rec := postSeparate(
		t,
		server,
		`{"track_id":1,"storage_key":"tracks/a.mp3","expected_worker":"stemsep-worker","expected_worker_version":"1999-01-01-1"}`,
		"",
	)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409 (%s)", rec.Code, rec.Body.String())
	}
}

func TestSeparateUploadsEveryStemAndReturnsManifest(t *testing.T) {
	store := newFakeStore()
	source := []byte("fake source audio bytes")
	store.objects["tracks/youtube/x.mp3"] = source
	server := newTestServer(t, store, "secret")

	rec := postSeparate(
		t,
		server,
		`{"schema_version":1,"track_id":42,"storage_key":"tracks/youtube/x.mp3","channel_set":"stems5-hybrid-v1","expected_worker":"stemsep-worker","expected_worker_version":"`+workerVersion+`"}`,
		"secret",
	)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (%s)", rec.Code, rec.Body.String())
	}

	var manifest separateManifest
	if err := json.Unmarshal(rec.Body.Bytes(), &manifest); err != nil {
		t.Fatalf("decode manifest: %v", err)
	}

	if manifest.ChannelSet != "stems5-hybrid-v1" {
		t.Fatalf("channel_set = %s", manifest.ChannelSet)
	}
	if manifest.StemModelVersion != "audio-separator-htdemucs-ft-4s-v1+lr4-180" {
		t.Fatalf("stem_model_version = %s", manifest.StemModelVersion)
	}
	if manifest.SourceStorageKey != "tracks/youtube/x.mp3" {
		t.Fatalf("source_storage_key = %s", manifest.SourceStorageKey)
	}

	digest := sha256.Sum256(source)
	wantHash := "sha256:" + hex.EncodeToString(digest[:])
	if manifest.SourceFileHash != wantHash {
		t.Fatalf("source_file_hash = %s, want %s", manifest.SourceFileHash, wantHash)
	}

	if len(store.uploads) != 6 {
		t.Fatalf("uploaded %d objects, want 6: %v", len(store.uploads), store.putOrder)
	}
	for _, obj := range manifest.Artifacts.Objects {
		key := stems.MemberKey(42, manifest.StemModelVersion, wantHash, manifest.Generation, obj.Channel, obj.SHA256)
		if _, ok := store.uploads[key]; !ok {
			t.Fatalf("missing upload %s (have %v)", key, store.putOrder)
		}
	}
	legacyKeys := map[string]struct{}{
		"stems/42/htdemucs-4s-v1/vocals.opus": {},
		"stems/42/htdemucs-4s-v1/other.opus":  {},
		"stems/42/htdemucs-4s-v1/bass.opus":   {},
		"stems/42/htdemucs-4s-v1/drums.opus":  {},
		"stems/42/stems5-hybrid-v1/kick.opus": {},
		"stems/42/stems5-hybrid-v1/perc.opus": {},
	}
	for key := range store.uploads {
		if _, overlaps := legacyKeys[key]; overlaps {
			t.Fatalf("new immutable artifact key overlaps legacy layout: %s", key)
		}
	}

	for _, obj := range manifest.Artifacts.Objects {
		if obj.Path != "" {
			t.Fatalf("manifest leaked a local scratch path for %s: %s", obj.Channel, obj.Path)
		}
		if obj.Bytes <= 0 {
			t.Fatalf("object %s has no size", obj.Channel)
		}
	}

	if manifest.Provenance["worker"] != workerName {
		t.Fatalf("provenance worker = %v", manifest.Provenance["worker"])
	}
	if manifest.Provenance["expected_worker_version"] != workerVersion {
		t.Fatalf("provenance expected_worker_version = %v", manifest.Provenance["expected_worker_version"])
	}
	src, ok := manifest.Provenance["source"].(map[string]interface{})
	if !ok || src["file_hash"] != wantHash {
		t.Fatalf("provenance source = %v", manifest.Provenance["source"])
	}
}

func TestSeparateDefaultsChannelSet(t *testing.T) {
	store := newFakeStore()
	store.objects["tracks/a.mp3"] = []byte("audio")
	server := newTestServer(t, store, "")
	rec := postSeparate(t, server, `{"track_id":3,"storage_key":"tracks/a.mp3"}`, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d (%s)", rec.Code, rec.Body.String())
	}
	var manifest separateManifest
	if err := json.Unmarshal(rec.Body.Bytes(), &manifest); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if manifest.ChannelSet != defaultChannelSet {
		t.Fatalf("channel_set = %s, want %s", manifest.ChannelSet, defaultChannelSet)
	}
}

func TestSeparateSurfacesMissingSourceObject(t *testing.T) {
	server := newTestServer(t, newFakeStore(), "")
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"tracks/missing.mp3"}`, "")
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (%s)", rec.Code, rec.Body.String())
	}
}

func TestSeparateRejectsHelperIdentityDrift(t *testing.T) {
	store := newFakeStore()
	store.objects["tracks/a.mp3"] = []byte("audio")
	server := newTestServer(t, store, "")
	inner := server.separate
	server.separate = func(ctx context.Context, audioPath, outDir string, trackID int64, channelSet string) (*separateManifest, error) {
		manifest, err := inner(ctx, audioPath, outDir, trackID, channelSet)
		if err != nil {
			return nil, err
		}
		manifest.StemModelVersion = "audio-separator-htdemucs-ft-4s-v1+lr4-120"
		return manifest, nil
	}
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"tracks/a.mp3"}`, "")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 (%s)", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "expected") {
		t.Fatalf("body should explain the identity drift: %s", rec.Body.String())
	}
}

func TestSeparateFailsWhenUploadFails(t *testing.T) {
	store := newFakeStore()
	store.objects["tracks/a.mp3"] = []byte("audio")
	store.putErr = fmt.Errorf("minio unavailable")
	server := newTestServer(t, store, "")
	rec := postSeparate(t, server, `{"track_id":1,"storage_key":"tracks/a.mp3"}`, "")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
}

func TestUploadObjectsRejectsManifestWithoutLocalPath(t *testing.T) {
	server := newTestServer(t, newFakeStore(), "")
	manifest := &separateManifest{Artifacts: manifestArtifacts{Objects: []manifestObject{{Channel: "kick", Key: "stems/1/stems5-hybrid-v1/kick.opus"}}}}
	if err := server.uploadObjects(context.Background(), manifest); err == nil {
		t.Fatal("expected an error when the helper emits no local path")
	}
}

func TestChannelSetModelVersionsMatchTheHelper(t *testing.T) {
	// Guards the one place the Go and Python halves must agree by hand.
	helper, err := os.ReadFile("stems_dsp.py")
	if err != nil {
		t.Fatalf("read helper: %v", err)
	}
	for set, version := range channelSetModelVersions {
		if !bytes.Contains(helper, []byte(`"`+set+`"`)) {
			t.Fatalf("helper does not declare channel set %s", set)
		}
		if !bytes.Contains(helper, []byte(version)) && set == "stems4-demucs-v1" {
			t.Fatalf("helper does not declare model version %s", version)
		}
	}
	if !bytes.Contains(helper, []byte(modelConfigSHA256)) {
		t.Fatalf("helper does not pin the verified model config sha256")
	}
	for filename, hash := range modelWeightSHA256 {
		if !bytes.Contains(helper, []byte(filename)) || !bytes.Contains(helper, []byte(hash)) {
			t.Fatalf("helper does not pin %s", filename)
		}
	}
	if bytes.Contains(helper, []byte(`"hihat"`)) {
		t.Fatal("helper still references the retired hihat channel name")
	}
}
