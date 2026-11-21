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

func TestLoadListenBrainzPopularityTokenIsIndependentOfMix(t *testing.T) {
	const fixtureToken = "listenbrainz-popularity-config-fixture"
	for _, tc := range []struct {
		name, token, wantToken string
		mixEnabled             bool
	}{
		{name: "empty_default"},
		{name: "blank_with_mix_enabled", token: " 	 ", mixEnabled: true},
		{name: "configured_without_mix", token: " " + fixtureToken + "\n", wantToken: fixtureToken},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("LISTENBRAINZ_POPULARITY_TOKEN", tc.token)
			t.Setenv("ENABLE_LISTENBRAINZ_MIX", "")
			if tc.mixEnabled {
				t.Setenv("ENABLE_LISTENBRAINZ_MIX", "true")
			}
			cfg := Load()
			if cfg.ListenBrainzPopularityToken != tc.wantToken || cfg.EnableListenBrainzMix != tc.mixEnabled {
				t.Fatal("popularity token did not load independently of the ListenBrainz mix flag")
			}
		})
	}
}
