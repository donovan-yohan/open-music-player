package validators

import "testing"

func TestYouTubeValidator_CanHandle(t *testing.T) {
	v := NewYouTubeValidator()

	tests := []struct {
		name string
		url  string
		want bool
	}{
		// Should handle
		{"youtube.com", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", true},
		{"youtube.com no www", "https://youtube.com/watch?v=dQw4w9WgXcQ", true},
		{"youtu.be", "https://youtu.be/dQw4w9WgXcQ", true},
		{"music.youtube.com", "https://music.youtube.com/watch?v=dQw4w9WgXcQ", true},
		{"mobile youtube", "https://m.youtube.com/watch?v=dQw4w9WgXcQ", true},
		{"http scheme", "http://youtube.com/watch?v=dQw4w9WgXcQ", true},

		// Should not handle
		{"soundcloud", "https://soundcloud.com/artist/track", false},
		{"google", "https://www.google.com", false},
		{"empty string", "", false},
		{"invalid url", "not a url", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := v.CanHandle(tt.url); got != tt.want {
				t.Errorf("CanHandle(%q) = %v, want %v", tt.url, got, tt.want)
			}
		})
	}
}

func TestYouTubeValidator_Validate(t *testing.T) {
	v := NewYouTubeValidator()

	tests := []struct {
		name          string
		url           string
		wantValid     bool
		wantMediaID   string
		wantMediaType string
		wantCanonical string
	}{
		// Standard watch URLs
		{
			name:          "standard watch URL",
			url:           "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},
		{
			name:          "watch URL with extra params",
			url:           "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=120&list=PLtest",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},
		{
			name:          "watch URL no www",
			url:           "https://youtube.com/watch?v=dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},

		// Short URLs
		{
			name:          "youtu.be short URL",
			url:           "https://youtu.be/dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},
		{
			name:          "youtu.be with timestamp",
			url:           "https://youtu.be/dQw4w9WgXcQ?t=30",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},

		// Shorts
		{
			name:          "YouTube Shorts",
			url:           "https://www.youtube.com/shorts/dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "short",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},

		// Embed URLs
		{
			name:          "embed URL",
			url:           "https://www.youtube.com/embed/dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},
		{
			name:          "old embed URL format",
			url:           "https://www.youtube.com/v/dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},

		// Live streams
		{
			name:          "live stream URL",
			url:           "https://www.youtube.com/live/dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "live",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},

		// YouTube Music
		{
			name:          "YouTube Music",
			url:           "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
			wantValid:     true,
			wantMediaID:   "dQw4w9WgXcQ",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
		},

		// Video IDs with special characters
		{
			name:          "video ID with hyphen",
			url:           "https://www.youtube.com/watch?v=abc-def_123",
			wantValid:     true,
			wantMediaID:   "abc-def_123",
			wantMediaType: "video",
			wantCanonical: "https://www.youtube.com/watch?v=abc-def_123",
		},

		// Invalid URLs
		{
			name:      "missing video ID",
			url:       "https://www.youtube.com/watch",
			wantValid: false,
		},
		{
			name:      "empty video ID",
			url:       "https://www.youtube.com/watch?v=",
			wantValid: false,
		},
		{
			name:      "invalid video ID length",
			url:       "https://www.youtube.com/watch?v=abc",
			wantValid: false,
		},
		{
			name:      "invalid video ID characters",
			url:       "https://www.youtube.com/watch?v=abc!@#$%^&*()",
			wantValid: false,
		},
		{
			name:      "youtube homepage",
			url:       "https://www.youtube.com/",
			wantValid: false,
		},
		{
			name:      "invalid scheme",
			url:       "ftp://www.youtube.com/watch?v=dQw4w9WgXcQ",
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
				if result.Canonical != tt.wantCanonical {
					t.Errorf("Validate(%q).Canonical = %q, want %q", tt.url, result.Canonical, tt.wantCanonical)
				}
				if result.SourceType != SourceYouTube {
					t.Errorf("Validate(%q).SourceType = %q, want %q", tt.url, result.SourceType, SourceYouTube)
				}
			}
		})
	}
}

func TestYouTubeValidator_SourceType(t *testing.T) {
	v := NewYouTubeValidator()
	if v.SourceType() != SourceYouTube {
		t.Errorf("SourceType() = %q, want %q", v.SourceType(), SourceYouTube)
	}
}
