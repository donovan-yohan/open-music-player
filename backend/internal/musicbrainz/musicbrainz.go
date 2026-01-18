package musicbrainz

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/openmusicplayer/backend/internal/cache"
)

const (
	baseURL          = "https://musicbrainz.org/ws/2"
	userAgent        = "OpenMusicPlayer/1.0.0 (https://github.com/openmusicplayer)"
	searchTTL        = 24 * time.Hour
	entityLookupTTL  = 7 * 24 * time.Hour
	defaultLimit     = 20
	maxLimit         = 100
)

type Client struct {
	httpClient *http.Client
	cache      *cache.Cache
}

func NewClient(cache *cache.Cache) *Client {
	return &Client{
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		cache: cache,
	}
}

type TrackResult struct {
	MBID        string `json:"mbid"`
	Title       string `json:"title"`
	Artist      string `json:"artist,omitempty"`
	ArtistMBID  string `json:"artistMbid,omitempty"`
	Album       string `json:"album,omitempty"`
	AlbumMBID   string `json:"albumMbid,omitempty"`
	Duration    int    `json:"duration,omitempty"`
	TrackNumber int    `json:"trackNumber,omitempty"`
	ReleaseDate string `json:"releaseDate,omitempty"`
	Score       int    `json:"score"`
}

type ArtistResult struct {
	MBID           string `json:"mbid"`
	Name           string `json:"name"`
	SortName       string `json:"sortName,omitempty"`
	Type           string `json:"type,omitempty"`
	Country        string `json:"country,omitempty"`
	Disambiguation string `json:"disambiguation,omitempty"`
	Score          int    `json:"score"`
}

type AlbumResult struct {
	MBID           string   `json:"mbid"`
	Title          string   `json:"title"`
	Artist         string   `json:"artist,omitempty"`
	ArtistMBID     string   `json:"artistMbid,omitempty"`
	ReleaseDate    string   `json:"releaseDate,omitempty"`
	PrimaryType    string   `json:"primaryType,omitempty"`
	SecondaryTypes []string `json:"secondaryTypes,omitempty"`
	TrackCount     int      `json:"trackCount,omitempty"`
	Score          int      `json:"score"`
}

type SearchResponse[T any] struct {
	Results []T `json:"results"`
	Total   int `json:"total"`
	Limit   int `json:"limit"`
	Offset  int `json:"offset"`
}

type mbRecordingResponse struct {
	Created    string `json:"created"`
	Count      int    `json:"count"`
	Offset     int    `json:"offset"`
	Recordings []struct {
		ID           string `json:"id"`
		Score        int    `json:"score"`
		Title        string `json:"title"`
		Length       int    `json:"length"`
		ArtistCredit []struct {
			Artist struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"artist"`
		} `json:"artist-credit"`
		Releases []struct {
			ID          string `json:"id"`
			Title       string `json:"title"`
			Date        string `json:"date"`
			TrackCount  int    `json:"track-count"`
			ReleaseGroup struct {
				ID string `json:"id"`
			} `json:"release-group"`
			Media []struct {
				Position   int `json:"position"`
				TrackCount int `json:"track-count"`
				Tracks     []struct {
					Position int    `json:"position"`
					Number   string `json:"number"`
				} `json:"tracks"`
			} `json:"media"`
		} `json:"releases"`
	} `json:"recordings"`
}

type mbArtistResponse struct {
	Created string `json:"created"`
	Count   int    `json:"count"`
	Offset  int    `json:"offset"`
	Artists []struct {
		ID             string `json:"id"`
		Score          int    `json:"score"`
		Name           string `json:"name"`
		SortName       string `json:"sort-name"`
		Type           string `json:"type"`
		Country        string `json:"country"`
		Disambiguation string `json:"disambiguation"`
	} `json:"artists"`
}

type mbReleaseGroupResponse struct {
	Created       string `json:"created"`
	Count         int    `json:"count"`
	Offset        int    `json:"offset"`
	ReleaseGroups []struct {
		ID             string   `json:"id"`
		Score          int      `json:"score"`
		Title          string   `json:"title"`
		PrimaryType    string   `json:"primary-type"`
		SecondaryTypes []string `json:"secondary-types"`
		FirstReleaseDate string `json:"first-release-date"`
		ArtistCredit   []struct {
			Artist struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"artist"`
		} `json:"artist-credit"`
		Releases []struct {
			TrackCount int `json:"track-count"`
		} `json:"releases"`
	} `json:"release-groups"`
}

