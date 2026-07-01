package processor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/matcher"
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

func TestApplyDeterministicCleanupPorterRobinsonOfficialVideo(t *testing.T) {
	metadata := &TrackMetadata{
		Title:  "Porter Robinson - Cheerleader (Official Music Video)",
		Artist: "Porter RobinsonVEVO",
	}

	cleanup := applyDeterministicCleanup(metadata)

	if !cleanup.Applied {
		t.Fatalf("expected deterministic cleanup to apply")
	}
	if metadata.Artist != "Porter Robinson" || metadata.Title != "Cheerleader" {
		t.Fatalf("metadata = artist %q title %q, want Porter Robinson/Cheerleader", metadata.Artist, metadata.Title)
	}
	if cleanup.Method != "separator" || cleanup.Confidence <= 0 {
		t.Fatalf("cleanup = method %q confidence %v, want separator with confidence", cleanup.Method, cleanup.Confidence)
	}
}

func TestApplyDeterministicCleanupDoesNotUseUploaderWhenTitleIsWeak(t *testing.T) {
	metadata := &TrackMetadata{
		Title:    "Cheerleader (Official Music Video)",
		Artist:   "Porter RobinsonVEVO",
		Uploader: "Porter RobinsonVEVO",
	}

	cleanup := applyDeterministicCleanup(metadata)

	if cleanup.Applied {
		t.Fatalf("weak non-separator title should not rewrite provider metadata")
	}
	if metadata.Artist != "Porter RobinsonVEVO" || metadata.Title != "Cheerleader (Official Music Video)" {
		t.Fatalf("metadata changed on weak parse: artist %q title %q", metadata.Artist, metadata.Title)
	}
}

func TestMetadataProvenanceRetainsRawProviderAndCleanup(t *testing.T) {
	metadata := &TrackMetadata{
		Title:      "Madeon // All My Friends (Visualizer) [HD]",
		Artist:     "madeonofficial",
		Uploader:   "madeonofficial",
		DurationMs: 190000,
		SourceURL:  "https://youtu.be/example",
		SourceType: "youtube",
		Raw: map[string]interface{}{
			"title":         "Madeon // All My Friends (Visualizer) [HD]",
			"uploader":      "madeonofficial",
			"thumbnail_url": "https://img.example/front.jpg",
		},
	}
	cleanup := applyDeterministicCleanup(metadata)
	provenance := metadataProvenance(metadata, cleanup)

	var decoded map[string]interface{}
	if err := json.Unmarshal(provenance, &decoded); err != nil {
		t.Fatalf("provenance is invalid JSON: %v", err)
	}
	provider := decoded["raw_provider"].(map[string]interface{})
	if provider["title"] != "Madeon // All My Friends (Visualizer) [HD]" {
		t.Fatalf("raw provider title = %v", provider["title"])
	}
	deterministic := decoded["deterministic"].(map[string]interface{})
	if deterministic["artist"] != "Madeon" || deterministic["title"] != "All My Friends" || deterministic["applied"] != true {
		t.Fatalf("deterministic provenance = %#v", deterministic)
	}
}

func TestProviderMetadataSkipsOnlyEmptyStrings(t *testing.T) {
	metadata := &TrackMetadata{
		Title: "Fallback Title",
		Raw: map[string]interface{}{
			"title":         "",
			"thumbnail":     []interface{}{"https://img.example/front.jpg"},
			"thumbnail_url": map[string]interface{}{"url": "https://img.example/front.jpg"},
			"duration":      float64(180),
		},
	}

	provider := providerMetadata(metadata)
	if provider["title"] != "Fallback Title" {
		t.Fatalf("empty raw title should fall back to metadata title, got %#v", provider["title"])
	}
	if _, ok := provider["thumbnail"]; !ok {
		t.Fatalf("non-string thumbnail array was incorrectly skipped")
	}
	if _, ok := provider["thumbnail_url"]; !ok {
		t.Fatalf("non-string thumbnail_url object was incorrectly skipped")
	}
}

func TestFailedMBMatchUpdateLeavesIdentityAndRespectsUserEdits(t *testing.T) {
	update := failedMBMatchUpdate(errors.New("musicbrainz unavailable"))

	if update.MBVerified != nil || update.ApplyMBIdentity {
		t.Fatalf("failure fallback should not alter MB identity: %#v", update)
	}
	if !update.RespectUserEdits {
		t.Fatalf("automatic failure update must respect sticky user edits")
	}
	if update.MetadataStatus != "failed" {
		t.Fatalf("status = %q, want failed", update.MetadataStatus)
	}
}

func TestAutomaticMBMatchUpdateLowConfidenceLeavesIdentityUnchanged(t *testing.T) {
	output := &matcher.MatchOutput{
		Verified: false,
		BestMatch: &matcher.MatchResult{
			MBID:        "11111111-1111-1111-1111-111111111111",
			ArtistMBID:  "22222222-2222-2222-2222-222222222222",
			ReleaseID:   "33333333-3333-3333-3333-333333333333",
			Title:       "Suggested Title",
			Artist:      "Suggested Artist",
			Confidence:  0.63,
			CoverArtURL: "https://coverartarchive.org/release/33333333-3333-3333-3333-333333333333/front-250",
		},
		Suggestions: []matcher.MatchResult{
			{MBID: "11111111-1111-1111-1111-111111111111", Title: "Suggested Title", Artist: "Suggested Artist", Confidence: 0.63},
		},
	}

	update := automaticMBMatchUpdate(output)
	if update.MBVerified != nil || update.ApplyMBIdentity || update.MBRecordingID != nil || update.MBArtistID != nil || update.MBReleaseID != nil {
		t.Fatalf("low-confidence suggestion should not alter MB identity: %#v", update)
	}
	if !update.RespectUserEdits {
		t.Fatalf("automatic suggestion update must respect sticky user edits")
	}
	if update.MetadataStatus != "suggested" || update.MetadataJSON == nil {
		t.Fatalf("low-confidence suggestion metadata not persisted correctly: status=%q json=%s", update.MetadataStatus, string(update.MetadataJSON))
	}
}

func TestAutomaticMBMatchUpdateNoMatchLeavesIdentityUnchanged(t *testing.T) {
	update := automaticMBMatchUpdate(&matcher.MatchOutput{Verified: false})

	if update.MBVerified != nil || update.ApplyMBIdentity || update.MBRecordingID != nil || update.MBArtistID != nil || update.MBReleaseID != nil {
		t.Fatalf("no-match fallback should not alter MB identity: %#v", update)
	}
	if !update.RespectUserEdits {
		t.Fatalf("automatic no-match update must respect sticky user edits")
	}
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
