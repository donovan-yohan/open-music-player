package musicbrainz

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

func TestRadarReadBudgetSeparatesUnboundedFlight(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	c := NewClient(nil)
	c.httpClient = &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(entered)
			<-release
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", 1048577))), Header: make(http.Header)}, nil
	})}
	unbounded := make(chan error, 1)
	go func() { _, e := c.doRequest(context.Background(), "https://radar-budget.invalid/test"); unbounded <- e }()
	<-entered
	bounded := make(chan error, 1)
	go func() {
		_, e := c.doRequest(WithRadarReadBudget(context.Background()), "https://radar-budget.invalid/test")
		bounded <- e
	}()
	close(release)
	if err := <-unbounded; err != nil {
		t.Fatal("unrelated default changed", err)
	}
	if err := <-bounded; err == nil {
		t.Fatal("oversized radar body admitted")
	}
	if calls.Load() != 2 {
		t.Fatalf("bounded/unbounded shared flight: %d", calls.Load())
	}
}
func TestRadarReadBudgetLimitsRetries(t *testing.T) {
	var starts atomic.Int32
	c := NewClient(nil)
	c.httpClient = &http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		starts.Add(1)
		return &http.Response{StatusCode: 503, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}, nil
	})}
	_, err := c.doRequest(WithRadarReadBudget(context.Background()), "https://radar-retries.invalid/test")
	if err == nil || starts.Load() != 2 {
		t.Fatalf("retry budget %d %v", starts.Load(), err)
	}
}
