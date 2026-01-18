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
	baseURL         = "https://musicbrainz.org/ws/2"
	coverArtURL     = "https://coverartarchive.org"
	userAgent       = "OpenMusicPlayer/1.0.0 (https://github.com/openmusicplayer)"
	searchTTL       = 24 * time.Hour
	entityLookupTTL = 7 * 24 * time.Hour
	defaultLimit    = 20
	maxLimit        = 100
)

// ErrNotFound is returned when a resource is not found
var ErrNotFound = fmt.Errorf("not found")

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

// Search result types
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

// Browse types (for detailed lookups)
type Artist struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	SortName       string    `json:"sortName,omitempty"`
	Type           string    `json:"type,omitempty"`
	Country        string    `json:"country,omitempty"`
	Disambiguation string    `json:"disambiguation,omitempty"`
	BeginDate      string    `json:"beginDate,omitempty"`
	EndDate        string    `json:"endDate,omitempty"`
	Releases       []Release `json:"releases,omitempty"`
}

type Release struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Artist      string  `json:"artist,omitempty"`
	ArtistID    string  `json:"artistId,omitempty"`
	Date        string  `json:"date,omitempty"`
	Country     string  `json:"country,omitempty"`
	TrackCount  int     `json:"trackCount,omitempty"`
	CoverArtURL string  `json:"coverArtUrl,omitempty"`
	Tracks      []Track `json:"tracks,omitempty"`
}

type Track struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	Artist       string `json:"artist,omitempty"`
	ArtistID     string `json:"artistId,omitempty"`
	Album        string `json:"album,omitempty"`
	AlbumID      string `json:"albumId,omitempty"`
	Duration     int    `json:"duration,omitempty"`
	Position     int    `json:"position,omitempty"`
	InLibrary    bool   `json:"inLibrary"`
	Downloadable bool   `json:"downloadable"`
}

// MusicBrainz API response types
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
			ID         string `json:"id"`
			Title      string `json:"title"`
			Date       string `json:"date"`
			TrackCount int    `json:"track-count"`
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
		ID               string   `json:"id"`
		Score            int      `json:"score"`
		Title            string   `json:"title"`
		PrimaryType      string   `json:"primary-type"`
		SecondaryTypes   []string `json:"secondary-types"`
		FirstReleaseDate string   `json:"first-release-date"`
		ArtistCredit     []struct {
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

// mbArtistLookupResponse is for single artist lookup with release-groups
type mbArtistLookupResponse struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	SortName       string `json:"sort-name"`
	Type           string `json:"type"`
	Country        string `json:"country"`
	Disambiguation string `json:"disambiguation"`
	LifeSpan       struct {
		Begin string `json:"begin"`
		End   string `json:"end"`
	} `json:"life-span"`
	ReleaseGroups []struct {
		ID               string `json:"id"`
		Title            string `json:"title"`
		PrimaryType      string `json:"primary-type"`
		FirstReleaseDate string `json:"first-release-date"`
	} `json:"release-groups"`
}

