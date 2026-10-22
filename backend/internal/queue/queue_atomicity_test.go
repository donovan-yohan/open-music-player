package queue

import (
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// isolatedQueueRedis starts a disposable real Redis, never REDIS_URL or a
// developer's existing database. No volumes, credentials, workers, or persistence.
func isolatedQueueRedis(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("isolated Redis tests require Docker")
	}
	name := "omp-queue-test-" + uuid.NewString()
	out, err := exec.Command("docker", "run", "--rm", "-d", "--name", name,
		"-p", "127.0.0.1::6379", "redis:7.4-alpine", "redis-server",
		"--save", "", "--appendonly", "no").CombinedOutput()
	if err != nil {
		t.Fatalf("start isolated Redis: %v: %s", err, out)
	}
	t.Cleanup(func() {
		if out, err := exec.Command("docker", "rm", "-f", name).CombinedOutput(); err != nil {
			t.Errorf("remove isolated Redis: %v: %s", err, out)
		}
		out, err := exec.Command("docker", "ps", "-a", "--filter", "name=^/"+name+"$", "--format", "{{.ID}}").CombinedOutput()
		if err != nil || strings.TrimSpace(string(out)) != "" {
			t.Errorf("verify isolated Redis removal: %v: %s", err, out)
		} else {
			t.Log("verified removed isolated Redis", name)
		}
	})
	out, err = exec.Command("docker", "port", name, "6379/tcp").CombinedOutput()
	if err != nil {
		t.Fatalf("isolated Redis port: %v: %s", err, out)
	}
	addr := strings.TrimSpace(string(out))
	host, port, err := net.SplitHostPort(addr)
	if err != nil || host != "127.0.0.1" {
		t.Fatalf("expected loopback-only isolated Redis, got %q: %v", addr, err)
	}
	if _, err := strconv.Atoi(port); err != nil {
		t.Fatal(err)
	}
	client := redis.NewClient(&redis.Options{Addr: addr})
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for {
		if err := client.Ping(ctx).Err(); err == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatalf("isolated Redis readiness: %v", ctx.Err())
		case <-time.After(20 * time.Millisecond):
		}
	}
	info, err := client.Info(ctx, "server").Result()
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(info, "\n") {
		if strings.HasPrefix(line, "redis_version:") {
			t.Log(strings.TrimSpace(line), "disposable loopback container", name, "at", addr)
		}
	}
	return "redis://" + addr
}

func queueTestService(t *testing.T, redisURL string) *Service {
	t.Helper()
	s, err := NewService(redisURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// Pause after the first real GET has captured its value, not before the read.
// The other client can now commit, forcing the suspended writer to detect stale
// state. Hooks are inherited by go-redis WATCH transactions.
type queueReadPause struct {
	armed      atomic.Bool
	read       chan struct{}
	release    chan struct{}
	resumeOnce sync.Once
}

func newQueueReadPause() *queueReadPause {
	p := &queueReadPause{read: make(chan struct{}), release: make(chan struct{})}
	p.armed.Store(true)
	return p
}

func (p *queueReadPause) resume() { p.resumeOnce.Do(func() { close(p.release) }) }

func (p *queueReadPause) DialHook(next redis.DialHook) redis.DialHook { return next }
func (p *queueReadPause) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return next
}
func (p *queueReadPause) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, cmd redis.Cmder) error {
		err := next(ctx, cmd)
		if cmd.Name() == "get" && p.armed.CompareAndSwap(true, false) {
			close(p.read)
			select {
			case <-p.release:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		return err
	}
}

func whileQueueReadPaused(t *testing.T, s *Service, mutation func() error, concurrent func()) error {
	t.Helper()
	pause := newQueueReadPause()
	s.client.AddHook(pause)
	done := make(chan error, 1)
	go func() { done <- mutation() }()
	defer pause.resume()
	select {
	case <-pause.read:
	case err := <-done:
		t.Fatalf("mutation finished before queue read: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for mutation's queue read")
	}
	concurrent()
	pause.resume()
	select {
	case err := <-done:
		return err
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for queue mutation")
		return nil
	}
}

func queueTrackIDs(t *testing.T, s *Service, userID string) string {
	t.Helper()
	state, err := s.GetQueue(context.Background(), userID)
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]string, len(state.Items))
	for i, item := range state.Items {
		if item.Position != i {
			t.Fatalf("item %s position = %d, want %d", item.ID, item.Position, i)
		}
		if item.TrackID == nil {
			ids[i] = item.ID
		} else {
			ids[i] = fmt.Sprint(*item.TrackID)
		}
	}
	return strings.Join(ids, ",")
}

