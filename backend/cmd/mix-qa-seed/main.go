// Command mix-qa-seed seeds a disposable, audio-backed Mix QA fixture against a
// running stack (local or tailnet staging): three short audible WAV tracks with
// distinct BPM/Camelot analysis metadata, a dedicated QA user, and a playlist
// wired for POST /playlists/{id}/auto-mix. It exists to unblock audible seam
// verification (#383): playback requires tracks.storage_key objects that
// actually exist in MinIO.
//
// The seeder is idempotent: it resets the QA user (cascade) and its fixtures by
// deterministic identity hash before reseeding, so repeated runs leave exactly
// one QA playlist behind. Fixture keys are namespaced under "mix-qa/" so they
// never collide with real library audio.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/storage"
)

const (
	defaultUserEmail    = "mix-qa@openmusicplayer.local"
	defaultUserPassword = "mix-qa-password"
	defaultUserName     = "mix-qa"
	defaultPlaylistName = "Mix QA Fixtures"
	sampleRate          = 44100
)

// fixtureSpec describes one seeded track. Tracks are 90 s so the interior-seam
// clip budget (duration/4 = 22.5 s) stays above the bar-aligned overlap the
// ladder picks (16 s at 120 BPM), letting aligned seams survive instead of
// collapsing to the bounded simple fade. BPM/key pairs still straddle the
// tempoMatched/tempoShift boundary (120→126 ≈ 4.8%, 126→140 ≈ 11%) with a
// compatible Camelot move on seam 0 and an opposite-letter same-number move on
// seam 1. Downbeats are emitted across the full track (no cap) so an outgoing
// anchor exists near duration − overlap for both seams.
type fixtureSpec struct {
	name        string // stable identifier used in titles and storage keys
	title       string
	artist      string
	bpm         float64
	camelot     string
	beatsPerBar int
	seconds     int
	freqA       float64 // base tone frequency (Hz)
	freqB       float64 // secondary tone for the back half
}

var fixtures = []fixtureSpec{
	{name: "a", title: "Mix QA A 120bpm 8B", artist: "MixQA Seeds", bpm: 120, camelot: "8B", beatsPerBar: 4, seconds: 90, freqA: 220, freqB: 330},
	{name: "b", title: "Mix QA B 126bpm 9A", artist: "MixQA Seeds", bpm: 126, camelot: "9A", beatsPerBar: 4, seconds: 90, freqA: 247, freqB: 370},
	{name: "c", title: "Mix QA C 140bpm 8A", artist: "MixQA Seeds", bpm: 140, camelot: "8A", beatsPerBar: 4, seconds: 90, freqA: 262, freqB: 392},
}

type seedConfig struct {
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
	playlistName        string
	timeout             time.Duration
}

func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envBoolDefault(key string, fallback bool) bool {
	switch strings.ToLower(os.Getenv(key)) {
	case "1", "true", "yes":
		return true
	case "0", "false", "no":
		return false
	}
	return fallback
}

func envDurationDefault(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}

