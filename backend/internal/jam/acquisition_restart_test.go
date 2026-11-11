package jam_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"github.com/redis/go-redis/v9"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/jam"
	"github.com/openmusicplayer/backend/internal/playlistimport"
	"github.com/openmusicplayer/backend/internal/processor"
	"github.com/openmusicplayer/backend/internal/storage"
)

const restartSource = "https://www.youtube.com/watch?v=partyrestart"
const restartExit = 73

// Only the external provider/extractor is controlled. It downloads real media
// over loopback HTTP. The production processor, worker, SQL schema, publication,
// lifecycle and S3 storage are exercised without contacting a provider/account.
type restartSearcher struct{}

func (restartSearcher) Search(context.Context, string, []string, int) discovery.SearchResponse {
	return discovery.SearchResponse{Results: []discovery.Candidate{{CandidateID: "youtube:partyrestart", Provider: "youtube", SourceID: "partyrestart", SourceURL: restartSource, Title: "Restart proof", Artist: "Local controlled adapter", DurationMs: 1000, Downloadable: true}}}
}

var errRestartLostResponse = errors.New("controlled lost Redis publish response")

// Drop the successful EVAL/EVALSHA response at the Redis client seam, after
// Redis executed the real publication. Do not fake an accepted queue job.
type restartLostResponseHook struct{ lost atomic.Bool }

func (*restartLostResponseHook) DialHook(next redis.DialHook) redis.DialHook { return next }
func (*restartLostResponseHook) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return next
}
func (h *restartLostResponseHook) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, cmd redis.Cmder) error {
		err := next(ctx, cmd)
		if err == nil && (cmd.Name() == "eval" || cmd.Name() == "evalsha") && h.lost.CompareAndSwap(false, true) {
			return errRestartLostResponse
		}
		return err
	}
}

type restartPublisher struct {
	service *download.Service
	cut     string
}

func (p restartPublisher) EnsureSourceCandidateWithID(ctx context.Context, job, owner string, candidate download.SourceCandidate, mb *string) (*download.DownloadJob, error) {
	if p.cut == "sql_committed" {
		os.Exit(restartExit)
	}
	result, err := p.service.EnsureSourceCandidateWithID(ctx, job, owner, candidate, mb)
	if errors.Is(err, errRestartLostResponse) && p.cut == "publish_accepted" {
		os.Exit(restartExit)
	}
	return result, err
}

// This observes the actual production startup consumer, before real workers start.
type restartStartProbe struct {
	*download.Service
	started bool
	t       *testing.T
}

func (s *restartStartProbe) Start() {
	s.started = true
	if os.Getenv("PARTY_RESTART_TERMINAL") == "1" && os.Getenv("PARTY_RESTART_EXPECT_RECOVERY_ERROR") != "1" {
		if n, err := s.GetQueueLength(context.Background()); err != nil || n != 0 {
			s.t.Errorf("terminal stale copies runnable BEFORE workers: %d %v", n, err)
		}
	}
	s.Service.Start()
}

type restartLifecycle struct {
	*db.SourceSelectionDownloadLifecycle
	cut string
}

func (l restartLifecycle) Complete(ctx context.Context, job *download.DownloadJob) error {
	if l.cut == "artifact_stored" {
		os.Exit(restartExit)
	}
	err := l.SourceSelectionDownloadLifecycle.Complete(ctx, job)
	if err == nil && l.cut == "sql_complete" {
		os.Exit(restartExit)
	}
	return err
}

