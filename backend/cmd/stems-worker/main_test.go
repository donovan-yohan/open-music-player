package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	return func(_ context.Context, _, outDir string, trackID int64, channelSet string) (*separateManifest, error) {
		channels := []struct {
			name       string
			key        string
			derivation string
		}{
			{"vocals", fmt.Sprintf("stems/%d/htdemucs-4s-v1/vocals.opus", trackID), "separator"},
			{"melody", fmt.Sprintf("stems/%d/htdemucs-4s-v1/other.opus", trackID), "separator"},
			{"bass", fmt.Sprintf("stems/%d/htdemucs-4s-v1/bass.opus", trackID), "separator"},
			{"kick", fmt.Sprintf("stems/%d/stems5-hybrid-v1/kick.opus", trackID), "dsp-crossover-lr4-180"},
			{"perc", fmt.Sprintf("stems/%d/stems5-hybrid-v1/perc.opus", trackID), "dsp-crossover-lr4-180"},
			{"drums", fmt.Sprintf("stems/%d/htdemucs-4s-v1/drums.opus", trackID), "separator"},
		}
		objects := make([]manifestObject, 0, len(channels))
		for _, channel := range channels {
			local := filepath.Join(outDir, strings.ReplaceAll(channel.key, "/", "__"))
			payload := []byte("opus-" + channel.name)
			if err := os.WriteFile(local, payload, 0o600); err != nil {
				return nil, err
			}
			objects = append(objects, manifestObject{
				Channel:    channel.name,
				Key:        channel.key,
				Path:       local,
				Bytes:      int64(len(payload)),
				DurationMs: 210000,
				Derivation: channel.derivation,
			})
		}
		return &separateManifest{
			SchemaVersion:    1,
			TrackID:          trackID,
			ChannelSet:       channelSet,
			StemModelVersion: channelSetModelVersions[channelSet],
			DurationMs:       210000,
			SampleRateHz:     44100,
			Artifacts: manifestArtifacts{
				Objects: objects,
				Codec:   json.RawMessage(`{"name":"libopus","bitrate_kbps":128,"sample_rate_hz":48000}`),
				NullSum: json.RawMessage(`{"pair":["kick","perc"],"against":"drums","residual_db":-120.4,"threshold_db":-80.0,"passed":true}`),
				Energy:  json.RawMessage(`{"frame_hz":80,"frame_count":4,"encoding":"uint8-linear","channels":{"vocals":"AAAA"}}`),
			},
			Provenance: map[string]interface{}{"demucs_version": demucsVersion},
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
	if payload["stem_model_version"] != "htdemucs-4s-v1+lr4-180" {
		t.Fatalf("stem_model_version = %v", payload["stem_model_version"])
	}
	if payload["checkpoint_sha256"] != "d9fa14133cfcc034a6758923bb3a8ca9f8dfd0b582134643bbf83f72c17576dd" {
		t.Fatalf("checkpoint sha mismatch: %v", payload["checkpoint_sha256"])
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
	if manifest.StemModelVersion != "htdemucs-4s-v1+lr4-180" {
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
	for _, key := range []string{
		"stems/42/htdemucs-4s-v1/vocals.opus",
		"stems/42/htdemucs-4s-v1/other.opus",
		"stems/42/htdemucs-4s-v1/bass.opus",
		"stems/42/htdemucs-4s-v1/drums.opus",
		"stems/42/stems5-hybrid-v1/kick.opus",
		"stems/42/stems5-hybrid-v1/perc.opus",
	} {
		if _, ok := store.uploads[key]; !ok {
			t.Fatalf("missing upload %s (have %v)", key, store.putOrder)
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
		manifest.StemModelVersion = "htdemucs-4s-v1+lr4-120"
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
	if !bytes.Contains(helper, []byte(checkpointSHA256)) {
		t.Fatalf("helper does not pin the verified checkpoint sha256")
	}
	if bytes.Contains(helper, []byte(`"hihat"`)) {
		t.Fatal("helper still references the retired hihat channel name")
	}
}
