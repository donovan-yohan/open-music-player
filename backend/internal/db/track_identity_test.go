package db

import (
	"testing"
)

func TestNormalizeString(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"empty string", "", ""},
		{"lowercase", "HELLO WORLD", "hello world"},
		{"trim whitespace", "  hello  ", "hello"},
		{"collapse spaces", "hello   world", "hello world"},
		{"remove The prefix", "The Beatles", "beatles"},
		{"remove A prefix", "A Tribe Called Quest", "tribe called quest"},
		{"transliterate accents", "Café Müller", "cafe muller"},
		{"complex normalization", "  The Beastie Boys  ", "beastie boys"},
		{"accented artist", "Björk", "bjork"},
		{"special characters preserved", "AC/DC", "ac/dc"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := NormalizeString(tt.input)
			if result != tt.expected {
				t.Errorf("NormalizeString(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestExtractVersion(t *testing.T) {
	tests := []struct {
		name            string
		title           string
		expectedClean   string
		expectedVersion string
	}{
		{"no version", "Bohemian Rhapsody", "Bohemian Rhapsody", ""},
		{"radio edit parens", "Song Title (Radio Edit)", "Song Title", "radio edit"},
		{"extended mix parens", "Song Title (Extended Mix)", "Song Title", "extended mix"},
		{"remix parens", "Song Title (Remix)", "Song Title", "remix"},
		{"artist remix", "Song Title (David Guetta Remix)", "Song Title", "remix"},
		{"live parens", "Song Title (Live)", "Song Title", "live"},
		{"live at venue", "Song Title (Live at Wembley)", "Song Title", "live"},
		{"acoustic", "Song Title (Acoustic)", "Song Title", "acoustic"},
		{"remastered", "Song Title (Remastered)", "Song Title", "remaster"},
		{"year remastered", "Song Title (2020 Remastered)", "Song Title", "remaster"},
		{"original mix empty", "Song Title (Original Mix)", "Song Title", ""},
		{"brackets radio edit", "Song Title [Radio Edit]", "Song Title", "radio edit"},
		{"brackets live", "Song Title [Live]", "Song Title", "live"},
		{"dash remix", "Song Title - Remix", "Song Title", "remix"},
		{"dash live", "Song Title - Live", "Song Title", "live"},
		{"featuring ignored", "Song Title (feat. Artist)", "Song Title", ""},
		{"explicit ignored", "Song Title (Explicit)", "Song Title", ""},
		{"instrumental", "Song Title (Instrumental)", "Song Title", "instrumental"},
		{"club mix", "Song Title (Club Mix)", "Song Title", "club mix"},
		{"empty title", "", "", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ExtractVersion(tt.title)
			if result.CleanTitle != tt.expectedClean {
				t.Errorf("ExtractVersion(%q).CleanTitle = %q, want %q", tt.title, result.CleanTitle, tt.expectedClean)
			}
			if result.Version != tt.expectedVersion {
				t.Errorf("ExtractVersion(%q).Version = %q, want %q", tt.title, result.Version, tt.expectedVersion)
			}
		})
	}
}

func TestDurationBucket(t *testing.T) {
	tests := []struct {
		name       string
		durationMs int
		bucketSize int
		expected   int
	}{
		{"zero duration", 0, 5000, 0},
		{"zero bucket", 5000, 0, 0},
		{"exact bucket", 10000, 5000, 10000},
		{"round down", 12000, 5000, 10000},
		{"round down close", 14999, 5000, 10000},
		{"next bucket", 15000, 5000, 15000},
		{"typical song 3:30", 210000, 5000, 210000},
		{"typical song 3:32", 212000, 5000, 210000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := DurationBucket(tt.durationMs, tt.bucketSize)
			if result != tt.expected {
				t.Errorf("DurationBucket(%d, %d) = %d, want %d", tt.durationMs, tt.bucketSize, result, tt.expected)
			}
		})
	}
}

