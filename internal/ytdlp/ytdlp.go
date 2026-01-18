package ytdlp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Config holds configuration for the yt-dlp service
type Config struct {
	// TempDir is the directory for temporary downloads
	TempDir string
	// AudioQuality is the MP3 bitrate (e.g., "320k")
	AudioQuality string
	// YtdlpPath is the path to yt-dlp binary (default: "yt-dlp")
	YtdlpPath string
}

// DefaultConfig returns a config with sensible defaults
func DefaultConfig() *Config {
	return &Config{
		TempDir:      os.TempDir(),
		AudioQuality: "320k",
		YtdlpPath:    "yt-dlp",
	}
}

// Service wraps yt-dlp for audio downloads
type Service struct {
	cfg *Config
}

// New creates a new yt-dlp service
func New(cfg *Config) (*Service, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}

	// Verify yt-dlp is available
	if _, err := exec.LookPath(cfg.YtdlpPath); err != nil {
		return nil, ErrYtdlpNotFound
	}

	// Ensure temp directory exists
	if err := os.MkdirAll(cfg.TempDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create temp directory: %w", err)
	}

	return &Service{cfg: cfg}, nil
}

// DownloadResult contains the result of a download operation
type DownloadResult struct {
	FilePath string
	Metadata *Metadata
}

// ProgressCallback is called during download with progress updates
type ProgressCallback func(percent float64, status string)

// Download downloads audio from the given URL
func (s *Service) Download(ctx context.Context, sourceURL string, progress ProgressCallback) (*DownloadResult, error) {
	// Validate URL
	if err := s.validateURL(sourceURL); err != nil {
		return nil, err
	}

	// Get metadata first
	metadata, err := s.GetMetadata(ctx, sourceURL)
	if err != nil {
		return nil, err
	}

	// Prepare output path
	outputTemplate := filepath.Join(s.cfg.TempDir, "%(id)s.%(ext)s")

	// Build yt-dlp command
	args := []string{
		"-f", "bestaudio",
		"--extract-audio",
		"--audio-format", "mp3",
		"--audio-quality", s.cfg.AudioQuality,
		"--output", outputTemplate,
		"--newline",
		"--progress",
		"--no-warnings",
		sourceURL,
	}

	cmd := exec.CommandContext(ctx, s.cfg.YtdlpPath, args...)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, &DownloadError{URL: sourceURL, Message: "failed to create stdout pipe", Err: err}
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, &DownloadError{URL: sourceURL, Message: "failed to create stderr pipe", Err: err}
	}

	if err := cmd.Start(); err != nil {
		return nil, s.categorizeError(sourceURL, err, "")
	}

	// Read stdout for progress
	var stderrOutput strings.Builder
	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			stderrOutput.WriteString(scanner.Text())
			stderrOutput.WriteString("\n")
		}
	}()

	if progress != nil {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			percent, status := parseProgress(line)
			progress(percent, status)
		}
	}

	if err := cmd.Wait(); err != nil {
		return nil, s.categorizeError(sourceURL, err, stderrOutput.String())
	}

	// Find the output file
	outputPath := filepath.Join(s.cfg.TempDir, metadata.ID+".mp3")
	if _, err := os.Stat(outputPath); os.IsNotExist(err) {
		return nil, &DownloadError{URL: sourceURL, Message: "output file not found", Err: ErrDownloadFailed}
	}

	return &DownloadResult{
		FilePath: outputPath,
		Metadata: metadata,
	}, nil
}

// GetMetadata retrieves metadata for a URL without downloading
func (s *Service) GetMetadata(ctx context.Context, sourceURL string) (*Metadata, error) {
	if err := s.validateURL(sourceURL); err != nil {
		return nil, err
	}

	args := []string{
		"--dump-json",
		"--no-download",
		"--no-warnings",
		sourceURL,
	}

	cmd := exec.CommandContext(ctx, s.cfg.YtdlpPath, args...)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, s.categorizeError(sourceURL, err, string(exitErr.Stderr))
		}
		return nil, s.categorizeError(sourceURL, err, "")
	}

	var ytdlpOutput YtdlpOutput
	if err := json.Unmarshal(output, &ytdlpOutput); err != nil {
		return nil, &DownloadError{URL: sourceURL, Message: "failed to parse metadata", Err: err}
	}

	return ytdlpOutput.ToMetadata(), nil
}

