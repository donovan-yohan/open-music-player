package db

import (
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
)

func TestResolveTrackArtworkFallbackContract(t *testing.T) {
	releaseID := uuid.MustParse("11111111-1111-1111-1111-111111111111")
	tests := []struct {
		name  string
		track Track
		want  ArtworkDescriptor
	}{
		{
			name: "stored enriched cover wins every fallback",
			track: Track{
				CoverArtURL: sql.NullString{
					String: "https://enriched.example/cover.jpg",
					Valid:  true,
				},
				MBReleaseID: &releaseID,
				MetadataJSON: json.RawMessage(
					`{"raw_provider":{"thumbnail":"https://provider.example/thumb.jpg"}}`,
				),
			},
			want: ArtworkDescriptor{
				URL:  "https://enriched.example/cover.jpg",
				Kind: ArtworkKindCoverArt,
			},
		},
		{
			name:  "release cover wins provider fallback",
			track: Track{MBReleaseID: &releaseID, MetadataJSON: json.RawMessage(`{"raw_provider":{"thumbnail":"https://provider.example/thumb.jpg"}}`)},
			want: ArtworkDescriptor{
				URL:  "https://coverartarchive.org/release/11111111-1111-1111-1111-111111111111/front-250",
				Kind: ArtworkKindReleaseCover,
			},
		},
		{
			name:  "retained metadata thumbnail is explicit provider art",
			track: Track{MetadataJSON: json.RawMessage(`{"raw_provider":{"thumbnail":" https://provider.example/thumb.jpg "}}`)},
			want: ArtworkDescriptor{
				URL:  "https://provider.example/thumb.jpg",
				Kind: ArtworkKindProviderThumbnail,
			},
		},
		{
			name:  "legacy provenance thumbnail url remains readable",
			track: Track{MetadataProvenance: json.RawMessage(`{"raw_provider":{"thumbnail_url":"http://legacy.example/thumb.jpg"}}`)},
			want: ArtworkDescriptor{
				URL:  "http://legacy.example/thumb.jpg",
				Kind: ArtworkKindProviderThumbnail,
			},
		},
		{
			name:  "missing remote image resolves deterministic none",
			track: Track{},
			want:  ArtworkDescriptor{Kind: ArtworkKindNone},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := ResolveTrackArtwork(test.track); got != test.want {
				t.Fatalf("ResolveTrackArtwork() = %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestResolveTrackArtworkRejectsUnsafeProviderURLs(t *testing.T) {
	for _, raw := range []string{
		"",
		"   ",
		"://bad",
		"file:///tmp/cover.jpg",
		"data:image/png;base64,abc",
		"javascript:alert(1)",
		"https:///missing-host.jpg",
		"https://user:secret@example.test/cover.jpg",
	} {
		t.Run(raw, func(t *testing.T) {
			track := Track{
				MetadataJSON: mustArtworkJSON(t, map[string]any{
					"raw_provider": map[string]any{"thumbnail": raw},
				}),
			}
			if got := ResolveTrackArtwork(track); got.Kind != ArtworkKindNone || got.URL != "" {
				t.Fatalf("unsafe URL %q resolved as %#v", raw, got)
			}
		})
	}
}

func TestResolveTrackArtworkSkipsMalformedProviderValuesAndDocuments(t *testing.T) {
	tracks := []Track{
		{MetadataJSON: json.RawMessage(`{`)},
		{MetadataJSON: json.RawMessage(`{"raw_provider":{"thumbnail":["https://example.test/not-a-string.jpg"]}}`)},
		{MetadataJSON: json.RawMessage(`{"raw_provider":{"thumbnail":{"url":"https://example.test/not-a-string.jpg"}}}`)},
	}
	for _, track := range tracks {
		if got := ResolveTrackArtwork(track); got != (ArtworkDescriptor{Kind: ArtworkKindNone}) {
			t.Fatalf("malformed provider value resolved as %#v", got)
		}
	}
}

func TestLegacyCoverArtURLNeverRelabelsProviderThumbnail(t *testing.T) {
	providerOnly := Track{
		MetadataJSON: json.RawMessage(
			`{"raw_provider":{"thumbnail":"https://provider.example/thumb.jpg"}}`,
		),
	}
	if got := LegacyCoverArtURL(providerOnly); got != "" {
		t.Fatalf("LegacyCoverArtURL(provider) = %q, want empty", got)
	}
}

func mustArtworkJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}
