package musicbrainz

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
)

const localEnrichmentLimit = 10
const localEnrichmentProviderBytes = 1 << 20

// ErrLocalEnrichmentUnavailable does not retain a request URL, provider body,
// or underlying error. Those may contain the user's unpersisted search terms.
var ErrLocalEnrichmentUnavailable = errors.New("MusicBrainz enrichment unavailable")

// LocalRecording is the provider projection for review, not a verified match.
// IDs are untrusted strings until the API validates and types them.
type LocalRecording struct {
	ID, Title, Artist, Album, ReleaseID, ReleaseGroupID string
	DurationMS                                          int
}

// Keep deadlines and cancellation without sharing inbound account or trace
// context with the outbound transport.
type localEnrichmentContext struct{ context.Context }

func (localEnrichmentContext) Value(any) any { return nil }

// One pool for default Enrich clients. Its independent protocol policy leaves
// the ordinary transport (including its HTTP/2 pool) in place.
var defaultLocalEnrichmentTransport = sync.OnceValue(func() http.RoundTripper {
	if transport := localEnrichmentHTTP1Transport(http.DefaultTransport); transport != nil {
		return transport
	}
	return nil
})

// An opaque configured RoundTripper is not presumed private. An explicit
// adapter implementing this method owns privacy, HTTP/1 and no-replay itself
// (for example, a synthetic in-memory fixture with no network egress).
type localEnrichmentRoundTrip func(*http.Request) (*http.Response, error)

func (f localEnrichmentRoundTrip) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func localEnrichmentHTTP1Transport(base http.RoundTripper) *http.Transport {
	transport, ok := base.(*http.Transport)
	if !ok || transport == nil || transport.DialTLSContext != nil {
		return nil // a custom TLS dial can negotiate outside net/http's policy
	}
	// Select only connection settings. Do not copy legacy TLS dialers, protocol
	// handlers, or hooks and headers for ordinary proxy CONNECT requests.
	private := &http.Transport{
		DialContext:            transport.DialContext,
		DisableCompression:     transport.DisableCompression,
		DisableKeepAlives:      transport.DisableKeepAlives,
		ExpectContinueTimeout:  transport.ExpectContinueTimeout,
		IdleConnTimeout:        transport.IdleConnTimeout,
		MaxConnsPerHost:        transport.MaxConnsPerHost,
		MaxIdleConns:           transport.MaxIdleConns,
		MaxIdleConnsPerHost:    transport.MaxIdleConnsPerHost,
		MaxResponseHeaderBytes: transport.MaxResponseHeaderBytes,
		Protocols:              new(http.Protocols),
		ReadBufferSize:         transport.ReadBufferSize,
		ResponseHeaderTimeout:  transport.ResponseHeaderTimeout,
		TLSClientConfig:        transport.TLSClientConfig.Clone(),
		TLSHandshakeTimeout:    transport.TLSHandshakeTimeout,
		WriteBufferSize:        transport.WriteBufferSize,
	}
	if proxy := transport.Proxy; proxy != nil {
		private.Proxy = func(req *http.Request) (*url.URL, error) {
			return proxy(&http.Request{URL: &url.URL{Scheme: req.URL.Scheme, Host: req.URL.Host}})
		}
	}
	private.Protocols.SetHTTP1(true)
	if private.TLSClientConfig != nil {
		private.TLSClientConfig.NextProtos = []string{"http/1.1"}
	}
	return private
}

func (c *Client) localEnrichmentTransport() http.RoundTripper {
	if c.httpClient.Transport == nil {
		return defaultLocalEnrichmentTransport()
	}
	c.localTransportOnce.Do(func() {
		if private, ok := c.httpClient.Transport.(interface {
			RoundTripLocalEnrichment(*http.Request) (*http.Response, error)
		}); ok {
			c.localTransport = localEnrichmentRoundTrip(private.RoundTripLocalEnrichment)
		} else if transport := localEnrichmentHTTP1Transport(c.httpClient.Transport); transport != nil {
			c.localTransport = transport
		}
	})
	return c.localTransport
}

