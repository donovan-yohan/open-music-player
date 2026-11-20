package musicbrainz

import (
	"context"
	"errors"
	"io"
	"net/http"
	"runtime"
	"strings"
	"testing"
)

func (f fixtureTransport) RoundTripLocalEnrichment(r *http.Request) (*http.Response, error) {
	return f(r)
}

func localEnrichmentFixtureClient(body io.Reader) *Client {
	client := NewClient(nil)
	client.httpClient.Transport = fixtureTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(body)}, nil
	})
	return client
}

const reviewProviderRow = `{"id":"provider-row","title":"Title"}`

type enrichmentReadFunc func([]byte) (int, error)

func (f enrichmentReadFunc) Read(p []byte) (int, error) { return f(p) }

func TestLocalEnrichmentProviderAggregateByteCap(t *testing.T) {
	// Each ignored value is smaller than the limit. Their aggregate plus trailing
	// whitespace must fit; the one-byte excess is not part of a JSON value.
	const bound = 1 << 20
	padding := strings.Repeat("x", 500_000)
	prefix := `{"ignored1":"` + padding + `","count":0,"recordings":[],"ignored2":"` + padding + `"}`
	exact := prefix + strings.Repeat(" ", bound-len(prefix))
	if out, err := localEnrichmentFixtureClient(strings.NewReader(exact)).SearchLocalEnrichment(context.Background(), "Paper", ""); err != nil || len(out) != 0 {
		t.Fatalf("exact provider byte limit rejected: %v %v", out, err)
	}
	if out, err := localEnrichmentFixtureClient(strings.NewReader(exact+" ")).SearchLocalEnrichment(context.Background(), "Paper", ""); err != ErrLocalEnrichmentUnavailable || out != nil {
		t.Fatalf("excess aggregate bytes accepted: %v %v", out, err)
	}
}

func TestLocalEnrichmentProviderReadErrorsPreserveContextOnly(t *testing.T) {
	const sentinel = "provider body error with a private URL"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	reader := enrichmentReadFunc(func([]byte) (int, error) {
		cancel()
		return 0, errors.New(sentinel)
	})
	if out, err := localEnrichmentFixtureClient(reader).SearchLocalEnrichment(ctx, "Paper", ""); err != context.Canceled || out != nil {
		t.Fatalf("provider cancellation lost context or exposed body error: %v %v", out, err)
	}
	reader = func([]byte) (int, error) { return 0, errors.New(sentinel) }
	if out, err := localEnrichmentFixtureClient(reader).SearchLocalEnrichment(context.Background(), "Paper", ""); err != ErrLocalEnrichmentUnavailable || out != nil {
		t.Fatalf("provider body error not sanitized: %v %v", out, err)
	}
	data := `{"count":0,"recordings":[]}`
	reader = func(p []byte) (int, error) {
		if data == "" {
			return 0, io.EOF
		}
		n := copy(p, data)
		data = data[n:]
		return n, io.ErrUnexpectedEOF
	}
	if out, err := localEnrichmentFixtureClient(reader).SearchLocalEnrichment(context.Background(), "Paper", ""); err != ErrLocalEnrichmentUnavailable || out != nil {
		t.Fatalf("valid JSON prefix hid a truncated provider response: %v %v", out, err)
	}
}

type enrichmentProviderReadCount struct {
	r io.Reader
	n int
}

func (r *enrichmentProviderReadCount) Read(buf []byte) (int, error) {
	n, err := r.r.Read(buf)
	r.n += n
	return n, err
}

func TestLocalEnrichmentStopsBeforeDecodingEleventhRow(t *testing.T) {
	body := `{"count":11,"recordings":[` + strings.Repeat(reviewProviderRow+",", 10) +
		`{"id":"extra","title":"` + strings.Repeat("x", 512<<10) + `"}]}`
	read := &enrichmentProviderReadCount{r: strings.NewReader(body)}
	out, err := localEnrichmentFixtureClient(read).SearchLocalEnrichment(context.Background(), "Paper", "")
	if err != ErrLocalEnrichmentUnavailable || out != nil {
		t.Fatalf("eleventh row not refused: %v %v", out, err)
	}
	if read.n >= 4096 {
		t.Fatalf("read %d provider bytes before refusing the eleventh row", read.n)
	}
	t.Logf("refused eleventh row after %d provider bytes (source body %d)", read.n, len(body))
}

func TestLocalEnrichmentDoesNotAllocateIgnoredCollections(t *testing.T) {
	body := `{"count":1,"recordings":[{"id":"first","title":"Title","artist-credit":[{"artist":{"name":"First Artist"}}` +
		strings.Repeat(`,{"artist":{"name":""}}`, 30_000) + `],"releases":[{"id":"edition","title":"First Album","release-group":{"id":"group"}}` +
		strings.Repeat(`,{}`, 70_000) + `]}]}`
	client := localEnrichmentFixtureClient(strings.NewReader(body))
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	out, err := client.SearchLocalEnrichment(context.Background(), "Paper", "")
	runtime.ReadMemStats(&after)
	if err != nil || len(out) != 1 || out[0] != (LocalRecording{ID: "first", Title: "Title", Artist: "First Artist", Album: "First Album", ReleaseID: "edition", ReleaseGroupID: "group"}) {
		t.Fatalf("first credit/edition not preserved: %v %v", out, err)
	}
	allocated := after.TotalAlloc - before.TotalAlloc
	if allocated >= 8<<20 {
		t.Fatalf("ignored collection allocation: %d bytes for a %d-byte response", allocated, len(body))
	}
	t.Logf("ignored collection allocation: %d bytes for a %d-byte response", allocated, len(body))
}

func TestLocalEnrichmentProviderRequiredStructure(t *testing.T) {
	for _, tc := range []struct{ name, body string }{
		{"null row", `{"count":1,"recordings":[null]}`},
		{"missing recordings", `{"count":0}`},
		{"null recordings", `{"count":0,"recordings":null}`},
		{"missing identity", `{"count":1,"recordings":[{"title":"Title"}]}`},
		{"missing title", `{"count":1,"recordings":[{"id":"provider-row"}]}`},
		{"missing count", `{"recordings":[]}`},
		{"positive count without rows", `{"count":1,"recordings":[]}`},
		{"trailing value", `{"count":0,"recordings":[]} null`},
		{"malformed ignored tail", `{"count":1,"recordings":[{"id":"first","title":"Title","releases":[{},]}]}`},
		{"valid empty", `{"count":0,"recordings":[]}`},
		{"valid ten of many", `{"recordings":[` + strings.Repeat(reviewProviderRow+",", 9) + reviewProviderRow + `],"count":123}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			out, err := localEnrichmentFixtureClient(strings.NewReader(tc.body)).SearchLocalEnrichment(context.Background(), "Paper", "")
			switch tc.name {
			case "valid empty":
				if err != nil || len(out) != 0 {
					t.Fatalf("valid empty provider response not accepted: %v %v", out, err)
				}
			case "valid ten of many":
				if err != nil || len(out) != 10 {
					t.Fatalf("valid ten-row provider response not accepted: %v %v", out, err)
				}
			default:
				if err != ErrLocalEnrichmentUnavailable || out != nil {
					t.Fatalf("malformed provider response accepted: %v %v", out, err)
				}
			}
		})
	}
}
