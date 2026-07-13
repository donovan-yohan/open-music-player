package playlistimport

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/validators"
)

var (
	ErrInvalidURL       = errors.New("playlist url must be an absolute http(s) URL")
	ErrNoImportableItem = errors.New("playlist contains no importable items")
	ErrLimitExceeded    = errors.New("playlist exceeds import item limit")
	ErrNotFound         = errors.New("playlist import job not found")
	ErrForbidden        = errors.New("playlist import job not owned by user")
)

type Enumerator interface {
	Enumerate(ctx context.Context, sourceURL string, maxItems int) (PlaylistMetadata, []Entry, error)
}

type JobStore interface {
	CreateJob(ctx context.Context, job *ImportJob) error
	GetJob(ctx context.Context, id uuid.UUID) (*ImportJob, error)
	ListItems(ctx context.Context, jobID uuid.UUID) ([]ImportItem, error)
	CreateItem(ctx context.Context, item *ImportItem) error
	MarkItemQueued(ctx context.Context, itemID int64, downloadJobID string) error
	MarkItemImported(ctx context.Context, itemID int64, trackID int64) error
	MarkItemFailed(ctx context.Context, itemID int64, message string) error
	MarkJobFailed(ctx context.Context, jobID uuid.UUID, message string) error
	RefreshJobCounts(ctx context.Context, jobID uuid.UUID) error
}

type PlaylistStore interface {
	Create(ctx context.Context, playlist *db.Playlist) error
	GetByID(ctx context.Context, id int64) (*db.Playlist, error)
	AddTrackAtPosition(ctx context.Context, playlistID, trackID int64, position int) error
}

type TrackSourceStore interface {
	FindTrackBySource(ctx context.Context, provider, sourceID, sourceURL string) (*db.Track, error)
}

type LibraryStore interface {
	AddTrackToLibrary(ctx context.Context, userID uuid.UUID, trackID int64) (*db.LibraryEntry, error)
}

type DownloadEnqueuer interface {
	EnqueuePlaylistImportItemWithID(ctx context.Context, jobID, userID string, candidate download.SourceCandidate, importJobID string, importItemID int64, playlistID int64, playlistPosition int) (*download.DownloadJob, error)
}

type SourceSelectionStore interface {
	CreateTrustedSourceSelectionDecision(context.Context, uuid.UUID, string, db.TrustedSourceSelectionCandidate, string) (*db.SourceSelectionDecision, error)
	AttachTrackForUser(context.Context, uuid.UUID, uuid.UUID, int64) error
}

type TrustedIngestion interface {
	CreateDownloadForDecision(context.Context, uuid.UUID, *db.SourceSelectionDecision, download.SourceCandidate) (*db.SourceSelectionDownload, error)
	EnqueueTrustedPlaylistDownload(context.Context, *db.SourceSelectionDownload, db.SourceSelectionPlaylistDownloadEnqueuer, string, int64, int64, int) (*download.DownloadJob, error)
}

type Service struct {
	store      JobStore
	playlists  PlaylistStore
	tracks     TrackSourceStore
	library    LibraryStore
	downloader DownloadEnqueuer
	selections SourceSelectionStore
	ingestion  TrustedIngestion
	enumerator Enumerator
	maxItems   int
	sourceType string
}

type Config struct {
	Store      JobStore
	Playlists  PlaylistStore
	Tracks     TrackSourceStore
	Library    LibraryStore
	Downloader DownloadEnqueuer
	Selections SourceSelectionStore
	Ingestion  TrustedIngestion
	Enumerator Enumerator
	MaxItems   int
}

func NewService(cfg Config) *Service {
	maxItems := cfg.MaxItems
	if maxItems <= 0 {
		maxItems = DefaultMaxItems
	}
	if maxItems > HardMaxItems {
		maxItems = HardMaxItems
	}
	return &Service{
		store:      cfg.Store,
		playlists:  cfg.Playlists,
		tracks:     cfg.Tracks,
		library:    cfg.Library,
		downloader: cfg.Downloader,
		selections: cfg.Selections,
		ingestion:  cfg.Ingestion,
		enumerator: cfg.Enumerator,
		maxItems:   maxItems,
		sourceType: "youtube",
	}
}