func (c *Client) SearchTracks(ctx context.Context, query string, limit, offset int, skipCache bool) (*SearchResponse[TrackResult], error) {
	limit = normalizeLimit(limit)
	cacheKey := c.buildCacheKey("recording", query, limit, offset)

	if !skipCache {
		if cached, ok := c.cache.Get(ctx, cacheKey); ok {
			var resp SearchResponse[TrackResult]
			if err := json.Unmarshal([]byte(cached), &resp); err == nil {
				return &resp, nil
			}
		}
	}

	reqURL := fmt.Sprintf("%s/recording?query=%s&limit=%d&offset=%d&fmt=json",
		baseURL, url.QueryEscape(query), limit, offset)

	body, err := c.doRequest(ctx, reqURL)
	if err != nil {
		return nil, err
	}

	var mbResp mbRecordingResponse
	if err := json.Unmarshal(body, &mbResp); err != nil {
		return nil, fmt.Errorf("failed to parse MusicBrainz response: %w", err)
	}

	results := make([]TrackResult, 0, len(mbResp.Recordings))
	for _, rec := range mbResp.Recordings {
		track := TrackResult{
			MBID:     rec.ID,
			Title:    rec.Title,
			Score:    rec.Score,
			Duration: rec.Length,
		}

		if len(rec.ArtistCredit) > 0 {
			track.Artist = rec.ArtistCredit[0].Artist.Name
			track.ArtistMBID = rec.ArtistCredit[0].Artist.ID
		}

		if len(rec.Releases) > 0 {
			release := rec.Releases[0]
			track.Album = release.Title
			track.AlbumMBID = release.ReleaseGroup.ID
			track.ReleaseDate = release.Date
			if len(release.Media) > 0 && len(release.Media[0].Tracks) > 0 {
				track.TrackNumber = release.Media[0].Tracks[0].Position
			}
		}

		results = append(results, track)
	}

	resp := &SearchResponse[TrackResult]{
		Results: results,
		Total:   mbResp.Count,
		Limit:   limit,
		Offset:  mbResp.Offset,
	}

	if respJSON, err := json.Marshal(resp); err == nil {
		c.cache.Set(ctx, cacheKey, string(respJSON), searchTTL)
	}

	return resp, nil
}

func (c *Client) SearchArtists(ctx context.Context, query string, limit, offset int, skipCache bool) (*SearchResponse[ArtistResult], error) {
	limit = normalizeLimit(limit)
	cacheKey := c.buildCacheKey("artist", query, limit, offset)

	if !skipCache {
		if cached, ok := c.cache.Get(ctx, cacheKey); ok {
			var resp SearchResponse[ArtistResult]
			if err := json.Unmarshal([]byte(cached), &resp); err == nil {
				return &resp, nil
			}
		}
	}

	reqURL := fmt.Sprintf("%s/artist?query=%s&limit=%d&offset=%d&fmt=json",
		baseURL, url.QueryEscape(query), limit, offset)

	body, err := c.doRequest(ctx, reqURL)
	if err != nil {
		return nil, err
	}

	var mbResp mbArtistResponse
	if err := json.Unmarshal(body, &mbResp); err != nil {
		return nil, fmt.Errorf("failed to parse MusicBrainz response: %w", err)
	}

	results := make([]ArtistResult, 0, len(mbResp.Artists))
	for _, artist := range mbResp.Artists {
		results = append(results, ArtistResult{
			MBID:           artist.ID,
			Name:           artist.Name,
			SortName:       artist.SortName,
			Type:           artist.Type,
			Country:        artist.Country,
			Disambiguation: artist.Disambiguation,
			Score:          artist.Score,
		})
	}

	resp := &SearchResponse[ArtistResult]{
		Results: results,
		Total:   mbResp.Count,
		Limit:   limit,
		Offset:  mbResp.Offset,
	}

	if respJSON, err := json.Marshal(resp); err == nil {
		c.cache.Set(ctx, cacheKey, string(respJSON), searchTTL)
	}

	return resp, nil
}

func (c *Client) SearchAlbums(ctx context.Context, query string, limit, offset int, skipCache bool) (*SearchResponse[AlbumResult], error) {
	limit = normalizeLimit(limit)
	cacheKey := c.buildCacheKey("release-group", query, limit, offset)

	if !skipCache {
		if cached, ok := c.cache.Get(ctx, cacheKey); ok {
			var resp SearchResponse[AlbumResult]
			if err := json.Unmarshal([]byte(cached), &resp); err == nil {
				return &resp, nil
			}
		}
	}

	reqURL := fmt.Sprintf("%s/release-group?query=%s&limit=%d&offset=%d&fmt=json",
		baseURL, url.QueryEscape(query), limit, offset)

	body, err := c.doRequest(ctx, reqURL)
	if err != nil {
		return nil, err
	}

	var mbResp mbReleaseGroupResponse
	if err := json.Unmarshal(body, &mbResp); err != nil {
		return nil, fmt.Errorf("failed to parse MusicBrainz response: %w", err)
	}

	results := make([]AlbumResult, 0, len(mbResp.ReleaseGroups))
	for _, rg := range mbResp.ReleaseGroups {
		album := AlbumResult{
			MBID:           rg.ID,
			Title:          rg.Title,
			PrimaryType:    rg.PrimaryType,
			SecondaryTypes: rg.SecondaryTypes,
			ReleaseDate:    rg.FirstReleaseDate,
			Score:          rg.Score,
		}

		if len(rg.ArtistCredit) > 0 {
			album.Artist = rg.ArtistCredit[0].Artist.Name
			album.ArtistMBID = rg.ArtistCredit[0].Artist.ID
		}

		if len(rg.Releases) > 0 {
			album.TrackCount = rg.Releases[0].TrackCount
		}

		results = append(results, album)
	}

	resp := &SearchResponse[AlbumResult]{
		Results: results,
		Total:   mbResp.Count,
		Limit:   limit,
		Offset:  mbResp.Offset,
	}

	if respJSON, err := json.Marshal(resp); err == nil {
		c.cache.Set(ctx, cacheKey, string(respJSON), searchTTL)
	}

	return resp, nil
}