// mbReleaseLookupResponse is for single release lookup
type mbReleaseLookupResponse struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	Date         string `json:"date"`
	Country      string `json:"country"`
	ArtistCredit []struct {
		Artist struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"artist"`
	} `json:"artist-credit"`
	Media []struct {
		Position int `json:"position"`
		Tracks   []struct {
			ID       string `json:"id"`
			Position int    `json:"position"`
			Title    string `json:"title"`
			Length   int    `json:"length"`
			Recording struct {
				ID string `json:"id"`
			} `json:"recording"`
		} `json:"tracks"`
	} `json:"media"`
}

// mbRecordingLookupResponse is for single recording lookup
type mbRecordingLookupResponse struct {
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
	} `json:"releases"`
}

// Search methods with caching

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

// Browse/lookup methods

// GetArtist fetches artist details with discography from MusicBrainz
func (c *Client) GetArtist(ctx context.Context, mbID string) (*Artist, error) {
	cacheKey := fmt.Sprintf("mb:artist-full:%s", mbID)

	if cached, ok := c.cache.Get(ctx, cacheKey); ok {
		var artist Artist
		if err := json.Unmarshal([]byte(cached), &artist); err == nil {
			return &artist, nil
		}
	}

	endpoint := fmt.Sprintf("%s/artist/%s?fmt=json&inc=release-groups", baseURL, url.PathEscape(mbID))

	body, err := c.doRequest(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	var mbResp mbArtistLookupResponse
	if err := json.Unmarshal(body, &mbResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	artist := &Artist{
		ID:             mbResp.ID,
		Name:           mbResp.Name,
		SortName:       mbResp.SortName,
		Type:           mbResp.Type,
		Country:        mbResp.Country,
		Disambiguation: mbResp.Disambiguation,
		BeginDate:      mbResp.LifeSpan.Begin,
		EndDate:        mbResp.LifeSpan.End,
		Releases:       make([]Release, 0, len(mbResp.ReleaseGroups)),
	}

	for _, rg := range mbResp.ReleaseGroups {
		release := Release{
			ID:          rg.ID,
			Title:       rg.Title,
			Date:        rg.FirstReleaseDate,
			CoverArtURL: c.GetCoverArtURL(rg.ID),
		}
		artist.Releases = append(artist.Releases, release)
	}

	if artistJSON, err := json.Marshal(artist); err == nil {
		c.cache.Set(ctx, cacheKey, string(artistJSON), entityLookupTTL)
	}

	return artist, nil
}

// GetRelease fetches release/album details with track listing from MusicBrainz
func (c *Client) GetRelease(ctx context.Context, mbID string) (*Release, error) {
	cacheKey := fmt.Sprintf("mb:release:%s", mbID)

	if cached, ok := c.cache.Get(ctx, cacheKey); ok {
		var release Release
		if err := json.Unmarshal([]byte(cached), &release); err == nil {
			return &release, nil
		}
	}

	endpoint := fmt.Sprintf("%s/release/%s?fmt=json&inc=artist-credits+recordings", baseURL, url.PathEscape(mbID))

	body, err := c.doRequest(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	var mbResp mbReleaseLookupResponse
	if err := json.Unmarshal(body, &mbResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	release := &Release{
		ID:          mbResp.ID,
		Title:       mbResp.Title,
		Date:        mbResp.Date,
		Country:     mbResp.Country,
		CoverArtURL: c.GetCoverArtURL(mbResp.ID),
		Tracks:      make([]Track, 0),
	}

	if len(mbResp.ArtistCredit) > 0 {
		release.Artist = mbResp.ArtistCredit[0].Artist.Name
		release.ArtistID = mbResp.ArtistCredit[0].Artist.ID
	}

	for _, media := range mbResp.Media {
		for _, t := range media.Tracks {
			track := Track{
				ID:       t.Recording.ID,
				Title:    t.Title,
				Duration: t.Length,
				Position: t.Position,
				Artist:   release.Artist,
				ArtistID: release.ArtistID,
				Album:    release.Title,
				AlbumID:  release.ID,
			}
			release.Tracks = append(release.Tracks, track)
		}
	}

	release.TrackCount = len(release.Tracks)

	if releaseJSON, err := json.Marshal(release); err == nil {
		c.cache.Set(ctx, cacheKey, string(releaseJSON), entityLookupTTL)
	}

	return release, nil
}

// GetRecording fetches recording/track details from MusicBrainz
func (c *Client) GetRecording(ctx context.Context, mbID string) (*Track, error) {
	cacheKey := fmt.Sprintf("mb:recording:%s", mbID)

	if cached, ok := c.cache.Get(ctx, cacheKey); ok {
		var track Track
		if err := json.Unmarshal([]byte(cached), &track); err == nil {
			return &track, nil
		}
	}

	endpoint := fmt.Sprintf("%s/recording/%s?fmt=json&inc=artist-credits+releases", baseURL, url.PathEscape(mbID))

	body, err := c.doRequest(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	var mbResp mbRecordingLookupResponse
	if err := json.Unmarshal(body, &mbResp); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	track := &Track{
		ID:       mbResp.ID,
		Title:    mbResp.Title,
		Duration: mbResp.Length,
	}

	if len(mbResp.ArtistCredit) > 0 {
		track.Artist = mbResp.ArtistCredit[0].Artist.Name
		track.ArtistID = mbResp.ArtistCredit[0].Artist.ID
	}

	if len(mbResp.Releases) > 0 {
		track.Album = mbResp.Releases[0].Title
		track.AlbumID = mbResp.Releases[0].ID
	}

	if trackJSON, err := json.Marshal(track); err == nil {
		c.cache.Set(ctx, cacheKey, string(trackJSON), entityLookupTTL)
	}

	return track, nil
}

// GetCoverArtURL returns the Cover Art Archive URL for a release
func (c *Client) GetCoverArtURL(releaseID string) string {
	return fmt.Sprintf("%s/release/%s/front-250", coverArtURL, releaseID)
}

// HTTP client helpers

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

	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrNotFound
	}

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
