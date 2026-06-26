package processor

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/matcher"
)

// ObjectStorage is the small MinIO surface the processor needs. storage.Client
// satisfies this interface; tests can use a fake without a real MinIO server.
type ObjectStorage interface {
	PutObject(ctx context.Context, key string, reader io.Reader, size int64, contentType string) error
}

const (
	maxYTDLPOutputBytes = 256 * 1024 * 1024
	maxYTDLPLogBytes    = 64 * 1024
)

// Processor handles the full download and matching pipeline
type Processor struct {
	matcher     *matcher.Matcher
	trackRepo   *db.TrackRepository
	libraryRepo *db.LibraryRepository
	storage     ObjectStorage
}

// ProcessorConfig holds configuration for the processor
type ProcessorConfig struct {
	Matcher     *matcher.Matcher
	TrackRepo   *db.TrackRepository
	LibraryRepo *db.LibraryRepository
	Storage     ObjectStorage
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
			"candidate_id":  job.CandidateID,
			"source_id":     job.SourceID,
			"title":         job.Title,
			"artist":        job.Artist,
			"album":         job.Album,
			"uploader":      job.Uploader,
			"duration_ms":   job.DurationMs,
			"source_url":    job.URL,
			"source_type":   job.SourceType,
			"thumbnail_url": job.ThumbnailURL,
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
	keys := []string{"id", "title", "fulltitle", "artist", "album", "uploader", "channel", "duration", "duration_ms", "webpage_url", "source_url", "source_type", "thumbnail", "thumbnail_url", "candidate_id", "source_id"}
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
	matchMetadata := matcher.TrackMetadata{Title: metadata.Title}
	if metadata.Artist != "" {
		matchMetadata.Uploader = metadata.Artist
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
		RespectUserEdits:   true,
		MetadataStatus:     "failed",
		MetadataProvenance: failedProvenance,
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
	}
	mbProvenance, _ := json.Marshal(map[string]interface{}{
		"musicbrainz": map[string]interface{}{
			"status":       update.MetadataStatus,
			"verified":     output.Verified,
			"best_match":   output.BestMatch,
			"suggestions":  output.Suggestions,
			"parsed_title": output.ParsedTitle,
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
