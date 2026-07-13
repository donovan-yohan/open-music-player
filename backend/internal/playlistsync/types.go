// Package playlistsync defines provider-neutral source snapshots and
// reconciliation plans. It deliberately has no database, scheduler, API, or
// downloader dependency.
package playlistsync

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

var (
	ErrIncompleteSnapshot = errors.New("playlist source snapshot is incomplete")
	ErrInvalidSnapshot    = errors.New("playlist source snapshot is invalid")
	ErrInvalidMappings    = errors.New("stored source-entry mappings are invalid")
	ErrInvalidPlaylistID  = errors.New("playlist ID must be positive")
	ErrMissingAdapter     = errors.New("playlist source adapter is required")
	ErrMissingStore       = errors.New("playlist sync store is required")
)

// SourceMetadata is provider metadata for a playlist source. It is descriptive
// only; Source.Provider, Source.PlaylistID, and Source.CanonicalURL form the
// stable source identity.
type SourceMetadata struct {
	Title       string
	Description string
	Owner       string
}

// Source identifies one provider playlist independently of a local OMP
// playlist. CanonicalURL is the stable display and re-fetch URL for the source.
type Source struct {
	Provider     string
	PlaylistID   string
	CanonicalURL string
	Metadata     SourceMetadata
}

// EntryMetadata carries the provider fields needed by later ingestion and UI
// layers. The stable entry ID, not this metadata, drives reconciliation.
type EntryMetadata struct {
	Title        string
	Artist       string
	Album        string
	Uploader     string
	DurationMS   int
	ThumbnailURL string
	Unavailable  bool
	Error        string
}

// Entry is one source playlist entry. Snapshot.Entries is in provider order.
// StableID must be stable within the source playlist.
type Entry struct {
	StableID  string
	SourceURL string
	Metadata  EntryMetadata
}

// Snapshot is the complete result of resolving a provider source. Only a
// complete, valid snapshot is eligible to change playlist membership or order.
type Snapshot struct {
	Source   Source
	Complete bool
	Entries  []Entry
}

// SourceAdapter resolves a user-supplied source URL into one provider-neutral
// snapshot. Implementations canonicalize the URL and supply provider-stable
// source and entry identities; provider failures return an error.
type SourceAdapter interface {
	Resolve(context.Context, string) (Snapshot, error)
}

// SourceEntryMapping is persisted source-entry state supplied by a future
// database/application layer. TrackID is only a reuse reference; a plan never
// requests deletion of that library track.
type SourceEntryMapping struct {
	StableEntryID string
	TrackID       *int64
	Position      int
}

// SkippedDuplicate records a later occurrence that is ignored in favor of the
// first occurrence of the same stable provider entry ID. Positions are zero
// based snapshot indexes.
type SkippedDuplicate struct {
	StableEntryID     string
	FirstPosition     int
	DuplicatePosition int
}

// ReconciliationPlan is an immutable description of playlist membership and
// ordering work. Removals concern playlist membership/source mappings only;
// this domain intentionally has no library-track deletion operation.
type ReconciliationPlan struct {
	Source             Source
	Additions          []Entry
	MembershipRemovals []SourceEntryMapping
	OrderedEntryIDs    []string
	Reordered          bool
	SkippedDuplicates  []SkippedDuplicate
	Noop               bool
}

// Result summarizes a completed or no-op reconciliation plan.
type Result struct {
	Noop              bool
	Added             int
	Removed           int
	Reordered         bool
	Reused            int
	SkippedDuplicates int
}

// Store is the future persistence/application seam. Apply receives only a
// membership/order plan after validation and can make that plan atomic.
type Store interface {
	ListSourceEntryMappings(context.Context, int64, Source) ([]SourceEntryMapping, error)
	ApplyReconciliation(context.Context, int64, ReconciliationPlan) error
}

// ValidateComplete confirms a snapshot is safe to use for mutation planning.
// Later duplicate entries remain valid and are normalized deterministically by
// PlanReconciliation.
func ValidateComplete(snapshot Snapshot) error {
	if !snapshot.Complete {
		return ErrIncompleteSnapshot
	}
	if invalidSourceText(snapshot.Source.Provider) ||
		invalidSourceText(snapshot.Source.PlaylistID) ||
		invalidSourceText(snapshot.Source.CanonicalURL) ||
		!isAbsoluteURL(snapshot.Source.CanonicalURL) {
		return ErrInvalidSnapshot
	}
	for index, entry := range snapshot.Entries {
		if invalidSourceText(entry.StableID) || entry.Metadata.DurationMS < 0 {
			return fmt.Errorf("%w: entry %d", ErrInvalidSnapshot, index)
		}
		if entry.SourceURL != "" && !isAbsoluteURL(entry.SourceURL) {
			return fmt.Errorf("%w: entry %d source URL", ErrInvalidSnapshot, index)
		}
	}
	return nil
}

func invalidSourceText(value string) bool {
	return strings.TrimSpace(value) == "" || strings.TrimSpace(value) != value
}

func isAbsoluteURL(value string) bool {
	parsed, err := url.ParseRequestURI(value)
	return err == nil && parsed.Scheme != "" && parsed.Host != ""
}
