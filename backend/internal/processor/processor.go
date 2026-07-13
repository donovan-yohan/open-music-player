package processor

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

// ObjectStorage is the small MinIO surface the processor needs. storage.Client
// satisfies this interface; tests can use a fake without a real MinIO server.
type ObjectStorage interface {
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error
}

// AnalysisStore is the audio-analysis persistence surface used by Processor.
type AnalysisStore interface {
	RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error
	MarkAnalyzing(ctx context.Context, trackID int64, provenance json.RawMessage) error
	StoreResult(ctx context.Context, trackID int64, result db.AnalysisResult) error
	MarkFailed(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error
	MarkUnsupported(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error
}

const (
	maxYTDLPOutputBytes             = 256 * 1024 * 1024
	maxYTDLPLogBytes                = 64 * 1024
	analysisQueueSize               = 256
	analysisShutdownRecoveryWorkers = 4
	analysisShutdownRecoveryReserve = time.Second
	analysisShutdownRecoveryTimeout = 2 * time.Second
)

type analysisTask struct {
	id      uint64
	request analyzer.Request
}

// Processor handles the full download and matching pipeline
type Processor struct {
	matcher                 *matcher.Matcher
	trackRepo               *db.TrackRepository
	libraryRepo             *db.LibraryRepository
	playlistRepo            *db.PlaylistRepository
	importRepo              *playlistimport.ImportRepository
	sourceRepo              *playlistimport.TrackSourceRepository
	playlistSourceRepo      *db.PlaylistSourceRepository
	analysisRepo            AnalysisStore
	analyzerClient          analyzer.Client
	analysisQueue           chan analysisTask
	analysisStop            chan struct{}
	analysisCtx             context.Context
	analysisCancel          context.CancelFunc
	analysisMu              sync.Mutex
	analysisTasks           sync.WaitGroup
	analysisWorkers         sync.WaitGroup
	analysisOutstanding     map[uint64]analyzer.Request
	analysisNextTaskID      uint64
	analysisStopping        bool
	requireAnalyzerIdentity bool
	expectedAnalyzer        string
	expectedAnalyzerVersion string
	storage                 ObjectStorage
}

// ProcessorConfig holds configuration for the processor
type ProcessorConfig struct {
	Matcher                 *matcher.Matcher
	TrackRepo               *db.TrackRepository
	LibraryRepo             *db.LibraryRepository
	PlaylistRepo            *db.PlaylistRepository
	ImportRepo              *playlistimport.ImportRepository
	SourceRepo              *playlistimport.TrackSourceRepository
	PlaylistSourceRepo      *db.PlaylistSourceRepository
	AnalysisRepo            AnalysisStore
	AnalyzerClient          analyzer.Client
	AnalysisConcurrency     int
	RequireAnalyzerIdentity bool
	Storage                 ObjectStorage
}

// New creates a new Processor instance
func New(config *ProcessorConfig) *Processor {
	analysisConcurrency := config.AnalysisConcurrency
	if analysisConcurrency <= 0 {
		analysisConcurrency = 1
	}
	if analysisConcurrency > 4 {
		analysisConcurrency = 4
	}
	processor := &Processor{
		matcher:                 config.Matcher,
		trackRepo:               config.TrackRepo,
		libraryRepo:             config.LibraryRepo,
		playlistRepo:            config.PlaylistRepo,
		importRepo:              config.ImportRepo,
		sourceRepo:              config.SourceRepo,
		playlistSourceRepo:      config.PlaylistSourceRepo,
		analysisRepo:            config.AnalysisRepo,
		analyzerClient:          config.AnalyzerClient,
		requireAnalyzerIdentity: config.RequireAnalyzerIdentity,
		storage:                 config.Storage,
	}
	if processor.analysisRepo != nil && processor.analyzerClient != nil {
		processor.analysisCtx, processor.analysisCancel = context.WithCancel(context.Background())
		processor.analysisQueue = make(chan analysisTask, analysisQueueSize)
		processor.analysisStop = make(chan struct{})
		processor.analysisOutstanding = make(map[uint64]analyzer.Request)
		for range analysisConcurrency {
			processor.analysisWorkers.Add(1)
			go func() {
				defer processor.analysisWorkers.Done()
				processor.analysisWorker()
			}()
		}
	}
	return processor
}

// ProcessResult contains the result of processing a download job
type ProcessResult struct {
	TrackID     int64
	Verified    bool
	Suggestions []matcher.MatchResult
}

// Process handles a download job through the full pipeline
func (p *Processor) Process(ctx context.Context, job *download.DownloadJob, progress func(int)) (err error) {
	defer func() {
		if err != nil {
			p.markPlaylistImportFailed(ctx, job, err)
		}
	}()
	log.Printf("Processing job %s: downloading from %s", job.ID, job.URL)
	progress(5)

	metadata, err := p.downloadAndStore(ctx, job)
	if err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	progress(50)

	log.Printf("Processing job %s: creating track record", job.ID)
	job.Status = download.StatusProcessing
	track, isNew, err := p.createTrack(ctx, job, metadata)
	if err != nil {
		return fmt.Errorf("track creation failed: %w", err)
	}
	job.TrackID = &track.ID
	p.recordTrackSource(ctx, job, track.ID)
	progress(65)

	if p.matcher != nil {
		log.Printf("Processing job %s: running MusicBrainz matching", job.ID)
		if err := p.runMatching(ctx, track, metadata); err != nil {
			log.Printf("Warning: matching failed for job %s: %v", job.ID, err)
		}
	}
	progress(80)

	log.Printf("Processing job %s: adding to library", job.ID)
	job.Status = download.StatusUploading
	if err := p.addToLibrary(ctx, job.UserID, track.ID); err != nil {
		log.Printf("Warning: failed to add track %d to library: %v", track.ID, err)
	}
	if err := p.attachPlaylistImportTrack(ctx, job, track.ID); err != nil {
		return fmt.Errorf("playlist import attach failed: %w", err)
	}
	p.enqueueAnalysis(ctx, track, metadata)
	progress(95)

	log.Printf("Processing job %s: complete (track_id=%d, is_new=%v)", job.ID, track.ID, isNew)
	progress(100)
	return nil
}

// TrackMetadata holds extracted metadata from a download
type TrackMetadata struct {
	Title           string
	Artist          string
	Album           string
	Uploader        string
	DurationMs      int
	SourceURL       string
	SourceType      string
	StorageKey      string
	FileSizeBytes   int64
	PreselectedMBID string
	Raw             map[string]interface{}
	Cleanup         deterministicCleanup
}

func (p *Processor) downloadAndStore(ctx context.Context, job *download.DownloadJob) (*TrackMetadata, error) {
	if p.storage == nil {
		return nil, fmt.Errorf("object storage is not configured")
	}

	metadata := &TrackMetadata{
		Title:      firstNonEmpty(job.Title, job.URL),
		Artist:     firstNonEmpty(job.Artist, job.Uploader),
		Album:      job.Album,
		Uploader:   job.Uploader,
		DurationMs: job.DurationMs,
		SourceURL:  job.URL,
		SourceType: job.SourceType,
		Raw: map[string]interface{}{
			"candidate_id":   job.CandidateID,
			"source_id":      job.SourceID,
			"title":          job.Title,
			"artist":         job.Artist,
			"album":          job.Album,
			"uploader":       job.Uploader,
			"duration_ms":    job.DurationMs,
			"source_url":     job.URL,
			"source_type":    job.SourceType,
			"thumbnail_url":  job.ThumbnailURL,
			"source_quality": job.Metadata["sourceQuality"],
		},
	}
	if job.MBRecordingID != nil {
		metadata.PreselectedMBID = *job.MBRecordingID
	}

	tmpPath, contentType, err := p.obtainAudioFile(ctx, job, metadata)
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmpPath)

	info, err := os.Stat(tmpPath)
	if err != nil {
		return nil, fmt.Errorf("stat downloaded audio: %w", err)
	}
	file, err := os.Open(tmpPath)
	if err != nil {
		return nil, fmt.Errorf("open downloaded audio: %w", err)
	}
	defer file.Close()

	if contentType == "" {
		contentType = mime.TypeByExtension(filepath.Ext(tmpPath))
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	key := storageKey(job, tmpPath)
	if err := p.storage.PutObject(ctx, key, file, info.Size(), contentType); err != nil {
		return nil, fmt.Errorf("upload audio to object storage: %w", err)
	}
	metadata.StorageKey = key
	metadata.FileSizeBytes = info.Size()
	return metadata, nil
}

func (p *Processor) obtainAudioFile(ctx context.Context, job *download.DownloadJob, metadata *TrackMetadata) (string, string, error) {
	if strings.HasPrefix(job.URL, "fixture://") || job.SourceType == "fixture" {
		return writeFixtureWAV(job.ID)
	}
	if strings.HasPrefix(job.URL, "file://") {
		path := strings.TrimPrefix(job.URL, "file://")
		if path == "" {
			return "", "", fmt.Errorf("empty file URL")
		}
		return copyToBoundedTemp(path, 256*1024*1024)
	}
	return runYTDLP(ctx, job.URL, metadata)
}

func writeFixtureWAV(jobID string) (string, string, error) {
	path := filepath.Join(os.TempDir(), "omp-fixture-"+jobID+".wav")
	file, err := os.Create(path)
	if err != nil {
		return "", "", err
	}
	defer file.Close()

	const sampleRate = 8000
	const seconds = 1
	const dataSize = sampleRate * seconds * 2
	if _, err := file.Write([]byte("RIFF")); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(36+dataSize)); err != nil {
		return "", "", err
	}
	if _, err := file.Write([]byte("WAVEfmt ")); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(16)); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint16(1)); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint16(1)); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(sampleRate)); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(sampleRate*2)); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint16(2)); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint16(16)); err != nil {
		return "", "", err
	}
	if _, err := file.Write([]byte("data")); err != nil {
		return "", "", err
	}
	if err := binary.Write(file, binary.LittleEndian, uint32(dataSize)); err != nil {
		return "", "", err
	}
	for i := 0; i < sampleRate*seconds; i++ {
		if err := binary.Write(file, binary.LittleEndian, int16(0)); err != nil {
			return "", "", err
		}
	}
	return path, "audio/wav", nil
}

