package db

import "testing"

func TestBuildPrefixTSQuery(t *testing.T) {
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{"simple word keeps prefix", "beat", "beat:*"},
		{"two words ANDed", "hello world", "hello:* & world:*"},
		{"slash is a separator (AC/DC)", "AC/DC", "AC:* & DC:*"},
		{"trailing ampersand", "foo &", "foo:*"},
		{"bang stripped", "foo!", "foo:*"},
		{"colon splits lexemes", "a:b", "a:* & b:*"},
		{"parens stripped", "(x)", "x:*"},
		{"digits allowed", "track 2", "track:* & 2:*"},
		{"unicode letters kept", "naïve", "naïve:*"},
		{"collapses extra whitespace", "  spaced   out  ", "spaced:* & out:*"},
		{"empty input", "", ""},
		{"whitespace only", "   ", ""},
		{"punctuation only", "&|!:()", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := buildPrefixTSQuery(tc.input); got != tc.want {
				t.Fatalf("buildPrefixTSQuery(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}
