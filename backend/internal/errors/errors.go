package errors

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// ErrorCategory represents the category of an error
type ErrorCategory string

const (
	CategoryClient   ErrorCategory = "client"
	CategoryServer   ErrorCategory = "server"
	CategoryExternal ErrorCategory = "external"
)

// Common error codes
const (
	// Client errors (4xx)
	CodeValidationError    = "VALIDATION_ERROR"
	CodeInvalidRequest     = "INVALID_REQUEST"
	CodeUnauthorized       = "UNAUTHORIZED"
	CodeForbidden          = "FORBIDDEN"
	CodeNotFound           = "NOT_FOUND"
	CodeConflict           = "CONFLICT"
	CodeRateLimited        = "RATE_LIMITED"

	// Authentication specific
	CodeInvalidCredentials = "INVALID_CREDENTIALS"
	CodeInvalidToken       = "INVALID_TOKEN"
	CodeTokenExpired       = "TOKEN_EXPIRED"
	CodeEmailExists        = "EMAIL_EXISTS"

	// Resource specific
	CodeTrackNotFound      = "TRACK_NOT_FOUND"
	CodeArtistNotFound     = "ARTIST_NOT_FOUND"
	CodeAlbumNotFound      = "ALBUM_NOT_FOUND"
	CodePlaylistNotFound   = "PLAYLIST_NOT_FOUND"
	CodeJobNotFound        = "JOB_NOT_FOUND"
	CodeUnsupportedSource  = "UNSUPPORTED_SOURCE"

	// Server errors (5xx)
	CodeInternalError      = "INTERNAL_ERROR"
	CodeDatabaseError      = "DATABASE_ERROR"
	CodeStorageError       = "STORAGE_ERROR"

	// External service errors
	CodeMusicBrainzError   = "MUSICBRAINZ_ERROR"
	CodeDownloadError      = "DOWNLOAD_ERROR"
	CodeExternalTimeout    = "EXTERNAL_TIMEOUT"
)

// AppError represents a structured application error
type AppError struct {
	Code       string            `json:"code"`
	Message    string            `json:"message"`
	Category   ErrorCategory     `json:"-"`
	HTTPStatus int               `json:"-"`
	Details    map[string]any    `json:"details,omitempty"`
	Cause      error             `json:"-"`
}

// Error implements the error interface
func (e *AppError) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("%s: %s (caused by: %v)", e.Code, e.Message, e.Cause)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// Unwrap returns the underlying error
func (e *AppError) Unwrap() error {
	return e.Cause
}

// WithDetails adds details to the error
func (e *AppError) WithDetails(details map[string]any) *AppError {
	e.Details = details
	return e
}

// WithCause sets the underlying cause of the error
func (e *AppError) WithCause(err error) *AppError {
	e.Cause = err
	return e
}

// ErrorResponse is the JSON structure returned to clients
type ErrorResponse struct {
	Error ErrorBody `json:"error"`
}

// ErrorBody contains the error details
type ErrorBody struct {
	Code      string         `json:"code"`
	Message   string         `json:"message"`
	RequestID string         `json:"request_id,omitempty"`
	Details   map[string]any `json:"details,omitempty"`
}

// New creates a new AppError
func New(code string, message string, category ErrorCategory, httpStatus int) *AppError {
	return &AppError{
		Code:       code,
		Message:    message,
		Category:   category,
		HTTPStatus: httpStatus,
	}
}

// Client error constructors

func BadRequest(message string) *AppError {
	return New(CodeInvalidRequest, message, CategoryClient, http.StatusBadRequest)
}

func ValidationError(message string) *AppError {
	return New(CodeValidationError, message, CategoryClient, http.StatusBadRequest)
}

func Unauthorized(message string) *AppError {
	return New(CodeUnauthorized, message, CategoryClient, http.StatusUnauthorized)
}

func InvalidCredentials() *AppError {
	return New(CodeInvalidCredentials, "invalid email or password", CategoryClient, http.StatusUnauthorized)
}

func InvalidToken(message string) *AppError {
	return New(CodeInvalidToken, message, CategoryClient, http.StatusUnauthorized)
}

func TokenExpired() *AppError {
	return New(CodeTokenExpired, "token has expired", CategoryClient, http.StatusUnauthorized)
}

func Forbidden(message string) *AppError {
	return New(CodeForbidden, message, CategoryClient, http.StatusForbidden)
}