func (c *Client) LookupRecording(ctx context.Context, mbid string, skipCache bool) (*TrackResult, error) {
	cacheKey := fmt.Sprintf("mb:recording:%s", mbid)

	if !skipCache {
		if cached, ok := c.cache.Get(ctx, cacheKey); ok {
			var track TrackResult
			if err := json.Unmarshal([]byte(cached), &track); err == nil {
				return &track, nil
			}
		}
	}

	reqURL := fmt.Sprintf("%s/recording/%s?inc=artist-credits+releases&fmt=json", baseURL, mbid)

	body, err := c.doRequest(ctx, reqURL)
	if err != nil {
		return nil, err
	}

	var rec struct {
		ID           string `json:"id"`
		Title        string `json:"title"`
		Length       int    `json:"length"`
		ArtistCredit []struct {
			Artist struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"artist"`
		} `json:"artist-credit"`
		Releases []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
			Date  string `json:"date"`
			ReleaseGroup struct {
				ID string `json:"id"`
			} `json:"release-group"`
		} `json:"releases"`
	}

	if err := json.Unmarshal(body, &rec); err != nil {
		return nil, fmt.Errorf("failed to parse MusicBrainz response: %w", err)
	}

	track := &TrackResult{
		MBID:     rec.ID,
		Title:    rec.Title,
		Duration: rec.Length,
		Score:    100,
	}

	if len(rec.ArtistCredit) > 0 {
		track.Artist = rec.ArtistCredit[0].Artist.Name
		track.ArtistMBID = rec.ArtistCredit[0].Artist.ID
	}

	if len(rec.Releases) > 0 {
		track.Album = rec.Releases[0].Title
		track.AlbumMBID = rec.Releases[0].ReleaseGroup.ID
		track.ReleaseDate = rec.Releases[0].Date
	}

	if trackJSON, err := json.Marshal(track); err == nil {
		c.cache.Set(ctx, cacheKey, string(trackJSON), entityLookupTTL)
	}

	return track, nil
}

func (c *Client) LookupArtist(ctx context.Context, mbid string, skipCache bool) (*ArtistResult, error) {
	cacheKey := fmt.Sprintf("mb:artist:%s", mbid)

	if !skipCache {
		if cached, ok := c.cache.Get(ctx, cacheKey); ok {
			var artist ArtistResult
			if err := json.Unmarshal([]byte(cached), &artist); err == nil {
				return &artist, nil
			}
		}
	}

	reqURL := fmt.Sprintf("%s/artist/%s?fmt=json", baseURL, mbid)

	body, err := c.doRequest(ctx, reqURL)
	if err != nil {
		return nil, err
	}

	var mbArtist struct {
		ID             string `json:"id"`
		Name           string `json:"name"`
		SortName       string `json:"sort-name"`
		Type           string `json:"type"`
		Country        string `json:"country"`
		Disambiguation string `json:"disambiguation"`
	}

	if err := json.Unmarshal(body, &mbArtist); err != nil {
		return nil, fmt.Errorf("failed to parse MusicBrainz response: %w", err)
	}

	artist := &ArtistResult{
		MBID:           mbArtist.ID,
		Name:           mbArtist.Name,
		SortName:       mbArtist.SortName,
		Type:           mbArtist.Type,
		Country:        mbArtist.Country,
		Disambiguation: mbArtist.Disambiguation,
		Score:          100,
	}

	if artistJSON, err := json.Marshal(artist); err == nil {
		c.cache.Set(ctx, cacheKey, string(artistJSON), entityLookupTTL)
	}

	return artist, nil
}

func (c *Client) doRequest(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("MusicBrainz API returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	return body, nil
}

func (c *Client) buildCacheKey(entityType, query string, limit, offset int) string {
	hash := sha256.Sum256([]byte(fmt.Sprintf("%s:%d:%d", query, limit, offset)))
	return fmt.Sprintf("mb:%s:%s", entityType, hex.EncodeToString(hash[:8]))
}

func normalizeLimit(limit int) int {
	if limit <= 0 {
		return defaultLimit
	}
	if limit > maxLimit {
		return maxLimit
	}
	return limit
}
