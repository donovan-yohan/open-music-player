package processor

import (
	"bytes"
	"context"
	"io"
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
