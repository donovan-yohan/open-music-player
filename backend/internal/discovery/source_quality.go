package discovery

import (
	"context"
	"math"
	"sort"
	"strings"
	"unicode"
)

const (
	SourceQualityMetadataKey = "sourceQuality"

	SourceQualityOfficialAudio = "official_audio"
	SourceQualityTopicAudio    = "topic_audio"
	SourceQualityArtistUpload  = "artist_upload"
	SourceQualityMusicVideo    = "music_video"
	SourceQualityVisualizer    = "visualizer"
	SourceQualityLive          = "live"
	SourceQualityLyricVideo    = "lyric_video"
	SourceQualityInterview     = "interview"
	SourceQualityCover         = "cover"
	SourceQualityRemix         = "remix"
	SourceQualityAlteredAudio  = "altered_audio"
	SourceQualityDirectURL     = "direct_url"
	SourceQualityUnknown       = "unknown"

	SourceQualityPreferred  = "preferred"
	SourceQualityAcceptable = "acceptable"
	SourceQualityReview     = "review"
	SourceQualityAvoid      = "avoid"

	// sourceQualityMaxModelScoreMovement is intentionally small: model judgments
	// are evidence on top of deterministic source-quality signals, not authority.
	sourceQualityMaxModelScoreMovement = 15
	sourceQualityModelEvidencePrefix   = "model evidence: "
)

// SourceQuality is the auditable deterministic judgment attached to source
// candidates. It is intentionally model-shaped so an optional LLM judge can
// produce the same contract later, while this fallback remains always-on.
type SourceQuality struct {
	Score          int      `json:"score"`
	Classification string   `json:"classification"`
	Recommendation string   `json:"recommendation"`
	Confidence     float64  `json:"confidence"`
	Reasons        []string `json:"reasons,omitempty"`
	Warnings       []string `json:"warnings,omitempty"`
	Provenance     string   `json:"provenance"`
}

type scoredCandidate struct {
	candidate Candidate
	quality   SourceQuality
	index     int
}

// SourceQualityJudge is an optional structured judge that can refine the
// deterministic fallback. It is deliberately grounded by candidateId only: a
// model can rank or explain existing candidates, but cannot create new URLs.
type SourceQualityJudge interface {
	JudgeSourceQuality(ctx context.Context, query string, candidates []SourceQualityCandidateFeature) ([]SourceQualityJudgment, error)
}

// SourceQualityCandidateFeature is the bounded candidate envelope passed to an
// optional judge. It contains source-selection clues but not raw provider blobs.
type SourceQualityCandidateFeature struct {
	CandidateID   string                 `json:"candidateId"`
	Provider      string                 `json:"provider"`
	SourceID      string                 `json:"sourceId,omitempty"`
	SourceURL     string                 `json:"sourceUrl"`
	Title         string                 `json:"title"`
	Artist        string                 `json:"artist,omitempty"`
	Uploader      string                 `json:"uploader,omitempty"`
	DurationMs    int                    `json:"durationMs,omitempty"`
	Downloadable  bool                   `json:"downloadable"`
	MetadataHints map[string]interface{} `json:"metadataHints,omitempty"`
}

// SourceQualityJudgment is the structured judge output. CandidateID must match
// an input feature; unknown ids are ignored and fall back deterministically.
type SourceQualityJudgment struct {
	CandidateID string        `json:"candidateId"`
	Quality     SourceQuality `json:"quality"`
}

// rankSourceCandidates annotates each candidate with sourceQuality metadata and
// orders them by likely suitability for a clean audio import. It is deterministic
// and does not require the AI assist model to be available.
func rankSourceCandidates(query string, candidates []Candidate) []Candidate {
	return rankSourceCandidatesWithQualities(candidates, deterministicSourceQualities(query, candidates))
}