func (s *Service) StartImport(ctx context.Context, userID uuid.UUID, req ImportRequest) (result *ImportResult, err error) {
	if err := validatePlaylistURL(req.URL); err != nil {
		return nil, err
	}
	limit := s.effectiveLimit(req.MaxItems)
	playlistID, err := s.resolvePlaylist(ctx, userID, req)
	if err != nil {
		return nil, err
	}

	job := &ImportJob{
		ID:         uuid.New(),
		UserID:     userID,
		PlaylistID: playlistID,
		SourceURL:  strings.TrimSpace(req.URL),
		Status:     JobStatusResolving,
		MaxItems:   limit,
	}
	if err := s.store.CreateJob(ctx, job); err != nil {
		return nil, fmt.Errorf("create playlist import job: %w", err)
	}
	jobFailed := false
	markJobFailed := func(message string) {
		jobFailed = true
		_ = s.store.MarkJobFailed(ctx, job.ID, message)
	}
	defer func() {
		if err != nil && !jobFailed {
			_ = s.store.MarkJobFailed(ctx, job.ID, err.Error())
		}
	}()

	metadata, entries, err := s.enumerator.Enumerate(ctx, job.SourceURL, limit+1)
	if err != nil {
		markJobFailed(err.Error())
		return nil, fmt.Errorf("enumerate playlist: %w", err)
	}
	if metadata.Title != "" {
		job.SourceTitle = sql.NullString{String: metadata.Title, Valid: true}
	}
	if len(entries) > limit {
		markJobFailed(ErrLimitExceeded.Error())
		return nil, ErrLimitExceeded
	}

	items := make([]ImportItem, 0, len(entries))
	seenSources := map[string]struct{}{}
	for i, entry := range entries {
		if entry.Index == 0 {
			entry.Index = i + 1
		}
		item := ImportItem{
			ImportJobID:      job.ID,
			SourceIndex:      entry.Index,
			PlaylistPosition: i,
			SourceID:         entry.SourceID,
			SourceURL:        strings.TrimSpace(entry.SourceURL),
			Title:            strings.TrimSpace(entry.Title),
			Artist:           strings.TrimSpace(entry.Artist),
			Album:            strings.TrimSpace(entry.Album),
			Uploader:         strings.TrimSpace(entry.Uploader),
			DurationMs:       entry.DurationMs,
			ThumbnailURL:     strings.TrimSpace(entry.ThumbnailURL),
			Status:           ItemStatusPending,
		}
		if entry.Unavailable || item.SourceURL == "" {
			item.Status = ItemStatusFailed
			msg := firstNonEmpty(entry.Error, "playlist entry is unavailable")
			item.Error = sql.NullString{String: msg, Valid: true}
		} else {
			if item.SourceID == "" {
				resolved := validators.DefaultRegistry().Validate(item.SourceURL)
				if !resolved.Valid || string(resolved.SourceType) != s.sourceType || resolved.MediaID == "" {
					item.Status = ItemStatusFailed
					item.Error = sql.NullString{String: "playlist entry source URL does not resolve to a supported media ID", Valid: true}
				} else {
					item.SourceID = resolved.MediaID
					item.SourceURL = resolved.Canonical
				}
			}
			if item.Status == ItemStatusFailed {
				if err := s.store.CreateItem(ctx, &item); err != nil {
					return nil, fmt.Errorf("create playlist import item: %w", err)
				}
				items = append(items, item)
				continue
			}
			sourceKey := firstNonEmpty(item.SourceID, item.SourceURL)
			if _, seen := seenSources[sourceKey]; seen {
				item.Status = ItemStatusSkippedDuplicate
				item.Error = sql.NullString{String: "duplicate source entry", Valid: true}
			} else {
				seenSources[sourceKey] = struct{}{}
			}
		}
		if err := s.store.CreateItem(ctx, &item); err != nil {
			return nil, fmt.Errorf("create playlist import item: %w", err)
		}
		items = append(items, item)
	}
	if len(items) == 0 {
		markJobFailed(ErrNoImportableItem.Error())
		return nil, ErrNoImportableItem
	}

	for i := range items {
		item := &items[i]
		if item.Status == ItemStatusFailed || item.Status == ItemStatusSkippedDuplicate {
			continue
		}
		candidate := playlistCandidate(*item, s.sourceType)
		if s.selections == nil || s.ingestion == nil {
			msg := "trusted source selection processing is disabled"
			_ = s.store.MarkItemFailed(ctx, item.ID, msg)
			item.Status = ItemStatusFailed
			item.Error = sql.NullString{String: msg, Valid: true}
			continue
		}
		decision, err := s.selections.CreateTrustedSourceSelectionDecision(ctx, userID, db.SourceSelectionOriginPlaylistExplicit, trustedPlaylistCandidate(candidate), "server-enumerated explicit playlist entry")
		if err != nil {
			_ = s.store.MarkItemFailed(ctx, item.ID, err.Error())
			item.Status = ItemStatusFailed
			item.Error = sql.NullString{String: err.Error(), Valid: true}
			continue
		}
		track, err := s.tracks.FindTrackBySource(ctx, s.sourceType, item.SourceID, item.SourceURL)
		if err == nil && track != nil {
			if s.library != nil {
				if _, libErr := s.library.AddTrackToLibrary(ctx, userID, track.ID); libErr != nil && !errors.Is(libErr, db.ErrTrackAlreadyInLibrary) {
					_ = s.store.MarkItemFailed(ctx, item.ID, libErr.Error())
					item.Status = ItemStatusFailed
					item.Error = sql.NullString{String: libErr.Error(), Valid: true}
					continue
				}
			}
			if err := s.selections.AttachTrackForUser(ctx, userID, decision.ID, track.ID); err != nil {
				_ = s.store.MarkItemFailed(ctx, item.ID, err.Error())
				item.Status = ItemStatusFailed
				item.Error = sql.NullString{String: err.Error(), Valid: true}
				continue
			}
			if err := s.playlists.AddTrackAtPosition(ctx, playlistID, track.ID, item.PlaylistPosition); err != nil && !errors.Is(err, db.ErrTrackAlreadyInPlaylist) {
				_ = s.store.MarkItemFailed(ctx, item.ID, err.Error())
				item.Status = ItemStatusFailed
				item.Error = sql.NullString{String: err.Error(), Valid: true}
				continue
			}
			_ = s.store.MarkItemImported(ctx, item.ID, track.ID)
			item.Status = ItemStatusImported
			item.TrackID = sql.NullInt64{Int64: track.ID, Valid: true}
			continue
		}
		if s.downloader == nil {
			msg := "download processing is disabled"
			_ = s.store.MarkItemFailed(ctx, item.ID, msg)
			item.Status = ItemStatusFailed
			item.Error = sql.NullString{String: msg, Valid: true}
			continue
		}
		persisted, err := s.ingestion.CreateDownloadForDecision(ctx, userID, decision, candidate)
		var queued *download.DownloadJob
		if err == nil {
			queued, err = s.ingestion.EnqueueTrustedPlaylistDownload(ctx, persisted, s.downloader, job.ID.String(), item.ID, playlistID, item.PlaylistPosition)
		}
		if err != nil {
			_ = s.store.MarkItemFailed(ctx, item.ID, err.Error())
			item.Status = ItemStatusFailed
			item.Error = sql.NullString{String: err.Error(), Valid: true}
			continue
		}
		if err := s.markItemQueued(ctx, item.ID, queued.ID); err != nil {
			return nil, fmt.Errorf("mark playlist import item queued: %w", err)
		}
		item.Status = ItemStatusQueued
		item.DownloadJobID = sql.NullString{String: queued.ID, Valid: true}
	}
	if err := s.store.RefreshJobCounts(ctx, job.ID); err != nil {
		return nil, fmt.Errorf("refresh playlist import counts: %w", err)
	}
	fresh, err := s.store.GetJob(ctx, job.ID)
	if err == nil {
		job = fresh
	}
	freshItems, err := s.store.ListItems(ctx, job.ID)
	if err == nil {
		items = freshItems
	}
	return &ImportResult{Job: job, Items: items}, nil
}

