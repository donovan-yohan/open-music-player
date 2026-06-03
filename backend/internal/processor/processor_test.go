package processor

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/download"
)

type fakeObjectStorage struct {
	key         string
	contentType string
	data        []byte
}

func (s *fakeObjectStorage) PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error {
	s.key = key
	s.contentType = contentType
	s.data, _ = io.ReadAll(reader)
	return nil
}

func TestDownloadAndStoreFixtureCreatesPlayableWAVObject(t *testing.T) {
	storage := &fakeObjectStorage{}
	processor := &Processor{storage: storage}
	job := &download.DownloadJob{
		ID:         "job-fixture",
		UserID:     "00000000-0000-0000-0000-000000000001",
		URL:        "fixture://silence",
		SourceType: "fixture",
		Title:      "Fixture Silence",
	}

	metadata, err := processor.downloadAndStore(context.Background(), job)
	if err != nil {
		t.Fatalf("downloadAndStore failed: %v", err)
	}
	if metadata.StorageKey != "tracks/fixture/job-fixture.wav" {
		t.Fatalf("unexpected storage key %q", metadata.StorageKey)
	}
	if metadata.FileSizeBytes <= 44 {
		t.Fatalf("expected wav payload bigger than header, got %d", metadata.FileSizeBytes)
	}
	if storage.contentType != "audio/wav" {
		t.Fatalf("expected audio/wav, got %s", storage.contentType)
	}
	if !bytes.HasPrefix(storage.data, []byte("RIFF")) || !bytes.Contains(storage.data[:16], []byte("WAVE")) {
		t.Fatalf("uploaded object is not a RIFF/WAVE fixture")
	}
}

func TestRunYTDLPCleansTempDirAfterSuccess(t *testing.T) {
	before := snapshotYTDLPTempDirs(t)
	fakeYTDLP := writeFakeYTDLP(t, `
set -eu
out=""
max=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  if [ "$prev" = "--max-filesize" ]; then max="$arg"; fi
  prev="$arg"
done
[ -n "$out" ]
[ "$max" = "268435456" ]
audio="${out%.*}.mp3"
printf 'fake mp3 data' > "$audio"
printf '{"title":"Downloaded Title","duration":2}' > "${out%.*}.info.json"
`)
	metadata := &TrackMetadata{}

	path, contentType, err := runYTDLPCommand(context.Background(), fakeYTDLP, "https://example.test/watch?v=1", metadata, maxYTDLPOutputBytes)
	if err != nil {
		t.Fatalf("runYTDLPCommand failed: %v", err)
	}
	defer os.Remove(path)

	if contentType != "audio/mpeg" {
		t.Fatalf("content type = %q, want audio/mpeg", contentType)
	}
	if metadata.Title != "Downloaded Title" || metadata.DurationMs != 2000 {
		t.Fatalf("metadata = title %q duration %d, want Downloaded Title/2000", metadata.Title, metadata.DurationMs)
	}
	if leaked := newYTDLPTempDirs(t, before); len(leaked) > 0 {
		t.Fatalf("yt-dlp temp dirs leaked after success: %v", leaked)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("returned copied audio missing: %v", err)
	}
}

func TestRunYTDLPRejectsOversizeOutputAndCleansTempDir(t *testing.T) {
	before := snapshotYTDLPTempDirs(t)
	fakeYTDLP := writeFakeYTDLP(t, `
set -eu
out=""
max=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  if [ "$prev" = "--max-filesize" ]; then max="$arg"; fi
  prev="$arg"
done
[ -n "$out" ]
[ "$max" = "8" ]
audio="${out%.*}.mp3"
head -c 32 /dev/zero > "$audio"
`)

	path, _, err := runYTDLPCommand(context.Background(), fakeYTDLP, "https://example.test/watch?v=oversize", &TrackMetadata{}, 8)
	if err == nil {
		os.Remove(path)
		t.Fatalf("runYTDLPCommand oversize succeeded with path %q", path)
	}
	if !strings.Contains(err.Error(), "too large") {
		t.Fatalf("oversize error = %v, want too large", err)
	}
	if leaked := newYTDLPTempDirs(t, before); len(leaked) > 0 {
		t.Fatalf("yt-dlp temp dirs leaked after oversize: %v", leaked)
	}
}

func TestRunYTDLPCleansTempDirAfterCommandFailure(t *testing.T) {
	before := snapshotYTDLPTempDirs(t)
	fakeYTDLP := writeFakeYTDLP(t, `
set -eu
printf 'nope' >&2
exit 7
`)

	_, _, err := runYTDLPCommand(context.Background(), fakeYTDLP, "https://example.test/watch?v=fail", &TrackMetadata{}, maxYTDLPOutputBytes)
	if err == nil {
		t.Fatalf("runYTDLPCommand failure succeeded")
	}
	if leaked := newYTDLPTempDirs(t, before); len(leaked) > 0 {
		t.Fatalf("yt-dlp temp dirs leaked after failure: %v", leaked)
	}
}

func writeFakeYTDLP(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "yt-dlp-fake")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatalf("write fake yt-dlp: %v", err)
	}
	return path
}

func snapshotYTDLPTempDirs(t *testing.T) map[string]struct{} {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(os.TempDir(), "omp-ytdlp-*"))
	if err != nil {
		t.Fatalf("glob temp dirs: %v", err)
	}
	seen := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		seen[match] = struct{}{}
	}
	return seen
}

func newYTDLPTempDirs(t *testing.T, before map[string]struct{}) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(os.TempDir(), "omp-ytdlp-*"))
	if err != nil {
		t.Fatalf("glob temp dirs: %v", err)
	}
	var leaked []string
	for _, match := range matches {
		if _, ok := before[match]; !ok {
			leaked = append(leaked, match)
		}
	}
	return leaked
}
