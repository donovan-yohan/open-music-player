package matcher

import (
	"testing"
)

func TestParseTitle(t *testing.T) {
	tests := []struct {
		name           string
		input          string
		expectedArtist string
		expectedTrack  string
		expectedFeat   []string
	}{
		{
			name:           "standard artist - track format",
			input:          "Radiohead - Creep",
			expectedArtist: "Radiohead",
			expectedTrack:  "Creep",
		},
		{
			name:           "artist - track with official video suffix",
			input:          "Daft Punk - Get Lucky (Official Video)",
			expectedArtist: "Daft Punk",
			expectedTrack:  "Get Lucky",
		},
		{
			name:           "artist - track with lyrics suffix",
			input:          "Ed Sheeran - Shape of You (Lyrics)",
			expectedArtist: "Ed Sheeran",
			expectedTrack:  "Shape of You",
		},
		{
			name:           "featuring in parentheses",
			input:          "Calvin Harris - This Is What You Came For (feat. Rihanna)",
			expectedArtist: "Calvin Harris",
			expectedTrack:  "This Is What You Came For",
			expectedFeat:   []string{"Rihanna"},
		},
		{
			name:           "featuring with ft. before dash",
			input:          "David Guetta - Titanium ft. Sia",
			expectedArtist: "David Guetta",
			expectedTrack:  "Titanium",
			expectedFeat:   []string{"Sia"},
		},
		{
			name:           "track by artist format",
			input:          "Bohemian Rhapsody by Queen",
			expectedArtist: "Queen",
			expectedTrack:  "Bohemian Rhapsody",
		},
		{
			name:           "quoted track title",
			input:          "Michael Jackson \"Billie Jean\"",
			expectedArtist: "Michael Jackson",
			expectedTrack:  "Billie Jean",
		},
		{
			name:           "standard with dash",
			input:          "Coldplay - Yellow",
			expectedArtist: "Coldplay",
			expectedTrack:  "Yellow",
		},
		{
			name:           "multiple featuring artists",
			input:          "DJ Khaled - I'm The One (feat. Justin Bieber, Quavo & Chance the Rapper)",
			expectedArtist: "DJ Khaled",
			expectedTrack:  "I'm The One",
			expectedFeat:   []string{"Justin Bieber", "Quavo", "Chance the Rapper"},
		},
		{
			name:           "remix in brackets",
			input:          "The Weeknd - Blinding Lights (Chromatics Remix)",
			expectedArtist: "The Weeknd",
			expectedTrack:  "Blinding Lights",
		},
		{
			name:           "remastered version",
			input:          "Led Zeppelin - Stairway to Heaven (Remastered)",
			expectedArtist: "Led Zeppelin",
			expectedTrack:  "Stairway to Heaven",
		},
		{
			name:           "official video suffix",
			input:          "Adele - Hello (Official Video)",
			expectedArtist: "Adele",
			expectedTrack:  "Hello",
		},
		{
			name:           "no artist - track only",
			input:          "Symphony No. 5",
			expectedArtist: "",
			expectedTrack:  "Symphony No. 5",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ParseTitle(tt.input)

			if result.Artist != tt.expectedArtist {
				t.Errorf("Artist = %q, want %q", result.Artist, tt.expectedArtist)
			}

			if result.Track != tt.expectedTrack {
				t.Errorf("Track = %q, want %q", result.Track, tt.expectedTrack)
			}

			if len(tt.expectedFeat) > 0 {
				if len(result.Featuring) != len(tt.expectedFeat) {
					t.Errorf("Featuring count = %d, want %d", len(result.Featuring), len(tt.expectedFeat))
				} else {
					for i, feat := range tt.expectedFeat {
						if result.Featuring[i] != feat {
							t.Errorf("Featuring[%d] = %q, want %q", i, result.Featuring[i], feat)
						}
					}
				}
			}
		})
	}
}

func TestCleanTitle(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"Song (Official Video)", "Song"},
		{"Song [Official Audio]", "Song"},
		{"Song (Lyric Video)", "Song"},
		{"Song HD", "Song"},
		{"Song (4K)", "Song"},
		{"Song (M/V)", "Song"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := cleanTitle(tt.input)
			if result != tt.expected {
				t.Errorf("cleanTitle(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestCleanArtist(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"Artist - Topic", "Artist"},
		{"ArtistVEVO", "Artist"},
		{"Artist", "Artist"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := cleanArtist(tt.input)
			if result != tt.expected {
				t.Errorf("cleanArtist(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestLooksLikeArtistName(t *testing.T) {
	tests := []struct {
		input    string
		expected bool
	}{
		{"Radiohead", true},
		{"The Beatles", true},
		{"Song (Remix)", false},
		{"Live at Madison Square Garden", false},
		{"Acoustic Version", false},
		{"A very long string that is definitely not an artist name because it is way too long", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := looksLikeArtistName(tt.input)
			if result != tt.expected {
				t.Errorf("looksLikeArtistName(%q) = %v, want %v", tt.input, result, tt.expected)
			}
		})
	}
}
