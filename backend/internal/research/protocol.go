package research

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"
	"sort"
	"strings"

	"github.com/openmusicplayer/backend/internal/discovery"
)

const RevisionPayloadSchemaVersion = "omp.research.revision.v1"

type RevisionStage string

const (
	StageBaseline    RevisionStage = "baseline"
	StageDirectJudge RevisionStage = "direct_judge"
	StageDeepAgent   RevisionStage = "deep_agent"
)

// RevisionPayload is Go-owned persisted state. Worker projections are derived
// explicitly below and never include the canonical source URL.
type RevisionPayload struct {
	SchemaVersion   string              `json:"schemaVersion"`
	Stage           RevisionStage       `json:"stage"`
	Query           string              `json:"query"`
	Candidates      []CandidateSnapshot `json:"candidates"`
	Recommendations []Recommendation    `json:"recommendations"`
	Provenance      Provenance          `json:"provenance"`
	Timing          SafeTiming          `json:"timing"`
}
type CandidateSnapshot struct {
	CandidateID   string                `json:"candidateId"`
	Provider      string                `json:"provider"`
	SourceID      string                `json:"sourceId,omitempty"`
	SourceURL     string                `json:"sourceUrl"`
	Title         string                `json:"title"`
	Artist        string                `json:"artist,omitempty"`
	Uploader      string                `json:"uploader,omitempty"`
	DurationMs    int                   `json:"durationMs,omitempty"`
	Downloadable  bool                  `json:"downloadable"`
	Playable      bool                  `json:"playable"`
	Explicit      *bool                 `json:"explicit,omitempty"`
	SourceQuality SourceQualitySnapshot `json:"sourceQuality"`
}
type SourceQualitySnapshot struct {
	Score          int      `json:"score"`
	Classification string   `json:"classification"`
	Recommendation string   `json:"recommendation"`
	Confidence     float64  `json:"confidence"`
	Warnings       []string `json:"warnings,omitempty"`
}
type Recommendation struct {
	CandidateID    string   `json:"candidateId"`
	Rank           int      `json:"rank"`
	Confidence     float64  `json:"confidence"`
	Rationale      string   `json:"rationale,omitempty"`
	Classification string   `json:"classification"`
	Warnings       []string `json:"warnings,omitempty"`
	EvidenceRefs   []string `json:"evidenceRefs,omitempty"`
}
type Provenance struct {
	Source                 string `json:"source"`
	WorkerSchemaVersion    string `json:"workerSchemaVersion,omitempty"`
	SpawnToFirstRevisionMs int64  `json:"spawnToFirstRevisionMs,omitempty"`
	SpawnToFinalMs         int64  `json:"spawnToFinalMs,omitempty"`
}
type SafeTiming struct {
	BaselineBuildMs   int64 `json:"baselineBuildMs,omitempty"`
	WorkerStartupMs   int64 `json:"workerStartupMs,omitempty"`
	WorkerInferenceMs int64 `json:"workerInferenceMs,omitempty"`
}
type WorkerCandidateProjection struct {
	CandidateID   string                        `json:"candidateId"`
	Provider      string                        `json:"provider"`
	SourceID      string                        `json:"sourceId,omitempty"`
	Title         string                        `json:"title"`
	Artist        string                        `json:"artist,omitempty"`
	Uploader      string                        `json:"uploader,omitempty"`
	DurationMs    int                           `json:"durationMs,omitempty"`
	Downloadable  bool                          `json:"downloadable"`
	Playable      bool                          `json:"playable"`
	Explicit      *bool                         `json:"explicit,omitempty"`
	SourceQuality WorkerSourceQualityProjection `json:"sourceQuality"`
}

// WorkerSourceQualityProjection intentionally mirrors Python WorkerSourceQuality.
// Recommendation and confidence are server-only baseline details and are not
// part of the model-facing worker contract.
type WorkerSourceQualityProjection struct {
	Score          int      `json:"score"`
	Classification string   `json:"classification"`
	Warnings       []string `json:"warnings,omitempty"`
}

var urlLikeText = regexp.MustCompile(`(?i)(https?://|www\\.|ftp://|mailto:)`)
var secretLikeText = regexp.MustCompile(`(?i)(bearer\\s+|api[_-]?key|token|secret|password|^sk-)`)

