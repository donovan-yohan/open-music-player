package playlistimport

import (
	"database/sql"
	"time"

	"github.com/google/uuid"
)

const (
	DefaultMaxItems = 500
	HardMaxItems    = 1000

	JobStatusResolving      = "resolving"
	JobStatusImporting      = "importing"
	JobStatusComplete       = "complete"
	JobStatusPartialFailure = "partial_failure"
	JobStatusFailed         = "failed"
	JobStatusCanceled       = "cancel" + "led"

	ItemStatusPending          = "pending"
	ItemStatusQueued           = "queued"
	ItemStatusImported         = "imported"
	ItemStatusFailed           = "failed"
	ItemStatusSkippedDuplicate = "skipped_duplicate"
)

type ImportRequest struct {
	URL         string
	PlaylistID  *int64
	Name        string
	Description string
	MaxItems    int
}

type ImportJob struct {
	ID            uuid.UUID
	UserID        uuid.UUID
	PlaylistID    int64
	SourceURL     string
	SourceTitle   sql.NullString
	Status        string
	TotalItems    int
	ImportedItems int
	QueuedItems   int
	FailedItems   int
	SkippedItems  int
	MaxItems      int
	Error         sql.NullString
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

type ImportItem struct {
	ID                    int64
	ImportJobID           uuid.UUID
	SourceIndex           int
	PlaylistPosition      int
	SourceID              string
	SourceURL             string
	Title                 string
	Artist                string
	Album                 string
	Uploader              string
	DurationMs            int
	ThumbnailURL          string
	Status                string
	Error                 sql.NullString
	TrackID               sql.NullInt64
	PlaylistSourceEntryID sql.NullInt64
	DownloadJobID         sql.NullString
	CreatedAt             time.Time
	UpdatedAt             time.Time
}

// ItemSourceEntryAssociation links one import item to a stable provider entry.
// Both IDs are validated and updated as one transaction by ImportRepository.
type ItemSourceEntryAssociation struct {
	ItemID        int64
	SourceEntryID int64
}

type PlaylistMetadata struct {
	Title string
}

type Entry struct {
	Index        int
	SourceID     string
	SourceURL    string
	Title        string
	Artist       string
	Album        string
	Uploader     string
	DurationMs   int
	ThumbnailURL string
	Unavailable  bool
	Error        string
}

type ImportResult struct {
	Job   *ImportJob
	Items []ImportItem
}
