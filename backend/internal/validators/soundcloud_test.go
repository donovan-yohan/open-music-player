package validators

import "testing"

func TestSoundCloudValidator_CanHandle(t *testing.T) {
	v := NewSoundCloudValidator()

	tests := []struct {
		name string
		url  string
		want bool
	}{
		{"soundcloud.com", "https://soundcloud.com/artist/track", true},
		{"www.soundcloud.com", "https://www.soundcloud.com/artist/track", true},
		{"m.soundcloud.com", "https://m.soundcloud.com/artist/track", true},
		{"on.soundcloud.com", "https://on.soundcloud.com/abc123", true},
		{"api.soundcloud.com", "https://api.soundcloud.com/tracks/123", true},
		{"w.soundcloud.com", "https://w.soundcloud.com/player/?url=test", true},
		{"youtube", "https://www.youtube.com/watch?v=test", false},
		{"google", "https://www.google.com", false},
		{"empty", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := v.CanHandle(tt.url); got != tt.want {
				t.Errorf("CanHandle(%q) = %v, want %v", tt.url, got, tt.want)
			}
		})
	}
}

func TestSoundCloudValidator_Validate(t *testing.T) {
	v := NewSoundCloudValidator()

	tests := []struct {
		name          string
		url           string
		wantValid     bool
		wantMediaID   string
		wantMediaType string
	}{
		// Track URLs
		{
			name:          "track URL",
			url:           "https://soundcloud.com/artist-name/track-name",
			wantValid:     true,
			wantMediaID:   "artist-name/track-name",
			wantMediaType: "track",
		},
		{
			name:          "track URL with www",
			url:           "https://www.soundcloud.com/artist-name/track-name",
			wantValid:     true,
			wantMediaID:   "artist-name/track-name",
			wantMediaType: "track",
		},

		// Artist URLs
		{
			name:          "artist URL",
			url:           "https://soundcloud.com/artist-name",
			wantValid:     true,
			wantMediaID:   "artist-name",
			wantMediaType: "artist",
		},
		{
			name:          "artist likes page",
			url:           "https://soundcloud.com/artist-name/likes",
			wantValid:     true,
			wantMediaID:   "artist-name",
			wantMediaType: "artist",
		},
		{
			name:          "artist tracks page",
			url:           "https://soundcloud.com/artist-name/tracks",
			wantValid:     true,
			wantMediaID:   "artist-name",
			wantMediaType: "artist",
		},

		// Playlist URLs
		{
			name:          "playlist URL",
			url:           "https://soundcloud.com/artist-name/sets/playlist-name",
			wantValid:     true,
			wantMediaID:   "artist-name/sets/playlist-name",
			wantMediaType: "playlist",
		},

		// Short URLs
		{
			name:          "short URL",
			url:           "https://on.soundcloud.com/abc123xyz",
			wantValid:     true,
			wantMediaID:   "abc123xyz",
			wantMediaType: "short_url",
		},

		// API URLs
		{
			name:          "API track URL",
			url:           "https://api.soundcloud.com/tracks/123456789",
			wantValid:     true,
			wantMediaID:   "123456789",
			wantMediaType: "track",
		},
		{
			name:          "API playlist URL",
			url:           "https://api.soundcloud.com/playlists/123456789",
			wantValid:     true,
			wantMediaID:   "123456789",
			wantMediaType: "playlist",
		},
		{
			name:          "API user URL",
			url:           "https://api.soundcloud.com/users/123456789",
			wantValid:     true,
			wantMediaID:   "123456789",
			wantMediaType: "artist",
		},

		// Widget URLs
		{
			name:          "widget URL with API track",
			url:           "https://w.soundcloud.com/player/?url=https://api.soundcloud.com/tracks/123456789",
			wantValid:     true,
			wantMediaID:   "123456789",
			wantMediaType: "track",
		},

		// Invalid URLs
		{
			name:      "empty path",
			url:       "https://soundcloud.com/",
			wantValid: false,
		},
		{
			name:      "reserved path discover",
			url:       "https://soundcloud.com/discover",
			wantValid: false,
		},
		{
			name:      "reserved path stream",
			url:       "https://soundcloud.com/stream",
			wantValid: false,
		},
		{
			name:      "reserved path search",
			url:       "https://soundcloud.com/search",
			wantValid: false,
		},
		{
			name:      "invalid scheme",
			url:       "ftp://soundcloud.com/artist/track",
			wantValid: false,
		},
		{
			name:      "playlist missing name",
			url:       "https://soundcloud.com/artist-name/sets",
			wantValid: false,
		},
		{
			name:      "short URL too short",
			url:       "https://on.soundcloud.com/abc",
			wantValid: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := v.Validate(tt.url)

			if result.Valid != tt.wantValid {
				t.Errorf("Validate(%q).Valid = %v, want %v (error: %s)", tt.url, result.Valid, tt.wantValid, result.Error)
			}

			if tt.wantValid {
				if result.MediaID != tt.wantMediaID {
					t.Errorf("Validate(%q).MediaID = %q, want %q", tt.url, result.MediaID, tt.wantMediaID)
				}
				if result.MediaType != tt.wantMediaType {
					t.Errorf("Validate(%q).MediaType = %q, want %q", tt.url, result.MediaType, tt.wantMediaType)
				}
				if result.SourceType != SourceSoundCloud {
					t.Errorf("Validate(%q).SourceType = %q, want %q", tt.url, result.SourceType, SourceSoundCloud)
				}
			}
		})
	}
}

func TestSoundCloudValidator_SourceType(t *testing.T) {
	v := NewSoundCloudValidator()
	if v.SourceType() != SourceSoundCloud {
		t.Errorf("SourceType() = %q, want %q", v.SourceType(), SourceSoundCloud)
	}
}
