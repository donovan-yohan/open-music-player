package preview

import (
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"strconv"
	"time"
)

const (
	maxRequestBytes = 8 * 1024

	prefixBytes = 1536 // Below net/http buffering; explicitly flush this head.
	chunkBytes  = 32 * 1024
)

// ServeHTTP is mounted only behind the router's bearer-auth middleware.
func (c *Catalog) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if c == nil || len(c.clips) == 0 {
		unavailable(w)
		return
	}
	// No queue: even slow request bodies and slow consumers share this cap.
	select {
	case c.active <- struct{}{}:
		defer func() { <-c.active }()
	default:
		unavailable(w)
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
	item, ok := c.clips[key] // No normalization, provider lookup, or URL egress.
	if !ok || !time.Now().Before(item.expiresAt) {
		unavailable(w)
		return
	}
	data, err := readLocal(ctx, c.dir, item.filename, maxClipBytes, item.length)
	if ctx.Err() != nil {
		return
	}
	if err != nil || sha256.Sum256(data) != item.digest || !validMP3(data, item.rate, item.frames) || !time.Now().Before(item.expiresAt) {
		unavailable(w)
		return
	}
	if ctx.Err() != nil {
		return
	}

	// Validate before committing 200, then serve those same bytes, not a reopened
	// pathname. The clip is buffered in RAM for digest safety, not in HTTP.
	h := w.Header()
	h.Set("Content-Type", "audio/mpeg")
	h.Set("Content-Length", strconv.Itoa(len(data)))
	h.Set("X-SoundQ-Preview-Sample-Rate", strconv.Itoa(item.rate))
	h.Set("X-SoundQ-Preview-Frames", strconv.Itoa(item.frames))
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