func TestCalculateIdentityHash(t *testing.T) {
	tests := []struct {
		name        string
		artist1     string
		title1      string
		album1      string
		durationMs1 int
		version1    string
		artist2     string
		title2      string
		album2      string
		durationMs2 int
		version2    string
		shouldMatch bool
	}{
		{
			name:        "identical tracks",
			artist1:     "The Beatles", title1: "Hey Jude", album1: "Past Masters", durationMs1: 431000, version1: "",
			artist2:     "The Beatles", title2: "Hey Jude", album2: "Past Masters", durationMs2: 431000, version2: "",
			shouldMatch: true,
		},
		{
			name:        "case insensitive",
			artist1:     "THE BEATLES", title1: "HEY JUDE", album1: "PAST MASTERS", durationMs1: 431000, version1: "",
			artist2:     "the beatles", title2: "hey jude", album2: "past masters", durationMs2: 431000, version2: "",
			shouldMatch: true,
		},
		{
			name:        "The prefix ignored",
			artist1:     "The Beatles", title1: "Hey Jude", album1: "Past Masters", durationMs1: 431000, version1: "",
			artist2:     "Beatles", title2: "Hey Jude", album2: "Past Masters", durationMs2: 431000, version2: "",
			shouldMatch: true,
		},
		{
			name:        "duration within bucket",
			artist1:     "Artist", title1: "Song", album1: "Album", durationMs1: 210000, version1: "",
			artist2:     "Artist", title2: "Song", album2: "Album", durationMs2: 212000, version2: "",
			shouldMatch: true,
		},
		{
			name:        "duration different bucket",
			artist1:     "Artist", title1: "Song", album1: "Album", durationMs1: 210000, version1: "",
			artist2:     "Artist", title2: "Song", album2: "Album", durationMs2: 220000, version2: "",
			shouldMatch: false,
		},
		{
			name:        "different version remix",
			artist1:     "Artist", title1: "Song", album1: "Album", durationMs1: 210000, version1: "",
			artist2:     "Artist", title2: "Song", album2: "Album", durationMs2: 210000, version2: "remix",
			shouldMatch: false,
		},
		{
			name:        "different version radio edit",
			artist1:     "Artist", title1: "Song", album1: "Album", durationMs1: 210000, version1: "",
			artist2:     "Artist", title2: "Song", album2: "Album", durationMs2: 210000, version2: "radio edit",
			shouldMatch: false,
		},
		{
			name:        "accents normalized",
			artist1:     "Björk", title1: "Jóga", album1: "Homogenic", durationMs1: 300000, version1: "",
			artist2:     "Bjork", title2: "Joga", album2: "Homogenic", durationMs2: 300000, version2: "",
			shouldMatch: true,
		},
		{
			name:        "different artist",
			artist1:     "Artist A", title1: "Song", album1: "Album", durationMs1: 210000, version1: "",
			artist2:     "Artist B", title2: "Song", album2: "Album", durationMs2: 210000, version2: "",
			shouldMatch: false,
		},
		{
			name:        "different title",
			artist1:     "Artist", title1: "Song A", album1: "Album", durationMs1: 210000, version1: "",
			artist2:     "Artist", title2: "Song B", album2: "Album", durationMs2: 210000, version2: "",
			shouldMatch: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hash1 := CalculateIdentityHash(tt.artist1, tt.title1, tt.album1, tt.durationMs1, tt.version1)
			hash2 := CalculateIdentityHash(tt.artist2, tt.title2, tt.album2, tt.durationMs2, tt.version2)

			if len(hash1) != 16 {
				t.Errorf("hash1 length = %d, want 16", len(hash1))
			}
			if len(hash2) != 16 {
				t.Errorf("hash2 length = %d, want 16", len(hash2))
			}

			if tt.shouldMatch && hash1 != hash2 {
				t.Errorf("hashes should match but don't: %q != %q", hash1, hash2)
			}
			if !tt.shouldMatch && hash1 == hash2 {
				t.Errorf("hashes should differ but match: %q == %q", hash1, hash2)
			}
		})
	}
}

func TestParseTrackMetadata(t *testing.T) {
	tests := []struct {
		name            string
		artist          string
		title           string
		album           string
		durationMs      int
		expectedTitle   string
		expectedVersion string
	}{
		{
			name:            "simple track",
			artist:          "Artist", title: "Song Title", album: "Album", durationMs: 210000,
			expectedTitle: "Song Title", expectedVersion: "",
		},
		{
			name:            "track with remix",
			artist:          "Artist", title: "Song Title (Remix)", album: "Album", durationMs: 210000,
			expectedTitle: "Song Title", expectedVersion: "remix",
		},
		{
			name:            "track with radio edit",
			artist:          "Artist", title: "Song Title (Radio Edit)", album: "Single", durationMs: 180000,
			expectedTitle: "Song Title", expectedVersion: "radio edit",
		},
		{
			name:            "track with live",
			artist:          "Artist", title: "Song Title [Live]", album: "Live Album", durationMs: 300000,
			expectedTitle: "Song Title", expectedVersion: "live",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ParseTrackMetadata(tt.artist, tt.title, tt.album, tt.durationMs)
			if result.Title != tt.expectedTitle {
				t.Errorf("ParseTrackMetadata().Title = %q, want %q", result.Title, tt.expectedTitle)
			}
			if result.Version != tt.expectedVersion {
				t.Errorf("ParseTrackMetadata().Version = %q, want %q", result.Version, tt.expectedVersion)
			}
			if result.Artist != tt.artist {
				t.Errorf("ParseTrackMetadata().Artist = %q, want %q", result.Artist, tt.artist)
			}
			if result.Album != tt.album {
				t.Errorf("ParseTrackMetadata().Album = %q, want %q", result.Album, tt.album)
			}
			if result.DurationMs != tt.durationMs {
				t.Errorf("ParseTrackMetadata().DurationMs = %d, want %d", result.DurationMs, tt.durationMs)
			}
		})
	}
}

func TestDeduplicationScenarios(t *testing.T) {
	// Test that same song from different sources (YT, SC) would deduplicate
	t.Run("same song different sources", func(t *testing.T) {
		// Simulating YouTube metadata
		ytHash := CalculateIdentityHash("Daft Punk", "Get Lucky", "Random Access Memories", 367000, "")
		// Simulating SoundCloud metadata (slightly different duration due to encoding, within 5s bucket)
		scHash := CalculateIdentityHash("Daft Punk", "Get Lucky", "Random Access Memories", 368000, "")

		if ytHash != scHash {
			t.Errorf("same song from YT and SC should deduplicate, got %q != %q", ytHash, scHash)
		}
	})

	t.Run("remix should not deduplicate with original", func(t *testing.T) {
		original := CalculateIdentityHash("Artist", "Song", "Album", 210000, "")
		remix := CalculateIdentityHash("Artist", "Song", "Album", 300000, "remix")

		if original == remix {
			t.Error("remix should have different hash from original")
		}
	})

	t.Run("radio edit should not deduplicate with album version", func(t *testing.T) {
		albumVersion := CalculateIdentityHash("Artist", "Song", "Album", 300000, "")
		radioEdit := CalculateIdentityHash("Artist", "Song", "Single", 210000, "radio edit")

		if albumVersion == radioEdit {
			t.Error("radio edit should have different hash from album version")
		}
	})
}
