package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strconv"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/storage"
	"github.com/openmusicplayer/backend/internal/testutil"
)

type qualityContractStorage struct {
	objects      map[string][]byte
	contentTypes map[string]string
}

func (s *qualityContractStorage) PutObject(_ context.Context, key string, reader io.Reader, _ int64, contentType string) error {
	data, err := io.ReadAll(reader)
	if err != nil {
		return err
	}
	s.objects[key] = data
	s.contentTypes[key] = contentType
	return nil
}

func (s *qualityContractStorage) GetObject(_ context.Context, key string) (io.ReadCloser, *storage.ObjectInfo, error) {
	data, ok := s.objects[key]
	if !ok {
		return nil, nil, os.ErrNotExist
	}
	return io.NopCloser(bytes.NewReader(data)), &storage.ObjectInfo{
		Size:        int64(len(data)),
		ContentType: s.contentTypes[key],
	}, nil
}

type contractProbe struct {
	Streams []struct {
		CodecName  string `json:"codec_name"`
		BitRate    string `json:"bit_rate"`
		SampleRate string `json:"sample_rate"`
		Channels   int    `json:"channels"`
	} `json:"streams"`
	Format struct {
		BitRate string `json:"bit_rate"`
	} `json:"format"`
}

func ffprobeContractObject(t *testing.T, data []byte) (codec string, bitrateKbps, sampleRateHz, channels int) {
	t.Helper()
	file, err := os.CreateTemp("", "omp-quality-contract-*.wav")
	if err != nil {
		t.Fatalf("create ffprobe input: %v", err)
	}
	path := file.Name()
	t.Cleanup(func() { _ = os.Remove(path) })
	if _, err := file.Write(data); err != nil {
		t.Fatalf("write ffprobe input: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close ffprobe input: %v", err)
	}
	output, err := exec.Command(
		"ffprobe",
		"-v", "error",
		"-select_streams", "a:0",
		"-show_entries", "stream=codec_name,bit_rate,sample_rate,channels:format=bit_rate",
		"-of", "json",
		path,
	).Output()
	if err != nil {
		t.Fatalf("ffprobe stored object: %v", err)
	}
	var probe contractProbe
	if err := json.Unmarshal(output, &probe); err != nil {
		t.Fatalf("decode ffprobe output: %v", err)
	}
	if len(probe.Streams) != 1 {
		t.Fatalf("ffprobe streams = %d, want 1", len(probe.Streams))
	}
	stream := probe.Streams[0]
	sampleRateHz, _ = strconv.Atoi(stream.SampleRate)
	bitRate, _ := strconv.ParseInt(stream.BitRate, 10, 64)
	if bitRate <= 0 {
		bitRate, _ = strconv.ParseInt(probe.Format.BitRate, 10, 64)
	}
	return stream.CodecName, int((bitRate + 500) / 1000), sampleRateHz, stream.Channels
}

func newAudioQualityContractDB(t *testing.T) *db.DB {
	t.Helper()
	dsn := testutil.PostgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run audio quality API contract integration test")
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open Postgres: %v", err)
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &db.DB{DB: raw}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping Postgres: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate Postgres: %v", err)
	}
	if _, err := database.Exec(`TRUNCATE TABLE users, tracks RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate contract tables: %v", err)
	}
	return database
}

func qualityLibraryResponse(t *testing.T, handler *LibraryHandlers, userID uuid.UUID) struct {
	Tracks []struct {
		ID            int64  `json:"id"`
		SourceURL     string `json:"source_url"`
		FileSizeBytes int64  `json:"file_size_bytes"`
		Codec         string `json:"codec"`
		BitrateKbps   int    `json:"bitrate_kbps"`
		SampleRateHz  int    `json:"sample_rate_hz"`
		Channels      int    `json:"channels"`
		ContentType   string `json:"content_type"`
	} `json:"tracks"`
} {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/library", nil)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: userID,
		Email:  "quality-contract@example.test",
	}))
	rec := httptest.NewRecorder()
	handler.GetLibrary(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET library status = %d; body=%s", rec.Code, rec.Body.String())
	}
	var response struct {
		Tracks []struct {
			ID            int64  `json:"id"`
			SourceURL     string `json:"source_url"`
			FileSizeBytes int64  `json:"file_size_bytes"`
			Codec         string `json:"codec"`
			BitrateKbps   int    `json:"bitrate_kbps"`
			SampleRateHz  int    `json:"sample_rate_hz"`
			Channels      int    `json:"channels"`
			ContentType   string `json:"content_type"`
		} `json:"tracks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode library response: %v", err)
	}
	return response
}

