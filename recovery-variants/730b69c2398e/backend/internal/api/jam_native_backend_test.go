package api

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/config"
	"github.com/openmusicplayer/backend/internal/connect"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/jam"
	"github.com/openmusicplayer/backend/internal/storage"
)

const nativeJamFixtureEmail = "native-jam@example.invalid"
const nativeJamFixturePassword = "fixture-only-password"
const nativeJamFixtureSource = "https://www.youtube.com/watch?v=aaaaaaaaaaa"

// The ONLY substituted acquisition boundary: an explicit synthetic external
// search/extractor result. SQL, JWT authentication, Connect leases, approval,
// Redis publication/worker/lifecycle, S3 upload/signing/read and native playback
// are not replaced. This fixture must never be reported as provider proof.
type nativeJamFixtureProvider struct{ calls atomic.Int32 }

func (p *nativeJamFixtureProvider) Name() string { return "youtube" }
func (p *nativeJamFixtureProvider) Search(context.Context, string, int) ([]discovery.Candidate, error) {
	p.calls.Add(1)
	return []discovery.Candidate{{CandidateID: "youtube:aaaaaaaaaaa", Provider: "youtube", SourceID: "aaaaaaaaaaa", SourceURL: nativeJamFixtureSource, Title: "Outside source fixture", Artist: "Synthetic ensemble", DurationMs: 12000, Downloadable: true}}, nil
}

// Each returned container ID was created by this call. Never accepts a remote
// dependency URL, reuses a user's database, changes a service, or cleans by name.
func nativeJamContainer(t *testing.T, image, port string, environment map[string]string, args ...string) string {
	t.Helper()
	name := "soundq-native-jam-" + uuid.NewString()[:8]
	command := []string{"run", "-d", "--name", name, "--label", "soundq.fixture=native-jam", "-p", "127.0.0.1::" + port}
	env := os.Environ()
	for key, value := range environment {
		command = append(command, "-e", key)
		env = append(env, key+"="+value)
	}
	command = append(command, image)
	command = append(command, args...)
	child := exec.Command("docker", command...)
	child.Env = env
	output, err := child.Output()
	if err != nil {
		t.Fatal("could not start owned native Jam dependency")
	}
	id := strings.TrimSpace(string(output))
	if len(id) != 64 {
		t.Fatal("Docker did not return an exact owned container ID")
	}
	if _, err = hex.DecodeString(id); err != nil {
		t.Fatal("invalid owned container ID")
	}
	t.Cleanup(func() {
		if err := exec.Command("docker", "rm", "-f", id).Run(); err != nil {
			t.Error("could not retire owned native Jam dependency")
		}
	})
	output, err = exec.Command("docker", "port", id, port+"/tcp").Output()
	address := strings.TrimSpace(string(output))
	if err != nil || !strings.HasPrefix(address, "127.0.0.1:") || strings.Contains(address, "\n") {
		t.Fatal("owned dependency must bind only one loopback port")
	}
	return address
}