// markItemQueued is idempotent. A store error can be an interrupted response
// after the durable update committed, so retry the same transition once before
// reporting failure instead of creating a second download.
func (s *Service) markItemQueued(ctx context.Context, itemID int64, downloadJobID string) error {
	if err := s.store.MarkItemQueued(ctx, itemID, downloadJobID); err != nil {
		if retryErr := s.store.MarkItemQueued(ctx, itemID, downloadJobID); retryErr != nil {
			return fmt.Errorf("initial attempt: %v; retry: %w", err, retryErr)
		}
	}
	return nil
}

func playlistCandidate(item ImportItem, provider string) download.SourceCandidate {
	return download.SourceCandidate{CandidateID: provider + ":" + item.SourceID, Provider: provider, SourceID: item.SourceID, SourceURL: item.SourceURL, Title: item.Title, Artist: item.Artist, Album: item.Album, Uploader: item.Uploader, DurationMs: item.DurationMs, ThumbnailURL: item.ThumbnailURL, Metadata: map[string]interface{}{"trustedIngestion": true, "origin": db.SourceSelectionOriginPlaylistExplicit}}
}

func trustedPlaylistCandidate(candidate download.SourceCandidate) db.TrustedSourceSelectionCandidate {
	return db.TrustedSourceSelectionCandidate{CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID, SourceURL: candidate.SourceURL, Title: candidate.Title, Downloadable: true, SourceQuality: &db.TrustedSourceSelectionQuality{Score: 0, Classification: "unknown", Recommendation: "review", Confidence: 0, Reasons: []string{"explicit playlist intent does not establish source quality"}, Provenance: db.SourceSelectionOriginPlaylistExplicit}}
}

