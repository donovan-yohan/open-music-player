package config

import "testing"

// The harmonic lineup block is opt-in everywhere, including staging: an
// operator has to set ENABLE_HARMONIC_LINEUP explicitly. A malformed value is
// treated as unset rather than as an accidental enable.
func TestLoadHarmonicLineupDisabledByDefault(t *testing.T) {
	t.Setenv("ENABLE_HARMONIC_LINEUP", "")

	if cfg := Load(); cfg.EnableHarmonicLineup {
		t.Fatal("EnableHarmonicLineup = true, want false when ENABLE_HARMONIC_LINEUP is unset")
	}

	t.Setenv("ENABLE_HARMONIC_LINEUP", "treu")

	if cfg := Load(); cfg.EnableHarmonicLineup {
		t.Fatal("EnableHarmonicLineup = true, want false for malformed ENABLE_HARMONIC_LINEUP")
	}
}

func TestLoadEnablesHarmonicLineupWhenSet(t *testing.T) {
	t.Setenv("ENABLE_HARMONIC_LINEUP", "true")

	if cfg := Load(); !cfg.EnableHarmonicLineup {
		t.Fatal("EnableHarmonicLineup = false, want true for ENABLE_HARMONIC_LINEUP=true")
	}
}
