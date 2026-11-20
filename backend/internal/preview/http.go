package preview

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/openmusicplayer/backend/internal/validators"
)

const (
	maxRequestBytes = 8 * 1024

	prefixBytes = 1536 // Below net/http buffering; explicitly flush this head.
	chunkBytes  = 32 * 1024
	// Leave headroom for reading the request and sending its headers before
	// Android's 20-second deadline. A slow client gets its own body budget.
	acquisitionTimeout = 11 * time.Second
	transferTimeout    = 35 * time.Second
	onDemandRate       = 48000
)

// ServeHTTP is mounted only behind the router's bearer-auth middleware.
func (c *Catalog) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if c == nil || (len(c.clips) == 0 && c.fetch == nil) {
		unavailable(w)
		return
	}
	// No queue: even slow request bodies and slow consumers share this cap.
	select {
	case c.active <- struct{}{}:
		defer func() { <-c.active }()
	default:
		if c.fetch == nil {
			unavailable(w)
		} else {
			http.Error(w, "preview busy", http.StatusServiceUnavailable)
		}
		return
	}

	ctx := r.Context()
	controller := http.NewResponseController(w)
	if ctx.Err() != nil {
		return
	}
	var key string
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRequestBytes))
	if r.URL.RawQuery != "" || r.URL.ForceQuery || !decodeObject(dec, map[string]any{"url": &key}) ||
		!atEOF(dec) || len(key) == 0 || len(key) > maxURLBytes {
		http.Error(w, "invalid preview request", http.StatusBadRequest)
		return
	}
	var data []byte
	var rate, frames int
	if c.fetch != nil {
		if canonicalSource(parseSource(key)) == validators.SourceUnknown {
			unavailable(w)
			return
		}
		acquisition, cancel := context.WithTimeout(ctx, acquisitionTimeout)
		var err error
		data, err = c.fetch(acquisition, key)
		timedOut := acquisition.Err() == context.DeadlineExceeded
		cancel()
		if ctx.Err() != nil {
			return
		}
		if timedOut {
			http.Error(w, "preview acquisition timed out", http.StatusServiceUnavailable)
			return
		}
		rate = onDemandRate
		if err != nil {
			unavailable(w)
			return
		}
		frames = mp3Frames(data, rate)
		if frames == 0 {
			unavailable(w)
			return
		}
	} else {
		item, ok := c.clips[key]
		if !ok || !time.Now().Before(item.expiresAt) {
			unavailable(w)
			return
		}
		var err error
		data, err = readLocal(ctx, c.dir, item.filename, maxClipBytes, item.length)
		if ctx.Err() != nil {
			return
		}
		if err != nil || sha256.Sum256(data) != item.digest || !validMP3(data, item.rate, item.frames) || !time.Now().Before(item.expiresAt) {
			unavailable(w)
			return
		}
		rate, frames = item.rate, item.frames
	}
	if ctx.Err() != nil {
		return
	}

	// Validate before committing 200, then stream those same bytes. Once they
	// are available, slow mobile delivery need not inherit the acquisition clock.
	if c.fetch != nil {
		_ = controller.SetWriteDeadline(time.Now().Add(transferTimeout))
	}
	h := w.Header()
	h.Set("Content-Type", "audio/mpeg")
	h.Set("Content-Length", strconv.Itoa(len(data)))
	h.Set("X-SoundQ-Preview-Sample-Rate", strconv.Itoa(rate))
	h.Set("X-SoundQ-Preview-Frames", strconv.Itoa(frames))
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	for limit := prefixBytes; len(data) != 0; limit = chunkBytes {
		if ctx.Err() != nil {
			return
		}
		n := min(limit, len(data))
		if written, err := w.Write(data[:n]); err != nil || written != n {
			return
		}
		if limit == prefixBytes && controller.Flush() != nil {
			return
		}
		data = data[n:]
	}
}

func unavailable(w http.ResponseWriter) {
	http.Error(w, "preview unavailable", http.StatusNotFound)
}
