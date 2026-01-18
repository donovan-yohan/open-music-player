package matcher

import (
	"math"
	"regexp"
	"strings"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

// ScoreWeights defines the weights for each scoring component
type ScoreWeights struct {
	ArtistWeight   float64 // Weight for artist name match (default 0.4)
	TrackWeight    float64 // Weight for track title match (default 0.4)
	DurationWeight float64 // Weight for duration match (default 0.2)
}

// DefaultWeights returns the default scoring weights as specified in the task
var DefaultWeights = ScoreWeights{
	ArtistWeight:   0.40,
	TrackWeight:    0.40,
	DurationWeight: 0.20,
}

// MatchScore represents the similarity score between two tracks
type MatchScore struct {
	Overall        float64 // Combined weighted score (0-100)
	ArtistScore    float64 // Artist name similarity (0-100)
	TrackScore     float64 // Track title similarity (0-100)
	DurationScore  float64 // Duration match score (0-100)
	MBAPIScore     int     // Original MusicBrainz API score
	Confidence     string  // "high", "medium", "low"
	IsAutoMatchable bool   // True if score is high enough for auto-matching
}

const (
	// AutoMatchThreshold is the minimum score required for automatic MB linking
	AutoMatchThreshold = 85.0

	// DurationTolerance is the maximum difference in seconds for a perfect duration match
	DurationTolerance = 10
)

// CalculateScore computes the match score between parsed title info and a MusicBrainz result
func CalculateScore(parsed *ParsedTitle, mbArtist, mbTrack string, parsedDurationMs, mbDurationMs int, mbAPIScore int, weights ScoreWeights) *MatchScore {
	score := &MatchScore{
		MBAPIScore: mbAPIScore,
	}

	// Calculate individual component scores
	score.ArtistScore = calculateStringSimilarity(parsed.Artist, mbArtist)
	score.TrackScore = calculateStringSimilarity(parsed.Track, mbTrack)
	score.DurationScore = calculateDurationScore(parsedDurationMs, mbDurationMs)

	// Calculate weighted overall score
	score.Overall = (score.ArtistScore * weights.ArtistWeight) +
		(score.TrackScore * weights.TrackWeight) +
		(score.DurationScore * weights.DurationWeight)

	// Boost score if featuring artists match
	if len(parsed.Featuring) > 0 {
		featScore := checkFeaturingMatch(parsed.Featuring, mbArtist)
		if featScore > 0 {
			// Add a small bonus for featuring artist matches
			score.Overall = math.Min(100, score.Overall+(featScore*5))
		}
	}

	// Determine confidence level
	switch {
	case score.Overall >= AutoMatchThreshold:
		score.Confidence = "high"
		score.IsAutoMatchable = true
	case score.Overall >= 70:
		score.Confidence = "medium"
		score.IsAutoMatchable = false
	default:
		score.Confidence = "low"
		score.IsAutoMatchable = false
	}

	return score
}

// calculateStringSimilarity computes similarity between two strings using normalized Levenshtein distance
func calculateStringSimilarity(s1, s2 string) float64 {
	// Normalize strings for comparison
	n1 := normalizeString(s1)
	n2 := normalizeString(s2)

	if n1 == "" && n2 == "" {
		return 100.0
	}
	if n1 == "" || n2 == "" {
		return 0.0
	}

	// Exact match after normalization
	if n1 == n2 {
		return 100.0
	}

	// Calculate Levenshtein distance
	distance := levenshteinDistance(n1, n2)
	maxLen := max(len(n1), len(n2))

	// Convert distance to similarity percentage
	similarity := (1.0 - float64(distance)/float64(maxLen)) * 100

	return math.Max(0, similarity)
}

// normalizeString prepares a string for comparison
func normalizeString(s string) string {
	// Convert to lowercase
	s = strings.ToLower(s)

	// Remove diacritics
	t := transform.Chain(norm.NFD, runes.Remove(runes.In(unicode.Mn)), norm.NFC)
	result, _, _ := transform.String(t, s)

	// Remove common noise words and punctuation
	noiseWords := regexp.MustCompile(`(?i)\b(the|a|an|and|or|of|in|on|at|to|for)\b`)
	result = noiseWords.ReplaceAllString(result, " ")

	// Remove non-alphanumeric characters (keep spaces)
	result = regexp.MustCompile(`[^\p{L}\p{N}\s]`).ReplaceAllString(result, " ")

	// Collapse multiple spaces and trim
	result = regexp.MustCompile(`\s+`).ReplaceAllString(result, " ")
	result = strings.TrimSpace(result)

	return result
}

// levenshteinDistance calculates the edit distance between two strings
func levenshteinDistance(s1, s2 string) int {
	if len(s1) == 0 {
		return len(s2)
	}
	if len(s2) == 0 {
		return len(s1)
	}

	// Convert to runes for proper Unicode handling
	r1 := []rune(s1)
	r2 := []rune(s2)

	// Create the distance matrix
	lenS1 := len(r1)
	lenS2 := len(r2)

	// Use two rows instead of full matrix for memory efficiency
	prev := make([]int, lenS2+1)
	curr := make([]int, lenS2+1)

	// Initialize first row
	for j := 0; j <= lenS2; j++ {
		prev[j] = j
	}

	// Fill in the rest of the matrix
	for i := 1; i <= lenS1; i++ {
		curr[0] = i
		for j := 1; j <= lenS2; j++ {
			cost := 0
			if r1[i-1] != r2[j-1] {
				cost = 1
			}
			curr[j] = min(
				prev[j]+1,      // deletion
				curr[j-1]+1,    // insertion
				prev[j-1]+cost, // substitution
			)
		}
		// Swap rows
		prev, curr = curr, prev
	}

	return prev[lenS2]
}

// calculateDurationScore computes how well durations match
func calculateDurationScore(durationMs1, durationMs2 int) float64 {
	// If either duration is unknown, return a neutral score
	if durationMs1 <= 0 || durationMs2 <= 0 {
		return 50.0 // Neutral score when duration is unavailable
	}

	// Calculate difference in seconds
	diffSeconds := math.Abs(float64(durationMs1-durationMs2)) / 1000.0

	// Perfect match within tolerance
	if diffSeconds <= float64(DurationTolerance) {
		return 100.0
	}

	// Gradual falloff beyond tolerance
	// Score decreases by 5 points per second beyond tolerance, down to 0
	score := 100.0 - ((diffSeconds - float64(DurationTolerance)) * 5.0)

	return math.Max(0, score)
}

// checkFeaturingMatch checks if any featuring artists appear in the MB artist string
func checkFeaturingMatch(featuring []string, mbArtist string) float64 {
	if len(featuring) == 0 {
		return 0
	}

	mbArtistNorm := normalizeString(mbArtist)
	matchCount := 0

	for _, feat := range featuring {
		featNorm := normalizeString(feat)
		if featNorm != "" && strings.Contains(mbArtistNorm, featNorm) {
			matchCount++
		}
	}

	return float64(matchCount) / float64(len(featuring))
}

// max returns the larger of two integers
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// min returns the smallest of three integers
func min(a, b, c int) int {
	if a < b {
		if a < c {
			return a
		}
		return c
	}
	if b < c {
		return b
	}
	return c
}
