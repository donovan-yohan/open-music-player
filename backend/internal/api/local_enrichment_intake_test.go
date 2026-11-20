package api

import (
	"bufio"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

func TestLocalEnrichmentNetworkBodyAdmission(t *testing.T) {
	if os.Getenv("ENRICH_TEST_INTAKE") == "1" {
		testLocalEnrichmentNetworkBodyAdmissionChild(t)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestLocalEnrichmentNetworkBodyAdmission$", "-test.v")
	cmd.Env = append(os.Environ(), "ENRICH_TEST_INTAKE=1")
	output, err := cmd.CombinedOutput()
	t.Logf("real listener receipt:\n%s", output)
	if err != nil {
		t.Fatalf("listener child failed: %v", err)
	}
}

func testLocalEnrichmentNetworkBodyAdmissionChild(t *testing.T) {
	var providerCalls atomic.Int32
	provider := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerCalls.Add(1)
		if r.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" {
			t.Errorf("unexpected provider destination: %s %s", r.Host, r.URL.Path)
		}
		switch query := r.URL.Query().Get("query"); query {
		case `recording:"Paper"`:
			_, _ = io.WriteString(w, `{"count":0,"recordings":[]}`)
		case `recording:"Null Provider Row"`:
			_, _ = io.WriteString(w, `{"count":1,"recordings":[null]}`)
		default:
			t.Errorf("unexpected provider fixture query: %s", query)
		}
	}))
	defer provider.Close()
	providerURL, err := url.Parse(provider.URL)
	if err != nil {
		t.Fatal(err)
	}
	tr := provider.Client().Transport.(*http.Transport).Clone()
	tr.Proxy = nil
	tr.TLSClientConfig.ServerName = providerURL.Hostname()
	tr.DialContext = func(ctx context.Context, _, addr string) (net.Conn, error) {
		if addr != "musicbrainz.org:443" {
			return nil, fmt.Errorf("unexpected dial target: %s", addr)
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", providerURL.Host)
	}
	defer tr.CloseIdleConnections()
	http.DefaultTransport = tr // child only; actual provider dispatch stays on loopback
	router, token := newLocalEnrichmentTestRouter(t, true, musicbrainz.NewClient(nil))
	server := httptest.NewServer(router) // no HTTP server read timeouts
	defer server.Close()
	addr := server.Listener.Addr().String()
	const syntheticInput = `{"title":"Paper"}`

	open := func(t *testing.T, tok string, length int, expect bool, body string) (net.Conn, *bufio.Reader) {
		t.Helper()
		c, err := net.DialTimeout("tcp", addr, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = c.Close() })
		var headers strings.Builder
		if tok != "" {
			fmt.Fprintf(&headers, "Authorization: Bearer %s\r\n", tok)
		}
		if expect {
			headers.WriteString("Expect: 100-continue\r\n")
		}
		if length < 0 {
			headers.WriteString("Transfer-Encoding: chunked\r\n")
		} else {
			fmt.Fprintf(&headers, "Content-Length: %d\r\n", length)
		}
		_ = c.SetWriteDeadline(time.Now().Add(time.Second))
		if _, err := fmt.Fprintf(c, "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nAccept-Encoding: gzip\r\n%s\r\n%s", localEnrichmentTestPath, addr, headers.String(), body); err != nil {
			t.Fatal(err)
		}
		return c, bufio.NewReader(c)
	}
	readStatus := func(t *testing.T, c net.Conn, br *bufio.Reader, within time.Duration, want int) *http.Response {
		t.Helper()
		start := time.Now()
		if err := c.SetReadDeadline(start.Add(within)); err != nil {
			t.Fatal(err)
		}
		resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodPost})
		if err != nil {
			t.Errorf("expected wire status %d within %s: %v", want, within, err)
			return nil
		}
		if resp.StatusCode != want {
			t.Errorf("expected wire status %d, got %d", want, resp.StatusCode)
		}
		t.Logf("wire status=%d elapsed=%s", resp.StatusCode, time.Since(start).Round(time.Millisecond))
		return resp
	}
	finishRefusal := func(t *testing.T, resp *http.Response, br *bufio.Reader) {
		t.Helper()
		if resp == nil {
			return
		}
		if _, err := io.Copy(io.Discard, resp.Body); err != nil {
			t.Error(err)
		}
		_ = resp.Body.Close()
		if !resp.Close {
			t.Error("incomplete HTTP/1 body did not retire its connection")
		}
		if _, err := br.ReadByte(); !errors.Is(err, io.EOF) {
			t.Errorf("rejected connection was not closed promptly: %v", err)
		}
	}
	newToken := func(t *testing.T, n int) string {
		t.Helper()
		user := fmt.Sprintf("aaaaaaaa-aaaa-4aaa-8aaa-%012d", n)
		claims := auth.Claims{UserID: user, RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}
		tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte("local-enrichment-synthetic-signing-key"))
		if err != nil {
			t.Fatal(err)
		}
		return tok
	}
	hold := func(t *testing.T, tok string) (net.Conn, *bufio.Reader) {
		t.Helper()
		c, br := open(t, tok, 100, true, "")
		resp := readStatus(t, c, br, time.Second, http.StatusContinue)
		if resp == nil || resp.StatusCode != http.StatusContinue {
			t.Fatal("fixture did not reach the server's first body read")
		}
		_ = resp.Body.Close()
		if _, err := io.WriteString(c, "{"); err != nil {
			t.Fatal(err)
		}
		return c, br
	}

	t.Run("known oversize and unauthenticated do not drain", func(t *testing.T) {
		c, br := open(t, token, 4097, false, "{")
		finishRefusal(t, readStatus(t, c, br, 750*time.Millisecond, http.StatusRequestEntityTooLarge), br)
		c, br = open(t, "", 100, false, "{")
		finishRefusal(t, readStatus(t, c, br, 750*time.Millisecond, http.StatusUnauthorized), br)
	})
	t.Run("over-limit chunked body does not await end of stream", func(t *testing.T) {
		chunk := strings.Repeat("x", 4097)
		c, br := open(t, token, -1, false, fmt.Sprintf("%x\r\n%s\r\n", len(chunk), chunk))
		finishRefusal(t, readStatus(t, c, br, 750*time.Millisecond, http.StatusRequestEntityTooLarge), br)
	})
	t.Run("router and per-account cap precede body reads", func(t *testing.T) {
		type heldBody struct {
			conn net.Conn
			buf  *bufio.Reader
		}
		var bodies []heldBody
		holdForCap := func(tok string) {
			conn, reader := hold(t, tok)
			bodies = append(bodies, heldBody{conn, reader})
		}
		holdForCap(token)
		c, br := open(t, token, 100, false, "{")
		finishRefusal(t, readStatus(t, c, br, 750*time.Millisecond, http.StatusTooManyRequests), br)
		for i := 1; i <= 3; i++ {
			holdForCap(newToken(t, i))
		}
		c, br = open(t, newToken(t, 4), 100, false, "{")
		finishRefusal(t, readStatus(t, c, br, 750*time.Millisecond, http.StatusTooManyRequests), br)
		for _, held := range bodies {
			if err := held.conn.SetWriteDeadline(time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, err := io.WriteString(held.conn, strings.Repeat(" ", 99)); err != nil {
				t.Fatal(err)
			}
			if resp := readStatus(t, held.conn, held.buf, time.Second, http.StatusBadRequest); resp != nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
			}
		}
	})
	t.Run("stalled body expires and an ordinary next request succeeds", func(t *testing.T) {
		tok := newToken(t, 5)
		c, br := hold(t, tok)
		finishRefusal(t, readStatus(t, c, br, 3500*time.Millisecond, http.StatusRequestTimeout), br)
		if providerCalls.Load() != 0 {
			t.Fatal("an incomplete or rejected body reached the provider")
		}
		c, br = open(t, tok, len(syntheticInput), false, syntheticInput)
		resp := readStatus(t, c, br, 3*time.Second, http.StatusOK)
		if resp == nil {
			return
		}
		defer resp.Body.Close()
		decompressed, err := gzip.NewReader(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(decompressed)
		_ = decompressed.Close()
		if err != nil || !strings.Contains(string(body), `"status":"no_match"`) || resp.Close || providerCalls.Load() != 1 || resp.Header.Get("Server-Timing") == "" || resp.Header.Get("Cache-Control") != "private, no-store" {
			t.Errorf("normal next response: close=%t calls=%d headers=%v body=%s error=%v", resp.Close, providerCalls.Load(), resp.Header, body, err)
		}
	})
	t.Run("null provider row is unavailable not a no-match", func(t *testing.T) {
		const input = `{"title":"Null Provider Row"}`
		c, br := open(t, token, len(input), false, input)
		if resp := readStatus(t, c, br, 3*time.Second, http.StatusServiceUnavailable); resp != nil {
			defer resp.Body.Close()
			reader, err := gzip.NewReader(resp.Body)
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			body, err := io.ReadAll(reader)
			if err != nil || !strings.Contains(string(body), "ENRICHMENT_UNAVAILABLE") || strings.Contains(string(body), "Null Provider Row") || providerCalls.Load() != 2 {
				t.Errorf("malformed provider response not safely classified: calls=%d body=%s err=%v", providerCalls.Load(), body, err)
			}
		}
	})
}

type localEnrichmentReadProbe struct{ reads int }

func (p *localEnrichmentReadProbe) Read([]byte) (int, error) { p.reads++; return 0, io.EOF }
func (*localEnrichmentReadProbe) Close() error               { return nil }

func TestLocalEnrichmentWithoutNetworkDeadlineFailsBeforeRead(t *testing.T) {
	router, token := newLocalEnrichmentTestRouter(t, true, nil)
	body := &localEnrichmentReadProbe{}
	r := httptest.NewRequest(http.MethodPost, localEnrichmentTestPath, body)
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	// A plain recorder intentionally has no SetReadDeadline or unwrap target.
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable || body.reads != 0 {
		t.Fatalf("deadline installation failure allowed intake: status=%d reads=%d", w.Code, body.reads)
	}
}