func copyToBoundedTemp(source string, maxBytes int64) (string, string, error) {
	in, err := os.Open(source)
	if err != nil {
		return "", "", err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return "", "", err
	}
	if info.Size() > maxBytes {
		return "", "", fmt.Errorf("downloaded file too large: %d bytes", info.Size())
	}
	out, err := os.CreateTemp("", "omp-download-*"+filepath.Ext(source))
	if err != nil {
		return "", "", err
	}
	outPath := out.Name()
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		os.Remove(outPath)
		return "", "", err
	}
	return outPath, mime.TypeByExtension(filepath.Ext(source)), nil
}

func runYTDLP(ctx context.Context, sourceURL string, metadata *TrackMetadata) (string, string, error) {
	return runYTDLPCommand(ctx, "yt-dlp", sourceURL, metadata, maxYTDLPOutputBytes)
}

func runYTDLPCommand(ctx context.Context, executable, sourceURL string, metadata *TrackMetadata, maxBytes int64) (string, string, error) {
	if _, err := exec.LookPath(executable); err != nil {
		return "", "", fmt.Errorf("yt-dlp is not installed")
	}
	dir, err := os.MkdirTemp("", "omp-ytdlp-*")
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(dir)

	outputTemplate := filepath.Join(dir, "audio.%(ext)s")
	cmd := exec.CommandContext(ctx, executable, "--no-playlist", "--max-filesize", fmt.Sprintf("%d", maxBytes), "--extract-audio", "--audio-format", "mp3", "--write-info-json", "--no-progress", "-o", outputTemplate, sourceURL)
	var output limitedOutput
	output.limit = maxYTDLPLogBytes
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Run(); err != nil {
		return "", "", fmt.Errorf("yt-dlp failed: %w: %s", err, strings.TrimSpace(output.String()))
	}
	return collectYTDLPOutput(dir, metadata, maxBytes)
}

