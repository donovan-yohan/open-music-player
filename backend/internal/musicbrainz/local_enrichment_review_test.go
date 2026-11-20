package musicbrainz

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const privateDebugTitle = "PrivateTitleCanaryZX"
const privateDebugArtist = "PrivateArtistCanaryZX"
const ordinaryDebugTerm = "OrdinaryDebugCanaryZX"

func TestLocalEnrichmentTLSProtocolAndDiagnostics(t *testing.T) {
	if os.Getenv("ENRICH_TEST_TLS_DIAGNOSTICS") == "1" {
		testLocalEnrichmentTLSProtocolChild(t)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestLocalEnrichmentTLSProtocolAndDiagnostics$", "-test.v")
	cmd.Env = append(os.Environ(), "ENRICH_TEST_TLS_DIAGNOSTICS=1", "GODEBUG=http2debug=2")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("TLS child did not complete: %v\n%s", err, output)
	}
	logs := string(output)
	ordinaryDiagnostic := false
	for _, line := range strings.Split(logs, "\n") {
		isOrdinaryDiagnostic := strings.Contains(line, "http2:") && strings.Contains(line, ordinaryDebugTerm)
		ordinaryDiagnostic = ordinaryDiagnostic || isOrdinaryDiagnostic
		if strings.Contains(line, "wire class=") || strings.Contains(line, "private_connection_reused=") || isOrdinaryDiagnostic {
			t.Log(line)
		}
	}
	if strings.Count(logs, "wire class=ordinary protocol=HTTP/2.0 alpn=h2") != 2 || !ordinaryDiagnostic {
		t.Fatalf("ordinary HTTP/2 diagnostic control not observed:\n%s", logs)
	}
	if strings.Contains(logs, privateDebugTitle) || strings.Contains(logs, privateDebugArtist) {
		t.Errorf("private title or artist appeared in HTTP/2 diagnostics:\n%s", logs)
	}
	if strings.Count(logs, "wire class=private protocol=HTTP/1.1 alpn=http/1.1") != 2 || !strings.Contains(logs, "private_connection_reused=true") {
		t.Errorf("private TLS must negotiate and reuse HTTP/1.1:\n%s", logs)
	}
	if !t.Failed() {
		t.Logf("TLS child combined stdout/stderr (synthetic only):\n%s", output)
	}
}

func testLocalEnrichmentTLSProtocolChild(t *testing.T) {
	type wireEvent struct{ class, protocol, alpn, connection string }
	events := make(chan wireEvent, 4)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query().Get("query")
		class := "ordinary"
		if query == `recording:"`+privateDebugTitle+`" AND artist:"`+privateDebugArtist+`"` {
			class = "private"
		} else if query != ordinaryDebugTerm {
			t.Errorf("unexpected fixture path/query: %s", r.URL)
		}
		if r.URL.Path != "/ws/2/recording" || r.Host != "musicbrainz.org" {
			t.Errorf("unexpected provider target: %s %s", r.Host, r.URL.Path)
		}
		events <- wireEvent{class, r.Proto, r.TLS.NegotiatedProtocol, r.RemoteAddr}
		_, _ = io.WriteString(w, `{"count":0,"recordings":[]}`)
	}))
	server.EnableHTTP2 = true
	server.TLS = &tls.Config{NextProtos: []string{"h2", "http/1.1"}}
	server.StartTLS()
	defer server.Close()
	u, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	transport := server.Client().Transport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.TLSClientConfig.ServerName = u.Hostname()
	transport.TLSClientConfig.NextProtos = []string{"h2", "http/1.1"}
	transport.ForceAttemptHTTP2 = true
	transport.DialContext = func(ctx context.Context, _, addr string) (net.Conn, error) {
		if addr != "musicbrainz.org:443" {
			return nil, fmt.Errorf("unexpected dial target: %s", addr)
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", u.Host)
	}
	defer transport.CloseIdleConnections()
	// A fresh child substitutes only the concrete default transport's loopback
	// dial and trust settings; the client's private/default branch is unmodified.
	http.DefaultTransport = transport
	client := NewClient(nil)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := client.SearchTracks(ctx, ordinaryDebugTerm, 10, 0, false); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := NewClient(nil).SearchLocalEnrichment(ctx, privateDebugTitle, privateDebugArtist); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := client.SearchTracks(ctx, ordinaryDebugTerm, 10, 0, false); err != nil {
		t.Fatal(err)
	}
	var private []string
	for i := 0; i < 4; i++ {
		select {
		case event := <-events:
			t.Logf("wire class=%s protocol=%s alpn=%s", event.class, event.protocol, event.alpn)
			if event.class == "private" {
				private = append(private, event.connection)
			}
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	t.Logf("private_connection_reused=%t", len(private) == 2 && private[0] == private[1])
}

type opaqueEnrichmentTestTransport func(*http.Request) (*http.Response, error)

func (transport opaqueEnrichmentTestTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return transport(r)
}

func TestLocalEnrichmentRefusesUnconfinedConfiguredTransport(t *testing.T) {
	called := false
	opaque := opaqueEnrichmentTestTransport(func(*http.Request) (*http.Response, error) {
		called = true
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"count":0,"recordings":[]}`))}, nil
	})
	client := NewClient(nil)
	client.httpClient.Transport = opaque
	if _, err := client.SearchLocalEnrichment(context.Background(), "Paper", ""); err != ErrLocalEnrichmentUnavailable || called {
		t.Errorf("unknown transport received private input: dispatched=%t err=%v", called, err)
	}
	called = false
	if _, err := client.SearchTracks(context.Background(), "Paper", 10, 0, false); err != nil || !called {
		t.Errorf("ordinary configured transport was not used: dispatched=%t err=%v", called, err)
	}
	called = false
	client = NewClient(nil)
	client.httpClient.Transport = &http.Transport{DialTLSContext: func(context.Context, string, string) (net.Conn, error) {
		called = true
		return nil, fmt.Errorf("custom TLS dial")
	}}
	if _, err := client.SearchLocalEnrichment(context.Background(), "Paper", ""); err != ErrLocalEnrichmentUnavailable || called {
		t.Errorf("unconfined TLS dial was used: dialed=%t err=%v", called, err)
	}
}
