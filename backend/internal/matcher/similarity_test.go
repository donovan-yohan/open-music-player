package matcher

import (
	"math"
	"testing"
)

func TestLevenshteinDistance(t *testing.T) {
	tests := []struct {
		s1       string
		s2       string
		expected int
	}{
		{"", "", 0},
		{"", "abc", 3},
		{"abc", "", 3},
		{"abc", "abc", 0},
		{"abc", "abd", 1},
		{"kitten", "sitting", 3},
		{"saturday", "sunday", 3},
	}

	for _, tt := range tests {
		t.Run(tt.s1+"_"+tt.s2, func(t *testing.T) {
			result := levenshteinDistance(tt.s1, tt.s2)
			if result != tt.expected {
				t.Errorf("levenshteinDistance(%q, %q) = %d, want %d", tt.s1, tt.s2, result, tt.expected)
			}
		})
	}
}

func TestCalculateStringSimilarity(t *testing.T) {
	tests := []struct {
		s1         string
		s2         string
		minPercent float64
	}{
		{"Radiohead", "Radiohead", 99.0},
		{"radiohead", "Radiohead", 99.0}, // case insensitive
		{"The Beatles", "Beatles", 80.0},
		{"completely different", "nothing alike", 0.0},
		{"", "", 99.0},
	}

	for _, tt := range tests {
		t.Run(tt.s1+"_"+tt.s2, func(t *testing.T) {
			result := calculateStringSimilarity(tt.s1, tt.s2)
			if result < tt.minPercent {
				t.Errorf("calculateStringSimilarity(%q, %q) = %.2f, want >= %.2f", tt.s1, tt.s2, result, tt.minPercent)
			}
		})
	}
}

