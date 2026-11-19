package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/preview"
)

const previewPath = "/api/v1/discovery/preview"
const previewSource = "https://www.youtube.com/watch?v=SQPreview01"
const previewSoundCloud = "https://soundcloud.com/sq-fixture/generated-preview"

//go:embed testdata/discover-preview-48000.mp3
var previewStereo []byte

//go:embed testdata/discover-preview-44100.mp3
var previewMono []byte

func previewRouterConfig(t *testing.T) (RouterConfig, string) {
	t.Helper()
	const secret = "generated-preview-test-secret"
	service := auth.NewService(nil, nil, secret)
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{
		UserID: uuid.NewString(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))},
	}).SignedString([]byte(secret))
	if err != nil {
		t.Fatal(err)
	}
	return RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, ResponseTransforms: true}, token
}

func TestDiscoveryPreviewAuthAndDisabled(t *testing.T) {
	cfg, token := previewRouterConfig(t)
	server := httptest.NewServer(NewRouterWithConfig(&cfg))
	defer server.Close()
	server.Client().Timeout = 5 * time.Second
	for _, tc := range []struct {
		name, token string
		status      int
	}{
		{"no bearer", "", http.StatusUnauthorized},
		{"invalid bearer", "invalid", http.StatusUnauthorized},
		{"no manifest", token, http.StatusNotFound},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := doPreview(t, server.Client(), server.URL, tc.token, `{"url":"`+previewSource+`"}`)
			defer res.Body.Close()
			if res.StatusCode != tc.status || res.Header.Get("Cache-Control") != "private, no-store" {
				t.Fatalf("status %d cache policy %q; want %d, private, no-store", res.StatusCode, res.Header.Get("Cache-Control"), tc.status)
			}
		})
	}
}

func doPreview(t *testing.T, client *http.Client, base, token, body string) *http.Response {
	t.Helper()
	res, err := requestPreview(t.Context(), client, base+previewPath, token, body)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func requestPreview(ctx context.Context, client *http.Client, endpoint, token, body string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept-Encoding", "gzip") // Explicit: client will not transparently decompress.
	return client.Do(req)
}

func previewBody(key string) string {
	return `{"url":` + strconv.Quote(key) + `}`
}

func previewManifestRow(key, file string, data []byte, rate, frames int) map[string]any {
	return map[string]any{
		"url": key, "file": file, "length": len(data), "sha256": fmt.Sprintf("%x", sha256.Sum256(data)),
		"sampleRate": rate, "frames": frames, "excerptStartFrames": 0,
		"rightsRef": "synthesized sine for SoundQ tests only", "attribution": "SoundQ fixture",
		"expiresAt": time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
	}
}

func writePreviewFiles(t *testing.T, dir string, files map[string][]byte) {
	t.Helper()
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o400); err != nil {
			t.Fatal(err)
		}
	}
}

