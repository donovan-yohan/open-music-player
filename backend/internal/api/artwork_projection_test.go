package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestHomeAndLibraryProjectTheSameProviderArtwork(t *testing.T) {
	track := db.Track{
		ID:    42,
		Title: "Provider fallback",
		MetadataJSON: json.RawMessage(
			`{"raw_provider":{"thumbnail":"https://provider.example/42.jpg"}}`,
		),
	}

	home := trackToPlayEventResponse(track)
	library := map[string]interface{}{}
	projectLibraryArtwork(
		library,
		db.LibraryTrack{Track: track},
		NewFieldSelector("cover_art_url,artwork_url,artwork_kind"),
	)

	if home.ArtworkURL != library["artwork_url"] ||
		home.ArtworkKind != library["artwork_kind"] {
		t.Fatalf("Home artwork %#v/%q != Library %#v/%#v",
			home.ArtworkURL, home.ArtworkKind,
			library["artwork_url"], library["artwork_kind"])
	}
	if home.CoverArtURL != "" {
		t.Fatalf("Home legacy cover mislabeled provider thumbnail: %q", home.CoverArtURL)
	}
	if _, ok := library["cover_art_url"]; ok {
		t.Fatalf("Library legacy cover mislabeled provider thumbnail: %#v", library)
	}

	encodedHome, err := json.Marshal(home)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encodedHome), `"artworkUrl":"https://provider.example/42.jpg"`) ||
		!strings.Contains(string(encodedHome), `"artworkKind":"provider_thumbnail"`) {
		t.Fatalf("Home JSON field contract = %s", encodedHome)
	}
	encodedLibrary, err := json.Marshal(library)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encodedLibrary), `"artwork_url":"https://provider.example/42.jpg"`) ||
		!strings.Contains(string(encodedLibrary), `"artwork_kind":"provider_thumbnail"`) {
		t.Fatalf("Library JSON field contract = %s", encodedLibrary)
	}
}

func TestLibraryArtworkProjectionHonorsFieldSelectionAndNone(t *testing.T) {
	projected := map[string]interface{}{}
	projectLibraryArtwork(
		projected,
		db.LibraryTrack{},
		NewFieldSelector("artwork_kind"),
	)

	if got := projected["artwork_kind"]; got != db.ArtworkKindNone {
		t.Fatalf("artwork_kind = %#v, want none", got)
	}
	if _, ok := projected["artwork_url"]; ok {
		t.Fatalf("unselected or absent artwork URL leaked: %#v", projected)
	}
	if _, ok := projected["cover_art_url"]; ok {
		t.Fatalf("unselected legacy cover leaked: %#v", projected)
	}
}

func TestLibraryArtworkProjectionKeepsDescriptorAtomic(t *testing.T) {
	track := db.Track{
		MetadataJSON: json.RawMessage(
			`{"raw_provider":{"thumbnail":"https://provider.example/42.jpg"}}`,
		),
	}
	for _, selected := range []string{"artwork_url", "artwork_kind"} {
		t.Run(selected, func(t *testing.T) {
			projected := map[string]interface{}{}
			projectLibraryArtwork(
				projected,
				db.LibraryTrack{Track: track},
				NewFieldSelector(selected),
			)

			if got := projected["artwork_url"]; got != "https://provider.example/42.jpg" {
				t.Fatalf("artwork_url = %#v for selector %q", got, selected)
			}
			if got := projected["artwork_kind"]; got != db.ArtworkKindProviderThumbnail {
				t.Fatalf("artwork_kind = %#v for selector %q", got, selected)
			}
		})
	}
}