func TestRedisQueueAtomicMutations(t *testing.T) {
	url := isolatedQueueRedis(t)
	ctx := context.Background()
	t.Run("concurrent adds preserve both commits", func(t *testing.T) {
		s, other := queueTestService(t, url), queueTestService(t, url)
		user := uuid.NewString()
		err := whileQueueReadPaused(t, s, func() error {
			_, err := s.AddToQueue(ctx, user, 1, "last")
			return err
		}, func() {
			if _, err := other.AddToQueue(ctx, user, 2, "last"); err != nil {
				t.Fatal(err)
			}
		})
		if err != nil {
			t.Fatal(err)
		}
		if got := queueTrackIDs(t, other, user); got != "2,1" {
			t.Fatalf("concurrent adds lost a committed item: got %q, want 2,1", got)
		}
	})
	t.Run("concurrent ensure of same ID is idempotent", func(t *testing.T) {
		s, other := queueTestService(t, url), queueTestService(t, url)
		user := uuid.NewString()
		candidate := SourceCandidate{Title: "source"}
		err := whileQueueReadPaused(t, s, func() error {
			_, err := s.EnsureSourceCandidateWithID(ctx, user, "stable", candidate, "job", "last")
			return err
		}, func() {
			if _, err := other.EnsureSourceCandidateWithID(ctx, user, "stable", candidate, "job", "last"); err != nil {
				t.Fatal(err)
			}
			if _, err := other.AddToQueue(ctx, user, 2, "last"); err != nil {
				t.Fatal(err)
			}
		})
		if err != nil {
			t.Fatal(err)
		}
		if got := queueTrackIDs(t, other, user); got != "stable,2" {
			t.Fatalf("ensure overwrote concurrent commit: got %q, want stable,2", got)
		}
	})
	t.Run("writers rebase on the watched value", func(t *testing.T) {
		for _, operation := range []string{"playlist add", "remove position", "reorder position", "remove ID", "reorder ID", "retry"} {
			t.Run(operation, func(t *testing.T) {
				s, other := queueTestService(t, url), queueTestService(t, url)
				user := uuid.NewString()
				seed, err := other.AddMultipleToQueue(ctx, user, []int64{1, 2, 3}, "last")
				if err != nil {
					t.Fatal(err)
				}
				target := seed.Items[1].ID
				if _, err := other.EnsureSourceCandidateWithID(ctx, user, "source", SourceCandidate{Title: "source"}, "job", "last"); err != nil {
					t.Fatal(err)
				}
				want := ""
				err = whileQueueReadPaused(t, s, func() error {
					var err error
					switch operation {
					case "playlist add":
						_, err = s.AddMultipleToQueue(ctx, user, []int64{4, 5}, "last")
					case "remove position":
						_, err = s.RemoveFromQueue(ctx, user, 1)
					case "reorder position":
						_, err = s.ReorderQueue(ctx, user, 1, 0)
					case "remove ID":
						_, err = s.RemoveQueueItem(ctx, user, target)
					case "reorder ID":
						_, err = s.ReorderQueueItem(ctx, user, target, 0)
					case "retry":
						_, _, err = s.RetryQueueItem(ctx, user, "source")
					}
					return err
				}, func() {
					if _, err := other.AddToQueue(ctx, user, 9, "0"); err != nil {
						t.Fatal(err)
					}
					switch operation {
					case "playlist add":
						want = "9,1,2,3,source,4,5"
					case "remove position":
						want = "9,2,3,source"
					case "reorder position":
						want = "1,9,2,3,source"
					case "remove ID":
						want = "9,1,3,source"
					case "reorder ID":
						want = "2,9,1,3,source"
					case "retry":
						want = "9,1,2,3,source"
					}
				})
				if err != nil {
					t.Fatal(err)
				}
				if got := queueTrackIDs(t, other, user); got != want {
					t.Fatalf("%s overwrote concurrent state or targeted wrong identity: got %q, want %q", operation, got, want)
				}
			})
		}
	})
	t.Run("clear fences in flight mutations", func(t *testing.T) {
		for _, operation := range []string{"add", "playlist", "ensure", "remove", "reorder", "retry"} {
			t.Run(operation, func(t *testing.T) {
				s, other := queueTestService(t, url), queueTestService(t, url)
				user := uuid.NewString()
				seed, err := other.AddMultipleToQueue(ctx, user, []int64{1, 2}, "last")
				if err != nil {
					t.Fatal(err)
				}
				if _, err := other.EnsureSourceCandidateWithID(ctx, user, "source", SourceCandidate{}, "job", "last"); err != nil {
					t.Fatal(err)
				}
				want := ""
				err = whileQueueReadPaused(t, s, func() error {
					var err error
					switch operation {
					case "add":
						_, err = s.AddToQueue(ctx, user, 9, "last")
					case "playlist":
						_, err = s.AddMultipleToQueue(ctx, user, []int64{8, 9}, "last")
					case "ensure":
						_, err = s.EnsureSourceCandidateWithID(ctx, user, "new", SourceCandidate{}, "new-job", "last")
					case "remove":
						_, err = s.RemoveQueueItem(ctx, user, seed.Items[0].ID)
					case "reorder":
						_, err = s.ReorderQueueItem(ctx, user, seed.Items[0].ID, 1)
					case "retry":
						_, _, err = s.RetryQueueItem(ctx, user, "source")
					}
					return err
				}, func() {
					if err := other.ClearQueue(ctx, user); err != nil {
						t.Fatal(err)
					}
					if got := queueTrackIDs(t, other, user); got != "" {
						t.Fatalf("clear did not commit: %q", got)
					}
				})
				switch operation {
				case "add":
					want = "9"
				case "playlist":
					want = "8,9"
				case "ensure":
					want = "new"
				default:
					if !errors.Is(err, ErrTrackNotFound) {
						t.Fatalf("%s after clear = %v, want not found", operation, err)
					}
				}
				if want != "" && err != nil {
					t.Fatal(err)
				}
				if got := queueTrackIDs(t, other, user); got != want {
					t.Fatalf("%s resurrected old queue: got %q want %q", operation, got, want)
				}
			})
		}
	})
}

func TestQueueHasOneMutationAuthority(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "queue.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			continue
		}
		ast.Inspect(fn.Body, func(node ast.Node) bool {
			call, ok := node.(*ast.CallExpr)
			if !ok {
				return true
			}
			selector, ok := call.Fun.(*ast.SelectorExpr)
			if ok && (selector.Sel.Name == "Set" || selector.Sel.Name == "Del") && fn.Name.Name != "mutateQueue" {
				t.Errorf("%s bypasses the watched queue mutation authority with %s", fn.Name.Name, selector.Sel.Name)
			}
			return true
		})
	}
}