func rankSourceCandidatesWithJudge(ctx context.Context, query string, candidates []Candidate, judge SourceQualityJudge) []Candidate {
	if len(candidates) == 0 {
		return candidates
	}
	if judge == nil {
		return rankSourceCandidates(query, candidates)
	}
	qualities := deterministicSourceQualities(query, candidates)
	if judgments, err := judge.JudgeSourceQuality(ctx, query, sourceQualityCandidateFeatures(candidates)); err == nil {
		applySourceQualityJudgments(qualities, judgments)
	}
	return rankSourceCandidatesWithQualities(candidates, qualities)
}

func deterministicSourceQualities(query string, candidates []Candidate) map[string]SourceQuality {
	qualities := make(map[string]SourceQuality, len(candidates))
	for _, candidate := range candidates {
		qualities[candidate.CandidateID] = EvaluateSourceQuality(query, candidate)
	}
	return qualities
}

func rankSourceCandidatesWithQualities(candidates []Candidate, qualities map[string]SourceQuality) []Candidate {
	scored := make([]scoredCandidate, 0, len(candidates))
	for i, candidate := range candidates {
		quality, ok := qualities[candidate.CandidateID]
		if !ok {
			quality = EvaluateSourceQuality("", candidate)
		}
		scored = append(scored, scoredCandidate{
			candidate: candidateWithSourceQuality(candidate, quality),
			quality:   quality,
			index:     i,
		})
	}
	sort.SliceStable(scored, func(i, j int) bool {
		left := scored[i]
		right := scored[j]
		if left.quality.Score != right.quality.Score {
			return left.quality.Score > right.quality.Score
		}
		if recommendationRank(left.quality.Recommendation) != recommendationRank(right.quality.Recommendation) {
			return recommendationRank(left.quality.Recommendation) > recommendationRank(right.quality.Recommendation)
		}
		if left.candidate.Downloadable != right.candidate.Downloadable {
			return left.candidate.Downloadable
		}
		return left.index < right.index
	})

	ranked := make([]Candidate, len(scored))
	for i, item := range scored {
		ranked[i] = item.candidate
	}
	return ranked
}

func applySourceQualityJudgments(qualities map[string]SourceQuality, judgments []SourceQualityJudgment) {
	for _, judgment := range judgments {
		deterministic, ok := qualities[judgment.CandidateID]
		if !ok {
			continue
		}
		qualities[judgment.CandidateID] = blendSourceQualityJudgment(deterministic, judgment.Quality)
	}
}

func blendSourceQualityJudgment(deterministic, model SourceQuality) SourceQuality {
	modelScore := clampInt(model.Score, 0, 100)
	quality := deterministic
	quality.Score = clampInt(modelScore, deterministic.Score-sourceQualityMaxModelScoreMovement, deterministic.Score+sourceQualityMaxModelScoreMovement)
	quality.Recommendation = recommendationForScore(quality.Score)
	quality.Confidence = confidenceForScore(quality.Score)
	quality.Reasons = appendModelEvidence(deterministic.Reasons, model.Reasons)
	quality.Warnings = appendModelEvidence(deterministic.Warnings, model.Warnings)
	quality.Provenance = deterministic.Provenance + "+model:"
	if provenance := strings.TrimSpace(model.Provenance); provenance != "" {
		quality.Provenance += provenance
	} else {
		quality.Provenance += "source_quality_judge"
	}
	return quality
}

func appendModelEvidence(deterministic, model []string) []string {
	combined := append([]string{}, deterministic...)
	for _, value := range model {
		value = strings.TrimSpace(value)
		if value != "" {
			combined = append(combined, sourceQualityModelEvidencePrefix+value)
		}
	}
	return uniqueStrings(combined)
}

