package musicbrainz

import (
	"net/http"
	"strings"
	"sync"
	"time"
)

// One process-local budget per provider origin/application, including Clients
// constructed separately. The production client has one fixed provider origin.
// This does not coordinate other processes or applications sharing an IP.
var providerBudgets = struct {
	sync.Mutex
	origins map[string]*requestBudget
}{origins: make(map[string]*requestBudget)}

type requestBudget struct {
	slot chan struct{}
	next time.Time // protected by slot, never reserved by canceled waiters
}

// Wrap a copy, retaining the configured timeout, redirect policy, cookie jar
// and underlying transport without mutating a Client used by other goroutines.
// Admission is per RoundTrip so automatic canonical-ID redirects are paced too.
func (c *Client) doPacedRequest(req *http.Request) (*http.Response, error) {
	client := *c.httpClient
	if recordingSourceRead(req.Context()) {
		// A merge redirect is not exact recording evidence, and no redirect
		// destination may receive a second request for this endpoint.
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	return doPacedRequestWithClient(req, client)
}

func doPacedRequestWithClient(req *http.Request, client http.Client) (*http.Response, error) {
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = pacedTransport{next: transport}
	return client.Do(req)
}

type pacedTransport struct {
	next http.RoundTripper
}

func (p pacedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	ctx := req.Context()
	scheme, host := strings.ToLower(req.URL.Scheme), strings.ToLower(req.URL.Host)
	if scheme == "https" {
		host = strings.TrimSuffix(host, ":443")
	}
	if scheme == "http" {
		host = strings.TrimSuffix(host, ":80")
	}
	key := scheme + "://" + host + " " + userAgent
	providerBudgets.Lock()
	budget := providerBudgets.origins[key]
	if budget == nil {
		budget = &requestBudget{slot: make(chan struct{}, 1)}
		providerBudgets.origins[key] = budget
	}
	providerBudgets.Unlock()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case budget.slot <- struct{}{}:
	}
	defer func() { <-budget.slot }()
	if delay := time.Until(budget.next); delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Keep admission owned through header return to prevent dispatch overtaking.
	// A conservative one-second cooldown after headers guarantees start spacing
	// even if this goroutine is delayed immediately before HTTP dispatch. Body
	// reads and JSON conversion do not hold the slot. No background timer owner.
	resp, err := weeklyRoundTrip(req, p.next)
	budget.next = time.Now().Add(time.Second)
	return resp, err
}