func previewManifest(t *testing.T, rows ...map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(rows)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func mountPreview(t *testing.T) (RouterConfig, string) {
	t.Helper()
	dir := t.TempDir()
	files := map[string][]byte{
		"stereo.mp3": previewStereo, "mono.mp3": previewMono,
		"manifest.json": previewManifest(t,
			previewManifestRow(previewSource, "stereo.mp3", previewStereo, 48000, 36000),
			previewManifestRow(previewSoundCloud, "mono.mp3", previewMono, 44100, 11025)),
	}
	writePreviewFiles(t, dir, files)
	t.Cleanup(func() {
		entries, err := os.ReadDir(dir)
		if err != nil || len(entries) != len(files) {
			t.Errorf("preview changed directory inventory: %d, %v", len(entries), err)
			return
		}
		for _, ent := range entries {
			info, statErr := ent.Info()
			got, readErr := os.ReadFile(filepath.Join(dir, ent.Name()))
			if statErr != nil || readErr != nil || info.Mode() != 0o400 || !bytes.Equal(got, files[ent.Name()]) {
				t.Errorf("preview changed file bytes or mode: %s", ent.Name())
			}
		}
	})
	catalog, err := preview.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	// DB, cache, Library, downloader and queue are intentionally unwired. The
	// positive response must work without access to any mutation dependency.
	cfg, token := previewRouterConfig(t)
	cfg.DiscoveryPreview = catalog
	return cfg, token
}

func assertPreviewHeaders(t *testing.T, res *http.Response, length, rate, frames int) {
	t.Helper()
	if res.StatusCode != http.StatusOK {
		text, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		t.Fatalf("preview status %d: %s", res.StatusCode, text)
	}
	for k, want := range map[string]string{
		"Content-Type": "audio/mpeg", "Content-Length": strconv.Itoa(length), "Content-Encoding": "",
		"Cache-Control": "private, no-store", "X-SoundQ-Preview-Sample-Rate": strconv.Itoa(rate),
		"X-SoundQ-Preview-Frames": strconv.Itoa(frames), "ETag": "",
	} {
		if got := res.Header.Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
	if res.ContentLength != int64(length) || len(res.TransferEncoding) != 0 {
		t.Fatalf("invalid length/transfer encoding: %d %v", res.ContentLength, res.TransferEncoding)
	}
}

func assertPreviewError(t *testing.T, res *http.Response, status int) {
	t.Helper()
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 512))
	if err != nil || res.StatusCode != status || res.Header.Get("Cache-Control") != "private, no-store" ||
		res.Header.Get("X-SoundQ-Preview-Frames") != "" || res.Header.Get("X-SoundQ-Preview-Sample-Rate") != "" ||
		!strings.HasPrefix(res.Header.Get("Content-Type"), "text/plain") {
		t.Fatalf("unexpected refusal: status=%d body=%q err=%v headers=%v", res.StatusCode, body, err, res.Header)
	}
	if status == http.StatusNotFound && string(body) != "preview unavailable\n" {
		t.Fatalf("unsafe 404 body: %q", body)
	}
	if status == http.StatusBadRequest && string(body) != "invalid preview request\n" {
		t.Fatalf("unsafe 400 body: %q", body)
	}
}

func TestDiscoveryPreviewExactSourcesAndNoWrites(t *testing.T) {
	cfg, token := mountPreview(t)
	server := httptest.NewServer(NewRouterWithConfig(&cfg))
	defer server.Close()
	client := server.Client()
	client.Timeout = 5 * time.Second
	for _, tc := range []struct {
		name, key    string
		data         []byte
		rate, frames int
	}{
		{"youtube stereo", previewSource, previewStereo, 48000, 36000},
		{"soundcloud mono", previewSoundCloud, previewMono, 44100, 11025},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := doPreview(t, client, server.URL, token, previewBody(tc.key))
			defer res.Body.Close()
			assertPreviewHeaders(t, res, len(tc.data), tc.rate, tc.frames)
			got, err := io.ReadAll(res.Body)
			if err != nil || !bytes.Equal(got, tc.data) {
				t.Fatalf("wire bytes differ: %d, %v", len(got), err)
			}
		})
	}
	for _, tc := range []struct{ name, key string }{
		{"unknown exact identity", "https://www.youtube.com/watch?v=SQPreview02"},
		{"short alias", "https://youtu.be/SQPreview01"},
		{"different music host", strings.Replace(previewSource, "www.", "music.", 1)},
		{"extra query", previewSource + "&t=0"},
		{"whitespace", " " + previewSource},
		{"case changed", strings.Replace(previewSource, "www.", "WWW.", 1)},
		{"filesystem path", "stereo.mp3"},
		{"network probe", "http://127.0.0.1/private"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			assertPreviewError(t, doPreview(t, client, server.URL, token, previewBody(tc.key)), http.StatusNotFound)
		})
	}
	assertPreviewError(t, doPreview(t, client, server.URL, "", previewBody(previewSource)), http.StatusUnauthorized)
	for _, body := range []string{
		`{"URL":"` + previewSource + `"}`, `{"url":null}`, `{}`, `[]`,
		`{"url":"` + previewSource + `","url":"` + previewSource + `"}`,
		previewBody(previewSource) + ` {}`, previewBody(previewSource) + strings.Repeat(" ", 8192),
		`{"url":"` + previewSource + `","file":"stereo.mp3"}`,
	} {
		assertPreviewError(t, doPreview(t, client, server.URL, token, body), http.StatusBadRequest)
	}
}

