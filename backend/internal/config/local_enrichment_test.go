package config

import "testing"

func TestLocalEnrichmentOffByDefault(t *testing.T) {
	for _, tc := range []struct {
		value string
		want  bool
	}{
		{"", false}, {"false", false}, {"required-review", false}, {"true", true},
	} {
		t.Setenv("LOCAL_ENRICHMENT_ENABLED", tc.value)
		if got := Load().LocalEnrichmentEnabled; got != tc.want {
			t.Errorf("LOCAL_ENRICHMENT_ENABLED=%q: got %v want %v", tc.value, got, tc.want)
		}
	}
}
