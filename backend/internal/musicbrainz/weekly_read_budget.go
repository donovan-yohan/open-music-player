package musicbrainz

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sync"
)

type weeklyBudgetKey struct{}

// WeeklyReadBudget belongs to one durably admitted generation. It counts real
// RoundTrips including redirects and retries, and all response bytes read.
// It cannot loosen the shared process-local pacing owner.
type WeeklyReadBudget struct {
	mu        sync.Mutex
	requests  int
	bodyBytes int64
}

func WithWeeklyReadBudget(ctx context.Context) (context.Context, *WeeklyReadBudget) {
	b := &WeeklyReadBudget{}
	return context.WithValue(WithRadarReadBudget(ctx), weeklyBudgetKey{}, b), b
}
func weeklyBudget(ctx context.Context) *WeeklyReadBudget {
	b, _ := ctx.Value(weeklyBudgetKey{}).(*WeeklyReadBudget)
	return b
}
func (b *WeeklyReadBudget) Usage() (int, int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.requests, b.bodyBytes
}
func (b *WeeklyReadBudget) admit() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.requests >= 4 {
		return fmt.Errorf("weekly provider request budget exhausted")
	}
	b.requests++
	return nil
}

type weeklyBody struct {
	io.ReadCloser
	budget *WeeklyReadBudget
}

func (b weeklyBody) Read(p []byte) (int, error) {
	b.budget.mu.Lock()
	defer b.budget.mu.Unlock()
	remaining := int64(2097152) - b.budget.bodyBytes
	if remaining <= 0 {
		return 0, fmt.Errorf("weekly provider body budget exhausted")
	}
	if int64(len(p)) > remaining {
		p = p[:remaining]
	}
	n, e := b.ReadCloser.Read(p)
	b.budget.bodyBytes += int64(n)
	return n, e
}
func weeklyRoundTrip(req *http.Request, next http.RoundTripper) (*http.Response, error) {
	budget := weeklyBudget(req.Context())
	if budget == nil {
		return next.RoundTrip(req)
	}
	// Redirects must not turn an admitted metadata read into a hidden second host.
	if req.URL.Scheme != "https" || req.URL.Host != "musicbrainz.org" {
		return nil, fmt.Errorf("weekly provider redirect destination refused")
	}
	if e := budget.admit(); e != nil {
		return nil, e
	}
	resp, e := next.RoundTrip(req)
	if resp != nil && resp.Body != nil {
		resp.Body = weeklyBody{resp.Body, budget}
	}
	return resp, e
}
