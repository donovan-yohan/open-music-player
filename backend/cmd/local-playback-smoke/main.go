package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

const (
	defaultSmokeUserEmail = "lowmem-playback-smoke@openmusicplayer.local"
	defaultSmokePassword  = "lowmem-smoke-password"
	defaultSmokeUsername  = "lowmem-smoke"
	defaultStorageKey     = "smoke/local-minio-playback-fixture.wav"
)

type smokeConfig struct {
	backendBaseURL      string
	dbHost              string
	dbPort              string
	dbUser              string
	dbPassword          string
	dbName              string
	minioEndpoint       string
	minioPublicEndpoint string
	minioAccessKey      string
	minioSecretKey      string
	minioBucket         string
	minioRegion         string
	minioUseSSL         bool
	userEmail           string
	userPassword        string
	username            string
	storageKey          string
	timeout             time.Duration
}

type playbackURLResponse struct {
	URLs        []playbackURLItem         `json:"urls"`
	Unavailable []playbackUnavailableItem `json:"unavailable,omitempty"`
}

type playbackURLItem struct {
	TrackID     int64     `json:"trackId"`
	URL         string    `json:"url"`
	ExpiresAt   time.Time `json:"expiresAt"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	ETag        string    `json:"etag,omitempty"`
}

type playbackUnavailableItem struct {
	TrackID int64  `json:"trackId"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type authRegisterResponse struct {
	AccessToken string `json:"accessToken"`
	User        struct {
		ID string `json:"id"`
	} `json:"user"`
}

func main() {
	log.SetFlags(0)

	cfg := parseConfig()
	ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
	defer cancel()

	if err := run(ctx, cfg); err != nil {
		log.Fatalf("playback fixture smoke: FAIL: %v", err)
	}
}

func parseConfig() smokeConfig {
	cfg := smokeConfig{}
	flag.StringVar(&cfg.backendBaseURL, "backend-url", envDefault("OMP_SMOKE_BACKEND_BASE_URL", "http://localhost:8080"), "backend root URL, without /api/v1")
	flag.StringVar(&cfg.dbHost, "db-host", envDefault("OMP_SMOKE_DB_HOST", "localhost"), "PostgreSQL host")
	flag.StringVar(&cfg.dbPort, "db-port", envDefault("OMP_SMOKE_DB_PORT", envDefault("POSTGRES_PORT", "5434")), "PostgreSQL port")
	flag.StringVar(&cfg.dbUser, "db-user", envDefault("OMP_SMOKE_DB_USER", envDefault("POSTGRES_USER", "omp")), "PostgreSQL user")
	flag.StringVar(&cfg.dbPassword, "db-password", envDefault("OMP_SMOKE_DB_PASSWORD", envDefault("POSTGRES_PASSWORD", "omp_dev_password")), "PostgreSQL password")
	flag.StringVar(&cfg.dbName, "db-name", envDefault("OMP_SMOKE_DB_NAME", envDefault("POSTGRES_DB", "openmusicplayer")), "PostgreSQL database")
	flag.StringVar(&cfg.minioEndpoint, "minio-endpoint", envDefault("OMP_SMOKE_MINIO_ENDPOINT", "localhost:9000"), "MinIO endpoint used by the smoke seeder")
	flag.StringVar(&cfg.minioPublicEndpoint, "minio-public-endpoint", envDefault("OMP_SMOKE_MINIO_PUBLIC_ENDPOINT", "http://localhost:9000"), "public endpoint expected in backend signed URLs")
	flag.StringVar(&cfg.minioAccessKey, "minio-access-key", envDefault("OMP_SMOKE_MINIO_ACCESS_KEY", envDefault("MINIO_ACCESS_KEY", "minioadmin")), "MinIO access key")
	flag.StringVar(&cfg.minioSecretKey, "minio-secret-key", envDefault("OMP_SMOKE_MINIO_SECRET_KEY", envDefault("MINIO_SECRET_KEY", "minioadmin")), "MinIO secret key")
	flag.StringVar(&cfg.minioBucket, "minio-bucket", envDefault("OMP_SMOKE_MINIO_BUCKET", envDefault("MINIO_BUCKET", "audio-files")), "MinIO bucket")
	flag.StringVar(&cfg.minioRegion, "minio-region", envDefault("OMP_SMOKE_MINIO_REGION", envDefault("S3_REGION", "us-east-1")), "MinIO/S3 region")
	flag.BoolVar(&cfg.minioUseSSL, "minio-use-ssl", envBoolDefault("OMP_SMOKE_MINIO_USE_SSL", false), "use HTTPS for MinIO")
	flag.StringVar(&cfg.userEmail, "user-email", envDefault("OMP_SMOKE_USER_EMAIL", defaultSmokeUserEmail), "deterministic smoke user email")
	flag.StringVar(&cfg.userPassword, "user-password", envDefault("OMP_SMOKE_USER_PASSWORD", defaultSmokePassword), "deterministic smoke user password")
	flag.StringVar(&cfg.username, "username", envDefault("OMP_SMOKE_USERNAME", defaultSmokeUsername), "deterministic smoke username")
	flag.StringVar(&cfg.storageKey, "storage-key", envDefault("OMP_SMOKE_STORAGE_KEY", defaultStorageKey), "deterministic fixture object key")
	flag.DurationVar(&cfg.timeout, "timeout", envDurationDefault("OMP_SMOKE_TIMEOUT", 45*time.Second), "overall smoke timeout")
	flag.Parse()

	cfg.backendBaseURL = strings.TrimRight(cfg.backendBaseURL, "/")
	return cfg
}

func run(ctx context.Context, cfg smokeConfig) error {
	client := &http.Client{Timeout: 10 * time.Second}
	if err := getOK(ctx, client, cfg.backendBaseURL+"/health"); err != nil {
		return fmt.Errorf("backend health check: %w", err)
	}

	database, err := db.New(cfg.dbHost, cfg.dbPort, cfg.dbUser, cfg.dbPassword, cfg.dbName)
	if err != nil {
		return fmt.Errorf("connect postgres: %w", err)
	}
	defer database.Close()

	storageClient, err := storage.New(&storage.Config{
		Endpoint:       cfg.minioEndpoint,
		PublicEndpoint: cfg.minioPublicEndpoint,
		Region:         cfg.minioRegion,
		AccessKey:      cfg.minioAccessKey,
		SecretKey:      cfg.minioSecretKey,
		Bucket:         cfg.minioBucket,
		UseSSL:         cfg.minioUseSSL,
	})
	if err != nil {
		return fmt.Errorf("create storage client: %w", err)
	}
	if err := storageClient.EnsureBucket(ctx); err != nil {
		return fmt.Errorf("ensure storage bucket: %w", err)
	}

	fixture := tinyWAVFixture()
	if err := storageClient.PutObject(ctx, cfg.storageKey, bytes.NewReader(fixture), int64(len(fixture)), "audio/wav"); err != nil {
		return fmt.Errorf("upload fixture object: %w", err)
	}
	objInfo, err := storageClient.StatObject(ctx, cfg.storageKey)
	if err != nil {
		return fmt.Errorf("stat fixture object: %w", err)
	}
	if objInfo.Size != int64(len(fixture)) {
		return fmt.Errorf("fixture object size mismatch: got %d want %d", objInfo.Size, len(fixture))
	}
	checksum := sha256.Sum256(fixture)
	identityHash := hex.EncodeToString(checksum[:])

	if _, err := database.ExecContext(ctx, `DELETE FROM users WHERE email = $1`, cfg.userEmail); err != nil {
		return fmt.Errorf("reset smoke user: %w", err)
	}
	if _, err := database.ExecContext(ctx, `DELETE FROM tracks WHERE storage_key = $1 OR identity_hash = $2`, cfg.storageKey, identityHash); err != nil {
		return fmt.Errorf("reset smoke track: %w", err)
	}

	authResp, err := registerSmokeUser(ctx, client, cfg)
	if err != nil {
		return fmt.Errorf("create smoke user: %w", err)
	}
	userID, err := uuid.Parse(authResp.User.ID)
	if err != nil {
		return fmt.Errorf("parse smoke user id: %w", err)
	}

	var trackID int64
	if err := database.QueryRowContext(ctx, `
		INSERT INTO tracks (
			identity_hash, title, artist, album, duration_ms,
			source_url, source_type, storage_key, file_size_bytes,
			metadata_json, metadata_provenance
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, '{}'::jsonb, '{}'::jsonb)
		RETURNING id
	`,
		identityHash,
		"Local MinIO Playback Smoke",
		"Open Music Player",
		"Fixture Smoke",
		8,
		"local-fixture://minio-playback-smoke",
		"fixture",
		cfg.storageKey,
		int64(len(fixture)),
	).Scan(&trackID); err != nil {
		return fmt.Errorf("insert smoke track: %w", err)
	}
	if _, err := db.NewLibraryRepository(database).AddTrackToLibrary(ctx, userID, trackID); err != nil {
		return fmt.Errorf("insert smoke user_library row: %w", err)
	}

	playback, err := requestPlaybackURL(ctx, client, cfg.backendBaseURL, authResp.AccessToken, trackID)
	if err != nil {
		return err
	}
	if playback.SizeBytes != int64(len(fixture)) {
		return fmt.Errorf("playback URL size mismatch: got %d want %d", playback.SizeBytes, len(fixture))
	}
	if playback.ContentType != "audio/wav" {
		return fmt.Errorf("playback URL content type mismatch: got %q want audio/wav", playback.ContentType)
	}

	rangeStatus, rangeBytes, contentRange, err := getSignedRange(ctx, client, playback.URL)
	if err != nil {
		return err
	}

	fmt.Println("playback fixture smoke: ok")
	fmt.Printf("track_id=%d created=true storage_key=%s fixture_bytes=%d fixture_sha256=%s\n", trackID, cfg.storageKey, len(fixture), identityHash)
	fmt.Printf("playback_url_status=200 content_type=%s size_bytes=%d expires_at=%s etag=%s\n", playback.ContentType, playback.SizeBytes, playback.ExpiresAt.Format(time.RFC3339), playback.ETag)
	fmt.Printf("signed_url_range_status=%d range_bytes=%d content_range=%q\n", rangeStatus, rangeBytes, contentRange)
	return nil
}

func registerSmokeUser(ctx context.Context, client *http.Client, cfg smokeConfig) (*authRegisterResponse, error) {
	bodyBytes, err := json.Marshal(map[string]interface{}{
		"email":    cfg.userEmail,
		"password": cfg.userPassword,
		"username": cfg.username,
	})
	if err != nil {
		return nil, fmt.Errorf("encode register request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.backendBaseURL+"/api/v1/auth/register", bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("build register request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request register: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read register response: %w", err)
	}
	if resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("register status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var out authRegisterResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		return nil, fmt.Errorf("decode register response: %w", err)
	}
	if strings.TrimSpace(out.AccessToken) == "" || strings.TrimSpace(out.User.ID) == "" {
		return nil, errors.New("register response missing access token or user id")
	}
	return &out, nil
}

func requestPlaybackURL(ctx context.Context, client *http.Client, backendBaseURL, accessToken string, trackID int64) (*playbackURLItem, error) {
	bodyBytes, err := json.Marshal(map[string]interface{}{
		"trackIds":   []int64{trackID},
		"ttlSeconds": 60,
	})
	if err != nil {
		return nil, fmt.Errorf("encode playback URL request: %w", err)
	}
	body := bytes.NewReader(bodyBytes)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, backendBaseURL+"/api/v1/playback/urls", body)
	if err != nil {
		return nil, fmt.Errorf("build playback URL request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request playback URL: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read playback URL response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("playback URL status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var out playbackURLResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		return nil, fmt.Errorf("decode playback URL response: %w", err)
	}
	if len(out.Unavailable) > 0 {
		return nil, fmt.Errorf("playback URL unavailable: %+v", out.Unavailable)
	}
	if len(out.URLs) != 1 {
		return nil, fmt.Errorf("playback URL count mismatch: got %d want 1", len(out.URLs))
	}
	if out.URLs[0].TrackID != trackID {
		return nil, fmt.Errorf("playback URL track id mismatch: got %d want %d", out.URLs[0].TrackID, trackID)
	}
	if strings.TrimSpace(out.URLs[0].URL) == "" {
		return nil, errors.New("playback URL response had an empty signed URL")
	}
	return &out.URLs[0], nil
}

func getSignedRange(ctx context.Context, client *http.Client, signedURL string) (int, int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, signedURL, nil)
	if err != nil {
		return 0, 0, "", fmt.Errorf("build signed range request: %w", err)
	}
	req.Header.Set("Range", "bytes=0-15")

	resp, err := client.Do(req)
	if err != nil {
		return 0, 0, "", fmt.Errorf("request signed URL range: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1024))
	if err != nil {
		return 0, 0, "", fmt.Errorf("read signed range response: %w", err)
	}
	if resp.StatusCode != http.StatusPartialContent && resp.StatusCode != http.StatusOK {
		return resp.StatusCode, len(body), resp.Header.Get("Content-Range"), fmt.Errorf("signed range status %d", resp.StatusCode)
	}
	if len(body) == 0 {
		return resp.StatusCode, 0, resp.Header.Get("Content-Range"), errors.New("signed range returned no bytes")
	}
	return resp.StatusCode, len(body), resp.Header.Get("Content-Range"), nil
}

func getOK(ctx context.Context, client *http.Client, url string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return nil
}

func tinyWAVFixture() []byte {
	const (
		sampleRate    = 8000
		bitsPerSample = 8
		channels      = 1
		samples       = 64
	)

	data := make([]byte, samples)
	for i := range data {
		// Deterministic quiet square wave centered around 8-bit PCM silence (128).
		if (i/8)%2 == 0 {
			data[i] = 160
		} else {
			data[i] = 96
		}
	}

	byteRate := sampleRate * channels * bitsPerSample / 8
	blockAlign := channels * bitsPerSample / 8
	out := bytes.NewBuffer(make([]byte, 0, 44+len(data)))
	out.WriteString("RIFF")
	writeLE32(out, uint32(36+len(data)))
	out.WriteString("WAVE")
	out.WriteString("fmt ")
	writeLE32(out, 16)
	writeLE16(out, 1) // PCM
	writeLE16(out, channels)
	writeLE32(out, sampleRate)
	writeLE32(out, uint32(byteRate))
	writeLE16(out, blockAlign)
	writeLE16(out, bitsPerSample)
	out.WriteString("data")
	writeLE32(out, uint32(len(data)))
	out.Write(data)
	return out.Bytes()
}

func writeLE16(w io.Writer, v int) {
	_ = binary.Write(w, binary.LittleEndian, uint16(v))
}

func writeLE32(w io.Writer, v uint32) {
	_ = binary.Write(w, binary.LittleEndian, v)
}

func envDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func envBoolDefault(key string, fallback bool) bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
	switch value {
	case "1", "true", "yes", "y", "on":
		return true
	case "0", "false", "no", "n", "off":
		return false
	case "":
		return fallback
	default:
		return fallback
	}
}

func envDurationDefault(key string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	d, err := time.ParseDuration(value)
	if err != nil || d <= 0 {
		return fallback
	}
	return d
}