func parseConfig() seedConfig {
	cfg := seedConfig{}
	flag.StringVar(&cfg.backendBaseURL, "backend-url", envDefault("OMP_SMOKE_BACKEND_BASE_URL", "http://localhost:8080"), "backend root URL, without /api/v1")
	flag.StringVar(&cfg.dbHost, "db-host", envDefault("OMP_SMOKE_DB_HOST", "localhost"), "PostgreSQL host")
	flag.StringVar(&cfg.dbPort, "db-port", envDefault("OMP_SMOKE_DB_PORT", envDefault("POSTGRES_PORT", "5434")), "PostgreSQL port")
	flag.StringVar(&cfg.dbUser, "db-user", envDefault("OMP_SMOKE_DB_USER", envDefault("POSTGRES_USER", "omp")), "PostgreSQL user")
	flag.StringVar(&cfg.dbPassword, "db-password", envDefault("OMP_SMOKE_DB_PASSWORD", envDefault("POSTGRES_PASSWORD", "omp_dev_password")), "PostgreSQL password")
	flag.StringVar(&cfg.dbName, "db-name", envDefault("OMP_SMOKE_DB_NAME", envDefault("POSTGRES_DB", "openmusicplayer")), "PostgreSQL database")
	flag.StringVar(&cfg.minioEndpoint, "minio-endpoint", envDefault("OMP_SMOKE_MINIO_ENDPOINT", "localhost:9000"), "MinIO endpoint used by the seeder")
	flag.StringVar(&cfg.minioPublicEndpoint, "minio-public-endpoint", envDefault("OMP_SMOKE_MINIO_PUBLIC_ENDPOINT", "http://dev.fish-rattlesnake.ts.net:9000"), "public endpoint expected in backend signed URLs")
	flag.StringVar(&cfg.minioAccessKey, "minio-access-key", envDefault("OMP_SMOKE_MINIO_ACCESS_KEY", envDefault("MINIO_ACCESS_KEY", "minioadmin")), "MinIO access key")
	flag.StringVar(&cfg.minioSecretKey, "minio-secret-key", envDefault("OMP_SMOKE_MINIO_SECRET_KEY", envDefault("MINIO_SECRET_KEY", "minioadmin")), "MinIO secret key")
	flag.StringVar(&cfg.minioBucket, "minio-bucket", envDefault("OMP_SMOKE_MINIO_BUCKET", envDefault("MINIO_BUCKET", "audio-files")), "MinIO bucket")
	flag.StringVar(&cfg.minioRegion, "minio-region", envDefault("OMP_SMOKE_MINIO_REGION", envDefault("S3_REGION", "us-east-1")), "MinIO/S3 region")
	flag.BoolVar(&cfg.minioUseSSL, "minio-use-ssl", envBoolDefault("OMP_SMOKE_MINIO_USE_SSL", false), "use HTTPS for MinIO")
	flag.StringVar(&cfg.userEmail, "user-email", envDefault("MIX_QA_USER_EMAIL", defaultUserEmail), "deterministic QA user email")
	flag.StringVar(&cfg.userPassword, "user-password", envDefault("MIX_QA_USER_PASSWORD", defaultUserPassword), "deterministic QA user password")
	flag.StringVar(&cfg.username, "username", envDefault("MIX_QA_USERNAME", defaultUserName), "deterministic QA username")
	flag.StringVar(&cfg.playlistName, "playlist-name", envDefault("MIX_QA_PLAYLIST_NAME", defaultPlaylistName), "QA playlist name")
	flag.DurationVar(&cfg.timeout, "timeout", envDurationDefault("MIX_QA_TIMEOUT", 3*time.Minute), "overall timeout")
	flag.Parse()
	cfg.backendBaseURL = strings.TrimRight(cfg.backendBaseURL, "/")
	return cfg
}

func main() {
	log.SetFlags(0)
	cfg := parseConfig()
	ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
	defer cancel()
	if err := run(ctx, cfg); err != nil {
		log.Fatalf("mix-qa-seed: FAIL: %v", err)
	}
}

func run(ctx context.Context, cfg seedConfig) error {
	client := &http.Client{Timeout: 15 * time.Second}
	if err := getOK(ctx, client, cfg.backendBaseURL+"/health"); err != nil {
		return fmt.Errorf("backend health check: %w", err)
	}
	fmt.Printf("backend healthy: %s\n", cfg.backendBaseURL)

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

	// Deterministic reset: drop the QA user (cascades playlists/library) and
	// any prior fixture rows/objects, then reseed from scratch.
	for _, spec := range fixtures {
		wav := renderFixtureWAV(spec)
		sum := sha256.Sum256(wav)
		identityHash := hex.EncodeToString(sum[:])
		key := fmt.Sprintf("mix-qa/%s.wav", spec.name)
		if _, err := database.ExecContext(ctx,
			`DELETE FROM tracks WHERE storage_key = $1 OR identity_hash = $2`, key, identityHash); err != nil {
			return fmt.Errorf("reset fixture track %s: %w", spec.name, err)
		}
		if err := storageClient.DeleteObject(ctx, key); err != nil {
			return fmt.Errorf("delete stale object %s: %w", key, err)
		}
	}
	if _, err := database.ExecContext(ctx, `DELETE FROM users WHERE email = $1`, cfg.userEmail); err != nil {
		return fmt.Errorf("reset qa user: %w", err)
	}

	authResp, err := registerUser(ctx, client, cfg)
	if err != nil {
		return fmt.Errorf("create qa user: %w", err)
	}
	userID, err := uuid.Parse(authResp.User.ID)
	if err != nil {
		return fmt.Errorf("parse qa user id: %w", err)
	}

	libRepo := db.NewLibraryRepository(database)
	trackIDs := make([]int64, 0, len(fixtures))
	for _, spec := range fixtures {
		trackID, err := seedFixtureTrack(ctx, database, storageClient, spec)
		if err != nil {
			return fmt.Errorf("seed fixture %s: %w", spec.name, err)
		}
		if entry, err := libRepo.AddTrackToLibrary(ctx, userID, trackID); err != nil {
			return fmt.Errorf("add fixture %s to library: %w", spec.name, err)
		} else if entry == nil {
			return fmt.Errorf("add fixture %s to library: nil entry", spec.name)
		}
		trackIDs = append(trackIDs, trackID)
		fmt.Printf("seeded %-4s track_id=%d\n", spec.name, trackID)
	}

	playlistID, err := createPlaylistViaAPI(ctx, client, cfg, authResp.AccessToken, trackIDs)
	if err != nil {
		return err
	}

	fmt.Println("mix-qa-seed: ok")
	fmt.Printf("login_email=%s login_password=%s\n", cfg.userEmail, cfg.userPassword)
	fmt.Printf("playlist_id=%d playlist_name=%q tracks=%v\n", playlistID, cfg.playlistName, trackIDs)
	fmt.Printf("next: POST /api/v1/playlists/%d/auto-mix then play on emulator; verify signed URLs resolve\n", playlistID)
	return nil
}