func TestNormalizeString(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"The Beatles", "beatles"},
		{"RADIOHEAD", "radiohead"},
		{"Sigur Rós", "sigur ros"},
		{"The, A, An", ""},
		{"Hello! World?", "hello world"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := normalizeString(tt.input)
			if result != tt.expected {
				t.Errorf("normalizeString(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestCalculateDurationScore(t *testing.T) {
	tests := []struct {
		duration1 int
		duration2 int
		minScore  float64
		maxScore  float64
	}{
		{180000, 180000, 99.0, 100.0}, // exact match
		{180000, 185000, 99.0, 100.0}, // 5 seconds difference (within tolerance)
		{180000, 190000, 99.0, 100.0}, // 10 seconds difference (at tolerance limit)
		{180000, 200000, 40.0, 60.0},  // 20 seconds difference
		{180000, 0, 40.0, 60.0},       // missing duration
		{0, 180000, 40.0, 60.0},       // missing duration
	}

	for _, tt := range tests {
		t.Run("", func(t *testing.T) {
			result := calculateDurationScore(tt.duration1, tt.duration2)
			if result < tt.minScore || result > tt.maxScore {
				t.Errorf("calculateDurationScore(%d, %d) = %.2f, want between %.2f and %.2f",
					tt.duration1, tt.duration2, result, tt.minScore, tt.maxScore)
			}
		})
	}
}

func TestCalculateScore(t *testing.T) {
	weights := DefaultWeights

	tests := []struct {
		name       string
		parsed     *ParsedTitle
		mbArtist   string
		mbTrack    string
		parsedDur  int
		mbDur      int
		mbAPIScore int
		expectHigh bool
		minOverall float64
	}{
		{
			name:       "exact match",
			parsed:     &ParsedTitle{Artist: "Radiohead", Track: "Creep"},
			mbArtist:   "Radiohead",
			mbTrack:    "Creep",
			parsedDur:  239000,
			mbDur:      239000,
			mbAPIScore: 100,
			expectHigh: true,
			minOverall: 95.0,
		},
		{
			name:       "case difference",
			parsed:     &ParsedTitle{Artist: "radiohead", Track: "creep"},
			mbArtist:   "Radiohead",
			mbTrack:    "Creep",
			parsedDur:  239000,
			mbDur:      239000,
			mbAPIScore: 100,
			expectHigh: true,
			minOverall: 95.0,
		},
		{
			name:       "slight variation",
			parsed:     &ParsedTitle{Artist: "The Beatles", Track: "Let It Be"},
			mbArtist:   "Beatles",
			mbTrack:    "Let It Be",
			parsedDur:  243000,
			mbDur:      243000,
			mbAPIScore: 95,
			expectHigh: true,
			minOverall: 85.0,
		},
		{
			name:       "completely different",
			parsed:     &ParsedTitle{Artist: "Artist A", Track: "Song X"},
			mbArtist:   "Artist B",
			mbTrack:    "Song Y",
			parsedDur:  180000,
			mbDur:      300000,
			mbAPIScore: 50,
			expectHigh: false,
			minOverall: 0.0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := CalculateScore(tt.parsed, tt.mbArtist, tt.mbTrack, tt.parsedDur, tt.mbDur, tt.mbAPIScore, weights)

			if result.Overall < tt.minOverall {
				t.Errorf("Overall score = %.2f, want >= %.2f", result.Overall, tt.minOverall)
			}

			if tt.expectHigh && !result.IsAutoMatchable {
				t.Errorf("Expected auto-matchable (high confidence), but got %s", result.Confidence)
			}

			if !tt.expectHigh && result.IsAutoMatchable {
				t.Errorf("Expected not auto-matchable, but got %s confidence", result.Confidence)
			}

			// Verify match reasons for high confidence
			if tt.expectHigh && len(result.MatchReasons) == 0 {
				t.Errorf("Expected match reasons for high confidence match, but got none")
			}
		})
	}
}

func TestMatchReasons(t *testing.T) {
	weights := DefaultWeights

	tests := []struct {
		name            string
		parsed          *ParsedTitle
		mbArtist        string
		mbTrack         string
		parsedDur       int
		mbDur           int
		expectedReasons []string
	}{
		{
			name:            "title and artist match",
			parsed:          &ParsedTitle{Artist: "Radiohead", Track: "Creep"},
			mbArtist:        "Radiohead",
			mbTrack:         "Creep",
			parsedDur:       0,
			mbDur:           0,
			expectedReasons: []string{"title_match", "artist_match"},
		},
		{
			name:            "title match only",
			parsed:          &ParsedTitle{Artist: "Unknown", Track: "Creep"},
			mbArtist:        "Radiohead",
			mbTrack:         "Creep",
			parsedDur:       0,
			mbDur:           0,
			expectedReasons: []string{"title_match"},
		},
		{
			name:            "duration match",
			parsed:          &ParsedTitle{Artist: "A", Track: "B"},
			mbArtist:        "C",
			mbTrack:         "D",
			parsedDur:       180000,
			mbDur:           180000,
			expectedReasons: []string{"duration_match"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := CalculateScore(tt.parsed, tt.mbArtist, tt.mbTrack, tt.parsedDur, tt.mbDur, 0, weights)

			for _, expected := range tt.expectedReasons {
				found := false
				for _, actual := range result.MatchReasons {
					if actual == expected {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("Expected reason %q not found in %v", expected, result.MatchReasons)
				}
			}
		})
	}
}

func TestScoreWeights(t *testing.T) {
	// Verify default weights sum to 1.0
	total := DefaultWeights.ArtistWeight + DefaultWeights.TrackWeight + DefaultWeights.DurationWeight
	if math.Abs(total-1.0) > 0.001 {
		t.Errorf("Default weights sum to %.3f, want 1.0", total)
	}

	// Verify weight distribution
	if DefaultWeights.ArtistWeight != 0.40 {
		t.Errorf("ArtistWeight = %.2f, want 0.40", DefaultWeights.ArtistWeight)
	}
	if DefaultWeights.TrackWeight != 0.40 {
		t.Errorf("TrackWeight = %.2f, want 0.40", DefaultWeights.TrackWeight)
	}
	if DefaultWeights.DurationWeight != 0.20 {
		t.Errorf("DurationWeight = %.2f, want 0.20", DefaultWeights.DurationWeight)
	}
}

func TestAutoMatchThreshold(t *testing.T) {
	if AutoMatchThreshold != 85.0 {
		t.Errorf("AutoMatchThreshold = %.2f, want 85.0", AutoMatchThreshold)
	}
}
