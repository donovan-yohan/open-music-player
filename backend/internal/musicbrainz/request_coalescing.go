package musicbrainz

import (
	"context"
	"errors"
)

type inflightRequest struct {
	done          chan struct{}
	body          []byte // read-only bytes; each caller independently decodes its own DTO
	err           error
	ownerCanceled bool
	next          *inflightRequest // protected by requestsMu; shared bounded takeover
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
	bounded := radarReadBounded(ctx)
	if bounded {
		flightKey += "\x00radar-1mib-1retry"
	}
	c.requestsMu.Lock()
	pending := c.requests[flightKey]
	leader := pending == nil
	if leader {
		pending = &inflightRequest{done: make(chan struct{})}
		if c.requests == nil {
			c.requests = make(map[string]*inflightRequest)
		}
		c.requests[flightKey] = pending
	}
	c.requestsMu.Unlock()

	for {
		if leader {
			// A synchronous owner keeps its original context, pacing, response and
			// retry limits. No detached worker or renewed deadline is introduced.
			pending.body, pending.err = c.requestWithRetry(ctx, reqURL)
			pending.ownerCanceled = ctx.Err() != nil && errors.Is(pending.err, ctx.Err())
			c.requestsMu.Lock()
			delete(c.requests, flightKey)
			close(pending.done)
			c.requestsMu.Unlock()
			return pending.body, pending.err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-pending.done:
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			// Ordinary metadata still shares leader failures. Only a live radar
			// waiter may recover actual owner cancellation, not provider errors.
			if !bounded || !pending.ownerCanceled {
				return pending.body, pending.err
			}
		}
		c.requestsMu.Lock()
		if pending.next == nil {
			pending.next = c.requests[flightKey]
			if pending.next == nil {
				pending.next = &inflightRequest{done: make(chan struct{})}
				c.requests[flightKey] = pending.next
				leader = true
			}
		}
		// Retain the successor on the retired flight so even a delayed original
		// waiter joins that same takeover rather than launching duplicate I/O.
		pending = pending.next
		c.requestsMu.Unlock()
	}
}
