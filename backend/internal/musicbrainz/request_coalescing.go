package musicbrainz

import "context"

type inflightRequest struct {
	done chan struct{}
	body []byte // read-only bytes; each caller independently decodes its own DTO
	err  error
}

// Share only overlapping identical public provider reads on this Client. This
// is not another persistent cache or cross-process stampede protection. A cache
// hit never reaches this method; skipCache still skips cache but may share I/O.
func (c *Client) doRequest(ctx context.Context, reqURL string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Different response/retry ceilings must never inherit an unbounded flight
	// (or impose a bounded leader failure on ordinary metadata consumers).
	flightKey := reqURL
	if radarReadBounded(ctx) {
		flightKey += "\x00radar-1mib-1retry"
	}
	c.requestsMu.Lock()
	if pending := c.requests[flightKey]; pending != nil {
		c.requestsMu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-pending.done:
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			return pending.body, pending.err
		}
	}
	pending := &inflightRequest{done: make(chan struct{})}
	if c.requests == nil {
		c.requests = make(map[string]*inflightRequest)
	}
	c.requests[flightKey] = pending
	c.requestsMu.Unlock()

	// The synchronous leader owns upstream cancellation/deadline. Waiters can
	// leave independently without canceling it. A leader failure is shared, not
	// cached; a later call starts fresh. No detached worker/context is created.
	pending.body, pending.err = c.requestWithRetry(ctx, reqURL)
	c.requestsMu.Lock()
	delete(c.requests, flightKey)
	close(pending.done)
	c.requestsMu.Unlock()
	return pending.body, pending.err
}
