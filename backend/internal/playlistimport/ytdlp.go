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

	"github.com/openmusicplayer/backend/internal/playlistsync"
)

const maxEnumeratorOutputBytes = 8 * 1024 * 1024

type YTDLPEnumerator struct {
	Executable string
	Timeout    time.Duration
	run        ytdlpCommandRunner
}

func NewYTDLPEnumerator() *YTDLPEnumerator {
	return &YTDLPEnumerator{Executable: "yt-dlp", Timeout: 2 * time.Minute}
}

func (e *YTDLPEnumerator) Enumerate(ctx context.Context, sourceURL string, maxItems int) (PlaylistMetadata, []Entry, error) {
	if maxItems <= 0 {
		maxItems = DefaultMaxItems
	}
	result, err := e.execute(ctx, []string{
		"--dump-single-json",
		"--flat-playlist",
		"--skip-download",
		"--no-warnings",
		"--playlist-end", strconv.Itoa(maxItems), sourceURL,
	})
	if err != nil {
		return PlaylistMetadata{}, nil, err
	}
	if result.stdoutTruncated {
		return PlaylistMetadata{}, nil, fmt.Errorf("parse yt-dlp playlist metadata: %w: yt-dlp output exceeded limit", playlistsync.ErrIncompleteSnapshot)
	}

	var payload ytdlpPlaylist
	if err := json.Unmarshal(result.stdout, &payload); err != nil {
		// Some yt-dlp versions emit one JSON object per line. Handle that as a
		// fallback instead of pretending enumeration broke. this is annoying but real.
		entries, scanErr := parseYTDLPLines(result.stdout, sourceURL, maxItems)
		if scanErr != nil {
			return PlaylistMetadata{}, nil, fmt.Errorf("parse yt-dlp playlist metadata: %w", scanErr)
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

// Resolve implements playlistsync.SourceAdapter. It intentionally asks yt-dlp
// for the full playlist: a capped or partial result must not mutate a synced
// playlist as though it were a complete provider snapshot.
func (e *YTDLPEnumerator) Resolve(ctx context.Context, sourceURL string) (playlistsync.Snapshot, error) {
	requestedID, err := youtubePlaylistID(sourceURL)
	if err != nil {
		return playlistsync.Snapshot{}, err
	}

	result, err := e.execute(ctx, []string{
		"--dump-single-json",
		"--flat-playlist",
		"--skip-download",
		"--no-warnings",
		"--yes-playlist",
		sourceURL,
	})
	if err != nil {
		return playlistsync.Snapshot{}, err
	}
	if result.stdoutTruncated {
		return playlistsync.Snapshot{}, fmt.Errorf("%w: yt-dlp output exceeded limit", playlistsync.ErrIncompleteSnapshot)
	}

	payload, err := parseCompleteYTDLPPlaylist(result.stdout)
	if err != nil {
		return playlistsync.Snapshot{}, err
	}
	playlistID := strings.TrimSpace(firstNonEmpty(payload.PlaylistID, payload.ID))
	if playlistID == "" || playlistID != requestedID || !payload.isPlaylist() {
		return playlistsync.Snapshot{}, fmt.Errorf("%w: missing or mismatched YouTube playlist identity", playlistsync.ErrInvalidSnapshot)
	}
	title := strings.TrimSpace(payload.Title)
	if title == "" {
		return playlistsync.Snapshot{}, fmt.Errorf("%w: playlist title is missing", playlistsync.ErrIncompleteSnapshot)
	}
	if payload.PlaylistCount == nil {
		return playlistsync.Snapshot{}, fmt.Errorf("%w: yt-dlp playlist count is missing", playlistsync.ErrIncompleteSnapshot)
	}
	if *payload.PlaylistCount != len(payload.Entries) {
		return playlistsync.Snapshot{}, fmt.Errorf("%w: yt-dlp returned %d of %d playlist entries", playlistsync.ErrIncompleteSnapshot, len(payload.Entries), *payload.PlaylistCount)
	}

	entries := make([]playlistsync.Entry, 0, len(payload.Entries))
	for index, raw := range payload.Entries {
		entry := raw.toEntry(index + 1)
		if entry.SourceID == "" {
			return playlistsync.Snapshot{}, fmt.Errorf("%w: entry %d is missing stable identity", playlistsync.ErrIncompleteSnapshot, index)
		}
		if entry.SourceURL == "" {
			entry.SourceURL = youtubeWatchURL(entry.SourceID)
		} else {
			entry.SourceURL = absolutizePlaylistURL(sourceURL, entry.SourceURL)
		}
		entries = append(entries, playlistsync.Entry{
			StableID:  entry.SourceID,
			SourceURL: entry.SourceURL,
			Metadata: playlistsync.EntryMetadata{
				Title:        entry.Title,
				Artist:       entry.Artist,
				Album:        entry.Album,
				Uploader:     entry.Uploader,
				DurationMS:   entry.DurationMs,
				ThumbnailURL: entry.ThumbnailURL,
				Unavailable:  entry.Unavailable,
				Error:        entry.Error,
			},
		})
	}

	snapshot := playlistsync.Snapshot{
		Source: playlistsync.Source{
			Provider:     "youtube",
			PlaylistID:   playlistID,
			CanonicalURL: canonicalYouTubePlaylistURL(playlistID),
			Metadata:     playlistsync.SourceMetadata{Title: title},
		},
		Complete: true,
		Entries:  entries,
	}
	if err := playlistsync.ValidateComplete(snapshot); err != nil {
		return playlistsync.Snapshot{}, err
	}
	return snapshot, nil
}

type ytdlpCommandResult struct {
	stdout          []byte
	stderr          []byte
	stdoutTruncated bool
}

type ytdlpCommandRunner func(context.Context, string, []string) (ytdlpCommandResult, error)

func (e *YTDLPEnumerator) execute(ctx context.Context, args []string) (ytdlpCommandResult, error) {
	timeout := e.Timeout
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	executable := e.Executable
	if executable == "" {
		executable = "yt-dlp"
	}
	run := e.run
	if run == nil {
		run = runYTDLP
	}
	result, err := run(ctx, executable, args)
	if err != nil {
		if ctx.Err() != nil {
			return ytdlpCommandResult{}, ctx.Err()
		}
		return ytdlpCommandResult{}, fmt.Errorf("yt-dlp playlist metadata failed: %w: %s", err, strings.TrimSpace(string(result.stderr)))
	}
	return result, nil
}

func runYTDLP(ctx context.Context, executable string, args []string) (ytdlpCommandResult, error) {
	cmd := exec.CommandContext(ctx, executable, args...)
	var stdout limitedBuffer
	stdout.limit = maxEnumeratorOutputBytes
	var stderr limitedBuffer
	stderr.limit = 64 * 1024
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return ytdlpCommandResult{
		stdout:          stdout.Bytes(),
		stderr:          stderr.Bytes(),
		stdoutTruncated: stdout.truncated,
	}, err
}

func parseCompleteYTDLPPlaylist(data []byte) (ytdlpPlaylist, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return ytdlpPlaylist{}, fmt.Errorf("%w: invalid yt-dlp playlist JSON", playlistsync.ErrIncompleteSnapshot)
	}
	entriesRaw, ok := raw["entries"]
	if !ok || string(entriesRaw) == "null" {
		return ytdlpPlaylist{}, fmt.Errorf("%w: yt-dlp entries are missing", playlistsync.ErrIncompleteSnapshot)
	}
	var payload ytdlpPlaylist
	if err := json.Unmarshal(data, &payload); err != nil {
		return ytdlpPlaylist{}, fmt.Errorf("%w: invalid yt-dlp playlist payload", playlistsync.ErrIncompleteSnapshot)
	}
	return payload, nil
}

func youtubePlaylistID(rawURL string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" || !isYouTubeHost(parsed.Hostname()) {
		return "", fmt.Errorf("%w: expected a YouTube playlist URL", playlistsync.ErrInvalidSnapshot)
	}
	playlistID := strings.TrimSpace(parsed.Query().Get("list"))
	if playlistID == "" {
		return "", fmt.Errorf("%w: YouTube playlist ID is missing", playlistsync.ErrInvalidSnapshot)
	}
	return playlistID, nil
}

func isYouTubeHost(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	return host == "youtube.com" || strings.HasSuffix(host, ".youtube.com") ||
		host == "youtu.be" || strings.HasSuffix(host, ".youtu.be")
}

func canonicalYouTubePlaylistURL(playlistID string) string {
	return "https://www.youtube.com/playlist?list=" + url.QueryEscape(playlistID)
}

type ytdlpPlaylist struct {
	ID            string       `json:"id"`
	PlaylistID    string       `json:"playlist_id"`
	PlaylistCount *int         `json:"playlist_count"`
	Type          string       `json:"_type"`
	Title         string       `json:"title"`
	Entries       []ytdlpEntry `json:"entries"`
}

func (p ytdlpPlaylist) isPlaylist() bool {
	return strings.EqualFold(strings.TrimSpace(p.Type), "playlist") || strings.TrimSpace(p.PlaylistID) != ""
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
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.limit <= 0 || b.buf.Len()+len(p) <= b.limit {
		return b.buf.Write(p)
	}
	b.truncated = true
	remaining := b.limit - b.buf.Len()
	if remaining > 0 {
		_, _ = b.buf.Write(p[:remaining])
	}
	return len(p), nil
}

func (b *limitedBuffer) Bytes() []byte  { return b.buf.Bytes() }
func (b *limitedBuffer) String() string { return b.buf.String() }