// Pattern matches the existing native Jam helper: exact newly-created Docker
// IDs, ephemeral loopback ports and cleanup by ID, never a shared dependency.
func restartContainer(t *testing.T, image, port string, environment map[string]string, args ...string) string {
	t.Helper()
	command := []string{"run", "-d", "--name", "soundq-jam-restart-" + uuid.NewString(), "--label", "soundq.fixture=jam-restart", "-p", "127.0.0.1::" + port}
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
		t.Fatal("start owned restart dependency:", err)
	}
	id := strings.TrimSpace(string(output))
	if len(id) != 64 {
		t.Fatal("missing exact Docker incarnation")
	}
	if _, err = hex.DecodeString(id); err != nil {
		t.Fatal("invalid Docker incarnation")
	}
	t.Cleanup(func() {
		if err := exec.Command("docker", "rm", "-f", id).Run(); err != nil {
			t.Error("cleanup owned dependency:", err)
			return
		}
		if exec.Command("docker", "inspect", id).Run() == nil {
			t.Error("owned dependency survived cleanup")
		} else {
			t.Log("removed owned container", id)
		}
	})
	output, err = exec.Command("docker", "port", id, port+"/tcp").Output()
	address := strings.TrimSpace(string(output))
	if err != nil || !strings.HasPrefix(address, "127.0.0.1:") || strings.Contains(address, "\n") {
		t.Fatal("non-loopback dependency")
	}
	return address
}
func restartWait(t *testing.T, probe func() bool) {
	t.Helper()
	deadline := time.Now().Add(45 * time.Second)
	for !probe() {
		if time.Now().After(deadline) {
			t.Fatal("restart proof condition timed out")
		}
		time.Sleep(30 * time.Millisecond)
	}
}
func restartSQL(t *testing.T, dsn string) *db.DB {
	t.Helper()
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal("protected DSN refused")
	}
	connection, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open owned SQL")
	}
	t.Cleanup(func() { _ = connection.Close() })
	restartWait(t, func() bool { return connection.Ping() == nil })
	database := &db.DB{DB: connection}
	if err = database.CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatal("protected database refused")
	}
	return database
}
func restartObjects(t *testing.T) *storage.Client {
	t.Helper()
	client, err := storage.New(&storage.Config{Endpoint: os.Getenv("PARTY_RESTART_S3"), Region: "us-east-1", AccessKey: "restartfixture", SecretKey: os.Getenv("PARTY_RESTART_S3_SECRET"), Bucket: "party-restart"})
	if err != nil {
		t.Fatal(err)
	}
	return client
}
func restartRun(t *testing.T, env []string, phase string, crash bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Second)
	defer cancel()
	child := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestPartyRecoveryProcess$", "-test.v")
	child.Env = append(append(os.Environ(), env...), "PARTY_RESTART_PHASE="+phase)
	output, err := child.CombinedOutput()
	var exited *exec.ExitError
	if crash {
		if !errors.As(err, &exited) || exited.ExitCode() != restartExit {
			t.Fatalf("cut %s did not reach abrupt process exit: %v\n%s", phase, err, output)
		}
	} else if err != nil {
		t.Fatalf("process %s: %v\n%s", phase, err, output)
	}
	t.Logf("process %s (crash=%t)\n%s", phase, crash, output)
}