func TestDiscoveryPreviewInvalidManifestDisablesEntireAllowlist(t *testing.T) {
	for _, tc := range []struct {
		name, field string
		value       any
	}{
		{"duplicate identity", "url", previewSource}, {"provider alias", "url", "https://youtu.be/SQPreview01"},
		{"credentials", "url", "https://key@www.youtube.com/watch?v=SQPreview01"},
		{"playlist", "url", "https://soundcloud.com/artist/sets/playlist"},
		{"popular tracks profile page", "url", "https://soundcloud.com/artist/popular-tracks"},
		{"case varied profile page", "url", "https://soundcloud.com/artist/Popular-Tracks"},
		{"provider page", "url", "https://soundcloud.com/pages/privacy"},
		{"escape path", "file", "../mono.mp3"}, {"absolute path", "file", "/mono.mp3"},
		{"remote path", "file", "https://bad.example/mono.mp3"}, {"unknown field", "other", "value"},
		{"unsupported sample rate", "sampleRate", 32000}, {"too many frames", "frames", 44100*30 + 1},
		{"zero frames", "frames", 0}, {"oversized clip", "length", 2097153}, {"invalid digest", "sha256", "secret-invalid-value"},
		{"blank rights", "rightsRef", "  "}, {"missing clearance expiry", "expiresAt", nil}, {"null offset", "excerptStartFrames", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			invalid := previewManifestRow(previewSoundCloud, "mono.mp3", previewMono, 44100, 11025)
			invalid[tc.field] = tc.value
			good := previewManifestRow(previewSource, "stereo.mp3", previewStereo, 48000, 36000)
			writePreviewFiles(t, dir, map[string][]byte{
				"manifest.json": previewManifest(t, good, invalid), "stereo.mp3": previewStereo,
			})
			catalog, err := preview.Load(dir)
			if err == nil || catalog != nil || err.Error() != "invalid preview manifest entry 2" {
				t.Fatalf("invalid manifest not safely rejected: catalog nil=%v err=%v", catalog == nil, err)
			}
			cfg, token := previewRouterConfig(t)
			cfg.DiscoveryPreview = catalog
			server := httptest.NewServer(NewRouterWithConfig(&cfg))
			defer server.Close()
			server.Client().Timeout = 5 * time.Second
			assertPreviewError(t, doPreview(t, server.Client(), server.URL, token, previewBody(previewSource)), http.StatusNotFound)
		})
	}
}

func TestDiscoveryPreviewInvalidMediaNeverCommits200(t *testing.T) {
	for _, name := range []string{"missing", "wrong length", "wrong digest", "wrong sample rate", "wrong frames", "bad tail with matching digest", "expired", "symlink", "fifo"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			data := bytes.Clone(previewStereo)
			row := previewManifestRow(previewSource, "test.mp3", data, 48000, 36000)
			switch name {
			case "wrong length":
				data = data[:len(data)-1]
			case "wrong digest":
				data[len(data)-1] ^= 1
			case "wrong sample rate":
				row["sampleRate"] = 44100
			case "wrong frames":
				row["frames"] = 36001
			case "bad tail with matching digest":
				data[len(data)-384] = 0 // First sync byte of last 48 kHz, 128 kbps packet.
				row["sha256"] = fmt.Sprintf("%x", sha256.Sum256(data))
			case "expired":
				row["expiresAt"] = "2000-01-01T00:00:00Z"
			}
			writePreviewFiles(t, dir, map[string][]byte{"manifest.json": previewManifest(t, row)})
			catalog, err := preview.Load(dir)
			if err != nil {
				t.Fatal(err)
			}
			filename := filepath.Join(dir, "test.mp3")
			switch name {
			case "missing":
			case "symlink":
				outside := t.TempDir()
				writePreviewFiles(t, outside, map[string][]byte{"target.mp3": data})
				if err := os.Symlink(filepath.Join(outside, "target.mp3"), filename); err != nil {
					t.Fatal(err)
				}
			case "fifo":
				if err := syscall.Mkfifo(filename, 0o600); err != nil {
					t.Fatal(err)
				}
			default:
				writePreviewFiles(t, dir, map[string][]byte{"test.mp3": data})
			}
			cfg, token := previewRouterConfig(t)
			cfg.DiscoveryPreview = catalog
			server := httptest.NewServer(NewRouterWithConfig(&cfg))
			defer server.Close()
			server.Client().Timeout = 5 * time.Second
			assertPreviewError(t, doPreview(t, server.Client(), server.URL, token, previewBody(previewSource)), http.StatusNotFound)
		})
	}
}