func collectYTDLPOutput(dir string, metadata *TrackMetadata, maxBytes int64) (string, string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", "", err
	}
	var audioPath string
	for _, entry := range entries {
		if entry.IsDir() || strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		audioPath = filepath.Join(dir, entry.Name())
		break
	}
	if audioPath == "" {
		return "", "", fmt.Errorf("yt-dlp did not produce an audio file")
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".info.json") {
			populateMetadataFromInfo(filepath.Join(dir, entry.Name()), metadata)
			break
		}
	}
	path, contentType, err := copyToBoundedTemp(audioPath, maxBytes)
	if err != nil {
		return "", "", err
	}
	if contentType == "" {
		contentType = "audio/mpeg"
	}
	return path, contentType, nil
}

type limitedOutput struct {
	buf       strings.Builder
	limit     int
	truncated bool
}

func (o *limitedOutput) Write(p []byte) (int, error) {
	if o.limit <= 0 || o.buf.Len() >= o.limit {
		o.truncated = true
		return len(p), nil
	}
	remaining := o.limit - o.buf.Len()
	if len(p) > remaining {
		o.buf.Write(p[:remaining])
		o.truncated = true
		return len(p), nil
	}
	o.buf.Write(p)
	return len(p), nil
}

func (o *limitedOutput) String() string {
	if o.truncated {
		return o.buf.String() + "... (yt-dlp output truncated)"
	}
	return o.buf.String()
}

func populateMetadataFromInfo(path string, metadata *TrackMetadata) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return
	}
	metadata.Raw = raw
	metadata.Title = firstNonEmpty(stringValue(raw, "title"), metadata.Title)
	metadata.Artist = firstNonEmpty(stringValue(raw, "artist"), stringValue(raw, "uploader"), metadata.Artist)
	metadata.Uploader = firstNonEmpty(stringValue(raw, "uploader"), metadata.Uploader)
	if duration := int(floatValue(raw, "duration") * 1000); duration > 0 {
		metadata.DurationMs = duration
	}
}

type deterministicCleanup struct {
	RawTitle   string  `json:"raw_title,omitempty"`
	RawArtist  string  `json:"raw_artist,omitempty"`
	Title      string  `json:"title,omitempty"`
	Artist     string  `json:"artist,omitempty"`
	Method     string  `json:"method,omitempty"`
	Applied    bool    `json:"applied"`
	Confidence float64 `json:"confidence,omitempty"`
}

