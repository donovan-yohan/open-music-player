package playlistimport

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
)

func (s *Service) acquireItems(ctx context.Context, userID uuid.UUID, playlistID int64, job *ImportJob, items []ImportItem) error {
	for i := range items {
		item := &items[i]
		if item.Status == ItemStatusFailed || item.Status == ItemStatusSkippedDuplicate {
			continue
		}
		candidate := playlistCandidate(*item, s.sourceType)
		if job.ManualSync {
			candidate.Metadata["manualSync"] = true
		}
		if s.selections == nil || s.ingestion == nil {
			msg := "trusted source selection processing is disabled"
			_ = s.store.MarkItemFailed(ctx, item.ID, msg)
			item.Status = ItemStatusFailed
			item.Error = sql.NullString{String: msg, Valid: true}
			continue
		}
		decision, err := s.itemDecision(ctx, userID, item, candidate)
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
			var attachErr error
			if repo, ok := s.store.(*ImportRepository); ok {
				attachErr = repo.CompletePlaylistImportItem(ctx, item.ID, track.ID)
			} else {
				attachErr = s.playlists.AddTrackAtPosition(ctx, playlistID, track.ID, item.PlaylistPosition)
				if errors.Is(attachErr, db.ErrTrackAlreadyInPlaylist) {
					attachErr = nil
				}
				if attachErr == nil {
					attachErr = s.store.MarkItemImported(ctx, item.ID, track.ID)
				}
			}
			if attachErr != nil {
				return attachErr
			}

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
			return fmt.Errorf("mark playlist import item queued: %w", err)
		}
		item.Status = ItemStatusQueued
		item.DownloadJobID = sql.NullString{String: queued.ID, Valid: true}
	}
	return nil
}
func (s *Service) itemDecision(ctx context.Context, userID uuid.UUID, item *ImportItem, candidate download.SourceCandidate) (*db.SourceSelectionDecision, error) {
	if repo, ok := s.store.(*ImportRepository); ok {
		return repo.itemDecision(ctx, s.selections, userID, item.ID, candidate)
	}
	return s.selections.CreateTrustedSourceSelectionDecision(ctx, userID, db.SourceSelectionOriginPlaylistExplicit, trustedPlaylistCandidate(candidate), "server-enumerated explicit playlist entry")
}
