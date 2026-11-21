package api

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/cache"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

// A loopback RESP fixture that answers Redis initialization and parks one
// observed command without sending any of its reply before the test ends.
func stalledCatalogRedis(t *testing.T, stall string) (string, *atomic.Int32) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop); listener.Close() })
	var hits atomic.Int32
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				go func() { <-stop; conn.Close() }()
				reader := bufio.NewReader(conn)
				for {
					line, err := reader.ReadString('\n')
					if err != nil || !strings.HasPrefix(line, "*") {
						return
					}
					argc, err := strconv.Atoi(strings.TrimSpace(line[1:]))
					if err != nil || argc < 1 {
						return
					}
					var command string
					for arg := 0; arg < argc; arg++ {
						header, err := reader.ReadString('\n')
						if err != nil || !strings.HasPrefix(header, "$") {
							return
						}
						size, err := strconv.Atoi(strings.TrimSpace(header[1:]))
						if err != nil || size < 0 || size > 10_000 {
							return
						}
						argBytes := make([]byte, size+2)
						if _, err := io.ReadFull(reader, argBytes); err != nil {
							return
						}
						if arg == 0 {
							command = strings.ToLower(string(argBytes[:size]))
						}
					}
					if command == stall {
						hits.Add(1)
						<-stop
						return
					}
					response := "+OK\r\n"
					switch command {
					case "ping":
						response = "+PONG\r\n"
					case "hello":
						response = "-ERR unknown command 'hello'\r\n"
					case "get":
						response = "$-1\r\n"
					}
					if _, err := io.WriteString(conn, response); err != nil {
						return
					}
				}
			}()
		}
	}()
	return listener.Addr().String(), &hits
}

func TestDiscoveryCatalogSearchRedisStallDoesNotBlockValidPage(t *testing.T) {
	for _, stall := range []string{"get", "set"} {
		t.Run(stall, func(t *testing.T) {
			addr, hits := stalledCatalogRedis(t, stall)
			store, err := cache.New(addr)
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			var upstream atomic.Int32
			mb := musicbrainz.NewClientWithTransport(store, discoveryCatalogTransport(func(*http.Request) (*http.Response, error) {
				upstream.Add(1)
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"count":1,"offset":0,"artists":[{"id":"6f12404a-c015-4b05-bc96-33594ade1227","name":"Tiffany Day","score":100}]}`))}, nil
			}))
			h := discovery.NewHandlersWithAssistAndSelectionStore(discovery.NewService(discovery.ServiceConfig{MusicCatalog: mb}), nil, nil)
			w := httptest.NewRecorder()
			start := time.Now()
			h.CatalogSearch(w, httptest.NewRequestWithContext(t.Context(), "GET", "/api/v1/discovery/catalog?kind=artist&q=Tiffany+Day", nil))
			elapsed := time.Since(start)
			if hits.Load() != 1 || upstream.Load() != 1 || w.Code != 200 || !strings.Contains(w.Body.String(), "Tiffany Day") || elapsed >= 2500*time.Millisecond {
				t.Fatalf("stalled %s: cache calls=%d upstream=%d status=%d elapsed=%s body=%s", stall, hits.Load(), upstream.Load(), w.Code, elapsed, w.Body.String())
			}
		})
	}
}