func applyDeterministicCleanup(metadata *TrackMetadata) deterministicCleanup {
	cleanup := deterministicCleanup{
		RawTitle:  metadata.Title,
		RawArtist: metadata.Artist,
	}
	parsed := matcher.ParseTitle(metadata.Title)
	cleanup.Method = parsed.Method
	cleanup.Title = parsed.Track
	cleanup.Artist = parsed.Artist

	if parsed.Method != "separator" || parsed.Artist == "" || parsed.Track == "" {
		return cleanup
	}

	metadata.Title = parsed.Track
	metadata.Artist = parsed.Artist
	cleanup.Applied = true
	cleanup.Confidence = 0.65
	return cleanup
}

func providerMetadata(metadata *TrackMetadata) map[string]interface{} {
	provider := make(map[string]interface{})
	keys := []string{"id", "title", "fulltitle", "artist", "album", "uploader", "channel", "duration", "duration_ms", "webpage_url", "source_url", "source_type", "thumbnail", "thumbnail_url", "candidate_id", "source_id", "source_quality"}
	for _, key := range keys {
		if value, ok := metadata.Raw[key]; ok && providerValueIsPresent(value) {
			provider[key] = value
		}
	}
	if _, ok := provider["title"]; !ok && metadata.Title != "" {
		provider["title"] = metadata.Title
	}
	if _, ok := provider["artist"]; !ok && metadata.Artist != "" {
		provider["artist"] = metadata.Artist
	}
	if metadata.Album != "" {
		provider["album"] = metadata.Album
	}
	if metadata.Uploader != "" {
		provider["uploader"] = metadata.Uploader
	}
	if metadata.DurationMs > 0 {
		provider["duration_ms"] = metadata.DurationMs
	}
	if metadata.SourceURL != "" {
		provider["source_url"] = metadata.SourceURL
	}
	if metadata.SourceType != "" {
		provider["source_type"] = metadata.SourceType
	}
	return provider
}

func providerValueIsPresent(value interface{}) bool {
	if value == nil {
		return false
	}
	if s, ok := value.(string); ok {
		return s != ""
	}
	return true
}

func metadataProvenance(metadata *TrackMetadata, cleanup deterministicCleanup) json.RawMessage {
	payload := map[string]interface{}{
		"raw_provider":  providerMetadata(metadata),
		"deterministic": cleanup,
	}
	encoded, _ := json.Marshal(payload)
	return encoded
}

func storageKey(job *download.DownloadJob, path string) string {
	ext := strings.TrimPrefix(filepath.Ext(path), ".")
	if ext == "" {
		ext = "bin"
	}
	sourceType := firstNonEmpty(job.SourceType, "unknown")
	return fmt.Sprintf("tracks/%s/%s.%s", sanitizeKeyPart(sourceType), job.ID, ext)
}

func sanitizeKeyPart(value string) string {
	value = strings.ToLower(value)
	value = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, value)
	return strings.Trim(value, "-")
}

// createTrack creates or retrieves the track record
func (p *Processor) createTrack(ctx context.Context, job *download.DownloadJob, metadata *TrackMetadata) (*db.Track, bool, error) {
	cleanup := applyDeterministicCleanup(metadata)
	metadata.Cleanup = cleanup
	provenance := metadataProvenance(metadata, cleanup)
	status := "provider"
	var confidence *float64
	if cleanup.Applied {
		status = "cleaned"
		confidence = &cleanup.Confidence
	}
	opts := []db.TrackOption{
		db.WithSource(metadata.SourceURL, metadata.SourceType),
		db.WithStorage(metadata.StorageKey, metadata.FileSizeBytes),
		db.WithMetadata(provenance),
		db.WithMetadataEnrichment(status, confidence, provenance, ""),
	}

	if metadata.PreselectedMBID != "" {
		mbid, err := uuid.Parse(metadata.PreselectedMBID)
		if err == nil {
			opts = append(opts, db.WithMusicBrainzIDs(&mbid, nil, nil))
		}
	}

	track, isNew, err := p.trackRepo.CreateTrackFromMetadata(ctx, metadata.Artist, metadata.Title, metadata.Album, metadata.DurationMs, opts...)
	if err != nil {
		return nil, false, err
	}
	return track, isNew, nil
}

