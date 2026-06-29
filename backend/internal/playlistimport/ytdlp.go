package playlistimport

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const maxEnumeratorOutputBytes = 8 * 1024 * 1024

type YTDLPEnumerator struct {
	Executable string
	Timeout    time.Duration
}

func NewYTDLPEnumerator() *YTDLPEnumerator {
	return &YTDLPEnumerator{Executable: "yt-dlp", Timeout: 2 * time.Minute}
}

func (e *YTDLPEnumerator) Enumerate(ctx context.Context, sourceURL string, maxItems int) (PlaylistMetadata, []Entry, error) {
	if maxItems <= 0 {
		maxItems = DefaultMaxItems
	}
	executable := e.Executable
	if executable == "" {
		executable = "yt-dlp"
	}
	timeout := e.Timeout
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, executable,
		"--dump-single-json",
		"--flat-playlist",
		"--skip-download",
		"--no-warnings",
		"--playlist-end", strconv.Itoa(maxItems),
		sourceURL,
	)
	var stdout limitedBuffer
	stdout.limit = maxEnumeratorOutputBytes
	var stderr limitedBuffer
	stderr.limit = 64 * 1024
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return PlaylistMetadata{}, nil, ctx.Err()
		}
		return PlaylistMetadata{}, nil, fmt.Errorf("yt-dlp playlist metadata failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	var payload ytdlpPlaylist
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		// Some yt-dlp versions emit one JSON object per line. Handle that as a
		// fallback instead of pretending enumeration broke. this is annoying but real.
		entries, scanErr := parseYTDLPLines(stdout.Bytes(), sourceURL, maxItems)
		if scanErr != nil {
			return PlaylistMetadata{}, nil, fmt.Errorf("parse yt-dlp playlist metadata: %w", err)
		}
		return PlaylistMetadata{}, entries, nil
	}

	entries := make([]Entry, 0, len(payload.Entries))
	for i, raw := range payload.Entries {
		if i >= maxItems {
			break
		}
		entry := raw.toEntry(i + 1)
		if entry.SourceURL == "" && entry.SourceID != "" {
			entry.SourceURL = youtubeWatchURL(entry.SourceID)
		}
		if entry.SourceURL != "" {
			entry.SourceURL = absolutizePlaylistURL(sourceURL, entry.SourceURL)
		}
		entries = append(entries, entry)
	}
	return PlaylistMetadata{Title: payload.Title}, entries, nil
}

type ytdlpPlaylist struct {
	Title   string       `json:"title"`
	Entries []ytdlpEntry `json:"entries"`
}

type ytdlpEntry struct {
	ID           string          `json:"id"`
	URL          string          `json:"url"`
	WebpageURL   string          `json:"webpage_url"`
	OriginalURL  string          `json:"original_url"`
	Title        string          `json:"title"`
	Artist       string          `json:"artist"`
	Album        string          `json:"album"`
	Uploader     string          `json:"uploader"`
	Duration     json.RawMessage `json:"duration"`
	DurationMs   int             `json:"duration_ms"`
	Thumbnail    string          `json:"thumbnail"`
	Availability string          `json:"availability"`
	Error        string          `json:"error"`
}

func (e ytdlpEntry) toEntry(index int) Entry {
	durationMs := e.DurationMs
	if durationMs == 0 && len(e.Duration) > 0 {
		var seconds float64
		if err := json.Unmarshal(e.Duration, &seconds); err == nil && seconds > 0 {
			durationMs = int(seconds * 1000)
		}
	}
	sourceURL := firstNonEmpty(e.WebpageURL, e.OriginalURL, e.URL)
	unavailable := strings.Contains(strings.ToLower(e.Availability), "private") || strings.Contains(strings.ToLower(e.Availability), "deleted") || e.Error != ""
	return Entry{
		Index:        index,
		SourceID:     strings.TrimSpace(e.ID),
		SourceURL:    strings.TrimSpace(sourceURL),
		Title:        strings.TrimSpace(e.Title),
		Artist:       strings.TrimSpace(e.Artist),
		Album:        strings.TrimSpace(e.Album),
		Uploader:     strings.TrimSpace(e.Uploader),
		DurationMs:   durationMs,
		ThumbnailURL: strings.TrimSpace(e.Thumbnail),
		Unavailable:  unavailable,
		Error:        strings.TrimSpace(e.Error),
	}
}

func parseYTDLPLines(data []byte, playlistURL string, maxItems int) ([]Entry, error) {
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 0, 64*1024), maxEnumeratorOutputBytes)
	entries := []Entry{}
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var raw ytdlpEntry
		if err := json.Unmarshal([]byte(line), &raw); err != nil {
			return nil, err
		}
		entry := raw.toEntry(len(entries) + 1)
		if entry.SourceURL == "" && entry.SourceID != "" {
			entry.SourceURL = youtubeWatchURL(entry.SourceID)
		}
		entry.SourceURL = absolutizePlaylistURL(playlistURL, entry.SourceURL)
		entries = append(entries, entry)
		if len(entries) >= maxItems {
			break
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}

func youtubeWatchURL(id string) string {
	return "https://www.youtube.com/watch?v=" + url.QueryEscape(id)
}

func absolutizePlaylistURL(baseRaw, itemRaw string) string {
	if itemRaw == "" {
		return ""
	}
	parsed, err := url.Parse(itemRaw)
	if err == nil && parsed.IsAbs() {
		return itemRaw
	}
	if strings.HasPrefix(itemRaw, "http") {
		return itemRaw
	}
	base, err := url.Parse(baseRaw)
	if err != nil {
		return itemRaw
	}
	resolved, err := base.Parse(itemRaw)
	if err != nil {
		return itemRaw
	}
	return resolved.String()
}

type limitedBuffer struct {
	buf   bytes.Buffer
	limit int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.limit <= 0 || b.buf.Len()+len(p) <= b.limit {
		return b.buf.Write(p)
	}
	remaining := b.limit - b.buf.Len()
	if remaining > 0 {
		_, _ = b.buf.Write(p[:remaining])
	}
	return len(p), nil
}

func (b *limitedBuffer) Bytes() []byte  { return b.buf.Bytes() }
func (b *limitedBuffer) String() string { return b.buf.String() }
