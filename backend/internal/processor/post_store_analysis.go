package processor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"regexp"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
)

// PostStoreAnalysisOrigin identifies the committed ingest path, not a client input.
type PostStoreAnalysisOrigin uint8

const (
	PostStoreDownload PostStoreAnalysisOrigin = iota + 1
	PostStoreLibraryUpload

	postStoreDispatchTimeout = 5 * time.Second
)

var storedSourceSHA256 = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// SchedulePostStoreAnalysis submits ordinary analysis after the canonical track
// is committed. Upload callers must pass the winning stored track (including
// key, byte length, and measured duration), never the staging candidate. The
// upload owner must commit its verified digest together with that immutable
// source; this hook verifies the recorded proof, not the object bytes again.
//
// The bool reports queue admission, not analysis readiness. False with nil
// means disabled, deferred, or the repository did not grant a new dispatch.
// Neither a refusal nor a dispatch error changes the committed ingest outcome.
func (p *Processor) SchedulePostStoreAnalysis(ctx context.Context, track *db.Track, origin PostStoreAnalysisOrigin) (bool, error) {
	var trigger string
	switch origin {
	case PostStoreDownload:
		trigger = "post_download"
	case PostStoreLibraryUpload:
		trigger = "post_library_upload"
	default:
		return false, fmt.Errorf("unsupported post-store analysis origin %d", origin)
	}
	upload := origin == PostStoreLibraryUpload
	if track == nil || !track.StorageKey.Valid || track.StorageKey.String == "" || (upload && strings.TrimSpace(track.StorageKey.String) == "") {
		if upload {
			return false, errors.New("post-upload analysis requires a canonical storage key")
		}
		return false, nil
	}
	if p.analysisRepo == nil || p.analyzerClient == nil {
		return false, nil
	}
	if upload {
		if p.analysisCtx == nil {
			return false, errors.New("post-upload analysis dispatcher is unavailable")
		}
		// The HTTP request may already have ended. Bound both the persisted
		// claim and queue admission under the processor's lifetime instead.
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(p.analysisCtx, postStoreDispatchTimeout)
		defer cancel()

		canonical, err := p.verifyPostUploadTrack(ctx, track)
		if err != nil {
			return false, err
		}
		track = canonical
	}

	// URL dedupe may return an older canonical object. Read the hash for that
	// object, not from the discarded candidate. It remains advisory for URLs.
	sourceFileHash := ""
	if p.trackRepo != nil {
		var err error
		sourceFileHash, err = p.trackRepo.GetSourceFileHash(ctx, track.ID)
		if err != nil {
			if upload {
				return false, fmt.Errorf("read canonical upload source hash: %w", err)
			}
			log.Printf("Warning: failed to read canonical source hash for track %d: %v", track.ID, err)
		}
	}
	if upload && !storedSourceSHA256.MatchString(sourceFileHash) {
		return false, errors.New("post-upload analysis requires a persisted canonical SHA-256")
	}
	expectedAnalyzer, expectedVersion := p.analyzerIdentity()

	req := analyzer.Request{
		TrackID:                 track.ID,
		StorageKey:              track.StorageKey.String,
		DurationMs:              int(nullableInt32(track.DurationMs)),
		SchemaVersion:           analyzer.SchemaVersion,
		ExpectedAnalyzer:        expectedAnalyzer,
		ExpectedAnalyzerVersion: expectedVersion,
	}
	source := map[string]interface{}{
		"storage_key":      req.StorageKey,
		"source_file_hash": sourceFileHash,
		"source_type":      nullableString(track.SourceType),
		"duration_ms":      req.DurationMs,
	}
	if upload {
		source["file_size_bytes"] = track.FileSizeBytes.Int64
	} else {
		req.SourceURL = nullableString(track.SourceURL)
		req.SourceType = nullableString(track.SourceType)
		req.Title = track.Title
		req.Artist = nullableString(track.Artist)
	}
	provenance, _ := json.Marshal(map[string]interface{}{
		"trigger":                   trigger,
		"expected_analyzer":         expectedAnalyzer,
		"expected_analyzer_version": expectedVersion,
		"source":                    source,
	})
	shouldSchedule, err := p.analysisRepo.RequestAnalysisIfNeeded(ctx, track.ID, provenance)
	if err != nil {
		return false, fmt.Errorf("request audio analysis: %w", err)
	}
	if !shouldSchedule {
		return false, nil
	}
	if p.requireAnalyzerIdentity && (expectedAnalyzer == "" || (upload && expectedVersion == "")) {
		// Keep the pending intent without dispatching an unversioned job.
		// Existing identity reconciliation can mark this row stale once the
		// analyzer identifies itself, then claim it through normal repair.
		log.Printf("Deferred audio analysis for track %d until analyzer identity is available", track.ID)
		return false, nil
	}
	if err := p.scheduleAnalysis(ctx, req); err != nil {
		p.markAnalysisSchedulingFailed(req, err)
		return false, fmt.Errorf("schedule audio analysis: %w", err)
	}
	return true, nil
}

func (p *Processor) verifyPostUploadTrack(ctx context.Context, track *db.Track) (*db.Track, error) {
	if p.trackRepo == nil || track.ID <= 0 {
		return nil, errors.New("post-upload analysis requires a persisted canonical track")
	}
	canonical, err := p.trackRepo.GetByID(ctx, track.ID)
	if err != nil {
		return nil, fmt.Errorf("read canonical upload track: %w", err)
	}
	if canonical.Private {
		return nil, errors.New("private import analysis is owned by the durable drain")
	}
	// GetByID and the hash read describe the same source because committed
	// upload keys and their proof are immutable. A future source replacement
	// feature would need a stronger fence at claim, dispatch, and result.
	if canonical.StorageKey != track.StorageKey || canonical.FileSizeBytes != track.FileSizeBytes || canonical.DurationMs != track.DurationMs {
		return nil, errors.New("post-upload analysis source differs from canonical track")
	}
	if !canonical.FileSizeBytes.Valid || canonical.FileSizeBytes.Int64 <= 0 || !canonical.DurationMs.Valid || canonical.DurationMs.Int32 <= 0 {
		return nil, errors.New("post-upload analysis requires persisted byte length and measured duration")
	}
	return canonical, nil
}
