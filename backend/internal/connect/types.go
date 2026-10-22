// Package connect implements private account-scoped ephemeral device visibility.
package connect

import (
	"errors"
	"time"
)

var (
	ErrInvalid     = errors.New("invalid device request")
	ErrConflict    = errors.New("device registration conflict")
	ErrCapacity    = errors.New("active device limit reached")
	ErrGone        = errors.New("device lease gone")
	ErrWriter      = errors.New("device writer mismatch")
	ErrStale       = errors.New("stale device report")
	ErrRate        = errors.New("device report rate limited")
	ErrUnavailable = errors.New("device store unavailable")
)

const MaxInteger int64 = 9007199254740991
const LeaseTTL = 90 * time.Second

type RegisterRequest struct {
	DeviceID     string `json:"deviceId"`
	Label        string `json:"label"`
	Platform     string `json:"platform"`
	WriterSecret string `json:"writerSecret"`
}
type Proof struct {
	LeaseID      string `json:"leaseId"`
	WriterSecret string `json:"writerSecret"`
}
type ReportRequest struct {
	LeaseID      string    `json:"leaseId"`
	WriterSecret string    `json:"writerSecret"`
	Sequence     int64     `json:"sequence"`
	Playback     *Playback `json:"playback"`
}
type Track struct {
	TrackID *int64 `json:"trackId"`
	Title   string `json:"title"`
	Artist  string `json:"artist"`
}
type Playback struct {
	SessionID        string  `json:"sessionId"`
	QueueItemID      *string `json:"queueItemId"`
	Track            Track   `json:"track"`
	Playing          bool    `json:"playing"`
	ProcessingState  string  `json:"processingState"`
	PositionMs       int64   `json:"positionMs"`
	DurationMs       int64   `json:"durationMs"`
	ActiveVoiceCount int     `json:"activeVoiceCount"`
}
type Device struct {
	DeviceID       string    `json:"deviceId"`
	LeaseID        string    `json:"leaseId"`
	Label          string    `json:"label"`
	Platform       string    `json:"platform"`
	Sequence       int64     `json:"sequence"`
	LastSeenAt     time.Time `json:"lastSeenAt"`
	LeaseExpiresAt time.Time `json:"leaseExpiresAt"`
	Playback       *Playback `json:"playback"`
}
