package matcher

import "testing"

func TestBuildSuggestionsJSONIncludesReleaseAndCoverArt(t *testing.T) {
	suggestions := BuildSuggestionsJSON([]MatchResult{
		{
			MBID:        "recording-id",
			Title:       "Cheerleader",
			Artist:      "Porter Robinson",
			ArtistMBID:  "artist-id",
			Album:       "Cheerleader",
			AlbumMBID:   "release-group-id",
			ReleaseID:   "release-id",
			CoverArtURL: "https://coverartarchive.org/release/release-id/front-250",
			Confidence:  0.91,
		},
	})

	raw, ok := suggestions["mb_suggestions"].([]MBSuggestion)
	if !ok || len(raw) != 1 {
		t.Fatalf("mb_suggestions = %#v", suggestions["mb_suggestions"])
	}
	if raw[0].ReleaseID != "release-id" {
		t.Fatalf("ReleaseID = %q, want release-id", raw[0].ReleaseID)
	}
	if raw[0].AlbumMBID != "release-group-id" {
		t.Fatalf("AlbumMBID = %q, want release-group-id", raw[0].AlbumMBID)
	}
	if raw[0].CoverArtURL == "" {
		t.Fatalf("CoverArtURL was not preserved")
	}
}
