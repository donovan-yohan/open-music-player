package musicbrainz

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

type fixtureTransport func(*http.Request) (*http.Response, error)

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func fixtureResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func fixtureClient(t *testing.T, body string) *Client {
	t.Helper()
	c := NewClient(nil)
	c.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "musicbrainz.org" || r.Header.Get("User-Agent") != userAgent || r.Header.Get("Accept") != "application/json" {
			t.Errorf("unexpected provider request: %s, headers %v", r.URL, r.Header)
		}
		return fixtureResponse(http.StatusOK, body), nil
	})
	return c
}

// Assert via the existing public HTTP handler, not a reflection check for a new field.
func TestRecordingSearchPreservesFirstReleaseEvidence(t *testing.T) {
	dates := []string{"1984-05-06", "1984", "1984-05", "", "not-a-date", "1984-02-31"}
	recordings := make([]map[string]any, 0, len(dates))
	for i, date := range dates {
		recordings = append(recordings, map[string]any{
			"id": fmt.Sprintf("recording-%d", i), "title": "Song", "score": 97, "length": 240001,
			"first-release-date": date,
			"artist-credit": []any{
				map[string]any{"name": "Alias on sleeve", "artist": map[string]any{"id": "11111111-1111-4111-8111-111111111111", "name": "First canonical"}},
				map[string]any{"artist": map[string]any{"id": "22222222-2222-4222-8222-222222222222", "name": "Listened canonical"}},
			},
			"releases": []any{map[string]any{"id": "edition", "title": "Reissue", "date": "2026-11-01", "release-group": map[string]any{"id": "group"}, "media": []any{map[string]any{"tracks": []any{map[string]any{"position": 7}}}}}},
		})
	}
	body, err := json.Marshal(map[string]any{"count": 30, "offset": 2, "recordings": recordings})
	if err != nil {
		t.Fatal(err)
	}
	c := fixtureClient(t, string(body))
	w := httptest.NewRecorder()
	NewHandlers(c).SearchTracks(w, httptest.NewRequest(http.MethodGet, "/?q=arid%3Asecond&limit=6&offset=2", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var got struct {
		Results              []map[string]any `json:"results"`
		Total, Limit, Offset int
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Results) != len(dates) || got.Total != 30 || got.Limit != 6 || got.Offset != 2 {
		t.Fatalf("pagination/order changed: %+v", got)
	}
	for i, row := range got.Results {
		if date, _ := row["firstReleaseDate"].(string); date != dates[i] {
			t.Errorf("row %d firstReleaseDate = %q, want raw %q", i, date, dates[i])
		}
		for key, want := range map[string]any{"mbid": fmt.Sprintf("recording-%d", i), "releaseDate": "2026-11-01", "artist": "First canonical", "artistMbid": "11111111-1111-4111-8111-111111111111", "album": "Reissue", "albumMbid": "group", "releaseGroupMbid": "group", "releaseId": "edition", "coverArtUrl": "https://coverartarchive.org/release/edition/front-250", "trackNumber": float64(7), "score": float64(97), "duration": float64(240001)} {
			if row[key] != want {
				t.Errorf("row %d %s = %v, want %v", i, key, row[key], want)
			}
		}
		wantCredits := []any{map[string]any{"mbid": "11111111-1111-4111-8111-111111111111", "name": "First canonical"}, map[string]any{"mbid": "22222222-2222-4222-8222-222222222222", "name": "Listened canonical"}}
		if !reflect.DeepEqual(row["artistCredits"], wantCredits) {
			t.Errorf("row %d credits = %#v, want canonical IDs including later credit", i, row["artistCredits"])
		}
	}
}

func TestRecordingSearchMissingFirstDateDoesNotInferEditionDate(t *testing.T) {
	c := fixtureClient(t, `{"count":1,"recordings":[{"id":"r","releases":[{"date":"2026-11-01"}]}]}`)
	resp, err := c.SearchTracks(context.Background(), "missing", 1, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(resp.Results[0])
	if err != nil {
		t.Fatal(err)
	}
	var row map[string]any
	if err := json.Unmarshal(encoded, &row); err != nil {
		t.Fatal(err)
	}
	if v, _ := row["firstReleaseDate"].(string); v != "" {
		t.Fatalf("invented first date: %q", v)
	}
	if row["releaseDate"] != "2026-11-01" {
		t.Fatalf("legacy edition date changed: %s", encoded)
	}
}

func TestRecordingSearchCreditEvidenceIsBoundedExplicitly(t *testing.T) {
	credits := make([]any, 101)
	for i := range credits {
		credits[i] = map[string]any{"artist": map[string]any{"id": fmt.Sprintf("id-%d", i), "name": fmt.Sprintf("Artist %d", i)}}
	}
	body, err := json.Marshal(map[string]any{"recordings": []any{map[string]any{"artist-credit": credits}}})
	if err != nil {
		t.Fatal(err)
	}
	c := fixtureClient(t, string(body))
	resp, err := c.SearchTracks(context.Background(), "many", 1, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(resp.Results[0])
	if err != nil {
		t.Fatal(err)
	}
	var row struct {
		ArtistCredits []struct {
			MBID string `json:"mbid"`
		} `json:"artistCredits"`
		Truncated bool `json:"artistCreditsTruncated"`
	}
	if err := json.Unmarshal(encoded, &row); err != nil {
		t.Fatal(err)
	}
	if len(row.ArtistCredits) != 100 || !row.Truncated {
		t.Fatalf("unbounded or silently incomplete evidence: count=%d truncated=%v", len(row.ArtistCredits), row.Truncated)
	}
	if row.ArtistCredits[99].MBID != "id-99" {
		t.Fatalf("credit order changed: %+v", row.ArtistCredits[99])
	}
}