// SearchLocalEnrichment performs one private recording search. It deliberately
// never enters the public Redis cache, retry logger, or coalesced flights.
func (c *Client) SearchLocalEnrichment(ctx context.Context, title, artist string) ([]LocalRecording, error) {
	query := "recording:" + lucenePhrase(title)
	if artist != "" {
		query += " AND artist:" + lucenePhrase(artist)
	}
	values := url.Values{"query": {query}, "limit": {strconv.Itoa(localEnrichmentLimit)}, "offset": {"0"}, "fmt": {"json"}}
	// Deliberately no GetBody: a nil or rewindable GET body permits Go's
	// transport to silently resend the URL after a failed pooled connection.
	// This reader yields zero bytes; it never sends user data as a body.
	empty := io.NopCloser(strings.NewReader(""))
	req, err := http.NewRequestWithContext(localEnrichmentContext{ctx}, http.MethodGet, baseURL+"/recording?"+values.Encode(), empty)
	if err != nil {
		return nil, ErrLocalEnrichmentUnavailable
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/json")

	client := *c.httpClient
	client.Transport = c.localEnrichmentTransport()
	if client.Transport == nil {
		return nil, localEnrichmentProviderError(ctx)
	}
	client.Jar = nil
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := doPacedRequestWithClient(req, client)
	if err != nil {
		return nil, localEnrichmentProviderError(ctx)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, localEnrichmentProviderError(ctx)
	}
	out, ok := decodeLocalEnrichmentProvider(ctx, resp.Body)
	if !ok || ctx.Err() != nil {
		return nil, localEnrichmentProviderError(ctx)
	}
	return out, nil
}

// The decoder reads the decompressed body, with a single limit covering even
// unknown fields and trailing whitespace. It never projects an eleventh row.
func decodeLocalEnrichmentProvider(ctx context.Context, body io.Reader) ([]LocalRecording, bool) {
	bound := &localEnrichmentProviderBody{LimitedReader: io.LimitedReader{R: body, N: localEnrichmentProviderBytes + 1}}
	dec := json.NewDecoder(bound)
	dec.UseNumber()
	if start, err := dec.Token(); err != nil || start != json.Delim('{') {
		return nil, false
	}
	var count *int
	var out []LocalRecording
	for dec.More() {
		key, err := dec.Token()
		if err != nil || ctx.Err() != nil {
			return nil, false
		}
		switch key {
		case "count":
			if count != nil || dec.Decode(&count) != nil || count == nil || *count < 0 {
				return nil, false
			}
		case "recordings":
			if out != nil {
				return nil, false
			}
			out, err = decodeLocalEnrichmentRecordings(ctx, dec)
			if err != nil {
				return nil, false
			}
		default:
			// The standard decoder validates/skips the raw value without
			// creating an object graph or retaining its backing buffer.
			if dec.Decode(new(localEnrichmentDiscard)) != nil {
				return nil, false
			}
		}
	}
	if end, err := dec.Token(); err != nil || end != json.Delim('}') || count == nil || out == nil ||
		*count < len(out) || (*count > 0 && len(out) == 0) {
		return nil, false
	}
	_, err := dec.Token()
	return out, err == io.EOF && bound.N > 0 && !bound.failed
}

type localEnrichmentProviderBody struct {
	io.LimitedReader
	failed bool
}

func (body *localEnrichmentProviderBody) Read(p []byte) (int, error) {
	n, err := body.LimitedReader.Read(p)
	// A decoder may consume the bytes from a Read that also reported an
	// error and later see EOF. A valid JSON prefix is not a complete reply.
	body.failed = body.failed || (err != nil && err != io.EOF)
	return n, err
}

func decodeLocalEnrichmentRecordings(ctx context.Context, dec *json.Decoder) ([]LocalRecording, error) {
	if start, err := dec.Token(); err != nil || start != json.Delim('[') {
		return nil, ErrLocalEnrichmentUnavailable
	}
	out := make([]LocalRecording, 0, localEnrichmentLimit)
	for dec.More() {
		if len(out) == localEnrichmentLimit || ctx.Err() != nil {
			return nil, ErrLocalEnrichmentUnavailable
		}
		var row struct {
			ID      *string `json:"id"`
			Title   *string `json:"title"`
			Length  int     `json:"length"`
			Credits localEnrichmentFirst[struct {
				Artist struct {
					Name string `json:"name"`
				} `json:"artist"`
			}] `json:"artist-credit"`
			Releases localEnrichmentFirst[struct {
				ID    string `json:"id"`
				Title string `json:"title"`
				Group struct {
					ID string `json:"id"`
				} `json:"release-group"`
			}] `json:"releases"`
		}
		// A null element leaves both required fields nil.
		if dec.Decode(&row) != nil || row.ID == nil || *row.ID == "" || row.Title == nil || *row.Title == "" {
			return nil, ErrLocalEnrichmentUnavailable
		}
		edition := row.Releases.value
		out = append(out, LocalRecording{ID: *row.ID, Title: *row.Title, DurationMS: row.Length,
			Artist: row.Credits.value.Artist.Name, Album: edition.Title, ReleaseID: edition.ID, ReleaseGroupID: edition.Group.ID})
	}
	if end, err := dec.Token(); err != nil || end != json.Delim(']') {
		return nil, ErrLocalEnrichmentUnavailable
	}
	return out, nil
}

type localEnrichmentDiscard struct{}

func (*localEnrichmentDiscard) UnmarshalJSON([]byte) error { return nil }

type localEnrichmentFirst[T any] struct{ value T }

// UnmarshalJSON receives an already syntax-validated value from the outer
// decoder. Borrow its bytes and decode just the first credit/edition; ignored
// elements never become Go values or require a separate raw-message copy.
func (first *localEnrichmentFirst[T]) UnmarshalJSON(raw []byte) error {
	*first = localEnrichmentFirst[T]{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	start, err := dec.Token()
	if err != nil || (start != nil && start != json.Delim('[')) {
		return ErrLocalEnrichmentUnavailable
	}
	if start != nil && dec.More() {
		return dec.Decode(&first.value)
	}
	return nil
}

func localEnrichmentProviderError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return ErrLocalEnrichmentUnavailable
}

func lucenePhrase(term string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, ch := range term {
		if strings.ContainsRune(`+-!(){}[]^"~*?:\/&|`, ch) {
			b.WriteByte('\\')
		}
		b.WriteRune(ch)
	}
	b.WriteByte('"')
	return b.String()
}
