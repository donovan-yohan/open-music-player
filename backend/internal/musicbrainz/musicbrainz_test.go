package musicbrainz

import "testing"

func TestGetCoverArtURLUsesReleaseID(t *testing.T) {
	client := NewClient(nil)
	got := client.GetCoverArtURL("release-id")
	want := "https://coverartarchive.org/release/release-id/front-250"
	if got != want {
		t.Fatalf("GetCoverArtURL = %q, want %q", got, want)
	}
}