// EvaluateSourceQuality scores one candidate against a user query. It prefers
// official audio / topic uploads and warns against visualizers, music videos,
// live clips, interviews, shorts, and user-modified versions unless the query
// asks for them.
func EvaluateSourceQuality(query string, candidate Candidate) SourceQuality {
	score := 55
	classification := SourceQualityUnknown
	reasons := []string{"deterministic fallback ranking"}
	var warnings []string

	title := strings.ToLower(candidate.Title)
	artist := strings.ToLower(candidate.Artist)
	uploader := strings.ToLower(candidate.Uploader)
	sourceURL := strings.ToLower(candidate.SourceURL)
	combined := sourceQualityText(candidate)
	queryText := strings.ToLower(query)
	queryTokens := tokenSet(queryText)
	combinedTokens := tokenSet(combined)

	if candidate.SourceURL == "" || !candidate.Downloadable {
		score -= 40
		warnings = append(warnings, "source is not downloadable")
	}

	queryRequestsVideo := containsAny(queryText, "music video") || hasAnyToken(queryTokens, "video", "mv")
	queryRequestsVisualizer := hasAnyToken(queryTokens, "visualizer", "visualiser")
	queryRequestsLive := hasAnyToken(queryTokens, "live", "concert", "festival", "set")
	queryRequestsLyrics := hasAnyToken(queryTokens, "lyric", "lyrics")
	queryRequestsCover := hasAnyToken(queryTokens, "cover")
	queryRequestsRemix := hasAnyToken(queryTokens, "remix", "edit", "mashup")

	hasOfficialAudio := containsAny(combined, "official audio", "audio only", "official track")
	hasYouTubeMusicSongsSurface := strings.EqualFold(metadataStringValue(candidate.Metadata, "discoverySurface"), "youtube_music_songs")
	hasYouTubeMusicAttribution := containsAny(combined, "provided to youtube by", "auto-generated by youtube")
	hasStructuredMusicMetadata := hasMetadataText(candidate.Metadata, "track") && hasMetadataText(candidate.Metadata, "artist") && hasMetadataText(candidate.Metadata, "album")
	hasReleaseMetadata := hasMetadataText(candidate.Metadata, "label") || hasMetadataText(candidate.Metadata, "release_date") || hasMetadataText(candidate.Metadata, "release_year")
	hasVisualizer := hasAnyToken(combinedTokens, "visualizer", "visualiser") || containsAny(combined, "official visualizer", "official visualiser")
	hasTopicUpload := strings.Contains(uploader, " - topic") || strings.HasSuffix(strings.TrimSpace(uploader), " topic")
	hasMusicVideo := containsAny(combined, "official music video", "music video", "official video", "(video)", "[video]") || strings.Contains(title, " mv")
	hasLive := hasAnyToken(combinedTokens, "live", "concert", "festival") || containsAny(combined, "boiler room", "live at")
	hasLyric := hasAnyToken(combinedTokens, "lyric", "lyrics") || strings.Contains(combined, "lyric video")
	hasInterview := hasAnyToken(combinedTokens, "interview", "documentary", "reaction") || containsAny(combined, "behind the scenes", "making of")
	hasCover := hasAnyToken(combinedTokens, "cover")
	hasRemix := hasAnyToken(combinedTokens, "remix", "mashup", "bootleg")
	hasAltered := hasAnyToken(combinedTokens, "slowed", "reverb", "nightcore") || containsAny(combined, "sped up", "8d audio")
	hasShorts := strings.Contains(sourceURL, "/shorts/") || hasAnyToken(combinedTokens, "shorts") || strings.Contains(combined, "youtube shorts")

	if hasOfficialAudio {
		score += 30
		classification = SourceQualityOfficialAudio
		reasons = append(reasons, "title indicates official audio")
	}
	if hasYouTubeMusicSongsSurface {
		score += 32
		classification = SourceQualityOfficialAudio
		reasons = append(reasons, "YouTube Music Songs discovery surface identifies an official track")
	}
	if hasYouTubeMusicAttribution && hasStructuredMusicMetadata {
		score += 32
		classification = SourceQualityOfficialAudio
		reasons = append(reasons, "YouTube Music metadata identifies a label-provided track")
	}
	if hasReleaseMetadata && (hasYouTubeMusicAttribution || hasStructuredMusicMetadata) {
		score += 10
		reasons = append(reasons, "label or release metadata supports official audio")
	}
	if hasVisualizer {
		if queryRequestsVisualizer {
			score += 8
			classification = SourceQualityVisualizer
			reasons = append(reasons, "query asked for visualizer content")
		} else {
			score += 6
			if classification == SourceQualityUnknown {
				classification = SourceQualityVisualizer
			}
			warnings = append(warnings, "candidate appears to be a visualizer; verify clean audio")
		}
	}
	if hasTopicUpload {
		score += 24
		if classification == SourceQualityUnknown {
			classification = SourceQualityTopicAudio
		}
		reasons = append(reasons, "YouTube topic upload is usually label-provided audio")
	}
	if artist != "" && uploader != "" && normalizedContains(uploader, artist) {
		score += 8
		if classification == SourceQualityUnknown {
			classification = SourceQualityArtistUpload
		}
		reasons = append(reasons, "uploader matches the artist")
	}
	if titleMatchesQuery(query, candidate) {
		score += 8
		reasons = append(reasons, "title and artist match the query terms")
	}

	if hasInterview {
		score -= 45
		classification = SourceQualityInterview
		warnings = append(warnings, "candidate appears to include interview or documentary content")
	}
	if hasAltered {
		score -= 35
		classification = SourceQualityAlteredAudio
		warnings = append(warnings, "candidate appears to be speed/pitch altered")
	}
	if hasShorts {
		score -= 35
		classification = SourceQualityMusicVideo
		warnings = append(warnings, "candidate appears to be a short-form video")
	}
	if hasMusicVideo && !queryRequestsVideo {
		score -= 30
		classification = SourceQualityMusicVideo
		warnings = append(warnings, "candidate appears to be a music video")
	} else if hasMusicVideo {
		score += 6
		classification = SourceQualityMusicVideo
		reasons = append(reasons, "query asked for video content")
	}
	if hasLive && !queryRequestsLive {
		score -= 32
		classification = SourceQualityLive
		warnings = append(warnings, "candidate appears to be a live version")
	} else if hasLive {
		score += 10
		classification = SourceQualityLive
		reasons = append(reasons, "query asked for live content")
	}
	if hasLyric && !queryRequestsLyrics {
		score -= 14
		if classification == SourceQualityUnknown || classification == SourceQualityArtistUpload || classification == SourceQualityVisualizer {
			classification = SourceQualityLyricVideo
		}
		warnings = append(warnings, "candidate appears to be a lyric video")
	}
	if hasCover && !queryRequestsCover {
		score -= 20
		classification = SourceQualityCover
		warnings = append(warnings, "candidate appears to be a cover")
	}
	if hasRemix && !queryRequestsRemix {
		score -= 16
		if classification == SourceQualityUnknown || classification == SourceQualityOfficialAudio {
			classification = SourceQualityRemix
		}
		warnings = append(warnings, "candidate appears to be a remix or edit")
	}

	if candidate.DurationMs > 0 {
		switch {
		case candidate.DurationMs < 75_000:
			score -= 18
			warnings = append(warnings, "candidate duration is very short")
		case candidate.DurationMs > 12*60_000 && !queryRequestsLive && !queryRequestsRemix:
			score -= 10
			warnings = append(warnings, "candidate duration is long for a single track")
		}
	}

	score = clampInt(score, 0, 100)
	if classification == SourceQualityUnknown && score >= 80 {
		classification = SourceQualityArtistUpload
	}
	return SourceQuality{
		Score:          score,
		Classification: classification,
		Recommendation: recommendationForScore(score),
		Confidence:     confidenceForScore(score),
		Reasons:        uniqueStrings(reasons),
		Warnings:       uniqueStrings(warnings),
		Provenance:     "deterministic_source_quality_v1",
	}
}

