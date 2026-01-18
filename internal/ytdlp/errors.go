package ytdlp

import "errors"

var (
	// ErrURLNotSupported indicates the URL is not from a supported source
	ErrURLNotSupported = errors.New("url not supported")

	// ErrVideoUnavailable indicates the video/audio is not available
	ErrVideoUnavailable = errors.New("video unavailable")

	// ErrVideoPrivate indicates the video is private
	ErrVideoPrivate = errors.New("video is private")

	// ErrAgeRestricted indicates the content is age-restricted
	ErrAgeRestricted = errors.New("content is age-restricted")

	// ErrNetworkError indicates a network-related error
	ErrNetworkError = errors.New("network error")

	// ErrYtdlpNotFound indicates yt-dlp is not installed
	ErrYtdlpNotFound = errors.New("yt-dlp not found in PATH")

	// ErrDownloadFailed indicates the download failed
	ErrDownloadFailed = errors.New("download failed")

	// ErrInvalidURL indicates the URL format is invalid
	ErrInvalidURL = errors.New("invalid url format")
)

// DownloadError wraps an error with additional context
type DownloadError struct {
	URL     string
	Message string
	Err     error
}

func (e *DownloadError) Error() string {
	if e.Err != nil {
		return e.Message + ": " + e.Err.Error()
	}
	return e.Message
}

func (e *DownloadError) Unwrap() error {
	return e.Err
}
