package musicbrainz

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/cache"
)

// Finite loopback RESP fixture exercises the existing concrete Redis cache.
// It is not a real service, account or shared local Redis instance.
func fixturePublicCache(t *testing.T) *cache.Cache {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	values := make(map[string]string)
	var wg sync.WaitGroup
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
				r := bufio.NewReader(conn)
				for {
					line, err := r.ReadString('\n')
					if err != nil {
						return
					}
					n, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "*")))
					if err != nil {
						return
					}
					args := make([]string, n)
					for i := range args {
						line, err = r.ReadString('\n')
						if err != nil {
							return
						}
						size, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "$")))
						if err != nil || size < 0 {
							return
						}
						b := make([]byte, size+2)
						if _, err := io.ReadFull(r, b); err != nil {
							return
						}
						args[i] = string(b[:size])
					}
					mu.Lock()
					response := "+OK\r\n"
					switch strings.ToLower(args[0]) {
					case "hello":
						response = "-ERR unknown command 'hello'\r\n"
					case "ping":
						response = "+PONG\r\n"
					case "client":
					case "get":
						if v, ok := values[args[1]]; ok {
							response = fmt.Sprintf("$%d\r\n%s\r\n", len(v), v)
						} else {
							response = "$-1\r\n"
						}
					case "set":
						values[args[1]] = args[2]
					default:
						response = "-ERR unsupported fixture command\r\n"
					}
					mu.Unlock()
					if _, err := io.WriteString(conn, response); err != nil {
						return
					}
				}
			}()
		}
	}()
	c, err := cache.New(ln.Addr().String())
	if err != nil {
		_ = ln.Close()
		<-stopped
		wg.Wait()
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close(); _ = ln.Close(); <-stopped; wg.Wait() })
	return c
}

func legacySearchKey(entity, query string, limit, offset int) string {
	hash := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:%d", query, limit, offset)))
	return "mb:" + entity + ":" + hex.EncodeToString(hash[:8])
}

func TestRecordingSearchIgnoresOldCacheShapeOnly(t *testing.T) {
	ctx := context.Background()
	store := fixturePublicCache(t)
	oldKey := legacySearchKey("recording", "song", 20, 0)
	old := `{"results":[{"mbid":"old","title":"stale","releaseDate":"2026-11-01"}],"total":1,"limit":20,"offset":0}`
	if err := store.Set(ctx, oldKey, old, time.Hour); err != nil {
		t.Fatal(err)
	}
	artistKey := legacySearchKey("artist", "artist", 20, 0)
	if err := store.Set(ctx, artistKey, `{"results":[{"mbid":"a","name":"cached artist"}],"total":1}`, time.Hour); err != nil {
		t.Fatal(err)
	}
	c := NewClient(store)
	var calls atomic.Int32
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		return fixtureResponse(200, `{"count":1,"recordings":[{"id":"fresh","first-release-date":"1984","artist-credit":[{"artist":{"id":"a","name":"Artist"}}]}]}`), nil
	})
	resp, err := c.SearchTracks(ctx, "song", 20, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Results) != 1 || resp.Results[0].MBID != "fresh" || calls.Load() != 1 {
		t.Fatalf("old DTO masqueraded as enriched metadata: response=%+v calls=%d", resp, calls.Load())
	}
	warm, err := c.SearchTracks(ctx, "song", 20, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatal("new recording metadata was not cached")
	}
	b, err := json.Marshal(warm.Results[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"firstReleaseDate":"1984"`) || !strings.Contains(string(b), `"artistCredits"`) {
		t.Fatalf("enriched cache lost metadata: %s", b)
	}
	artists, err := c.SearchArtists(ctx, "artist", 20, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if artists.Results[0].Name != "cached artist" || calls.Load() != 1 {
		t.Fatal("unaffected artist cache invalidated")
	}
	if got, ok := store.Get(ctx, oldKey); !ok || got != old {
		t.Fatal("legacy cache entry mutated")
	}
	for _, entity := range []string{"artist", "release-group"} {
		if got, want := c.buildCacheKey(entity, "q", 20, 2), legacySearchKey(entity, "q", 20, 2); got != want {
			t.Fatalf("unaffected key %s = %q, want %q", entity, got, want)
		}
	}
}
