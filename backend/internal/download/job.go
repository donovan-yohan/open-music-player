package download

import (
	"time"
)

// Job status constants representing the job lifecycle
const (
	StatusQueued      = "queued"
	StatusDownloading = "downloading"
	StatusProcessing  = "processing"
	StatusUploading   = "uploading"
	StatusComplete    = "complete"
	StatusFailed      = "failed"
)

// DownloadJob represents a download task in the queue
type DownloadJob struct {
	ID            string     `json:"id"`
	UserID        string     `json:"user_id"`
	URL           string     `json:"url"`
	SourceType    string     `json:"source_type"`
	Status        string     `json:"status"`
	Progress      int        `json:"progress"`
	Error         string     `json:"error,omitempty"`
	RetryCount    int        `json:"retry_count"`
	MBRecordingID *string    `json:"mb_recording_id,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
	StartedAt     *time.Time `json:"started_at,omitempty"`
	CompletedAt   *time.Time `json:"completed_at,omitempty"`
}

// IsTerminal returns true if the job is in a terminal state
func (j *DownloadJob) IsTerminal() bool {
	return j.Status == StatusComplete || j.Status == StatusFailed
}

// CanRetry returns true if the job can be retried
func (j *DownloadJob) CanRetry(maxRetries int) bool {
	return j.Status == StatusFailed && j.RetryCount < maxRetries
}
