package matcher

import (
	"context"
	"fmt"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

// MatchResult represents a potential MusicBrainz match for a track
type MatchResult struct {
	MBID         string      `json:"mb_recording_id"`
	Title        string      `json:"title"`
	Artist       string      `json:"artist"`
	ArtistMBID   string      `json:"artist_mbid,omitempty"`
	Album        string      `json:"album,omitempty"`
	AlbumMBID    string      `json:"album_mbid,omitempty"`
	Duration     int         `json:"duration,omitempty"`
	Score        *MatchScore `json:"score,omitempty"`
	MatchReasons []string    `json:"match_reasons,omitempty"`
	Confidence   float64     `json:"confidence"`
	ReleaseDate  string      `json:"release_date,omitempty"`
}

// MBSuggestion represents a stored match suggestion in the database
type MBSuggestion struct {
	MBRecordingID string   `json:"mb_recording_id"`
	Title         string   `json:"title"`
	Artist        string   `json:"artist"`
	ArtistMBID    string   `json:"artist_mbid,omitempty"`
	Album         string   `json:"album,omitempty"`
	AlbumMBID     string   `json:"album_mbid,omitempty"`
	Duration      int      `json:"duration,omitempty"`
	Confidence    float64  `json:"confidence"`
	MatchReasons  []string `json:"match_reasons,omitempty"`
}

// BuildSuggestionsJSON creates the suggestion format for storage
func BuildSuggestionsJSON(suggestions []MatchResult) map[string]interface{} {
	mbSuggestions := make([]MBSuggestion, 0, len(suggestions))

	for _, s := range suggestions {
		mbSuggestions = append(mbSuggestions, MBSuggestion{
			MBRecordingID: s.MBID,
			Title:         s.Title,
			Artist:        s.Artist,
			ArtistMBID:    s.ArtistMBID,
			Album:         s.Album,
			AlbumMBID:     s.AlbumMBID,
			Duration:      s.Duration,
			Confidence:    s.Confidence,
			MatchReasons:  s.MatchReasons,
		})
	}

	return map[string]interface{}{
		"mb_suggestions": mbSuggestions,
	}
}

// MatchOutput is the result of the matching process
type MatchOutput struct {
	Verified    bool          `json:"verified"`               // True if auto-matched with high confidence
	BestMatch   *MatchResult  `json:"best_match,omitempty"`   // The best match (if any)
	Suggestions []MatchResult `json:"suggestions,omitempty"`  // Top 3 suggestions for uncertain matches
	ParsedTitle *ParsedTitle  `json:"parsed_title,omitempty"` // How the title was parsed
}

// TrackMetadata contains the input metadata for matching
type TrackMetadata struct {
	Title      string `json:"title"`      // Video/track title
	Uploader   string `json:"uploader"`   // Channel/uploader name (fallback for artist)
	DurationMs int    `json:"durationMs"` // Duration in milliseconds
}

// Matcher handles automatic MusicBrainz matching
type Matcher struct {
	mbClient *musicbrainz.Client
	weights  ScoreWeights
}

// NewMatcher creates a new Matcher instance
func NewMatcher(mbClient *musicbrainz.Client) *Matcher {
	return &Matcher{
		mbClient: mbClient,
		weights:  DefaultWeights,
	}
}

// NewMatcherWithWeights creates a Matcher with custom scoring weights
func NewMatcherWithWeights(mbClient *musicbrainz.Client, weights ScoreWeights) *Matcher {
	return &Matcher{
		mbClient: mbClient,
		weights:  weights,
	}
}

// Match attempts to find a MusicBrainz match for the given track metadata
func (m *Matcher) Match(ctx context.Context, metadata TrackMetadata) (*MatchOutput, error) {
	// Parse the title to extract artist and track info
	parsed := ParseTitle(metadata.Title)

	// If no artist was parsed from title, try using the uploader name
	if parsed.Artist == "" && metadata.Uploader != "" {
		parsed.Artist = cleanArtist(metadata.Uploader)
	}

	// Build the search query
	query := m.buildSearchQuery(parsed)
	if query == "" {
		return &MatchOutput{
			Verified:    false,
			ParsedTitle: parsed,
		}, nil
	}

	// Search MusicBrainz for matches
	searchResp, err := m.mbClient.SearchTracks(ctx, query, 10, 0, false)
	if err != nil {
		return nil, fmt.Errorf("musicbrainz search failed: %w", err)
	}

	if len(searchResp.Results) == 0 {
		return &MatchOutput{
			Verified:    false,
			ParsedTitle: parsed,
		}, nil
	}

	// Score each result
	var scoredResults []MatchResult
	for _, mbTrack := range searchResp.Results {
		score := CalculateScore(
			parsed,
			mbTrack.Artist,
			mbTrack.Title,
			metadata.DurationMs,
			mbTrack.Duration, // MB duration is in ms
			mbTrack.Score,
			m.weights,
		)

		scoredResults = append(scoredResults, MatchResult{
			MBID:         mbTrack.MBID,
			Title:        mbTrack.Title,
			Artist:       mbTrack.Artist,
			ArtistMBID:   mbTrack.ArtistMBID,
			Album:        mbTrack.Album,
			AlbumMBID:    mbTrack.AlbumMBID,
			Duration:     mbTrack.Duration,
			Score:        score,
			MatchReasons: score.MatchReasons,
			Confidence:   score.Overall / 100.0,
			ReleaseDate:  mbTrack.ReleaseDate,
		})
	}

	// Sort by overall score (descending)
	sortByScore(scoredResults)

	output := &MatchOutput{
		ParsedTitle: parsed,
	}

	// Check if the best match is good enough for auto-matching
	if len(scoredResults) > 0 {
		best := scoredResults[0]

		if best.Score.IsAutoMatchable {
			// High confidence match - auto-verify
			output.Verified = true
			output.BestMatch = &best
		} else {
			// Uncertain - store top 3 as suggestions
			output.Verified = false
			output.BestMatch = &best

			maxSuggestions := 3
			if len(scoredResults) < maxSuggestions {
				maxSuggestions = len(scoredResults)
			}
			output.Suggestions = scoredResults[:maxSuggestions]
		}
	}

	return output, nil
}

// MatchNonMusic checks if the content appears to be non-music
func (m *Matcher) MatchNonMusic(metadata TrackMetadata) bool {
	title := normalizeString(metadata.Title)

	// Common non-music patterns
	nonMusicPatterns := []string{
		"podcast",
		"interview",
		"tutorial",
		"review",
		"unboxing",
		"vlog",
		"gameplay",
		"lets play",
		"stream",
		"reaction",
		"commentary",
		"news",
		"lecture",
		"audiobook",
		"asmr",
	}

	for _, pattern := range nonMusicPatterns {
		if containsWord(title, pattern) {
			return true
		}
	}

	return false
}

// buildSearchQuery constructs the MusicBrainz search query
func (m *Matcher) buildSearchQuery(parsed *ParsedTitle) string {
	if parsed.Track == "" {
		return ""
	}

	var query string

	if parsed.Artist != "" {
		// Search with both artist and track
		query = fmt.Sprintf("recording:\"%s\" AND artist:\"%s\"", parsed.Track, parsed.Artist)
	} else {
		// Search with just track title
		query = fmt.Sprintf("recording:\"%s\"", parsed.Track)
	}

	return query
}

// sortByScore sorts results by overall score in descending order
func sortByScore(results []MatchResult) {
	for i := 0; i < len(results)-1; i++ {
		for j := i + 1; j < len(results); j++ {
			if results[j].Score.Overall > results[i].Score.Overall {
				results[i], results[j] = results[j], results[i]
			}
		}
	}
}

// containsWord checks if a string contains a word (not just substring)
func containsWord(s, word string) bool {
	// Simple contains check for now - can be enhanced with word boundary checks
	return len(s) > 0 && len(word) > 0 &&
		(s == word ||
		 len(s) > len(word) &&
		 (s[:len(word)+1] == word+" " ||
		  s[len(s)-len(word)-1:] == " "+word ||
		  contains(s, " "+word+" ")))
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && findSubstring(s, substr) >= 0
}

func findSubstring(s, substr string) int {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}