// renderFixtureWAV renders a mono 16-bit PCM WAV: freqA sine for the first
// half, freqB for the second half, with short fade-in/out so the clip has no
// hard edges. Loud enough to hear on the emulator at moderate volume.
func renderFixtureWAV(spec fixtureSpec) []byte {
	totalSamples := sampleRate * spec.seconds
	fadeSamples := sampleRate // 1s fades
	data := make([]byte, 0, totalSamples*2)
	for i := 0; i < totalSamples; i++ {
		t := float64(i) / sampleRate
		freq := spec.freqA
		if i >= totalSamples/2 {
			freq = spec.freqB
		}
		amp := 0.55
		if i < fadeSamples {
			amp *= float64(i) / float64(fadeSamples)
		} else if i > totalSamples-fadeSamples {
			amp *= float64(totalSamples-i) / float64(fadeSamples)
		}
		v := amp * math.Sin(2*math.Pi*freq*t)
		sample := int16(v * 32767 * 0.9)
		data = binary.LittleEndian.AppendUint16(data, uint16(sample))
	}

	out := bytes.NewBuffer(make([]byte, 0, 44+len(data)))
	out.WriteString("RIFF")
	appendLE32(out, uint32(36+len(data)))
	out.WriteString("WAVE")
	out.WriteString("fmt ")
	appendLE32(out, 16)
	appendLE16(out, 1) // PCM
	appendLE16(out, 1) // mono
	appendLE32(out, sampleRate)
	appendLE32(out, sampleRate*2) // byte rate
	appendLE16(out, 2)            // block align
	appendLE16(out, 16)           // bits per sample
	out.WriteString("data")
	appendLE32(out, uint32(len(data)))
	out.Write(data)
	return out.Bytes()
}

func appendLE16(b *bytes.Buffer, v uint16) { _ = binary.Write(b, binary.LittleEndian, v) }
func appendLE32(b *bytes.Buffer, v uint32) { _ = binary.Write(b, binary.LittleEndian, v) }