func sourceQualityForDirectURL(candidate Candidate) SourceQuality {
	return SourceQuality{
		Score:          60,
		Classification: SourceQualityDirectURL,
		Recommendation: SourceQualityReview,
		Confidence:     0.62,
		Reasons:        []string{"user supplied this direct URL"},
		Warnings:       []string{"title is not resolved until download metadata is fetched"},
		Provenance:     "deterministic_source_quality_v1",
	}
}

func candidateWithSourceQuality(candidate Candidate, quality SourceQuality) Candidate {
	metadata := make(map[string]interface{}, len(candidate.Metadata)+1)
	for key, value := range candidate.Metadata {
		metadata[key] = value
	}
	metadata[SourceQualityMetadataKey] = quality
	candidate.Metadata = metadata
	return candidate
}

func recommendationForScore(score int) string {
	switch {
	case score >= 82:
		return SourceQualityPreferred
	case score >= 65:
		return SourceQualityAcceptable
	case score >= 45:
		return SourceQualityReview
	default:
		return SourceQualityAvoid
	}
}

func recommendationRank(recommendation string) int {
	switch recommendation {
	case SourceQualityPreferred:
		return 4
	case SourceQualityAcceptable:
		return 3
	case SourceQualityReview:
		return 2
	case SourceQualityAvoid:
		return 1
	default:
		return 0
	}
}