func (s *Service) GetImport(ctx context.Context, userID uuid.UUID, id uuid.UUID) (*ImportResult, error) {
	job, err := s.store.GetJob(ctx, id)
	if err != nil {
		return nil, err
	}
	if job.UserID != userID {
		return nil, ErrForbidden
	}
	items, err := s.store.ListItems(ctx, id)
	if err != nil {
		return nil, err
	}
	return &ImportResult{Job: job, Items: items}, nil
}

func (s *Service) effectiveLimit(requested int) int {
	limit := s.maxItems
	if requested > 0 && requested < limit {
		limit = requested
	}
	if limit > HardMaxItems {
		limit = HardMaxItems
	}
	return limit
}

func (s *Service) resolvePlaylist(ctx context.Context, userID uuid.UUID, req ImportRequest) (int64, error) {
	if req.PlaylistID != nil {
		playlist, err := s.playlists.GetByID(ctx, *req.PlaylistID)
		if err != nil {
			return 0, err
		}
		if playlist.UserID != userID {
			return 0, db.ErrPlaylistNotOwned
		}
		return *req.PlaylistID, nil
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		name = "YouTube Playlist Import"
	}
	playlist := &db.Playlist{
		UserID:      userID,
		Name:        name,
		Description: sql.NullString{String: strings.TrimSpace(req.Description), Valid: strings.TrimSpace(req.Description) != ""},
	}
	if err := s.playlists.Create(ctx, playlist); err != nil {
		return 0, err
	}
	return playlist.ID, nil
}

func validatePlaylistURL(raw string) error {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return ErrInvalidURL
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return ErrInvalidURL
	}
	host := strings.ToLower(parsed.Hostname())
	if !isAllowedPlaylistHost(host) {
		return ErrInvalidURL
	}
	return nil
}

func isAllowedPlaylistHost(host string) bool {
	return host == "youtube.com" || strings.HasSuffix(host, ".youtube.com") ||
		host == "youtu.be" || strings.HasSuffix(host, ".youtu.be")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