// validateURL checks if the URL is valid and from a supported source
func (s *Service) validateURL(sourceURL string) error {
	parsed, err := url.Parse(sourceURL)
	if err != nil {
		return &DownloadError{URL: sourceURL, Message: "invalid url", Err: ErrInvalidURL}
	}

	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return &DownloadError{URL: sourceURL, Message: "invalid url scheme", Err: ErrInvalidURL}
	}

	host := strings.ToLower(parsed.Host)

	// Check for supported hosts
	supportedHosts := []string{
		"youtube.com",
		"www.youtube.com",
		"youtu.be",
		"m.youtube.com",
		"music.youtube.com",
		"soundcloud.com",
		"www.soundcloud.com",
		"m.soundcloud.com",
	}

	for _, supported := range supportedHosts {
		if host == supported {
			return nil
		}
	}

	return &DownloadError{URL: sourceURL, Message: "unsupported source", Err: ErrURLNotSupported}
}

// categorizeError converts yt-dlp errors into specific error types
func (s *Service) categorizeError(sourceURL string, err error, stderr string) error {
	stderrLower := strings.ToLower(stderr)

	switch {
	case strings.Contains(stderrLower, "video unavailable") ||
		strings.Contains(stderrLower, "this video is unavailable"):
		return &DownloadError{URL: sourceURL, Message: "video unavailable", Err: ErrVideoUnavailable}

	case strings.Contains(stderrLower, "private video") ||
		strings.Contains(stderrLower, "is private"):
		return &DownloadError{URL: sourceURL, Message: "video is private", Err: ErrVideoPrivate}

	case strings.Contains(stderrLower, "age-restricted") ||
		strings.Contains(stderrLower, "sign in to confirm your age"):
		return &DownloadError{URL: sourceURL, Message: "content is age-restricted", Err: ErrAgeRestricted}

	case strings.Contains(stderrLower, "unable to download") ||
		strings.Contains(stderrLower, "connection") ||
		strings.Contains(stderrLower, "network"):
		return &DownloadError{URL: sourceURL, Message: "network error", Err: ErrNetworkError}

	case strings.Contains(stderrLower, "unsupported url") ||
		strings.Contains(stderrLower, "no suitable extractor"):
		return &DownloadError{URL: sourceURL, Message: "url not supported", Err: ErrURLNotSupported}

	default:
		return &DownloadError{URL: sourceURL, Message: "download failed", Err: fmt.Errorf("%w: %s", ErrDownloadFailed, stderr)}
	}
}

// parseProgress extracts progress percentage and status from yt-dlp output
func parseProgress(line string) (percent float64, status string) {
	line = strings.TrimSpace(line)

	// yt-dlp progress format: [download]  45.2% of 5.00MiB at 1.00MiB/s ETA 00:03
	if strings.HasPrefix(line, "[download]") {
		parts := strings.Fields(line)
		if len(parts) >= 2 {
			percentStr := strings.TrimSuffix(parts[1], "%")
			fmt.Sscanf(percentStr, "%f", &percent)
			status = "downloading"
		}
	} else if strings.Contains(line, "Destination:") {
		status = "converting"
	} else if strings.Contains(line, "Deleting original file") {
		percent = 100
		status = "finalizing"
	}

	return percent, status
}

// IsSupportedURL checks if a URL is from a supported source without downloading
func IsSupportedURL(sourceURL string) bool {
	parsed, err := url.Parse(sourceURL)
	if err != nil {
		return false
	}

	host := strings.ToLower(parsed.Host)
	supportedHosts := []string{
		"youtube.com",
		"www.youtube.com",
		"youtu.be",
		"m.youtube.com",
		"music.youtube.com",
		"soundcloud.com",
		"www.soundcloud.com",
		"m.soundcloud.com",
	}

	for _, supported := range supportedHosts {
		if host == supported {
			return true
		}
	}

	return false
}
