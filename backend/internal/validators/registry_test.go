package validators

import "testing"

func TestRegistry_Validate(t *testing.T) {
	r := DefaultRegistry()

	tests := []struct {
		name           string
		url            string
		wantValid      bool
		wantSourceType SourceType
	}{
		{
			name:           "YouTube URL",
			url:            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
			wantValid:      true,
			wantSourceType: SourceYouTube,
		},
		{
			name:           "SoundCloud URL",
			url:            "https://soundcloud.com/artist/track",
			wantValid:      true,
			wantSourceType: SourceSoundCloud,
		},
		{
			name:           "unsupported URL",
			url:            "https://spotify.com/track/123",
			wantValid:      false,
			wantSourceType: SourceUnknown,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := r.Validate(tt.url)

			if result.Valid != tt.wantValid {
				t.Errorf("Validate(%q).Valid = %v, want %v", tt.url, result.Valid, tt.wantValid)
			}
			if result.SourceType != tt.wantSourceType {
				t.Errorf("Validate(%q).SourceType = %q, want %q", tt.url, result.SourceType, tt.wantSourceType)
			}
		})
	}
}

func TestRegistry_GetSupportedSources(t *testing.T) {
	r := DefaultRegistry()
	sources := r.GetSupportedSources()

	if len(sources) != 2 {
		t.Errorf("GetSupportedSources() returned %d sources, want 2", len(sources))
	}

	hasYouTube := false
	hasSoundCloud := false
	for _, s := range sources {
		if s == SourceYouTube {
			hasYouTube = true
		}
		if s == SourceSoundCloud {
			hasSoundCloud = true
		}
	}

	if !hasYouTube {
		t.Error("GetSupportedSources() missing YouTube")
	}
	if !hasSoundCloud {
		t.Error("GetSupportedSources() missing SoundCloud")
	}
}

func TestNewRegistry(t *testing.T) {
	r := NewRegistry()
	sources := r.GetSupportedSources()

	if len(sources) != 0 {
		t.Errorf("NewRegistry() should have 0 sources, got %d", len(sources))
	}
}

func TestRegistry_Register(t *testing.T) {
	r := NewRegistry()
	r.Register(NewYouTubeValidator())

	sources := r.GetSupportedSources()
	if len(sources) != 1 {
		t.Errorf("After Register(), should have 1 source, got %d", len(sources))
	}
	if sources[0] != SourceYouTube {
		t.Errorf("Registered source should be YouTube, got %q", sources[0])
	}
}