// runMatching runs MusicBrainz matching and stores suggestions
func (p *Processor) runMatching(ctx context.Context, track *db.Track, metadata *TrackMetadata) error {
	if track.MBVerified || metadata.PreselectedMBID != "" || p.matcher == nil {
		return nil
	}
	provider := providerMetadata(metadata)
	matchMetadata := matcher.TrackMetadata{
		Title:         metadata.Title,
		Artist:        metadata.Artist,
		Album:         metadata.Album,
		Uploader:      metadata.Uploader,
		SourceType:    metadata.SourceType,
		SourceDomain:  sourceDomain(metadata.SourceURL),
		ThumbnailURL:  stringValueFromMap(provider, "thumbnail_url"),
		RawProvider:   provider,
		Deterministic: deterministicCleanupMetadata(metadata.Cleanup),
	}
	if metadata.DurationMs > 0 {
		matchMetadata.DurationMs = metadata.DurationMs
	}
	if p.matcher.MatchNonMusic(matchMetadata) {
		log.Printf("Track %d appears to be non-music content, skipping matching", track.ID)
		return nil
	}
	output, err := p.matcher.Match(ctx, matchMetadata)
	if err != nil {
		_ = p.trackRepo.UpdateMBMatch(ctx, track.ID, failedMBMatchUpdate(err))
		return fmt.Errorf("matching failed: %w", err)
	}
	update := automaticMBMatchUpdate(output)
	return p.trackRepo.UpdateMBMatch(ctx, track.ID, update)
}

func failedMBMatchUpdate(matchErr error) *db.MBMatchUpdate {
	failedProvenance, _ := json.Marshal(map[string]interface{}{
		"musicbrainz": map[string]interface{}{
			"status": "failed",
			"error":  matchErr.Error(),
		},
	})
	return &db.MBMatchUpdate{
		RespectUserEdits:        true,
		MetadataStatus:          "failed",
		ClearMetadataConfidence: true,
		MetadataProvenance:      failedProvenance,
	}
}

func automaticMBMatchUpdate(output *matcher.MatchOutput) *db.MBMatchUpdate {
	update := &db.MBMatchUpdate{RespectUserEdits: true}
	if output.BestMatch != nil {
		confidence := output.BestMatch.Confidence
		update.MetadataConfidence = &confidence
		if output.Verified {
			verified := true
			update.MBVerified = &verified
			update.ApplyMBIdentity = true
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
			if output.BestMatch.ReleaseID != "" {
				if mbid, err := uuid.Parse(output.BestMatch.ReleaseID); err == nil {
					update.MBReleaseID = &mbid
				}
			}
			update.MetadataStatus = "enriched"
			update.Title = output.BestMatch.Title
			update.Artist = output.BestMatch.Artist
			update.Album = output.BestMatch.Album
			update.DurationMs = output.BestMatch.Duration
			update.CoverArtURL = output.BestMatch.CoverArtURL
		} else {
			update.MetadataStatus = "suggested"
		}
	} else {
		update.MetadataStatus = "no_match"
		update.ClearMetadataConfidence = true
	}
	mbProvenance, _ := json.Marshal(map[string]interface{}{
		"musicbrainz": map[string]interface{}{
			"status":       update.MetadataStatus,
			"verified":     output.Verified,
			"best_match":   output.BestMatch,
			"suggestions":  output.Suggestions,
			"parsed_title": output.ParsedTitle,
			"ollama":       output.Disambiguation,
		},
	})
	update.MetadataProvenance = mbProvenance
	if !output.Verified && len(output.Suggestions) > 0 {
		suggestions := matcher.BuildSuggestionsJSON(output.Suggestions)
		if suggestionsJSON, err := json.Marshal(suggestions); err == nil {
			update.MetadataJSON = suggestionsJSON
		}
	}
	return update
}

// addToLibrary adds the track to the user's library
func (p *Processor) addToLibrary(ctx context.Context, userID string, trackID int64) error {
	if p.libraryRepo == nil {
		return nil
	}
	userUUID, err := uuid.Parse(userID)
	if err != nil {
		return fmt.Errorf("invalid user ID: %w", err)
	}
	_, err = p.libraryRepo.AddTrackToLibrary(ctx, userUUID, trackID)
	if err != nil {
		if err == db.ErrTrackAlreadyInLibrary {
			return nil
		}
		return err
	}
	return nil
}

func (p *Processor) recordTrackSource(ctx context.Context, job *download.DownloadJob, trackID int64) {
	if p.sourceRepo == nil || job == nil {
		return
	}
	if err := p.sourceRepo.UpsertTrackSource(ctx, trackID, job.SourceType, job.SourceID, job.URL); err != nil {
		log.Printf("Warning: failed to record track source for track %d: %v", trackID, err)
	}
}

