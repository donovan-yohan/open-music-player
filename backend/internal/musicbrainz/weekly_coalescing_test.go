package musicbrainz

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Block body consumption, not header return. Shared pacing deliberately owns
// admission until headers return, independently of request coalescing.
type weeklyFlightBody struct {
	*strings.Reader
	ctx     context.Context
	release <-chan struct{}
}

func (b *weeklyFlightBody) Read(p []byte) (int, error) {
	select {
	case <-b.release:
		return b.Reader.Read(p)
	case <-b.ctx.Done():
		return 0, b.ctx.Err()
	}
}

func (b *weeklyFlightBody) Close() error { return nil }

func TestWeeklyCoalescingKeepsDurableAttemptBudgetsSeparate(t *testing.T) {
	for _, separate := range []bool{false, true} {
		name := "same-attempt"
		if separate {
			name = "separate-attempts"
		}
		t.Run(name, func(t *testing.T) {
			withFixtureClock(t, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
				defer cancel()
				first, firstBudget := WithWeeklyReadBudget(ctx)
				second, secondBudget := first, firstBudget
				if separate {
					second, secondBudget = WithWeeklyReadBudget(ctx)
				}
				client := NewClient(nil)
				entered, secondEntered, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
				var calls atomic.Int32
				client.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
					if calls.Add(1) == 1 {
						close(entered)
					} else {
						close(secondEntered)
					}
					resp := fixtureResponse(200, `{"bounded":true}`)
					resp.Body = &weeklyFlightBody{Reader: strings.NewReader(`{"bounded":true}`), ctx: r.Context(), release: release}
					return resp, nil
				})
				results := make(chan error, 2)
				url := "https://musicbrainz.org/ws/2/recording?query=synthetic-weekly-isolation"
				go func() { _, err := client.doRequest(first, url); results <- err }()
				select {
				case <-entered:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				waiter := &waitObservedContext{Context: second, waiting: make(chan struct{})}
				go func() { _, err := client.doRequest(waiter, url); results <- err }()
				if separate {
					select {
					case <-secondEntered:
					case <-ctx.Done():
						t.Fatal("separate durable attempt inherited another budget's flight", ctx.Err())
					}
				} else {
					select {
					case <-waiter.waiting:
					case <-ctx.Done():
						t.Fatal(ctx.Err())
					}
				}
				close(release)
				for n := 0; n < 2; n++ {
					if err := <-results; err != nil {
						t.Fatal(err)
					}
				}
				wantCalls := int32(1)
				if separate {
					wantCalls = 2
				}
				if calls.Load() != wantCalls {
					t.Fatalf("dispatch count %d want %d", calls.Load(), wantCalls)
				}
				for _, budget := range []*WeeklyReadBudget{firstBudget, secondBudget} {
					requests, bytes := budget.Usage()
					if requests != 1 || bytes != int64(len(`{"bounded":true}`)) {
						t.Fatalf("attempt accounting requests=%d bytes=%d", requests, bytes)
					}
				}
			})
		})
	}
}
