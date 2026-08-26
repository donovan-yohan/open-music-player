package config

import (
	"testing"
)

// TestLoadListenBrainzMixDisabledByDefault pins the issue-#392 flag default:
// without ENABLE_LISTENBRAINZ_MIX in the environment the expansion route must
// stay off, mirroring the ENABLE_PLAYLIST_MIX precedent.
func TestLoadListenBrainzMixDisabledByDefault(t *testing.T) {
	t.Setenv("ENABLE_LISTENBRAINZ_MIX", "")

	cfg := Load()
	if cfg.EnableListenBrainzMix {
		t.Fatal("EnableListenBrainzMix = true with no env var, want default false")
	}
}

func TestLoadListenBrainzMixEnabledWhenSet(t *testing.T) {
	t.Setenv("ENABLE_LISTENBRAINZ_MIX", "true")

	cfg := Load()
	if !cfg.EnableListenBrainzMix {
		t.Fatal("EnableListenBrainzMix = false with ENABLE_LISTENBRAINZ_MIX=true, want true")
	}
}
