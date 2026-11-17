package musicbrainz

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestGetArtistWarmLegacyGroupArtworkDoesNotRefresh(t *testing.T) {
	const artistID = "11111111-1111-4111-8111-111111111111"
	const groupID = "48140466-cff6-3222-bd55-63c27e43190d"
	store := fixturePublicCache(t)
	raw := `{"id":"` + artistID + `","name":"Synthetic artist","releases":[{"id":"` + groupID + `","title":"Synthetic album","coverArtUrl":"https://coverartarchive.org/release/` + groupID + `/front-250"}]}`
	key := "mb:artist-full:" + artistID
	if e := store.Set(context.Background(), key, raw, time.Hour); e != nil {
		t.Fatal(e)
	}
	client := NewClient(store)
	client.httpClient.Transport = fixtureTransport(func(*http.Request) (*http.Response, error) {
		t.Error("warm artwork normalization performed provider I/O")
		return fixtureResponse(500, ""), nil
	})
	artist, e := client.GetArtist(context.Background(), artistID)
	if e != nil || len(artist.Releases) != 1 || artist.Releases[0].CoverArtURL != "https://coverartarchive.org/release-group/"+groupID+"/front-250" {
		t.Fatalf("warm namespace still wrong %+v %v", artist, e)
	}
	if after, ok := store.Get(context.Background(), key); !ok || after != raw {
		t.Fatal("projection rewrote or removed cached data")
	}
}

func TestGetArtistReleaseGroupArtworkUsesGroupNamespace(t *testing.T) {
	const artistID = "11111111-1111-4111-8111-111111111111"
	const groupID = "48140466-cff6-3222-bd55-63c27e43190d"
	client := NewClient(nil)
	calls := 0
	client.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Path != "/ws/2/artist/"+artistID || r.URL.Query().Get("inc") != "release-groups" {
			t.Fatalf("unexpected provider request %s", r.URL.Path)
		}
		return fixtureResponse(200, `{"id":"`+artistID+`","name":"Synthetic artist","release-groups":[{"id":"`+groupID+`","title":"Synthetic album","first-release-date":"2026-11-12"}]}`), nil
	})
	artist, err := client.GetArtist(context.Background(), artistID)
	if err != nil || len(artist.Releases) != 1 {
		t.Fatalf("GetArtist: %+v %v", artist, err)
	}
	want := "https://coverartarchive.org/release-group/" + groupID + "/front-250"
	if artist.Releases[0].CoverArtURL != want {
		t.Fatalf("group routed as edition: got %s want %s", artist.Releases[0].CoverArtURL, want)
	}
	if calls != 1 {
		t.Fatalf("artwork repair added %d provider requests", calls)
	}
	if got := client.GetCoverArtURL("76df3287-6cda-33eb-8e9a-044b5e15ffdd"); got != "https://coverartarchive.org/release/76df3287-6cda-33eb-8e9a-044b5e15ffdd/front-250" {
		t.Fatal("release helper changed namespace")
	}
}
