// Standalone, stdlib-only wire probe; no SoundQ configuration or media.
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	previewPath  = "/api/v1/discovery/preview"
	cacheControl = "private, no-store" // Shipped upstream policy.
	prefixBytes  = 1536                // Shipped upstream first flush.
	prefixBudget = 3 * time.Second
	requestLimit = 12 * time.Second
	unavailable  = "preview unavailable\n"
)

// The only release signal stays in this process. There is no HTTP control route
// or timer that automatically sends the tail.
type heldTail struct {
	body          []byte
	accel         bool
	held, release chan struct{}
}

func (f *heldTail) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", cacheControl)
	w.Header().Set("Content-Type", "audio/mpeg")
	w.Header().Set("Content-Length", strconv.Itoa(len(f.body)))
	w.Header().Set("X-SoundQ-Preview-Sample-Rate", "48000")
	w.Header().Set("X-SoundQ-Preview-Frames", "36000")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if f.accel {
		w.Header().Set("X-Accel-Buffering", "no")
	}
	if _, err := w.Write(f.body[:prefixBytes]); err != nil {
		return
	}
	if err := http.NewResponseController(w).Flush(); err != nil {
		return
	}
	f.held <- struct{}{}
	select {
	case <-f.release:
		_, _ = w.Write(f.body[prefixBytes:])
	case <-r.Context().Done():
	}
}

func post(client *http.Client, endpoint string, payload []byte) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer preview-smoke-fixture")
	req.Header.Set("Accept-Encoding", "gzip") // Don't let the client auto-decompress.
	return client.Do(req)
}

func checkAudio(client *http.Client, endpoint string, f *heldTail) error {
	prefix, done := make(chan string, 1), make(chan error, 1)
	started := time.Now()
	go func() {
		done <- func() error {
			res, err := post(client, endpoint, f.body[:32])
			if err != nil {
				return fmt.Errorf("POST failed: %T", err)
			}
			defer res.Body.Close()
			if res.StatusCode != http.StatusOK || res.ContentLength != int64(len(f.body)) {
				return fmt.Errorf("expected 200 and the fixture Content-Length; got %d, %d", res.StatusCode, res.ContentLength)
			}
			for name, want := range map[string]string{
				"Content-Type": "audio/mpeg", "Cache-Control": cacheControl,
				"X-SoundQ-Preview-Sample-Rate": "48000", "X-SoundQ-Preview-Frames": "36000",
			} {
				if res.Header.Get(name) != want {
					return fmt.Errorf("unexpected %s", name)
				}
			}
			if len(res.Header.Values("Content-Encoding")) != 0 {
				return errors.New("audio response was encoded")
			}
			got := make([]byte, len(f.body))
			if _, err := io.ReadFull(res.Body, got[:prefixBytes]); err != nil || !bytes.Equal(got[:prefixBytes], f.body[:prefixBytes]) {
				return errors.New("missing exact fixture prefix")
			}
			prefix <- res.Proto
			if _, err := io.ReadFull(res.Body, got[prefixBytes:]); err != nil || !bytes.Equal(got, f.body) {
				return errors.New("missing exact fixture tail")
			}
			if _, err := res.Body.Read(make([]byte, 1)); err != io.EOF {
				return errors.New("expected EOF after fixture bytes")
			}
			return nil
		}()
	}()

	// First establish that the origin has flushed and is now holding its tail.
	select {
	case <-f.held:
	case err := <-done:
		close(f.release)
		return fmt.Errorf("exchange ended before origin hold: %v", err)
	case <-time.After(requestLimit):
		close(f.release)
		return errors.New("fixture origin did not reach the hold")
	}
	var early bool
	select {
	case protocol := <-prefix:
		early = true
		fmt.Printf("  exact %d-byte prefix observed with tail held over %s (%s from POST)\n", prefixBytes, protocol, time.Since(started).Round(time.Millisecond))
	case err := <-done:
		close(f.release)
		return fmt.Errorf("exchange ended during hold: %v", err)
	case <-time.After(prefixBudget):
	}
	close(f.release)
	if err := <-done; err != nil {
		return err
	}
	if !early {
		return fmt.Errorf("prefix missed %s held-tail deadline; full bytes arrived only after release", prefixBudget)
	}
	fmt.Printf("  all %d bytes and EOF verified after release\n", len(f.body))
	return nil
}

