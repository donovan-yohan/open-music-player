package processor

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/storage"
)

// Processor handles the full download and matching pipeline
type Processor struct {
	matcher     *matcher.Matcher
	trackRepo   *db.TrackRepository
	libraryRepo *db.LibraryRepository
	storage     *storage.Client
}

// ProcessorConfig holds configuration for the processor
type ProcessorConfig struct {
	Matcher     *matcher.Matcher
	TrackRepo   *db.TrackRepository
	LibraryRepo *db.LibraryRepository
	Storage     *storage.Client
}

// New creates a new Processor instance
func New(config *ProcessorConfig) *Processor {
	return &Processor{
		matcher:     config.Matcher,
		trackRepo:   config.TrackRepo,
		libraryRepo: config.LibraryRepo,
		storage:     config.Storage,
	}
}

// ProcessResult contains the result of processing a download job
type ProcessResult struct {
	TrackID     int64
	Verified    bool
	Suggestions []matcher.MatchResult
}

// Process handles a download job through the full pipeline
func (p *Processor) Process(ctx context.Context, job *download.DownloadJob, progress func(int)) error {
	// Stage 1: Download (0-25%)
	log.Printf("Processing job %s: downloading from %s", job.ID, job.URL)
	progress(5)

	metadata, err := p.downloadAndExtractMetadata(ctx, job)
	if err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	progress(25)

	// Stage 2: Process and create track (25-50%)
	log.Printf("Processing job %s: creating track record", job.ID)
	job.Status = download.StatusProcessing

	track, isNew, err := p.createTrack(ctx, job, metadata)
	if err != nil {
		return fmt.Errorf("track creation failed: %w", err)
	}
	progress(50)

	// Stage 3: Run matching and store suggestions (50-75%)
	log.Printf("Processing job %s: running MusicBrainz matching", job.ID)

	if err := p.runMatching(ctx, track, metadata); err != nil {
		// Log but don't fail - matching is not critical
		log.Printf("Warning: matching failed for job %s: %v", job.ID, err)
	}
	progress(75)

	// Stage 4: Add to user's library (75-90%)
	log.Printf("Processing job %s: adding to library", job.ID)
	job.Status = download.StatusUploading

	if err := p.addToLibrary(ctx, job.UserID, track.ID); err != nil {
		log.Printf("Warning: failed to add track %d to library: %v", track.ID, err)
	}
	progress(90)

	log.Printf("Processing job %s: complete (track_id=%d, is_new=%v)", job.ID, track.ID, isNew)
	progress(100)

	return nil
}

// downloadAndExtractMetadata downloads the audio and extracts metadata
func (p *Processor) downloadAndExtractMetadata(ctx context.Context, job *download.DownloadJob) (*TrackMetadata, error) {
	// TODO: Implement actual audio download using yt-dlp or similar
	// For now, parse metadata from the URL and job info

	// This is a placeholder that extracts metadata from the page title
	// In production, this would:
	// 1. Use yt-dlp to download audio
	// 2. Extract metadata from the downloaded file
	// 3. Use the page title as fallback

	metadata := &TrackMetadata{
		Title:      job.URL, // Placeholder - would come from yt-dlp metadata
		SourceURL:  job.URL,
		SourceType: job.SourceType,
	}

	// If MBRecordingID was provided (user pre-selected a match), use it
	if job.MBRecordingID != nil {
		metadata.PreselectedMBID = *job.MBRecordingID
	}

	return metadata, nil
}

// TrackMetadata holds extracted metadata from a download
type TrackMetadata struct {
	Title           string
	Artist          string
	Album           string
	DurationMs      int
	SourceURL       string
	SourceType      string
	StorageKey      string
	FileSizeBytes   int64
	PreselectedMBID string
}

// createTrack creates or retrieves the track record
func (p *Processor) createTrack(ctx context.Context, job *download.DownloadJob, metadata *TrackMetadata) (*db.Track, bool, error) {
	opts := []db.TrackOption{
		db.WithSource(metadata.SourceURL, metadata.SourceType),
	}

	if metadata.StorageKey != "" {
		opts = append(opts, db.WithStorage(metadata.StorageKey, metadata.FileSizeBytes))
	}

	// If a pre-selected MBID was provided, verify the track with it
	if metadata.PreselectedMBID != "" {
		mbid, err := uuid.Parse(metadata.PreselectedMBID)
		if err == nil {
			opts = append(opts, db.WithMusicBrainzIDs(&mbid, nil, nil))
		}
	}

	track, isNew, err := p.trackRepo.CreateTrackFromMetadata(
		ctx,
		metadata.Artist,
		metadata.Title,
		metadata.Album,
		metadata.DurationMs,
		opts...,
	)
	if err != nil {
		return nil, false, err
	}

	return track, isNew, nil
}

// runMatching runs MusicBrainz matching and stores suggestions
func (p *Processor) runMatching(ctx context.Context, track *db.Track, metadata *TrackMetadata) error {
	// Skip matching if track is already verified
	if track.MBVerified {
		return nil
	}

	// Skip if a preselected MBID was used
	if metadata.PreselectedMBID != "" {
		return nil
	}

	// Build metadata for matcher
	matchMetadata := matcher.TrackMetadata{
		Title: metadata.Title,
	}
	if metadata.Artist != "" {
		matchMetadata.Uploader = metadata.Artist
	}
	if metadata.DurationMs > 0 {
		matchMetadata.DurationMs = metadata.DurationMs
	}

	// Check if it looks like non-music content
	if p.matcher.MatchNonMusic(matchMetadata) {
		log.Printf("Track %d appears to be non-music content, skipping matching", track.ID)
		return nil
	}

	// Run matching
	output, err := p.matcher.Match(ctx, matchMetadata)
	if err != nil {
		return fmt.Errorf("matching failed: %w", err)
	}

	// Update track with match results
	update := &db.MBMatchUpdate{
		MBVerified: output.Verified,
	}

	if output.BestMatch != nil {
		// Parse and set MBIDs
		if output.BestMatch.MBID != "" {
			if mbid, err := uuid.Parse(output.BestMatch.MBID); err == nil {
				update.MBRecordingID = &mbid
			}
		}
		if output.BestMatch.ArtistMBID != "" {
			if mbid, err := uuid.Parse(output.BestMatch.ArtistMBID); err == nil {
				update.MBArtistID = &mbid
			}
		}
		if output.BestMatch.AlbumMBID != "" {
			if mbid, err := uuid.Parse(output.BestMatch.AlbumMBID); err == nil {
				update.MBReleaseID = &mbid
			}
		}
	}

	// Store suggestions if not auto-verified
	if !output.Verified && len(output.Suggestions) > 0 {
		suggestions := matcher.BuildSuggestionsJSON(output.Suggestions)
		if suggestionsJSON, err := json.Marshal(suggestions); err == nil {
			update.MetadataJSON = suggestionsJSON
		}
	}

	return p.trackRepo.UpdateMBMatch(ctx, track.ID, update)
}

// addToLibrary adds the track to the user's library
func (p *Processor) addToLibrary(ctx context.Context, userID string, trackID int64) error {
	userUUID, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("invalid user ID: %w", err)
	}

	_, err = p.libraryRepo.AddTrackToLibrary(ctx, userUUID, trackID)
	if err != nil {
		// Ignore "already in library" errors
		if err == db.ErrTrackAlreadyInLibrary {
			return nil
		}
		return err
	}

	return nil
}
