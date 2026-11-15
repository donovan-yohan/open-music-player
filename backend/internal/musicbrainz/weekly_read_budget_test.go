package musicbrainz

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestWeeklyBudgetRedirectsAndDestination(t *testing.T) {
	for _, foreign := range []bool{false, true} {
		t.Run(map[bool]string{false: "redirect-loop", true: "foreign-origin"}[foreign], func(t *testing.T) {
			var calls atomic.Int32
			old := http.DefaultTransport
			http.DefaultTransport = budgetFixtureTransport(func(r *http.Request) (*http.Response, error) {
				if r.URL.Host != "musicbrainz.org" {
					t.Fatalf("redirect reached foreign host %s", r.URL.Host)
				}
				n := calls.Add(1)
				host := "https://musicbrainz.org"
				if foreign {
					host = "https://fixture.invalid"
				}
				return &http.Response{StatusCode: 302, Header: http.Header{"Location": []string{host + "/redirect/" + strings.Repeat("x", int(n))}}, Body: io.NopCloser(strings.NewReader("synthetic redirect")), Request: r}, nil
			})
			defer func() { http.DefaultTransport = old }()
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			ctx, budget := WithWeeklyReadBudget(ctx)
			_, e := NewClient(nil).SearchTracks(ctx, "arid:11111111-1111-4111-8111-111111111111", 100, 0, true)
			requests, _ := budget.Usage()
			if e == nil || requests > 4 || int32(requests) != calls.Load() {
				t.Fatalf("redirect budget not enforced requests=%d dispatched=%d err=%v", requests, calls.Load(), e)
			}
			if foreign && (calls.Load() < 1 || calls.Load() > 2) {
				t.Fatal("redirect escaped provider origin")
			}
			if !foreign && calls.Load() != 4 {
				t.Fatal("loop control did not reach exact admission ceiling")
			}
		})
	}
}

type budgetFixtureTransport func(*http.Request) (*http.Response, error)

func (f budgetFixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestWeeklyBudgetCumulativeResponseBytes(t *testing.T) {
	old := http.DefaultTransport
	http.DefaultTransport = budgetFixtureTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"count":0,"recordings":[],"padding":"` + strings.Repeat("x", 700000) + `"}`)), Request: r}, nil
	})
	defer func() { http.DefaultTransport = old }()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ctx, b := WithWeeklyReadBudget(ctx)
	c := NewClient(nil)
	for n := 0; n < 3; n++ {
		_, e := c.SearchTracks(ctx, "synthetic-budget", 100, n*100, true)
		if n < 2 && e != nil {
			t.Fatal(e)
		}
		if n == 2 && e == nil {
			t.Fatal("cumulative body ceiling absent")
		}
	}
	calls, bytes := b.Usage()
	if calls != 3 || bytes != 2097152 {
		t.Fatal("actual budget accounting", calls, bytes)
	}
}