func qualityMaintenanceRequest(t *testing.T, handler *MaintenanceHandlers, userID uuid.UUID, limit int) maintenanceRepairResponse {
	t.Helper()
	body := bytes.NewBufferString(`{"metadata":false,"analysis":false,"audioQuality":true,"limit":` + strconv.Itoa(limit) + `}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/maintenance/repair", body)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: userID,
		Email:  "quality-contract@example.test",
	}))
	rec := httptest.NewRecorder()
	handler.RepairTracks(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST maintenance status = %d; body=%s", rec.Code, rec.Body.String())
	}
	var response maintenanceRepairResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode maintenance response: %v", err)
	}
	return response
}

func TestIngestAndBackfillExposeStoredObjectFFprobeFactsThroughLibraryAPI(t *testing.T) {
	database := newAudioQualityContractDB(t)
	ctx := context.Background()
	userID := uuid.New()
	if _, err := database.ExecContext(ctx,
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, 'quality', 'x')`,
		userID, "quality-contract@example.test",
	); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	objectStore := &qualityContractStorage{
		objects:      make(map[string][]byte),
		contentTypes: make(map[string]string),
	}
	jobProcessor := processor.New(&processor.ProcessorConfig{
		TrackRepo:   trackRepo,
		LibraryRepo: libraryRepo,
		Storage:     objectStore,
	})
	job := &download.DownloadJob{
		ID:         "quality-contract",
		UserID:     userID.String(),
		URL:        "fixture://quality-contract",
		SourceType: "fixture",
		Title:      "Quality Contract",
	}
	if err := jobProcessor.Process(ctx, job, func(int) {}); err != nil {
		t.Fatalf("ingest fixture: %v", err)
	}
	if job.TrackID == nil {
		t.Fatal("ingest did not associate a track")
	}
	stored := objectStore.objects["tracks/fixture/quality-contract.wav"]
	codec, bitrateKbps, sampleRateHz, channels := ffprobeContractObject(t, stored)

	libraryHandler := NewLibraryHandlers(trackRepo, libraryRepo)
	assertContract := func(stage string) {
		t.Helper()
		response := qualityLibraryResponse(t, libraryHandler, userID)
		if len(response.Tracks) != 1 {
			t.Fatalf("%s library tracks = %d, want 1", stage, len(response.Tracks))
		}
		got := response.Tracks[0]
		if got.ID != *job.TrackID ||
			got.SourceURL != "fixture://quality-contract" ||
			got.FileSizeBytes != int64(len(stored)) ||
			got.Codec != codec ||
			got.BitrateKbps != bitrateKbps ||
			got.SampleRateHz != sampleRateHz ||
			got.Channels != channels ||
			got.ContentType != "audio/wav" {
			t.Fatalf("%s library artifact facts = %+v; ffprobe=%s/%d/%d/%d size=%d",
				stage, got, codec, bitrateKbps, sampleRateHz, channels, len(stored))
		}
	}
	assertContract("ingest")

	if _, err := database.ExecContext(ctx, `
		UPDATE tracks
		SET codec = NULL, bitrate_kbps = NULL, sample_rate_hz = NULL,
			channels = NULL, content_type = NULL
		WHERE id = $1
	`, *job.TrackID); err != nil {
		t.Fatalf("clear artifact facts for backfill: %v", err)
	}
	maintenance := NewMaintenanceHandlers(trackRepo, jobProcessor)
	first := qualityMaintenanceRequest(t, maintenance, userID, 1)
	if first.Summary.Selected != 1 || first.Summary.AudioQualityDone != 1 || first.Summary.Errors != 0 {
		t.Fatalf("backfill summary = %+v, want one successful repair", first.Summary)
	}
	assertContract("backfill")

	second := qualityMaintenanceRequest(t, maintenance, userID, 1)
	if second.Summary.Selected != 0 {
		t.Fatalf("idempotent backfill selected %d rows, want 0", second.Summary.Selected)
	}

	corrupt, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Artist", "Corrupt Artifact", "", 1000,
		db.WithStorage("tracks/fixture/corrupt.wav", 9))
	if err != nil {
		t.Fatalf("create corrupt candidate: %v", err)
	}
	objectStore.objects["tracks/fixture/corrupt.wav"] = []byte("not audio")
	objectStore.contentTypes["tracks/fixture/corrupt.wav"] = "audio/wav"
	failed := qualityMaintenanceRequest(t, maintenance, userID, 1)
	if failed.Summary.Selected != 1 || failed.Summary.Errors != 1 || failed.Tracks[0].TrackID != corrupt.ID {
		t.Fatalf("nonfatal corrupt-object result = %+v", failed)
	}
	if failed.Tracks[0].AudioQuality != nil {
		t.Fatalf("failed repair emitted empty audioQuality result: %+v", failed.Tracks[0].AudioQuality)
	}

	valid, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Artist", "Later Valid Artifact", "", 1000,
		db.WithStorage("tracks/fixture/later.wav", int64(len(stored))))
	if err != nil {
		t.Fatalf("create later candidate: %v", err)
	}
	objectStore.objects["tracks/fixture/later.wav"] = stored
	objectStore.contentTypes["tracks/fixture/later.wav"] = "audio/wav"
	resumed := qualityMaintenanceRequest(t, maintenance, userID, 1)
	if resumed.Summary.AudioQualityDone != 1 || len(resumed.Tracks) != 1 || resumed.Tracks[0].TrackID != valid.ID {
		t.Fatalf("resumed bounded backfill = %+v, want later valid track %d", resumed, valid.ID)
	}
}

