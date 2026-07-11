package processor

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/analyzer"
	"github.com/openmusicplayer/backend/internal/db"
)

const defaultAnalysisRepairStaleAfter = 30 * time.Minute

type MetadataRepairOptions struct {
	Force bool
}

type MetadataRepairResult struct {
	TrackID   int64  `json:"trackId"`
	Status    string `json:"status"`
	Reason    string `json:"reason,omitempty"`
	WaitingOn string `json:"waitingOn,omitempty"`
}

type AnalysisRepairOptions struct {
	Force                   bool
	OnlyStale               bool
	StaleAfter              time.Duration
	ExpectedAnalyzer        string
	ExpectedAnalyzerVersion string
}

type AnalysisRepairResult struct {
	TrackID        int64  `json:"trackId"`
	Queued         bool   `json:"queued"`
	Status         string `json:"status"`
	PreviousStatus string `json:"previousStatus,omitempty"`
	Reason         string `json:"reason,omitempty"`
	WaitingOn      string `json:"waitingOn,omitempty"`
}

type analysisRepairStore interface {
	RequestRepairAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage, force, onlyStale bool, staleAfter time.Duration) (db.AnalysisRepairRequest, error)
}

func (p *Processor) RepairMetadata(ctx context.Context, track *db.Track, opts MetadataRepairOptions) (MetadataRepairResult, error) {
	if track == nil {
		return MetadataRepairResult{Status: "skipped", Reason: "missing_track"}, nil
	}
	result := MetadataRepairResult{TrackID: track.ID}
	if track.MetadataUserEdited && !opts.Force {
		result.Status = "skipped"
		result.Reason = "user_edited_metadata"
		return result, nil
	}
	if track.MBVerified && !opts.Force {
		result.Status = "skipped"
		result.Reason = "already_verified"
		return result, nil
	}
	if p.matcher == nil {
		result.Status = "skipped"
		result.Reason = "metadata_matcher_disabled"
		result.WaitingOn = "metadata_verifier"
		return result, nil
	}

	metadata := trackMetadataFromDBTrack(track)
	if err := p.runMatching(ctx, track, metadata); err != nil {
		result.Status = "failed"
		result.Reason = err.Error()
		if strings.Contains(strings.ToLower(err.Error()), "ollama") {
			result.WaitingOn = "ollama"
		} else {
			result.WaitingOn = "metadata_verifier"
		}
		return result, err
	}
	result.Status = "processed"
	result.Reason = "metadata_match_reran"
	return result, nil
}

