package musicbrainz

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

const interactiveCatalogPageMaxBytes = 1 << 20

var errInteractiveCatalogPage = errors.New("invalid MusicBrainz interactive catalog page")

// SearchInteractiveArtists reads a validated artist page without consulting or
// populating the permissive legacy artist search cache.
func (c *Client) SearchInteractiveArtists(ctx context.Context, query string, limit, offset int) (*SearchResponse[ArtistResult], error) {
	return readInteractiveCatalogPage(ctx, c, "artist", query, limit, offset, decodeInteractiveArtistPage, validInteractiveArtist)
}

// SearchInteractiveAlbums reads a validated release-group page without
// consulting or populating the permissive legacy release-group search cache.
func (c *Client) SearchInteractiveAlbums(ctx context.Context, query string, limit, offset int) (*SearchResponse[AlbumResult], error) {
	return readInteractiveCatalogPage(ctx, c, "release-group", query, limit, offset, decodeInteractiveAlbumPage, validInteractiveAlbum)
}

func readInteractiveCatalogPage[T any](ctx context.Context, c *Client, entity, query string, limit, offset int,
	decode func([]byte, int, int) (*SearchResponse[T], error), validRow func(T) bool,
) (*SearchResponse[T], error) {
	ctx = WithInteractiveCatalogRead(ctx)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if limit <= 0 || limit > maxLimit || offset < 0 {
		return nil, errInteractiveCatalogPage
	}
	key := c.buildCacheKey("interactive-catalog-v1-"+entity, query, limit, offset)
	if cached, ok := c.cacheGet(ctx, key); ok && len(cached) <= interactiveCatalogPageMaxBytes {
		var stored struct {
			Results []T  `json:"results"`
			Total   *int `json:"total"`
			Limit   *int `json:"limit"`
			Offset  *int `json:"offset"`
		}
		if json.Unmarshal([]byte(cached), &stored) == nil && stored.Limit != nil && *stored.Limit == limit {
			if page, err := validatedInteractivePage(stored.Results, stored.Total, stored.Offset, limit, offset, validRow); err == nil {
				if err := ctx.Err(); err != nil {
					return nil, err
				}
				return page, nil
			}
		}
	}
	reqURL := fmt.Sprintf("%s/%s?query=%s&limit=%d&offset=%d&fmt=json", baseURL, entity, url.QueryEscape(query), limit, offset)
	body, err := c.doRequest(ctx, reqURL)
	if err != nil {
		return nil, err
	}
	page, err := decode(body, limit, offset)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if data, err := json.Marshal(page); err == nil && len(data) <= interactiveCatalogPageMaxBytes {
		c.cacheSet(ctx, key, string(data), searchTTL)
	}
	return page, nil
}

func decodeInteractiveArtistPage(body []byte, limit, offset int) (*SearchResponse[ArtistResult], error) {
	// Override the legacy scalar fields to detect missing and null metadata
	// separately from the explicit zeroes in a legitimate empty result.
	wire := struct {
		mbArtistResponse
		Count  *int `json:"count"`
		Offset *int `json:"offset"`
	}{}
	if err := json.Unmarshal(body, &wire); err != nil || wire.Artists == nil || len(wire.Artists) > limit {
		return nil, errInteractiveCatalogPage
	}
	results := make([]ArtistResult, 0, len(wire.Artists))
	for _, row := range wire.Artists {
		results = append(results, ArtistResult{
			MBID: row.ID, Name: row.Name, SortName: row.SortName, Type: row.Type,
			Country: row.Country, Disambiguation: row.Disambiguation, Score: row.Score,
		})
	}
	return validatedInteractivePage(results, wire.Count, wire.Offset, limit, offset, validInteractiveArtist)
}

func decodeInteractiveAlbumPage(body []byte, limit, offset int) (*SearchResponse[AlbumResult], error) {
	wire := struct {
		mbReleaseGroupResponse
		Count  *int `json:"count"`
		Offset *int `json:"offset"`
	}{}
	if err := json.Unmarshal(body, &wire); err != nil || wire.ReleaseGroups == nil || len(wire.ReleaseGroups) > limit {
		return nil, errInteractiveCatalogPage
	}
	results := make([]AlbumResult, 0, len(wire.ReleaseGroups))
	for _, row := range wire.ReleaseGroups {
		album := AlbumResult{
			MBID: row.ID, Title: row.Title, PrimaryType: row.PrimaryType, SecondaryTypes: row.SecondaryTypes,
			ReleaseDate: row.FirstReleaseDate, Score: row.Score,
		}
		if len(row.ArtistCredit) > 0 {
			album.Artist = row.ArtistCredit[0].Artist.Name
			album.ArtistMBID = row.ArtistCredit[0].Artist.ID
		}
		if len(row.Releases) > 0 {
			album.TrackCount = row.Releases[0].TrackCount
		}
		results = append(results, album)
	}
	return validatedInteractivePage(results, wire.Count, wire.Offset, limit, offset, validInteractiveAlbum)
}

func validatedInteractivePage[T any](results []T, count, returnedOffset *int, limit, offset int, validRow func(T) bool) (*SearchResponse[T], error) {
	if results == nil || len(results) > limit || count == nil || *count < 0 || returnedOffset == nil || *returnedOffset != offset {
		return nil, errInteractiveCatalogPage
	}
	remaining := max(0, *count-offset) // An exhausted offset can exceed the total.
	if len(results) > remaining || len(results) == 0 && remaining > 0 {
		return nil, errInteractiveCatalogPage
	}
	for _, row := range results {
		if !validRow(row) {
			return nil, errInteractiveCatalogPage
		}
	}
	return &SearchResponse[T]{Results: results, Total: *count, Limit: limit, Offset: offset}, nil
}

func validInteractiveArtist(row ArtistResult) bool {
	return validDiscoverID(row.MBID) && strings.TrimSpace(row.Name) != ""
}

func validInteractiveAlbum(row AlbumResult) bool {
	return validDiscoverID(row.MBID) && strings.TrimSpace(row.Title) != "" &&
		(row.ArtistMBID == "" || validDiscoverID(row.ArtistMBID))
}