func TestIngestQualityContractAgainstRealMinIO(t *testing.T) {
	endpoint := os.Getenv("OMP_MINIO_TEST_ENDPOINT")
	if endpoint == "" {
		t.Skip("set OMP_MINIO_TEST_ENDPOINT to run real MinIO quality contract")
	}
	database := newAudioQualityContractDB(t)
	ctx := context.Background()
	userID := uuid.New()
	email := "quality-minio-" + userID.String() + "@example.test"
	if _, err := database.ExecContext(ctx,
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, 'quality-minio', 'x')`,
		userID, email,
	); err != nil {
		t.Fatalf("seed MinIO contract user: %v", err)
	}
	minioClient, err := storage.New(&storage.Config{
		Endpoint:  endpoint,
		AccessKey: "minioadmin",
		SecretKey: "minioadmin",
		Bucket:    "audio-files",
	})
	if err != nil {
		t.Fatalf("create MinIO client: %v", err)
	}
	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	jobID := "quality-minio-" + uuid.NewString()
	key := "tracks/fixture/" + jobID + ".wav"
	t.Cleanup(func() { _ = minioClient.DeleteObject(context.Background(), key) })
	jobProcessor := processor.New(&processor.ProcessorConfig{
		TrackRepo:   trackRepo,
		LibraryRepo: libraryRepo,
		Storage:     minioClient,
	})
	job := &download.DownloadJob{
		ID:         jobID,
		UserID:     userID.String(),
		URL:        "fixture://quality-minio",
		SourceType: "fixture",
		Title:      "Quality MinIO Contract",
	}
	if err := jobProcessor.Process(ctx, job, func(int) {}); err != nil {
		t.Fatalf("ingest fixture through MinIO: %v", err)
	}
	reader, info, err := minioClient.GetObject(ctx, key)
	if err != nil {
		t.Fatalf("read stored MinIO object: %v", err)
	}
	stored, err := io.ReadAll(reader)
	_ = reader.Close()
	if err != nil {
		t.Fatalf("read MinIO bytes: %v", err)
	}
	codec, bitrateKbps, sampleRateHz, channels := ffprobeContractObject(t, stored)
	response := qualityLibraryResponse(t, NewLibraryHandlers(trackRepo, libraryRepo), userID)
	if len(response.Tracks) != 1 {
		t.Fatalf("MinIO library tracks = %d, want 1", len(response.Tracks))
	}
	got := response.Tracks[0]
	if got.SourceURL != "fixture://quality-minio" ||
		got.FileSizeBytes != info.Size ||
		got.Codec != codec ||
		got.BitrateKbps != bitrateKbps ||
		got.SampleRateHz != sampleRateHz ||
		got.Channels != channels ||
		got.ContentType != "audio/wav" {
		t.Fatalf("MinIO API facts = %+v; ffprobe=%s/%d/%d/%d object=%+v",
			got, codec, bitrateKbps, sampleRateHz, channels, info)
	}
}