func (p *Processor) RequestAnalysisRepair(ctx context.Context, track *db.Track, opts AnalysisRepairOptions) (AnalysisRepairResult, error) {
	if track == nil {
		return AnalysisRepairResult{Status: "skipped", Reason: "missing_track"}, nil
	}
	result := AnalysisRepairResult{TrackID: track.ID}
	if p.analysisRepo == nil {
		result.Status = "skipped"
		result.Reason = "analysis_store_disabled"
		result.WaitingOn = "analyzer"
		return result, nil
	}
	if p.analyzerClient == nil {
		result.Status = "skipped"
		result.Reason = "analyzer_client_disabled"
		result.WaitingOn = "analyzer_config"
		return result, nil
	}
	if !track.StorageKey.Valid || track.StorageKey.String == "" {
		result.Status = "skipped"
		result.Reason = "missing_storage_key"
		result.WaitingOn = "storage"
		return result, nil
	}
	expectedAnalyzer := strings.TrimSpace(opts.ExpectedAnalyzer)
	expectedAnalyzerVersion := strings.TrimSpace(opts.ExpectedAnalyzerVersion)
	if expectedAnalyzer == "" && expectedAnalyzerVersion == "" {
		expectedAnalyzer, expectedAnalyzerVersion = p.analyzerIdentity()
	}
	if (expectedAnalyzer == "") != (expectedAnalyzerVersion == "") {
		return result, fmt.Errorf("expected analyzer identity requires both name and version")
	}
	if p.requireAnalyzerIdentity && expectedAnalyzer == "" {
		result.Status = "skipped"
		result.Reason = "analyzer_identity_unavailable"
		result.WaitingOn = "analyzer"
		return result, nil
	}
	staleAfter := opts.StaleAfter
	if staleAfter <= 0 {
		staleAfter = defaultAnalysisRepairStaleAfter
	}

	provenance, _ := json.Marshal(map[string]interface{}{
		"trigger":                   "maintenance_repair",
		"force":                     opts.Force,
		"only_stale":                opts.OnlyStale,
		"expected_analyzer":         expectedAnalyzer,
		"expected_analyzer_version": expectedAnalyzerVersion,
		"source": map[string]interface{}{
			"storage_key": track.StorageKey.String,
			"source_type": nullableString(track.SourceType),
			"duration_ms": nullableInt32(track.DurationMs),
		},
	})

	repairer, ok := p.analysisRepo.(analysisRepairStore)
	if !ok {
		result.Status = "skipped"
		result.Reason = "analysis_repair_unsupported"
		result.WaitingOn = "analysis_store"
		return result, nil
	}
	repair, err := repairer.RequestRepairAnalysis(ctx, track.ID, provenance, opts.Force, opts.OnlyStale, staleAfter)
	if err != nil {
		return result, err
	}
	result.PreviousStatus = repair.PreviousStatus
	result.Queued = repair.Queued
	result.Status = repair.Status
	result.Reason = repair.Reason
	if !repair.Queued {
		if result.WaitingOn == "" && (repair.Status == db.AnalysisStatusPending || repair.Status == db.AnalysisStatusAnalyzing) {
			result.WaitingOn = "analyzer"
		}
		return result, nil
	}

	req := analyzer.Request{
		TrackID:                 track.ID,
		StorageKey:              track.StorageKey.String,
		SourceURL:               nullableString(track.SourceURL),
		SourceType:              nullableString(track.SourceType),
		DurationMs:              int(nullableInt32(track.DurationMs)),
		Title:                   track.Title,
		Artist:                  nullableString(track.Artist),
		SchemaVersion:           analyzer.SchemaVersion,
		ExpectedAnalyzer:        expectedAnalyzer,
		ExpectedAnalyzerVersion: expectedAnalyzerVersion,
	}
	if err := p.scheduleAnalysis(ctx, req); err != nil {
		p.markAnalysisSchedulingFailed(req, err)
		return result, fmt.Errorf("schedule analysis repair: %w", err)
	}
	return result, nil
}

func trackMetadataFromDBTrack(track *db.Track) *TrackMetadata {
	metadata := &TrackMetadata{
		Title:         track.Title,
		Artist:        nullableString(track.Artist),
		Album:         nullableString(track.Album),
		DurationMs:    int(nullableInt32(track.DurationMs)),
		SourceURL:     nullableString(track.SourceURL),
		SourceType:    nullableString(track.SourceType),
		StorageKey:    nullableString(track.StorageKey),
		FileSizeBytes: nullableInt64(track.FileSizeBytes),
		Raw: map[string]interface{}{
			"title":           track.Title,
			"artist":          nullableString(track.Artist),
			"album":           nullableString(track.Album),
			"duration_ms":     nullableInt32(track.DurationMs),
			"source_url":      nullableString(track.SourceURL),
			"source_type":     nullableString(track.SourceType),
			"storage_key":     nullableString(track.StorageKey),
			"file_size_bytes": nullableInt64(track.FileSizeBytes),
		},
	}
	if len(track.MetadataProvenance) > 0 {
		var provenance map[string]interface{}
		if err := json.Unmarshal(track.MetadataProvenance, &provenance); err == nil {
			if rawProvider, ok := provenance["raw_provider"].(map[string]interface{}); ok {
				for key, value := range rawProvider {
					metadata.Raw[key] = value
				}
			}
		}
	}
	return metadata
}

func nullableString(value interface{}) string {
	switch v := value.(type) {
	case sql.NullString:
		if v.Valid {
			return v.String
		}
	case fmt.Stringer:
		return v.String()
	}
	return ""
}

func nullableInt32(value sql.NullInt32) int32 {
	if value.Valid {
		return value.Int32
	}
	return 0
}

func nullableInt64(value sql.NullInt64) int64 {
	if value.Valid {
		return value.Int64
	}
	return 0
}
