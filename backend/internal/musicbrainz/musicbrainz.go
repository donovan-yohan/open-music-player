package musicbrainz

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sync"
	"time"
)

const (
	baseURL        = "https://musicbrainz.org/ws/2"
	coverArtURL    = "https://coverartarchive.org"
	userAgent      = "OpenMusicPlayer/1.0.0 (https://github.com/openmusicplayer/openmusicplayer)"
	requestTimeout = 10 * time.Second
	rateLimitDelay = time.Second // MusicBrainz requires 1 request per second for anonymous requests
)

// Client provides access to the MusicBrainz API
type Client struct {
	httpClient    *http.Client
	lastRequest   time.Time
	rateLimitLock sync.Mutex
}

// NewClient creates a new MusicBrainz API client
func NewClient() *Client {
	return &Client{
		httpClient: &http.Client{
			Timeout: requestTimeout,
		},
	}
}

// Artist represents a MusicBrainz artist with discography
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

// Release represents a MusicBrainz release (album)
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

// Track represents a MusicBrainz recording/track
type Track struct {
	ID         string `json:"id"`
	Title      string `json:"title"`
	Artist     string `json:"artist,omitempty"`
	ArtistID   string `json:"artistId,omitempty"`
	Album      string `json:"album,omitempty"`
	AlbumID    string `json:"albumId,omitempty"`
	Duration   int    `json:"duration,omitempty"` // Duration in milliseconds
	Position   int    `json:"position,omitempty"`
	InLibrary  bool   `json:"inLibrary"`
	Downloadable bool `json:"downloadable"`
}

// mbArtistResponse is the raw MusicBrainz API response for artist lookup
type mbArtistResponse struct {
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
		ID            string `json:"id"`
		Title         string `json:"title"`
		PrimaryType   string `json:"primary-type"`
		FirstReleaseDate string `json:"first-release-date"`
	} `json:"release-groups"`
}

// mbReleaseResponse is the raw MusicBrainz API response for release lookup
type mbReleaseResponse struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Date        string `json:"date"`
	Country     string `json:"country"`
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

// mbRecordingResponse is the raw MusicBrainz API response for recording lookup
type mbRecordingResponse struct {
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

// enforceRateLimit ensures we don't exceed MusicBrainz's rate limit
func (c *Client) enforceRateLimit() {
	c.rateLimitLock.Lock()
	defer c.rateLimitLock.Unlock()

	elapsed := time.Since(c.lastRequest)
	if elapsed < rateLimitDelay {
		time.Sleep(rateLimitDelay - elapsed)
	}
	c.lastRequest = time.Now()
}

// doRequest performs an HTTP request to the MusicBrainz API
func (c *Client) doRequest(ctx context.Context, endpoint string) ([]byte, error) {
	c.enforceRateLimit()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
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
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var body []byte
	body = make([]byte, 0, 1024*64)
	buf := make([]byte, 1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			body = append(body, buf[:n]...)
		}
		if err != nil {
			break
		}
	}

	return body, nil
}

// ErrNotFound is returned when a resource is not found
var ErrNotFound = fmt.Errorf("not found")

// GetArtist fetches artist details with discography from MusicBrainz
func (c *Client) GetArtist(ctx context.Context, mbID string) (*Artist, error) {
	endpoint := fmt.Sprintf("%s/artist/%s?fmt=json&inc=release-groups", baseURL, url.PathEscape(mbID))

	body, err := c.doRequest(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	var mbResp mbArtistResponse
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

	return artist, nil
}

// GetRelease fetches release/album details with track listing from MusicBrainz
func (c *Client) GetRelease(ctx context.Context, mbID string) (*Release, error) {
	endpoint := fmt.Sprintf("%s/release/%s?fmt=json&inc=artist-credits+recordings", baseURL, url.PathEscape(mbID))

	body, err := c.doRequest(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	var mbResp mbReleaseResponse
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

	return release, nil
}

// GetRecording fetches recording/track details from MusicBrainz
func (c *Client) GetRecording(ctx context.Context, mbID string) (*Track, error) {
	endpoint := fmt.Sprintf("%s/recording/%s?fmt=json&inc=artist-credits+releases", baseURL, url.PathEscape(mbID))

	body, err := c.doRequest(ctx, endpoint)
	if err != nil {
		return nil, err
	}

	var mbResp mbRecordingResponse
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

	return track, nil
}

// GetCoverArtURL returns the Cover Art Archive URL for a release
func (c *Client) GetCoverArtURL(releaseID string) string {
	return fmt.Sprintf("%s/release/%s/front-250", coverArtURL, releaseID)
}