func (p *Processor) attachPlaylistImportTrack(ctx context.Context, job *download.DownloadJob, trackID int64) error {
	if job == nil || job.PlaylistImportItemID == 0 {
		return nil
	}
	if p.importRepo != nil {
		return p.importRepo.CompletePlaylistImportItem(ctx, job.PlaylistImportItemID, trackID)
	}
	if p.playlistSourceRepo != nil {
		return p.playlistSourceRepo.CompletePlaylistImportItem(ctx, job.PlaylistImportItemID, trackID)
	}
	if p.playlistRepo != nil && job.PlaylistID != 0 {
		if err := p.playlistRepo.AddTrackAtPosition(ctx, job.PlaylistID, trackID, job.PlaylistPosition); err != nil && !errors.Is(err, db.ErrTrackAlreadyInPlaylist) {
			return err
		}
	}
	if p.importRepo != nil {
		if err := p.importRepo.MarkItemImported(ctx, job.PlaylistImportItemID, trackID); err != nil {
			return err
		}
		if job.PlaylistImportJobID != "" {
			if importJobID, err := uuid.Parse(job.PlaylistImportJobID); err == nil {
				if err := p.importRepo.RefreshJobCounts(ctx, importJobID); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func (p *Processor) markPlaylistImportFailed(ctx context.Context, job *download.DownloadJob, jobErr error) {
	if p.importRepo == nil || job == nil || job.PlaylistImportItemID == 0 || jobErr == nil {
		return
	}
	if err := p.importRepo.MarkItemFailed(ctx, job.PlaylistImportItemID, jobErr.Error()); err != nil {
		log.Printf("Warning: failed to mark playlist import item %d failed: %v", job.PlaylistImportItemID, err)
	}
	if job.PlaylistImportJobID != "" {
		if importJobID, err := uuid.Parse(job.PlaylistImportJobID); err == nil {
			if err := p.importRepo.RefreshJobCounts(ctx, importJobID); err != nil {
				log.Printf("Warning: failed to refresh playlist import job %s counts: %v", job.PlaylistImportJobID, err)
			}
		}
	}
}

func (p *Processor) enqueueAnalysis(ctx context.Context, track *db.Track, metadata *TrackMetadata) {
	if p.analysisRepo == nil || p.analyzerClient == nil || track == nil || metadata == nil {
		return
	}
	expectedAnalyzer, expectedVersion := p.analyzerIdentity()
	provenance, _ := json.Marshal(map[string]interface{}{
		"trigger":                   "post_download",
		"expected_analyzer":         expectedAnalyzer,
		"expected_analyzer_version": expectedVersion,
		"source": map[string]interface{}{
			"storage_key": metadata.StorageKey,
			"source_type": metadata.SourceType,
			"duration_ms": metadata.DurationMs,
		},
	})
	if err := p.analysisRepo.RequestAnalysis(ctx, track.ID, provenance); err != nil {
		log.Printf("Warning: failed to request audio analysis for track %d: %v", track.ID, err)
		return
	}
	if p.requireAnalyzerIdentity && expectedAnalyzer == "" {
		log.Printf("Deferred audio analysis for track %d until analyzer identity is available", track.ID)
		return
	}
	req := analyzer.Request{
		TrackID:                 track.ID,
		StorageKey:              metadata.StorageKey,
		SourceURL:               metadata.SourceURL,
		SourceType:              metadata.SourceType,
		DurationMs:              metadata.DurationMs,
		Title:                   metadata.Title,
		Artist:                  metadata.Artist,
		SchemaVersion:           analyzer.SchemaVersion,
		ExpectedAnalyzer:        expectedAnalyzer,
		ExpectedAnalyzerVersion: expectedVersion,
	}
	if err := p.scheduleAnalysis(ctx, req); err != nil {
		p.markAnalysisSchedulingFailed(req, err)
		log.Printf("Warning: failed to schedule audio analysis for track %d: %v", track.ID, err)
	}
}

func (p *Processor) SetAnalyzerIdentity(analyzerName, analyzerVersion string) {
	if p == nil {
		return
	}
	p.analysisMu.Lock()
	defer p.analysisMu.Unlock()
	p.expectedAnalyzer = strings.TrimSpace(analyzerName)
	p.expectedAnalyzerVersion = strings.TrimSpace(analyzerVersion)
}

func (p *Processor) analyzerIdentity() (string, string) {
	p.analysisMu.Lock()
	defer p.analysisMu.Unlock()
	return p.expectedAnalyzer, p.expectedAnalyzerVersion
}

func (p *Processor) scheduleAnalysis(ctx context.Context, req analyzer.Request) error {
	p.analysisMu.Lock()
	if p.analysisQueue == nil || p.analysisStopping {
		p.analysisMu.Unlock()
		return fmt.Errorf("audio analysis queue is unavailable")
	}
	p.analysisTasks.Add(1)
	p.analysisNextTaskID++
	task := analysisTask{id: p.analysisNextTaskID, request: req}
	p.analysisOutstanding[task.id] = req
	queue := p.analysisQueue
	stop := p.analysisStop
	p.analysisMu.Unlock()
	select {
	case queue <- task:
		return nil
	case <-ctx.Done():
		p.finishAnalysisTask(task.id)
		return ctx.Err()
	case <-stop:
		p.finishAnalysisTask(task.id)
		return errors.New("audio analysis queue is shutting down")
	}
}

func (p *Processor) analysisWorker() {
	for {
		select {
		case task := <-p.analysisQueue:
			if p.analysisCtx.Err() == nil {
				p.runAnalysis(task.request)
			}
			p.finishAnalysisTask(task.id)
		case <-p.analysisCtx.Done():
			return
		}
	}
}

// Shutdown stops submissions and drains cooperative work until the caller's
// recovery reserve. Outstanding rows then use an independent bounded recovery
// context while the database is still open. A client that ignores cancellation
// may keep its goroutine, but cannot hold shutdown open or store a late result.
func (p *Processor) Shutdown(ctx context.Context) error {
	if p == nil || p.analysisQueue == nil {
		return nil
	}
	p.analysisMu.Lock()
	if !p.analysisStopping {
		p.analysisStopping = true
		close(p.analysisStop)
	}
	p.analysisMu.Unlock()

	drained := make(chan struct{})
	go func() {
		p.analysisTasks.Wait()
		close(drained)
	}()
	recoveryTimer, recoveryStart := analysisRecoveryTimer(ctx)
	if recoveryTimer != nil {
		defer recoveryTimer.Stop()
	}
	var shutdownErr error
	select {
	case <-drained:
		p.analysisCancel()
		p.analysisWorkers.Wait()
		return nil
	case <-ctx.Done():
		shutdownErr = ctx.Err()
	case <-recoveryStart:
		shutdownErr = context.DeadlineExceeded
	}

	outstanding := p.outstandingAnalysisRequests()
	p.analysisCancel()
	recoveryCtx, recoveryCancel := context.WithTimeout(context.Background(), analysisShutdownRecoveryTimeout)
	defer recoveryCancel()
	p.recoverAnalysisRows(recoveryCtx, outstanding, fmt.Errorf("analysis canceled during shutdown: %w", shutdownErr))
	p.drainAnalysisQueue(recoveryCtx)
	return shutdownErr
}

func analysisRecoveryTimer(ctx context.Context) (*time.Timer, <-chan time.Time) {
	deadline, ok := ctx.Deadline()
	if !ok {
		return nil, nil
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		timer := time.NewTimer(0)
		return timer, timer.C
	}
	reserve := remaining * 3 / 4
	if reserve > analysisShutdownRecoveryReserve {
		reserve = analysisShutdownRecoveryReserve
	}
	timer := time.NewTimer(remaining - reserve)
	return timer, timer.C
}

func (p *Processor) outstandingAnalysisRequests() []analyzer.Request {
	p.analysisMu.Lock()
	defer p.analysisMu.Unlock()
	latest := make(map[int64]struct {
		id      uint64
		request analyzer.Request
	})
	for id, req := range p.analysisOutstanding {
		current, ok := latest[req.TrackID]
		if !ok || id > current.id {
			latest[req.TrackID] = struct {
				id      uint64
				request analyzer.Request
			}{id: id, request: req}
		}
	}
	requests := make([]analyzer.Request, 0, len(latest))
	for _, task := range latest {
		requests = append(requests, task.request)
	}
	return requests
}

func (p *Processor) drainAnalysisQueue(ctx context.Context) {
	for {
		select {
		case task := <-p.analysisQueue:
			p.finishAnalysisTask(task.id)
		case <-ctx.Done():
			return
		default:
			return
		}
	}
}

func (p *Processor) finishAnalysisTask(taskID uint64) {
	p.analysisMu.Lock()
	_, outstanding := p.analysisOutstanding[taskID]
	if outstanding {
		delete(p.analysisOutstanding, taskID)
	}
	p.analysisMu.Unlock()
	if outstanding {
		p.analysisTasks.Done()
	}
}

func (p *Processor) recoverAnalysisRows(ctx context.Context, requests []analyzer.Request, recoveryErr error) {
	if len(requests) == 0 || recoveryErr == nil {
		return
	}
	jobs := make(chan analyzer.Request, len(requests))
	for _, req := range requests {
		jobs <- req
	}
	close(jobs)

	var workers sync.WaitGroup
	workerCount := min(analysisShutdownRecoveryWorkers, len(requests))
	for range workerCount {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for req := range jobs {
				p.markAnalysisSchedulingFailedWithContext(ctx, req, recoveryErr)
			}
		}()
	}
	// The SQL-backed AnalysisStore honors context cancellation. Join every
	// recovery worker so database.Close cannot race a late recovery write.
	workers.Wait()
}

func (p *Processor) markAnalysisSchedulingFailed(req analyzer.Request, scheduleErr error) {
	if p.analysisRepo == nil || scheduleErr == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	p.markAnalysisSchedulingFailedWithContext(ctx, req, scheduleErr)
}

func (p *Processor) markAnalysisSchedulingFailedWithContext(ctx context.Context, req analyzer.Request, scheduleErr error) {
	if p.analysisRepo == nil || scheduleErr == nil {
		return
	}
	provenance, _ := json.Marshal(map[string]interface{}{
		"trigger":                   "analysis_queue",
		"expected_analyzer":         req.ExpectedAnalyzer,
		"expected_analyzer_version": req.ExpectedAnalyzerVersion,
	})
	if err := p.analysisRepo.MarkFailed(ctx, req.TrackID, scheduleErr.Error(), provenance); err != nil && !errors.Is(err, db.ErrAnalysisResultSuperseded) {
		log.Printf("Warning: failed to mark unscheduled analysis for track %d failed: %v", req.TrackID, err)
	}
}

func (p *Processor) runAnalysis(req analyzer.Request) {
	parent := p.analysisCtx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 2*time.Minute)
	defer cancel()
	provenance, _ := json.Marshal(map[string]interface{}{
		"trigger":                   "analyzer_client",
		"expected_analyzer":         req.ExpectedAnalyzer,
		"expected_analyzer_version": req.ExpectedAnalyzerVersion,
	})
	if err := p.analysisRepo.MarkAnalyzing(ctx, req.TrackID, provenance); err != nil {
		if errors.Is(err, db.ErrAnalysisResultSuperseded) {
			log.Printf("Discarded superseded analysis request for track %d", req.TrackID)
			return
		}
		if ctx.Err() != nil && !p.analysisShutdownCanceled() {
			p.markAnalysisSchedulingFailed(req, fmt.Errorf("analysis canceled before start: %w", ctx.Err()))
			return
		}
		log.Printf("Warning: failed to mark track %d analyzing: %v", req.TrackID, err)
		return
	}
	result, err := p.analyzerClient.Analyze(ctx, req)
	if err != nil {
		if p.analysisShutdownCanceled() {
			return
		}
		terminalCtx, terminalCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer terminalCancel()
		if errors.Is(err, analyzer.ErrUnsupported) {
			_ = p.analysisRepo.MarkUnsupported(terminalCtx, req.TrackID, err.Error(), provenance)
			return
		}
		_ = p.analysisRepo.MarkFailed(terminalCtx, req.TrackID, err.Error(), provenance)
		return
	}
	if err := ctx.Err(); err != nil {
		if p.analysisShutdownCanceled() {
			return
		}
		terminalCtx, terminalCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer terminalCancel()
		_ = p.analysisRepo.MarkFailed(terminalCtx, req.TrackID, err.Error(), provenance)
		return
	}
	if err := p.analysisRepo.StoreResult(ctx, req.TrackID, db.AnalysisResult{
		SchemaVersion:   result.SchemaVersion,
		SummaryJSON:     result.SummaryJSON,
		ArtifactsJSON:   result.ArtifactsJSON,
		ProvenanceJSON:  result.ProvenanceJSON,
		Analyzer:        result.Analyzer,
		AnalyzerVersion: result.AnalyzerVersion,
	}); err != nil {
		if errors.Is(err, db.ErrAnalysisResultSuperseded) {
			log.Printf("Discarded superseded analysis result for track %d", req.TrackID)
			return
		}
		log.Printf("Warning: failed to store analysis result for track %d: %v", req.TrackID, err)
		return
	}
	if p.trackRepo != nil {
		if err := p.trackRepo.ApplyAnalysisGenreHint(ctx, req.TrackID, result.SummaryJSON); err != nil {
			log.Printf("Warning: failed to apply analysis genre hint for track %d: %v", req.TrackID, err)
		}
	}
}

func (p *Processor) analysisShutdownCanceled() bool {
	p.analysisMu.Lock()
	defer p.analysisMu.Unlock()
	return p.analysisStopping && p.analysisCtx != nil && p.analysisCtx.Err() != nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func stringValue(raw map[string]interface{}, key string) string {
	if v, ok := raw[key].(string); ok {
		return v
	}
	return ""
}

func stringValueFromMap(raw map[string]interface{}, key string) string {
	if v, ok := raw[key].(string); ok {
		return v
	}
	return ""
}

func deterministicCleanupMetadata(cleanup deterministicCleanup) map[string]interface{} {
	return map[string]interface{}{
		"raw_title":  cleanup.RawTitle,
		"raw_artist": cleanup.RawArtist,
		"title":      cleanup.Title,
		"artist":     cleanup.Artist,
		"method":     cleanup.Method,
		"applied":    cleanup.Applied,
		"confidence": cleanup.Confidence,
	}
}

func sourceDomain(sourceURL string) string {
	parsed, err := url.Parse(sourceURL)
	if err != nil {
		return ""
	}
	return parsed.Hostname()
}

func floatValue(raw map[string]interface{}, key string) float64 {
	switch v := raw[key].(type) {
	case float64:
		return v
	case int:
		return float64(v)
	case json.Number:
		f, _ := v.Float64()
		return f
	default:
		return 0
	}
}
