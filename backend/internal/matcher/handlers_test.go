package matcher

import "testing"

func TestMatchTrackMBUpdateUsesConcreteReleaseID(t *testing.T) {
	releaseGroupID := "11111111-1111-1111-1111-111111111111"
	releaseID := "22222222-2222-2222-2222-222222222222"

	update := matchTrackMBUpdate(&MatchOutput{
		Verified: true,
		BestMatch: &MatchResult{
			MBID:       "33333333-3333-3333-3333-333333333333",
			ArtistMBID: "44444444-4444-4444-4444-444444444444",
			AlbumMBID:  releaseGroupID,
			ReleaseID:  releaseID,
		},
	})

	if update.MBReleaseID == nil {
		t.Fatal("verified match did not set MBReleaseID")
	}
	if got := update.MBReleaseID.String(); got != releaseID {
		t.Fatalf("MBReleaseID = %q, want concrete ReleaseID %q", got, releaseID)
	}
	if got := update.MBReleaseID.String(); got == releaseGroupID {
		t.Fatalf("MBReleaseID used release-group AlbumMBID %q", releaseGroupID)
	}
	if !update.ApplyMBIdentity || update.MBVerified == nil || !*update.MBVerified {
		t.Fatalf("verified match identity flags not set: %#v", update)
	}
}