func NotFound(resource string) *AppError {
	return New(CodeNotFound, fmt.Sprintf("%s not found", resource), CategoryClient, http.StatusNotFound)
}

func TrackNotFound() *AppError {
	return New(CodeTrackNotFound, "track not found", CategoryClient, http.StatusNotFound)
}

func ArtistNotFound() *AppError {
	return New(CodeArtistNotFound, "artist not found", CategoryClient, http.StatusNotFound)
}

func AlbumNotFound() *AppError {
	return New(CodeAlbumNotFound, "album not found", CategoryClient, http.StatusNotFound)
}

func PlaylistNotFound() *AppError {
	return New(CodePlaylistNotFound, "playlist not found", CategoryClient, http.StatusNotFound)
}

func JobNotFound() *AppError {
	return New(CodeJobNotFound, "job not found", CategoryClient, http.StatusNotFound)
}

func Conflict(message string) *AppError {
	return New(CodeConflict, message, CategoryClient, http.StatusConflict)
}

func EmailExists() *AppError {
	return New(CodeEmailExists, "email already registered", CategoryClient, http.StatusConflict)
}

func UnsupportedSource(source string) *AppError {
	return New(CodeUnsupportedSource, fmt.Sprintf("unsupported source: %s", source), CategoryClient, http.StatusBadRequest)
}

func RateLimited() *AppError {
	return New(CodeRateLimited, "rate limit exceeded", CategoryClient, http.StatusTooManyRequests)
}

// Server error constructors

func InternalError(message string) *AppError {
	return New(CodeInternalError, message, CategoryServer, http.StatusInternalServerError)
}

func DatabaseError(message string) *AppError {
	return New(CodeDatabaseError, message, CategoryServer, http.StatusInternalServerError)
}

func StorageError(message string) *AppError {
	return New(CodeStorageError, message, CategoryServer, http.StatusInternalServerError)
}

// External service error constructors

func MusicBrainzError(message string) *AppError {
	return New(CodeMusicBrainzError, message, CategoryExternal, http.StatusBadGateway)
}

func DownloadError(message string) *AppError {
	return New(CodeDownloadError, message, CategoryExternal, http.StatusBadGateway)
}

func ExternalTimeout(service string) *AppError {
	return New(CodeExternalTimeout, fmt.Sprintf("%s request timed out", service), CategoryExternal, http.StatusGatewayTimeout)
}

// WriteError writes an error response to the HTTP response writer
func WriteError(w http.ResponseWriter, requestID string, err error) {
	var appErr *AppError

	switch e := err.(type) {
	case *AppError:
		appErr = e
	default:
		// Wrap unknown errors as internal errors
		appErr = InternalError("an unexpected error occurred").WithCause(err)
	}

	resp := ErrorResponse{
		Error: ErrorBody{
			Code:      appErr.Code,
			Message:   appErr.Message,
			RequestID: requestID,
			Details:   appErr.Details,
		},
	}

	w.Header().Set("Content-Type", "application/json")
	if requestID != "" {
		w.Header().Set("X-Request-ID", requestID)
	}
	w.WriteHeader(appErr.HTTPStatus)
	json.NewEncoder(w).Encode(resp)
}

// WriteJSON writes a JSON response with the request ID header
func WriteJSON(w http.ResponseWriter, requestID string, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	if requestID != "" {
		w.Header().Set("X-Request-ID", requestID)
	}
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// IsRetryable returns true if the error is retryable
func IsRetryable(err error) bool {
	appErr, ok := err.(*AppError)
	if !ok {
		return false
	}

	// External service errors are typically retryable
	if appErr.Category == CategoryExternal {
		return true
	}

	// Server errors may be retryable (except database conflicts, etc.)
	if appErr.Category == CategoryServer {
		return appErr.Code != CodeDatabaseError
	}

	return false
}

// IsClientError returns true if the error is a client error
func IsClientError(err error) bool {
	appErr, ok := err.(*AppError)
	if !ok {
		return false
	}
	return appErr.Category == CategoryClient
}

// IsServerError returns true if the error is a server error
func IsServerError(err error) bool {
	appErr, ok := err.(*AppError)
	if !ok {
		return false
	}
	return appErr.Category == CategoryServer
}

// IsExternalError returns true if the error is an external service error
func IsExternalError(err error) bool {
	appErr, ok := err.(*AppError)
	if !ok {
		return false
	}
	return appErr.Category == CategoryExternal
}