func confidenceForScore(score int) float64 {
	confidence := 0.35 + (float64(score) / 100 * 0.6)
	return math.Round(confidence*100) / 100
}

func containsAny(value string, needles ...string) bool {
	for _, needle := range needles {
		if strings.Contains(value, needle) {
			return true
		}
	}
	return false
}

func normalizedContains(value, needle string) bool {
	return strings.Contains(normalizedTokenText(value), normalizedTokenText(needle))
}

func sourceQualityText(candidate Candidate) string {
	fragments := []string{
		candidate.Title,
		candidate.Artist,
		candidate.Uploader,
		candidate.SourceURL,
	}
	for _, key := range sourceQualityMetadataHintKeys() {
		appendMetadataText(&fragments, candidate.Metadata[key], 0)
	}
	return strings.ToLower(strings.Join(fragments, " "))
}

func sourceQualityCandidateFeatures(candidates []Candidate) []SourceQualityCandidateFeature {
	features := make([]SourceQualityCandidateFeature, 0, len(candidates))
	for _, candidate := range candidates {
		features = append(features, SourceQualityCandidateFeature{
			CandidateID:   candidate.CandidateID,
			Provider:      candidate.Provider,
			SourceID:      candidate.SourceID,
			SourceURL:     candidate.SourceURL,
			Title:         candidate.Title,
			Artist:        candidate.Artist,
			Uploader:      candidate.Uploader,
			DurationMs:    candidate.DurationMs,
			Downloadable:  candidate.Downloadable,
			MetadataHints: sourceQualityMetadataHints(candidate.Metadata),
		})
	}
	return features
}

func sourceQualityMetadataHints(metadata map[string]interface{}) map[string]interface{} {
	hints := make(map[string]interface{})
	for _, key := range sourceQualityMetadataHintKeys() {
		if value, ok := metadata[key]; ok {
			if normalized, keep := normalizeMetadataHint(value, 0); keep {
				hints[key] = normalized
			}
		}
	}
	if len(hints) == 0 {
		return nil
	}
	return hints
}

func sourceQualityMetadataHintKeys() []string {
	return []string{
		"description",
		"snippet",
		"channel",
		"channelName",
		"channel_name",
		"creator",
		"fulltitle",
		"altTitle",
		"alt_title",
		"webpageUrl",
		"webpage_url",
		"track",
		"artist",
		"album",
		"label",
		"release_date",
		"release_year",
		"tags",
		"categories",
	}
}

func hasMetadataText(metadata map[string]interface{}, key string) bool {
	value, ok := metadata[key]
	if !ok {
		return false
	}
	var fragments []string
	appendMetadataText(&fragments, value, 0)
	return len(fragments) > 0
}

func metadataStringValue(metadata map[string]interface{}, key string) string {
	value, _ := metadata[key].(string)
	return strings.TrimSpace(value)
}