func (p RevisionPayload) Marshal() (json.RawMessage, error) {
	if err := ValidateRevisionPayload(p, true); err != nil {
		return nil, err
	}
	return json.Marshal(p)
}
func ParseRevisionPayload(raw json.RawMessage) (RevisionPayload, error) {
	if len(raw) == 0 || len(raw) > 64*1024 {
		return RevisionPayload{}, errors.New("research payload size invalid")
	}
	var p RevisionPayload
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&p); err != nil {
		return RevisionPayload{}, errors.New("research payload schema invalid")
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return RevisionPayload{}, errors.New("research payload schema invalid")
	}
	if err := ValidateRevisionPayload(p, true); err != nil {
		return RevisionPayload{}, err
	}
	return p, nil
}
func ValidateRevisionPayload(p RevisionPayload, allowURLs bool) error {
	if p.SchemaVersion != RevisionPayloadSchemaVersion || (p.Stage != StageBaseline && p.Stage != StageDirectJudge && p.Stage != StageDeepAgent) || !safeRequiredText(p.Query, 512) || len(p.Candidates) > 25 || len(p.Recommendations) > 10 || (p.Stage != StageBaseline && len(p.Candidates) == 0) || (len(p.Candidates) == 0 && len(p.Recommendations) != 0) {
		return errors.New("research payload contract invalid")
	}
	seen := map[string]bool{}
	for i, candidate := range p.Candidates {
		if err := validateCandidateSnapshot(candidate, allowURLs); err != nil {
			return err
		}
		if seen[candidate.CandidateID] {
			return errors.New("duplicate research candidate")
		}
		if i > 0 && compareCandidateRank(p.Candidates[i-1], candidate) > 0 {
			return errors.New("research candidates not ranked")
		}
		seen[candidate.CandidateID] = true
	}
	for i, recommendation := range p.Recommendations {
		if recommendation.Rank != i+1 || recommendation.Confidence < 0 || recommendation.Confidence > 1 || !safeText(recommendation.Rationale, 240) || !safeText(recommendation.Classification, 64) || !seen[recommendation.CandidateID] || len(recommendation.Warnings) > 12 || len(recommendation.EvidenceRefs) > 8 {
			return errors.New("research recommendation invalid")
		}
		for _, value := range append(append([]string{}, recommendation.Warnings...), recommendation.EvidenceRefs...) {
			if !safeText(value, 128) {
				return errors.New("research recommendation unsafe")
			}
		}
	}
	if !safeText(p.Provenance.Source, 128) || !safeText(p.Provenance.WorkerSchemaVersion, 128) || p.Provenance.SpawnToFirstRevisionMs < 0 || p.Provenance.SpawnToFinalMs < 0 || p.Timing.BaselineBuildMs < 0 || p.Timing.WorkerStartupMs < 0 || p.Timing.WorkerInferenceMs < 0 {
		return errors.New("research provenance invalid")
	}
	return nil
}
func validateCandidateSnapshot(c CandidateSnapshot, allowURLs bool) error {
	if !safeRequiredID(c.CandidateID) || !allowedProvider(c.Provider) || !safeOptionalID(c.SourceID) || !safeRequiredText(c.Title, 240) || !safeText(c.Artist, 180) || !safeText(c.Uploader, 180) || c.DurationMs < 0 || c.DurationMs > 86_400_000 || c.SourceQuality.Score < 0 || c.SourceQuality.Score > 100 || !knownSourceQualityClassification(c.SourceQuality.Classification) || !knownSourceQualityRecommendation(c.SourceQuality.Recommendation) || c.SourceQuality.Confidence < 0 || c.SourceQuality.Confidence > 1 {
		return errors.New("research candidate invalid")
	}
	if allowURLs {
		if !canonicalProviderURL(c.Provider, c.SourceURL) {
			return errors.New("research source url invalid")
		}
	} else if c.SourceURL != "" {
		return errors.New("worker URL leak")
	}
	for _, warning := range c.SourceQuality.Warnings {
		if !safeText(warning, 128) {
			return errors.New("research warning unsafe")
		}
	}
	return nil
}
func WorkerProjection(candidates []CandidateSnapshot) ([]WorkerCandidateProjection, error) {
	result := make([]WorkerCandidateProjection, len(candidates))
	for i, c := range candidates {
		if err := validateCandidateSnapshot(c, true); err != nil {
			return nil, err
		}
		result[i] = WorkerCandidateProjection{c.CandidateID, c.Provider, c.SourceID, c.Title, c.Artist, c.Uploader, c.DurationMs, c.Downloadable, c.Playable, c.Explicit, WorkerSourceQualityProjection{Score: c.SourceQuality.Score, Classification: c.SourceQuality.Classification, Warnings: append([]string(nil), c.SourceQuality.Warnings...)}}
	}
	return result, nil
}
func snapshotCandidate(c discovery.Candidate, q discovery.SourceQuality) CandidateSnapshot {
	return CandidateSnapshot{CandidateID: c.CandidateID, Provider: c.Provider, SourceID: c.SourceID, SourceURL: c.SourceURL, Title: c.Title, Artist: c.Artist, Uploader: c.Uploader, DurationMs: c.DurationMs, Downloadable: c.Downloadable, Playable: c.Playable, Explicit: c.Explicit, SourceQuality: SourceQualitySnapshot{Score: q.Score, Classification: q.Classification, Recommendation: q.Recommendation, Confidence: q.Confidence, Warnings: append([]string(nil), q.Warnings...)}}
}
func compareCandidateRank(a, b CandidateSnapshot) int {
	if a.SourceQuality.Score != b.SourceQuality.Score {
		return b.SourceQuality.Score - a.SourceQuality.Score
	}
	if recommendationOrder(a.SourceQuality.Recommendation) != recommendationOrder(b.SourceQuality.Recommendation) {
		return recommendationOrder(b.SourceQuality.Recommendation) - recommendationOrder(a.SourceQuality.Recommendation)
	}
	if a.Downloadable != b.Downloadable {
		if a.Downloadable {
			return -1
		}
		return 1
	}
	return strings.Compare(a.CandidateID, b.CandidateID)
}
func SortCandidateSnapshots(c []CandidateSnapshot) {
	sort.SliceStable(c, func(i, j int) bool { return compareCandidateRank(c[i], c[j]) < 0 })
}
func recommendationOrder(s string) int {
	switch s {
	case discovery.SourceQualityPreferred:
		return 4
	case discovery.SourceQualityAcceptable:
		return 3
	case discovery.SourceQualityReview:
		return 2
	case discovery.SourceQualityAvoid:
		return 1
	}
	return 0
}
func knownSourceQualityClassification(s string) bool {
	switch s {
	case discovery.SourceQualityOfficialAudio,
		discovery.SourceQualityTopicAudio,
		discovery.SourceQualityArtistUpload,
		discovery.SourceQualityMusicVideo,
		discovery.SourceQualityVisualizer,
		discovery.SourceQualityLive,
		discovery.SourceQualityLyricVideo,
		discovery.SourceQualityInterview,
		discovery.SourceQualityCover,
		discovery.SourceQualityRemix,
		discovery.SourceQualityAlteredAudio,
		discovery.SourceQualityDirectURL,
		discovery.SourceQualityUnknown:
		return true
	}
	return false
}
func knownSourceQualityRecommendation(s string) bool {
	switch s {
	case discovery.SourceQualityPreferred,
		discovery.SourceQualityAcceptable,
		discovery.SourceQualityReview,
		discovery.SourceQualityAvoid:
		return true
	}
	return false
}
func allowedProvider(s string) bool { return s == "youtube" || s == "soundcloud" }
func safeRequiredID(s string) bool {
	return safeRequiredText(s, 128)
}
func safeOptionalID(s string) bool {
	return s == "" || safeRequiredID(s)
}
func safeText(s string, n int) bool {
	return len(s) <= n && !urlLikeText.MatchString(s) && !secretLikeText.MatchString(s) && !strings.ContainsAny(s, "\r\n\x00")
}
func safeRequiredText(s string, n int) bool {
	return strings.TrimSpace(s) != "" && safeText(s, n)
}
func canonicalProviderURL(provider, raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Fragment != "" || parsed.Host == "" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	if provider == "youtube" {
		if host == "youtu.be" {
			return len(strings.Trim(parsed.Path, "/")) > 0
		}
		if host != "youtube.com" && host != "www.youtube.com" && host != "m.youtube.com" && host != "music.youtube.com" {
			return false
		}
		switch parsed.Path {
		case "/watch":
			return strings.TrimSpace(parsed.Query().Get("v")) != ""
		case "/playlist":
			return strings.TrimSpace(parsed.Query().Get("list")) != ""
		default:
			return strings.HasPrefix(parsed.Path, "/shorts/") || strings.HasPrefix(parsed.Path, "/embed/") || strings.HasPrefix(parsed.Path, "/live/")
		}
	}
	if provider != "soundcloud" || (host != "soundcloud.com" && host != "www.soundcloud.com" && host != "m.soundcloud.com") {
		return false
	}
	return len(strings.Split(strings.Trim(parsed.Path, "/"), "/")) >= 2
}
func payloadError(kind string) error { return errors.New("research " + kind + " rejected") }