// This child opens every repository, SQL/Redis connection, publisher and
// processor afresh. Exit cuts run inside the real consuming calls, not a replay
// of a captured Go object. Its parent alone owns dependency cleanup.
func TestPartyRecoveryProcess(t *testing.T) {
	phase := os.Getenv("PARTY_RESTART_PHASE")
	if phase == "" {
		t.Skip("private process helper")
	}
	ctx := context.Background()
	database := restartSQL(t, os.Getenv("PARTY_RESTART_DSN"))
	life := db.NewSourceSelectionDownloadLifecycle(database)
	uploads := restartObjects(t)
	proc := processor.New(&processor.ProcessorConfig{TrackRepo: db.NewTrackRepository(database), LibraryRepo: db.NewLibraryRepository(database), SourceRepo: playlistimport.NewTrackSourceRepository(database), Storage: uploads})
	process := func(ctx context.Context, job *download.DownloadJob, progress func(int)) error {
		if phase == "worker_claimed" {
			os.Exit(restartExit)
		}
		if job.URL != restartSource || job.SourceID != "partyrestart" || job.CandidateID != "youtube:partyrestart" || job.UserID != os.Getenv("PARTY_RESTART_OWNER") {
			return errors.New("captured identity changed")
		}
		return proc.Process(ctx, job, progress)
	}
	service, err := download.NewService(&download.ServiceConfig{RedisURL: os.Getenv("PARTY_RESTART_REDIS"), WorkerCount: 1, JobTimeout: 30 * time.Second}, process, restartLifecycle{life, phase})
	if err != nil {
		t.Fatal("construct fresh download service")
	}
	defer service.Stop(ctx)
	owner := jam.Owner{UserID: uuid.MustParse(os.Getenv("PARTY_RESTART_OWNER"))}
	party := uuid.MustParse(os.Getenv("PARTY_RESTART_JAM"))
	repo := jam.NewRepository(database.DB)
	if phase == "sql_committed" || phase == "publish_accepted" {
		if phase == "publish_accepted" {
			service.Queue().Client().AddHook(&restartLostResponseHook{})
		}
		repo.Downloads = restartPublisher{service, phase}
		proof := jam.Proof{HostDeviceID: uuid.MustParse(os.Getenv("PARTY_RESTART_DEVICE")), LeaseID: uuid.MustParse(os.Getenv("PARTY_RESTART_LEASE")), WriterSecret: os.Getenv("PARTY_RESTART_WRITER")}
		_, err = repo.Approve(ctx, owner, party, proof, uuid.MustParse(os.Getenv("PARTY_RESTART_REQUEST")), jam.ApprovalInput{ExpectedVersion: 2, HostSessionID: "restart-host"})
		t.Fatal("approval cut did not exit", err)
	}
	// Exact production boot seam, before Service.Start, with no playback intent
	// for a party acquisition. Recover twice to prove publication is idempotent.
	for i := 0; i < 2 && os.Getenv("PARTY_RESTART_EXPECT_RECOVERY_ERROR") != "1"; i++ {
		if _, err = life.RecoverWithPlayback(ctx, service, nil, 0); err != nil {
			t.Fatal(err)
		}
	}
	start := &restartStartProbe{Service: service, t: t}
	_, err = life.RecoverAndStart(ctx, start, nil, 0)
	if os.Getenv("PARTY_RESTART_EXPECT_RECOVERY_ERROR") == "1" {
		// Logging/returning an error alone must not start the real worker pool.
		if err == nil {
			t.Error("identity conflict did not refuse startup")
		}
		if start.started {
			t.Error("recovery error ignored: production startup started workers")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	restartWait(t, func() bool {
		var status string
		if err := database.QueryRow(`SELECT status FROM download_jobs LIMIT 1`).Scan(&status); err != nil {
			return false
		}
		if status == "failed" {
			t.Fatal("real acquisition failed")
		}
		return status == "complete"
	})
	// Deliberately do not poll the party here. Completion must survive process
	// death before the host's first request-status/receipt read.
}

func TestPartyAcquisitionDisposableRestart(t *testing.T) {
	if os.Getenv("PARTY_RESTART_DISPOSABLE") != "1" {
		t.Skip("set PARTY_RESTART_DISPOSABLE=1 for owned SQL/Redis/S3 process proof")
	}
	for _, tool := range []string{"docker", "ffmpeg", "ffprobe", "python3"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatal("missing proof tool", tool)
		}
	}
	ctx := context.Background()
	password := jam.NewSecret()
	pg := restartContainer(t, "postgres:16-alpine", "5432", map[string]string{"POSTGRES_USER": "fixture", "POSTGRES_PASSWORD": password, "POSTGRES_DB": "fixture"})
	redisAddress := restartContainer(t, "redis:7-alpine", "6379", nil, "redis-server", "--save", "", "--appendonly", "no")
	s3Secret := jam.NewSecret()
	s3Address := restartContainer(t, "soundq-ci-deps-minio:local", "9000", map[string]string{"MINIO_ROOT_USER": "restartfixture", "MINIO_ROOT_PASSWORD": s3Secret}, "minio", "server", "/data", "--address", ":9000")
	dsn := "postgres://fixture:" + password + "@" + pg + "/fixture?sslmode=disable"
	admin := restartSQL(t, dsn)
	client := redis.NewClient(&redis.Options{Addr: redisAddress})
	defer client.Close()
	restartWait(t, func() bool { return client.Ping(ctx).Err() == nil })
	t.Setenv("PARTY_RESTART_S3", "http://"+s3Address)
	t.Setenv("PARTY_RESTART_S3_SECRET", s3Secret)
	objects := restartObjects(t)
	restartWait(t, func() bool { return objects.EnsureBucket(ctx) == nil })
	directory := t.TempDir()
	audio := filepath.Join(directory, "controlled.mp3")
	if err := exec.Command("ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-ac", "2", "-ar", "48000", "-codec:a", "libmp3lame", audio).Run(); err != nil {
		t.Fatal(err)
	}
	media, err := os.ReadFile(audio)
	if err != nil {
		t.Fatal(err)
	}
	var reads atomic.Int32
	adapter := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/media" || r.URL.Query().Get("source") != restartSource {
			http.Error(w, "unexpected selected source", 400)
			return
		}
		reads.Add(1)
		w.Header().Set("Content-Type", "audio/mpeg")
		_, _ = w.Write(media)
	}))
	defer adapter.Close()
	// Explicit local controlled extractor. It accepts only the exact selected
	// URL and retrieves the actual audio via the parent's loopback HTTP adapter.
	extractor := `#!/usr/bin/env python3
import os, sys, urllib.request
args=sys.argv[1:]
assert args[-1] == 'https://www.youtube.com/watch?v=partyrestart'
output=args[args.index('-o')+1].replace('%(ext)s','mp3')
with urllib.request.urlopen(os.environ['PARTY_RESTART_MEDIA'], timeout=10) as response:
    data=response.read(1024*1024)
assert data
with open(output,'wb') as target:
    target.write(data)
`
	if err = os.WriteFile(filepath.Join(directory, "yt-dlp"), []byte(extractor), 0700); err != nil {
		t.Fatal(err)
	}
	for _, cut := range []string{"sql_committed", "publish_accepted", "worker_claimed", "artifact_stored", "sql_complete", "sql_complete_removed", "redis_complete_removed", "redis_complete_stale", "sql_complete_recovery_error"} {
		crashCut := cut
		removed := cut == "sql_complete_removed" || cut == "redis_complete_removed"
		if removed || cut == "redis_complete_stale" || cut == "sql_complete_recovery_error" {
			crashCut = "sql_complete"
		}
		t.Run(cut, func(t *testing.T) {
			schema := "party_restart_" + strings.ReplaceAll(uuid.NewString(), "-", "")
			if _, err := admin.Exec(`CREATE DATABASE ` + schema); err != nil {
				t.Fatal(err)
			}
			caseDSN := strings.Replace(dsn, "/fixture?", "/"+schema+"?", 1)
			database := restartSQL(t, caseDSN)
			if err := database.Migrate(); err != nil {
				t.Fatal(err)
			}
			owner := jam.Owner{UserID: uuid.New()}
			if _, err := database.Exec(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'restart-fixture','fixture-not-a-login')`, owner.UserID, owner.UserID.String()+"@example.invalid"); err != nil {
				t.Fatal(err)
			}
			tracks := db.NewTrackRepository(database)
			host, _, err := tracks.CreateTrackFromMetadata(ctx, "Local artist", "Offered", "", 1000, db.WithStorage("not-read-by-this-test", 1))
			if err != nil {
				t.Fatal(err)
			}
			if _, err = db.NewLibraryRepository(database).AddTrackToLibrary(ctx, owner.UserID, host.ID); err != nil {
				t.Fatal(err)
			}
			repo := jam.NewRepository(database.DB)
			repo.Searcher = restartSearcher{}
			service, err := download.NewService(&download.ServiceConfig{RedisURL: "redis://" + redisAddress + "/0", WorkerCount: 0}, nil, db.NewSourceSelectionDownloadLifecycle(database))
			if err != nil {
				t.Fatal(err)
			}
			defer service.Queue().Close()
			repo.Downloads = service
			party := uuid.New()
			proof := jam.Proof{HostDeviceID: uuid.New(), LeaseID: uuid.New(), WriterSecret: jam.NewSecret()}
			if _, err = repo.Create(ctx, owner, jam.CreateInput{JamID: party, Proof: proof, TrackIDs: []int64{host.ID}, AllowOutsideDiscovery: true}); err != nil {
				t.Fatal(err)
			}
			invite, err := repo.RotateInvite(ctx, owner, party, proof)
			if err != nil {
				t.Fatal(err)
			}
			secret := jam.NewSecret()
			if _, err = repo.Join(ctx, party, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: secret}); err != nil {
				t.Fatal(err)
			}
			search, err := repo.Search(ctx, party, secret, jam.SearchInput{SearchID: uuid.New(), Query: "Restart proof"})
			if err != nil {
				t.Fatal(err)
			}
			request := jam.SourceRequestInput{RequestID: uuid.New(), SelectionSessionID: search.SearchID, CandidateID: search.Results[0].CandidateID, ExpectedVersion: 1}
			if _, err = repo.AddSourceRequest(ctx, party, secret, request); err != nil {
				t.Fatal(err)
			}
			env := []string{"PARTY_RESTART_DSN=" + caseDSN, "PARTY_RESTART_REDIS=redis://" + redisAddress + "/0", "PARTY_RESTART_OWNER=" + owner.UserID.String(), "PARTY_RESTART_JAM=" + party.String(), "PARTY_RESTART_REQUEST=" + request.RequestID.String(), "PARTY_RESTART_DEVICE=" + proof.HostDeviceID.String(), "PARTY_RESTART_LEASE=" + proof.LeaseID.String(), "PARTY_RESTART_WRITER=" + proof.WriterSecret, "PARTY_RESTART_MEDIA=" + adapter.URL + "/media?source=" + restartSource, "PATH=" + directory + string(os.PathListSeparator) + os.Getenv("PATH")}
			beforeReads := reads.Load()
			approval := jam.ApprovalInput{ExpectedVersion: 2, HostSessionID: "restart-host"}
			if cut == "sql_committed" || cut == "publish_accepted" {
				restartRun(t, env, cut, true)
			} else {
				if _, err = repo.Approve(ctx, owner, party, proof, request.RequestID, approval); err != nil {
					t.Fatal(err)
				}
			}
			// Keep immutable approval/decision/source identity from SQL, not a retained
			// request object. A later source-session replacement cannot redirect it.
			var jobID, decisionID uuid.UUID
			var capture []byte
			if err = database.QueryRow(`SELECT download_job_id,id,selected_candidate FROM source_selection_decisions`).Scan(&jobID, &decisionID, &capture); err != nil {
				t.Fatal(err)
			}
			if cut == "sql_committed" {
				if n := client.Exists(ctx, "download:job:"+jobID.String()).Val(); n != 0 {
					t.Fatal("Redis publish preceded cut")
				}
			}
			if cut == "publish_accepted" {
				if n := client.LLen(ctx, "download:queue").Val(); n != 1 {
					t.Fatal("accepted publication missing")
				}
			}
			if _, err = database.Exec(`UPDATE source_selection_sessions SET candidates=jsonb_set(candidates,'{0,sourceUrl}','"https://www.youtube.com/watch?v=replaced"'),created_at=now()-interval '4 minutes',expires_at=now()-interval '1 second'`); err != nil {
				t.Fatal(err)
			}
			if crashCut == "worker_claimed" || crashCut == "artifact_stored" || crashCut == "sql_complete" {
				restartRun(t, env, crashCut, true)
			}
			if crashCut != "sql_complete" {
				snapshot, err := repo.HostSnapshot(ctx, owner, party)
				if err != nil {
					t.Fatal(err)
				}
				if q := snapshot.HostRequests[0]; q.Status != "importing" || q.CanAdmit || q.TrackID != 0 {
					t.Fatalf("interrupted acquisition became playable: %+v", q)
				}
				if _, err = repo.Decide(ctx, owner, party, proof, request.RequestID, jam.DecisionInput{ExpectedVersion: snapshot.Version, Status: "queued", Receipt: &jam.AdmissionReceipt{RequestID: request.RequestID, SessionID: "restart-host", OccurrenceID: "must-not-enter"}}); err == nil {
					t.Fatal("import accepted queued receipt")
				}
			}
			if cut == "sql_complete" {
				// A terminal SQL receipt must not follow a forged Redis owner or
				// source, or advertise a track whose Library membership was removed.
				key := "download:job:" + jobID.String()
				raw, err := client.Get(ctx, key).Bytes()
				if err != nil {
					t.Fatal(err)
				}
				var original download.DownloadJob
				if err = json.Unmarshal(raw, &original); err != nil {
					t.Fatal(err)
				}
				life := db.NewSourceSelectionDownloadLifecycle(database)
				for _, variant := range []string{"owner", "source", "membership"} {
					changed := original
					switch variant {
					case "owner":
						changed.UserID = uuid.NewString()
					case "source":
						changed.URL = "https://www.youtube.com/watch?v=wrong"
					case "membership":
						if _, err = database.Exec(`DELETE FROM user_library WHERE user_id=$1 AND track_id=(SELECT track_id FROM download_jobs WHERE id=$2)`, owner.UserID, jobID); err != nil {
							t.Fatal(err)
						}
					}
					payload, err := json.Marshal(changed)
					if err != nil {
						t.Fatal(err)
					}
					if err = client.Set(ctx, key, payload, 0).Err(); err != nil {
						t.Fatal(err)
					}
					_, err = life.Recover(ctx, service, 10)
					if variant != "membership" && !errors.Is(err, db.ErrSourceSelectionConflict) {
						t.Fatal("forged completion identity was not refused", err)
					}
					if variant == "membership" && err != nil {
						t.Fatal(err)
					}
					job, err := service.GetJob(ctx, jobID.String())
					if err != nil || job.TrackID != nil || (variant != "membership" && job.Status != download.StatusUploading) || job.Status == download.StatusComplete {
						t.Fatal("invalid completion advertised playable job", err)
					}
					if err = client.Set(ctx, key, raw, 0).Err(); err != nil {
						t.Fatal(err)
					}
					if variant == "membership" {
						if _, err = database.Exec(`INSERT INTO user_library(user_id,track_id) SELECT user_id,track_id FROM download_jobs WHERE id=$1`, jobID); err != nil {
							t.Fatal(err)
						}
					}
				}
				// A stale queued copy of a committed job must be retired before a
				// fresh worker can reacquire it.
				if err = client.LPush(ctx, "download:queue", jobID.String()).Err(); err != nil {
					t.Fatal(err)
				}
			}
			if removed {
				// Keep the reviewer's exact membership removal in force THROUGH startup.
				if _, err = database.Exec(`DELETE FROM user_library WHERE user_id=$1 AND track_id=(SELECT track_id FROM download_jobs WHERE id=$2)`, owner.UserID, jobID); err != nil {
					t.Fatal(err)
				}
			}
			if cut == "redis_complete_removed" || cut == "redis_complete_stale" {
				if err = client.Set(ctx, "download:job:"+jobID.String(), func() []byte {
					job, e := service.GetJob(ctx, jobID.String())
					if e != nil {
						t.Fatal(e)
					}
					var track int64
					if e = database.QueryRow(`SELECT track_id FROM download_jobs WHERE id=$1`, jobID).Scan(&track); e != nil {
						t.Fatal(e)
					}
					job.Status = download.StatusComplete
					job.TrackID = &track
					data, e := json.Marshal(job)
					if e != nil {
						t.Fatal(e)
					}
					return data
				}(), 0).Err(); err != nil {
					t.Fatal(err)
				}
			}
			if removed || cut == "redis_complete_stale" || cut == "sql_complete_recovery_error" {
				if err = client.LPush(ctx, "download:queue", jobID.String(), jobID.String(), jobID.String()).Err(); err != nil {
					t.Fatal(err)
				}
			}
			if crashCut == "sql_complete" {
				env = append(env, "PARTY_RESTART_TERMINAL=1")
			}
			if cut == "sql_complete_recovery_error" {
				job, e := service.GetJob(ctx, jobID.String())
				if e != nil {
					t.Fatal(e)
				}
				job.URL = "https://www.youtube.com/watch?v=wrong"
				data, e := json.Marshal(job)
				if e != nil {
					t.Fatal(e)
				}
				if e = client.Set(ctx, "download:job:"+jobID.String(), data, 0).Err(); e != nil {
					t.Fatal(e)
				}
				env = append(env, "PARTY_RESTART_EXPECT_RECOVERY_ERROR=1")
			}
			restartRun(t, env, "recover", false)
			if cut == "sql_complete_recovery_error" {
				if delta := reads.Load() - beforeReads; delta != 1 {
					t.Errorf("error startup transferred again: %d", delta)
				}
				var status string
				if e := database.QueryRow(`SELECT status FROM download_jobs WHERE id=$1`, jobID).Scan(&status); e != nil || status != "complete" {
					t.Errorf("error startup rewound SQL: %s %v", status, e)
				}
				if n := client.LLen(ctx, "download:queue").Val(); n != 3 {
					t.Errorf("identity refusal mutated stale copies: %d", n)
				}
				client.LRem(ctx, "download:queue", 0, jobID.String())
				client.Del(ctx, "download:job:"+jobID.String())
				return
			}
			if removed {
				// Assertions are independent: a readiness failure cannot mask extra transfer
				// or a durable rewind. This is deliberately not the playable happy path.
				if delta := reads.Load() - beforeReads; delta != 1 {
					t.Errorf("controlled media transfers=%d want 1", delta)
				}
				var status string
				var n int
				if err = database.QueryRow(`SELECT status FROM download_jobs WHERE id=$1`, jobID).Scan(&status); err != nil || status != "complete" {
					t.Errorf("SQL terminal rewound: %s %v", status, err)
				}
				if err = database.QueryRow(`SELECT count(*) FROM user_library WHERE user_id=$1 AND track_id=(SELECT track_id FROM download_jobs WHERE id=$2)`, owner.UserID, jobID).Scan(&n); err != nil || n != 0 {
					t.Errorf("removed membership restored: %d %v", n, err)
				}
				job, e := service.GetJob(ctx, jobID.String())
				if e != nil || job.Status == download.StatusComplete || job.TrackID != nil {
					t.Errorf("unplayable completion advertised: %+v %v", job, e)
				}
				if n := client.LLen(ctx, "download:queue").Val(); n != 0 {
					t.Errorf("stale entries remain runnable: %d", n)
				}
				view, e := repo.HostSnapshot(ctx, owner, party)
				if e != nil {
					t.Fatal(e)
				}
				q := view.HostRequests[0]
				if q.Status == "ready" || q.CanAdmit || q.Receipt != nil {
					t.Errorf("removed track admissible: %+v", q)
				}
				if _, e = repo.Decide(ctx, owner, party, proof, request.RequestID, jam.DecisionInput{ExpectedVersion: view.Version, Status: "queued", Receipt: &jam.AdmissionReceipt{RequestID: request.RequestID, SessionID: "restart-host", OccurrenceID: "must-not-enter"}}); e == nil {
					t.Error("removed track accepted admission")
				}
				if e = service.RetryJob(ctx, jobID.String()); e == nil {
					t.Error("terminal SQL job accepted manual retry")
				}
				if n := client.LLen(ctx, "download:queue").Val(); n != 0 {
					t.Errorf("manual retry revived terminal acquisition: %d", n)
				}
				client.Del(ctx, "download:job:"+jobID.String())
				client.LRem(ctx, "download:queue", 0, jobID.String())
				return
			}
			// Reopen connections and reconstruct party repository after worker exit.
			recovered := restartSQL(t, caseDSN)
			fresh := jam.NewRepository(recovered.DB)
			fresh.Downloads = service
			// The host heartbeat may have elapsed during process startup. Ordinary
			// authority renewal is not replaying approval or re-running discovery.
			if _, err = fresh.Heartbeat(ctx, owner, party, jam.HeartbeatInput{Proof: proof, HostSequence: 1}); err != nil {
				t.Fatal(err)
			}
			view, err := fresh.HostSnapshot(ctx, owner, party)
			if err != nil {
				t.Fatal(err)
			}
			q := view.HostRequests[0]
			if q.Status != "ready" || !q.CanAdmit || q.TrackID <= 0 || q.DownloadJobID != jobID || q.RequestID != request.RequestID || q.ApprovalOrder != 1 || q.HostSessionID != "restart-host" || q.Receipt != nil || view.OwnerUserID != owner.UserID || view.OwnerAuthGeneration != 0 {
				t.Fatalf("recovered party identity/readiness: %+v", q)
			}
			redisJob, err := service.GetJob(ctx, jobID.String())
			if err != nil || redisJob.Status != download.StatusComplete || redisJob.TrackID == nil || *redisJob.TrackID != q.TrackID {
				t.Fatalf("durable completion did not converge in Redis: job=%+v err=%v", redisJob, err)
			}
			var sameJob, sameDecision uuid.UUID
			var sameCapture []byte
			var n int
			if err = recovered.QueryRow(`SELECT download_job_id,id,selected_candidate FROM source_selection_decisions`).Scan(&sameJob, &sameDecision, &sameCapture); err != nil {
				t.Fatal(err)
			}
			if sameJob != jobID || sameDecision != decisionID || !bytes.Equal(capture, sameCapture) {
				t.Fatal("durable source identity changed")
			}
			for _, query := range []string{`SELECT count(*) FROM download_jobs`, `SELECT count(*) FROM source_selection_decisions`, `SELECT count(*) FROM track_sources WHERE source_id='partyrestart'`, `SELECT count(*) FROM user_library WHERE track_id<>` + fmt.Sprint(host.ID), `SELECT count(*) FROM tracks WHERE id<>` + fmt.Sprint(host.ID)} {
				if err = recovered.QueryRow(query).Scan(&n); err != nil || n != 1 {
					t.Fatalf("one acquisition invariant: count=%d err=%v query=%s", n, err, query)
				}
			}
			track, err := db.NewTrackRepository(recovered).GetByID(ctx, q.TrackID)
			if err != nil {
				t.Fatal(err)
			}
			body, _, err := objects.GetObject(ctx, track.StorageKey.String)
			if err != nil {
				t.Fatal(err)
			}
			stored, err := io.ReadAll(body)
			_ = body.Close()
			if err != nil || sha256.Sum256(stored) != sha256.Sum256(media) {
				t.Fatal("stored playable media bytes changed")
			}
			downloaded := filepath.Join(directory, "readback-"+cut+".mp3")
			if err = os.WriteFile(downloaded, stored, 0600); err != nil {
				t.Fatal(err)
			}
			if err = exec.Command("ffmpeg", "-nostdin", "-v", "error", "-i", downloaded, "-f", "null", "-").Run(); err != nil {
				t.Fatal("stored media did not decode")
			}
			receipt := jam.DecisionInput{ExpectedVersion: view.Version, Status: "queued", Receipt: &jam.AdmissionReceipt{RequestID: request.RequestID, SessionID: "restart-host", OccurrenceID: "local-occurrence"}}
			if _, err = fresh.Decide(ctx, owner, party, proof, request.RequestID, receipt); err != nil {
				t.Fatal(err)
			}
			final := jam.NewRepository(recovered.DB)
			if _, err = final.Decide(ctx, owner, party, proof, request.RequestID, receipt); err != nil {
				t.Fatal("lost receipt ACK retry", err)
			}
			settled, err := final.HostSnapshot(ctx, owner, party)
			if err != nil || settled.HostRequests[0].Status != "queued" || settled.HostRequests[0].Receipt.OccurrenceID != "local-occurrence" {
				t.Fatal("receipt failed to survive repository reconstruction", err)
			}
			expectedReads := int32(1)
			if cut == "artifact_stored" {
				expectedReads = 2
			}
			if delta := reads.Load() - beforeReads; delta != expectedReads {
				t.Fatalf("controlled media transfers=%d want %d", delta, expectedReads)
			}
			t.Logf("one SQL job/decision/source/track; exact S3 bytes decode; receipt durable; controlled HTTP transfers=%d", expectedReads)
			// Only this subcase's Redis job is removed; no FLUSHDB or shared DSN.
			client.LRem(ctx, "download:queue", 0, jobID.String())
			client.Del(ctx, "download:job:"+jobID.String())
			client.ZRem(ctx, "download:user:"+owner.UserID.String(), jobID.String())
		})
	}
}