func appendMetadataText(fragments *[]string, value interface{}, depth int) {
	if value == nil || depth > 1 {
		return
	}
	switch typed := value.(type) {
	case string:
		text := strings.TrimSpace(typed)
		if text == "" {
			return
		}
		if len(text) > 512 {
			text = text[:512]
		}
		*fragments = append(*fragments, text)
	case []string:
		for _, item := range typed {
			appendMetadataText(fragments, item, depth+1)
		}
	case []interface{}:
		for _, item := range typed {
			appendMetadataText(fragments, item, depth+1)
		}
	}
}

func normalizeMetadataHint(value interface{}, depth int) (interface{}, bool) {
	if value == nil || depth > 1 {
		return nil, false
	}
	switch typed := value.(type) {
	case string:
		text := strings.TrimSpace(typed)
		if text == "" {
			return nil, false
		}
		if len(text) > 512 {
			text = text[:512]
		}
		return text, true
	case []string:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if normalized, ok := normalizeMetadataHint(item, depth+1); ok {
				out = append(out, normalized.(string))
			}
		}
		if len(out) == 0 {
			return nil, false
		}
		return out, true
	case []interface{}:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if normalized, ok := normalizeMetadataHint(item, depth+1); ok {
				if text, ok := normalized.(string); ok {
					out = append(out, text)
				}
			}
		}
		if len(out) == 0 {
			return nil, false
		}
		return out, true
	default:
		return nil, false
	}
}

func titleMatchesQuery(query string, candidate Candidate) bool {
	tokens := meaningfulQueryTokens(query)
	if len(tokens) == 0 {
		return false
	}
	haystack := normalizedTokenText(strings.Join([]string{candidate.Title, candidate.Artist, candidate.Uploader}, " "))
	matches := 0
	for _, token := range tokens {
		if strings.Contains(haystack, token) {
			matches++
		}
	}
	if len(tokens) <= 2 {
		return matches == len(tokens)
	}
	return matches >= len(tokens)-1
}

func meaningfulQueryTokens(query string) []string {
	stop := map[string]struct{}{
		"a": {}, "an": {}, "and": {}, "by": {}, "for": {}, "from": {}, "me": {}, "music": {}, "official": {}, "on": {}, "play": {}, "song": {}, "the": {}, "to": {}, "track": {}, "video": {}, "youtube": {},
	}
	parts := strings.Fields(normalizedTokenText(query))
	out := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		if len(part) < 3 {
			continue
		}
		if _, ok := stop[part]; ok {
			continue
		}
		if _, ok := seen[part]; ok {
			continue
		}
		seen[part] = struct{}{}
		out = append(out, part)
	}
	return out
}

func tokenSet(value string) map[string]struct{} {
	parts := strings.Fields(normalizedTokenText(value))
	out := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		out[part] = struct{}{}
	}
	return out
}

func hasAnyToken(tokens map[string]struct{}, values ...string) bool {
	for _, value := range values {
		if _, ok := tokens[value]; ok {
			return true
		}
	}
	return false
}

func normalizedTokenText(value string) string {
	return strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return ' '
	}, value)), " ")
}

func clampInt(value, minValue, maxValue int) int {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func uniqueStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func knownSourceQualityClassification(value string) bool {
	switch value {
	case SourceQualityOfficialAudio,
		SourceQualityTopicAudio,
		SourceQualityArtistUpload,
		SourceQualityMusicVideo,
		SourceQualityVisualizer,
		SourceQualityLive,
		SourceQualityLyricVideo,
		SourceQualityInterview,
		SourceQualityCover,
		SourceQualityRemix,
		SourceQualityAlteredAudio,
		SourceQualityDirectURL,
		SourceQualityUnknown:
		return true
	default:
		return false
	}
}

func knownSourceQualityRecommendation(value string) bool {
	switch value {
	case SourceQualityPreferred,
		SourceQualityAcceptable,
		SourceQualityReview,
		SourceQualityAvoid:
		return true
	default:
		return false
	}
}