func checkError(client *http.Client, endpoint, encoding string) error {
	res, err := post(client, endpoint, []byte("{}"))
	if err != nil {
		return fmt.Errorf("POST failed: %T", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusNotFound || res.Header.Get("Cache-Control") != cacheControl {
		return fmt.Errorf("expected fixture 404 and no-store; got status %d", res.StatusCode)
	}
	if got := res.Header.Get("Content-Encoding"); got != encoding {
		return fmt.Errorf("Content-Encoding = %q, want %q", got, encoding)
	}
	var reader io.Reader = res.Body
	if encoding == "gzip" {
		gz, err := gzip.NewReader(res.Body)
		if err != nil {
			return err
		}
		defer gz.Close()
		reader = gz
	}
	body, err := io.ReadAll(io.LimitReader(reader, 128))
	if err != nil || string(body) != unavailable {
		return errors.New("unexpected fixture error body")
	}
	return nil
}

func newHeldTail(accel bool) *heldTail {
	fixture := &heldTail{make([]byte, 12288), accel, make(chan struct{}, 1), make(chan struct{})}
	_, _ = rand.Read(fixture.body)
	return fixture
}

func run(receiver string, port int) error {
	transport := &http.Transport{DisableCompression: true, ForceAttemptHTTP2: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: requestLimit, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	listener, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return fmt.Errorf("fixture listen failed: %w", err)
	}
	direct, shipped, accel := newHeldTail(false), newHeldTail(false), newHeldTail(true)
	fixture := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer preview-smoke-fixture" {
			http.NotFound(w, r)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 128))
		if err == nil && r.URL.Path == previewPath {
			for _, f := range []*heldTail{direct, shipped, accel} {
				if bytes.Equal(body, f.body[:32]) {
					f.ServeHTTP(w, r)
					return
				}
			}
		}
		w.Header().Set("Cache-Control", cacheControl)
		http.Error(w, strings.TrimSuffix(unavailable, "\n"), http.StatusNotFound)
	})
	server := &http.Server{Handler: fixture, ReadTimeout: requestLimit, WriteTimeout: requestLimit}
	defer server.Close()
	go server.Serve(listener)
	if err := checkAudio(client, "http://"+listener.Addr().String()+previewPath, direct); err != nil {
		return fmt.Errorf("direct origin control: %w", err)
	}
	fmt.Println("PASS: direct origin control (shipped headers)")

	local := receiver == ""
	if local {
		receiver = "http://127.0.0.1:80"
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for {
			conn, err := (&net.Dialer{}).DialContext(ctx, "tcp4", "127.0.0.1:80")
			if err == nil {
				conn.Close()
				break
			}
			if ctx.Err() != nil {
				return errors.New("bundled Nginx did not start")
			}
			time.Sleep(25 * time.Millisecond)
		}
	}
	var failures []error
	check := func(label string, err error) {
		if err != nil {
			fmt.Printf("FAIL: %s: %v\n", label, err)
			failures = append(failures, err)
		} else {
			fmt.Println("PASS: " + label)
		}
	}
	check("receiving route (shipped headers, no X-Accel-Buffering)", checkAudio(client, receiver+previewPath, shipped))
	if local {
		check("receiving route (hypothetical X-Accel-Buffering: no)", checkAudio(client, receiver+previewPath, accel))
	}
	check("exact preview path keeps 404 plain and no-store", checkError(client, receiver+previewPath, ""))
	if local {
		check("trailing-slash path retains ordinary API gzip", checkError(client, receiver+previewPath+"/", "gzip"))
	}
	return errors.Join(failures...)
}

func main() {
	local := flag.Bool("bundled-nginx", false, "internal: use only inside the isolated Nginx smoke container")
	receiver := flag.String("receiver", "", "approved disposable HTTPS origin (no path)")
	port := flag.Int("upstream-port", 8080, "local loopback port the receiving proxy forwards to")
	flag.Parse()
	if *receiver != "" {
		u, err := url.Parse(*receiver)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Path != "" || strings.ContainsAny(*receiver, "?#") {
			fmt.Fprintln(os.Stderr, "-receiver must be a disposable HTTPS origin without a path, credentials, query or fragment")
			os.Exit(2)
		}
	}
	if flag.NArg() != 0 || *port < 1 || *port > 65535 || *local == (*receiver != "") || (*local && *port != 8080) {
		flag.Usage()
		os.Exit(2)
	}
	if err := run(*receiver, *port); err != nil {
		fmt.Fprintln(os.Stderr, "Preview proxy qualification failed:", err)
		os.Exit(1)
	}
}