func nativeJamWait(t *testing.T, probe func() error) {
	t.Helper()
	deadline := time.Now().Add(45 * time.Second)
	for {
		if probe() == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("owned native Jam dependency did not become ready")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func nativeJamAudio(t *testing.T, directory, name, frequency string) string {
	t.Helper()
	path := filepath.Join(directory, name+".mp3")
	child := exec.Command("ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency="+frequency+":duration=12", "-ac", "2", "-ar", "48000", "-codec:a", "libmp3lame", "-b:a", "128k", path)
	if err := child.Run(); err != nil {
		t.Fatal("could not generate explicit synthetic native Jam audio")
	}
	return path
}

// TestNativeJamBackend is an opt-in bounded server for an owned Android journey.
// A ready manifest is bootstrap evidence, NOT an Android or release verdict.
func TestNativeJamBackend(t *testing.T) {
	manifest := os.Getenv("NATIVE_JAM_MANIFEST")
	if manifest == "" {
		t.Skip("set NATIVE_JAM_MANIFEST to start an owned native backend fixture")
	}
	if !filepath.IsAbs(manifest) || filepath.Clean(manifest) != manifest || filepath.Dir(manifest) == os.TempDir() {
		t.Fatal("native fixture needs its own private absolute directory")
	}
	if _, err := os.Lstat(manifest); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("refusing an existing native fixture manifest")
	}
	directory := filepath.Dir(manifest)
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		t.Fatal("native fixture directory must be private and owned")
	}
	ctx := context.Background()
	password := jam.NewSecret()
	pg := nativeJamContainer(t, "postgres:16-alpine", "5432", map[string]string{"POSTGRES_USER": "fixture", "POSTGRES_PASSWORD": password, "POSTGRES_DB": "fixture"})
	dsn := "postgres://fixture:"+password+"@"+pg+"/fixture?sslmode=disable"
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal("owned fixture DSN refused by database protection")
	}
	sqlDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("could not configure owned SQL fixture")
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	nativeJamWait(t, func() error { return sqlDB.PingContext(ctx) })
	database := &db.DB{DB: sqlDB}
	if err = database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal("owned fixture database refused before migration")
	}
	if err = database.Migrate(); err != nil {
		t.Fatal(err)
	}
	if err = database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatal("owned fixture database refused after migration")
	}
	redisAddress := nativeJamContainer(t, "redis:7-alpine", "6379", nil, "redis-server", "--save", "", "--appendonly", "no")
	redisClient := redis.NewClient(&redis.Options{Addr: redisAddress})
	t.Cleanup(func() { _ = redisClient.Close() })
	nativeJamWait(t, func() error { return redisClient.Ping(ctx).Err() })
	minioSecret := jam.NewSecret()
	minioAddress := nativeJamContainer(t, "soundq-ci-deps-minio:local", "9000", map[string]string{"MINIO_ROOT_USER": "nativefixture", "MINIO_ROOT_PASSWORD": minioSecret}, "minio", "server", "/data", "--address", ":9000")
	minioOrigin, _ := url.Parse("http://" + minioAddress)
	proxy := httputil.NewSingleHostReverseProxy(minioOrigin)
	var apiHandler http.Handler
	var mediaReads atomic.Int32
	var mediaBearerLeak atomic.Bool
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/native-jam/") {
			if r.Header.Get("Authorization") != "" {
				mediaBearerLeak.Store(true)
				w.WriteHeader(http.StatusForbidden)
				return
			}
			if (r.Method != http.MethodGet && r.Method != http.MethodHead) || r.URL.Query().Get("X-Amz-Signature") == "" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			mediaReads.Add(1)
			proxy.ServeHTTP(w, r)
			return
		}
		if apiHandler == nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		apiHandler.ServeHTTP(w, r)
	}))
	origin := "https://" + server.Listener.Addr().String()
	objects, err := storage.New(&storage.Config{Endpoint: minioOrigin.String(), PublicEndpoint: origin, Region: "us-east-1", AccessKey: "nativefixture", SecretKey: minioSecret, Bucket: "native-jam"})
	if err != nil {
		t.Fatal(err)
	}
	nativeJamWait(t, func() error { return objects.EnsureBucket(ctx) })
	uploads, err := storage.NewS3Storage(&config.Config{S3Endpoint: minioOrigin.String(), S3AccessKey: "nativefixture", S3SecretKey: minioSecret, S3Region: "us-east-1", S3Bucket: "native-jam", S3UsePathStyle: true})
	if err != nil {
		t.Fatal(err)
	}
	users := db.NewUserRepository(database)
	tokens := db.NewTokenRepository(database)
	authService := auth.NewService(users, tokens, jam.NewSecret())
	owner, err := authService.Register(ctx, nativeJamFixtureEmail, nativeJamFixturePassword, "Native fixture")
	if err != nil {
		t.Fatal(err)
	}
	ownerID, err := uuid.Parse(owner.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	tracks := db.NewTrackRepository(database)
	library := db.NewLibraryRepository(database)
	hostAudio := nativeJamAudio(t, directory, "host", "220")
	sourceAudio := nativeJamAudio(t, directory, "outside", "440")
	publish := func(ctx context.Context, path, title, source string) (*db.Track, error) {
		meta := storage.TrackMetadata{Title: title, Artist: "Synthetic ensemble", DurationMs: 12000}
		data, e := os.ReadFile(path)
		if e != nil {
			return nil, e
		}
		// Production Upload consumes its temporary input. Retain the immutable
		// fixture and hand the real uploader a uniquely owned disposable copy.
		staged := filepath.Join(directory, "upload-"+uuid.NewString()+".mp3")
		e = os.WriteFile(staged, data, 0600)
		if e != nil {
			return nil, e
		}
		result, e := uploads.Upload(ctx, staged, meta)
		if e != nil {
			return nil, e
		}
		object, _, e := objects.GetObject(ctx, result.StorageKey)
		if e != nil {
			return nil, e
		}
		stored, e := io.ReadAll(object)
		_ = object.Close()
		if e != nil {
			return nil, e
		}
		if sha256.Sum256(data) != sha256.Sum256(stored) {
			return nil, errors.New("native fixture S3 bytes disagree")
		}
		row := &db.Track{IdentityHash: result.IdentityHash, Title: title, Artist: sql.NullString{String: "Synthetic ensemble", Valid: true}, DurationMs: sql.NullInt32{Int32: 12000, Valid: true}, StorageKey: sql.NullString{String: result.StorageKey, Valid: true}, FileSizeBytes: sql.NullInt64{Int64: int64(len(data)), Valid: true}, ContentType: sql.NullString{String: "audio/mpeg", Valid: true}, Codec: sql.NullString{String: "mp3", Valid: true}, SampleRateHz: sql.NullInt32{Int32: 48000, Valid: true}, Channels: sql.NullInt32{Int32: 2, Valid: true}}
		if source != "" {
			row.SourceURL = sql.NullString{String: source, Valid: true}
			row.SourceType = sql.NullString{String: "youtube", Valid: true}
		}
		if e = tracks.Create(ctx, row); e != nil {
			return nil, e
		}
		_, e = library.AddTrackToLibrary(ctx, ownerID, row.ID)
		return row, e
	}
	host, err := publish(ctx, hostAudio, "Host fixture", "")
	if err != nil {
		t.Fatal(err)
	}
	offered, err := publish(ctx, hostAudio, "Offered fixture", "")
	if err != nil {
		t.Fatal(err)
	}
	lifecycle := db.NewSourceSelectionDownloadLifecycle(database)
	service, err := download.NewService(&download.ServiceConfig{RedisURL: "redis://" + redisAddress + "/0", WorkerCount: 1, MaxRetries: 1, JobTimeout: 30 * time.Second}, func(ctx context.Context, job *download.DownloadJob, progress func(int)) error {
		if job.URL != nativeJamFixtureSource || job.UserID != ownerID.String() {
			return errors.New("unexpected synthetic extractor identity")
		}
		progress(20)
		row, e := publish(ctx, sourceAudio, "Outside source fixture", nativeJamFixtureSource)
		if e != nil {
			return e
		}
		job.TrackID = &row.ID
		progress(100)
		return nil
	}, lifecycle)
	if err != nil {
		t.Fatal(err)
	}
	service.Start()
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		_ = service.Stop(stop)
	})
	repository := jam.NewRepository(sqlDB)
	provider := &nativeJamFixtureProvider{}
	repository.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{provider}})
	repository.Downloads = service
	writers := connect.NewService(redisClient)
	jamHandlers := NewJamHandlers(repository, jam.NewRedisLimiter(redisClient), func(r *http.Request) (jam.Owner, error) {
		user := auth.GetUserFromContext(r.Context())
		if user == nil {
			return jam.Owner{}, jam.ErrDenied
		}
		return jam.Owner{UserID: user.UserID, Generation: user.ConnectGeneration}, nil
	}, func(ctx context.Context, owner jam.Owner, proof jam.Proof) error {
		e := writers.ValidateWriter(ctx, owner.UserID, owner.Generation, proof.HostDeviceID.String(), proof.LeaseID.String(), proof.WriterSecret)
		if errors.Is(e, connect.ErrUnavailable) {
			return jam.ErrUnavailable
		}
		if e != nil {
			return jam.ErrDenied
		}
		return nil
	})
	apiHandler = NewRouterWithConfig(&RouterConfig{AuthService: authService, AuthHandlers: auth.NewHandlers(authService), ConnectHandlers: NewConnectHandlers(writers), JamHandlers: jamHandlers, LibraryHandlers: NewLibraryHandlers(tracks, library), PlaybackHandlers: NewPlaybackHandlers(tracks, library, objects), PlayEventHandlers: NewPlayEventHandlers(db.NewPlayEventRepository(database), tracks)})
	server.StartTLS()
	defer server.Close()
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	// Exercise real private middleware before publishing a ready endpoint.
	request, e := http.NewRequestWithContext(ctx, http.MethodGet, origin+"/api/v1/library", nil)
	if e != nil {
		t.Fatal(e)
	}
	response, e := server.Client().Do(request)
	if e != nil {
		t.Fatal(e)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatal("private API accepted an unauthenticated caller")
	}
	data, err := json.Marshal(map[string]any{"origin": origin, "apiBase": origin + "/api/v1", "certificatePem": string(certificate), "hostTrackId": host.ID, "offeredTrackId": offered.ID, "stopFile": manifest + ".stop", "runtimeVerified": false, "boundary": "synthetic provider/extractor only; actual SQL/JWT/Connect/Redis worker/S3 and API; Android qualification is separate"})
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(manifest, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Log("owned TLS native Jam backend ready; public certificate and scope in private manifest")
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.After(15 * time.Minute)
	for {
		select {
		case <-deadline:
			t.Fatal("bounded native Jam backend expired without stop receipt")
		case <-ticker.C:
			if _, e = os.Stat(manifest + ".stop"); errors.Is(e, os.ErrNotExist) {
				continue
			} else if e != nil {
				t.Fatal(e)
			}
			var jobs, decisions int
			if e = sqlDB.QueryRowContext(ctx, `SELECT count(*) FROM download_jobs`).Scan(&jobs); e != nil {
				t.Fatal(e)
			}
			if e = sqlDB.QueryRowContext(ctx, `SELECT count(*) FROM source_selection_decisions`).Scan(&decisions); e != nil {
				t.Fatal(e)
			}
			result, _ := json.MarshalIndent(map[string]any{"jobs": jobs, "decisions": decisions, "providerCalls": provider.calls.Load(), "mediaReads": mediaReads.Load(), "mediaBearerLeak": mediaBearerLeak.Load(), "runtimeVerified": false, "note": "backend observations only; pair with exact-source Android result"}, "", "  ")
			if e = os.WriteFile(filepath.Join(directory, "backend-observations.json"), result, 0600); e != nil {
				t.Fatal(e)
			}
			if mediaBearerLeak.Load() {
				t.Fatal("owner authorization leaked into object reads")
			}
			return
		}
	}
}