func seedFixtureTrack(ctx context.Context, database *db.DB, storageClient *storage.Client, spec fixtureSpec) (int64, error) {
	wav := renderFixtureWAV(spec)
	sum := sha256.Sum256(wav)
	identityHash := hex.EncodeToString(sum[:])
	key := fmt.Sprintf("mix-qa/%s.wav", spec.name)

	if err := storageClient.PutObject(ctx, key, bytes.NewReader(wav), int64(len(wav)), "audio/wav"); err != nil {
		return 0, fmt.Errorf("upload object: %w", err)
	}

	var trackID int64
	err := database.QueryRowContext(ctx, `
		INSERT INTO tracks (
			identity_hash, title, artist, album, duration_ms,
			source_url, source_type, storage_key, file_size_bytes,
			metadata_json, metadata_provenance
		) VALUES ($1, $2, $3, 'MixQA', $4, $5, 'fixture', $6, $7, '{}'::jsonb, '{}'::jsonb)
		RETURNING id
	`,
		identityHash, spec.title, spec.artist, spec.seconds*1000,
		fmt.Sprintf("local-fixture://mix-qa/%s", spec.name),
		key, len(wav),
	).Scan(&trackID)
	if err != nil {
		return 0, fmt.Errorf("insert track row: %w", err)
	}

	// Analysis summary shaped like the analyzer's compact document: bpm.value,
	// camelot.value, meter.beats_per_bar, downbeats.positions_ms. The auto-blend
	// handler reads exactly these fields. Downbeats are emitted across the whole
	// track (no cap), rounded to the nearest millisecond so the grid matches the
	// declared BPM without truncation drift, and spaced by spec.beatsPerBar so
	// the grid cannot contradict the meter.
	downbeats := make([]int64, 0, spec.seconds)
	barLen := float64(spec.beatsPerBar) * 60000 / spec.bpm
	for ms := 200.0; ms < float64(spec.seconds*1000)-barLen; ms += barLen {
		downbeats = append(downbeats, int64(math.Round(ms)))
	}
	summary, err := json.Marshal(map[string]any{
		"bpm":       map[string]any{"value": spec.bpm},
		"key":       map[string]any{"value": spec.camelot},
		"camelot":   map[string]any{"value": spec.camelot},
		"meter":     map[string]any{"beats_per_bar": spec.beatsPerBar},
		"downbeats": map[string]any{"positions_ms": downbeats},
		"energy":    map[string]any{"value": 0.6},
	})
	if err != nil {
		return 0, fmt.Errorf("marshal analysis summary: %w", err)
	}
	provenance, err := json.Marshal(map[string]any{
		"analyzer":         "mix-qa-seed",
		"analyzer_version": "1",
	})
	if err != nil {
		return 0, fmt.Errorf("marshal provenance: %w", err)
	}

	if err := database.QueryRowContext(ctx, `
		INSERT INTO track_analysis (track_id, schema_version, status, summary_json, provenance_json)
		VALUES ($1, 1, 'analyzed', $2::jsonb, $3::jsonb)
		ON CONFLICT (track_id) DO UPDATE
		SET schema_version = 1,
			status = 'analyzed',
			summary_json = EXCLUDED.summary_json,
			provenance_json = EXCLUDED.provenance_json,
			error = NULL,
			completed_at = NOW(),
			updated_at = NOW()
		RETURNING track_id
	`, trackID, string(summary), string(provenance)).Scan(&trackID); err != nil {
		return 0, fmt.Errorf("store analysis result: %w", err)
	}
	return trackID, nil
}

type authRegisterResponse struct {
	AccessToken string `json:"accessToken"`
	User        struct {
		ID string `json:"id"`
	} `json:"user"`
}

func registerUser(ctx context.Context, client *http.Client, cfg seedConfig) (*authRegisterResponse, error) {
	bodyBytes, err := json.Marshal(map[string]string{
		"email":    cfg.userEmail,
		"password": cfg.userPassword,
		"username": cfg.username,
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.backendBaseURL+"/api/v1/auth/register", bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("register status %d: %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	var out authRegisterResponse
	if err := json.Unmarshal(respBody, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func createPlaylistViaAPI(ctx context.Context, client *http.Client, cfg seedConfig, token string, trackIDs []int64) (int64, error) {
	createBody, err := json.Marshal(map[string]any{"name": cfg.playlistName, "description": "Disposable audio-backed fixtures for Mix seam QA (#383)"})
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cfg.backendBaseURL+"/api/v1/playlists", bytes.NewReader(createBody))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("create playlist: %w", err)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("create playlist status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var created struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(body, &created); err != nil || created.ID == 0 {
		return 0, fmt.Errorf("decode created playlist (id=%d): %v", created.ID, err)
	}

	addBody, err := json.Marshal(map[string]any{"trackIds": trackIDs})
	if err != nil {
		return 0, err
	}
	req, err = http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/api/v1/playlists/%d/tracks", cfg.backendBaseURL, created.ID), bytes.NewReader(addBody))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err = client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("add tracks: %w", err)
	}
	body, _ = io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return 0, fmt.Errorf("add tracks status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return created.ID, nil
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
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: status %d", url, resp.StatusCode)
	}
	return nil
}
