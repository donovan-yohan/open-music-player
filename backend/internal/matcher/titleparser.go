package matcher

import (
	"regexp"
	"strings"
)

// ParsedTitle contains extracted artist and track information from a title
type ParsedTitle struct {
	Artist      string   `json:"artist"`
	Track       string   `json:"track"`
	Featuring   []string `json:"featuring,omitempty"`
	IsRemix     bool     `json:"is_remix"`
	RemixArtist string   `json:"remix_artist,omitempty"`
	Raw         string   `json:"raw"`
}

var (
	// Patterns for "Artist - Track" format (most common)
	dashPattern = regexp.MustCompile(`^(.+?)\s*[-–—]\s*(.+)$`)

	// Patterns for "Track by Artist" format
	byPattern = regexp.MustCompile(`(?i)^(.+?)\s+by\s+(.+)$`)

	// Patterns for featuring artists
	featPatterns = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s*([^\)\]]+)[\)\]]`),
		regexp.MustCompile(`(?i)\s+(?:feat\.?|ft\.?|featuring)\s+(.+?)(?:\s*[-–—]|$)`),
	}

	// Patterns for video suffixes to remove
	videoSuffixes = regexp.MustCompile(`(?i)(?:\s*[\(\[]\s*(?:official\s*(?:video|audio|music\s*video|lyric\s*video|visualizer)|lyric\s*video|lyrics?|audio|video|hd|hq|4k|1080p|720p|m/v|mv)\s*[\)\]]|\s+(?:hd|hq|4k|1080p|720p))\s*$`)

	// Patterns for remix detection
	remixPattern = regexp.MustCompile(`(?i)[\(\[]\s*(.+?)\s*(?:remix|edit|mix|bootleg|flip|rework)\s*[\)\]]`)

	// Pattern for quoted track titles: Artist "Track"
	quotedPattern = regexp.MustCompile(`^(.+?)\s*[""](.+?)[""]`)

	// Clean up extra whitespace
	multiSpace = regexp.MustCompile(`\s+`)
)

// ParseTitle extracts artist and track information from a video title
func ParseTitle(title string) *ParsedTitle {
	result := &ParsedTitle{
		Raw: title,
	}

	// Clean up the title
	cleaned := cleanTitle(title)

	// Extract featuring artists first (before main parsing)
	cleaned, featuring := extractFeaturing(cleaned)
	result.Featuring = featuring

	// Check for remix
	if match := remixPattern.FindStringSubmatch(cleaned); match != nil {
		result.IsRemix = true
		result.RemixArtist = strings.TrimSpace(match[1])
		// Remove remix info from title for cleaner matching
		cleaned = remixPattern.ReplaceAllString(cleaned, "")
		cleaned = strings.TrimSpace(cleaned)
	}

	// Try different parsing strategies in order of reliability

	// 1. Try "Artist - Track" format (most common for music)
	if match := dashPattern.FindStringSubmatch(cleaned); match != nil {
		artist := strings.TrimSpace(match[1])
		track := strings.TrimSpace(match[2])

		// Sometimes it's "Track - Artist" instead
		// Heuristic: if the second part looks like it could be an artist name
		// (shorter, no common track suffixes), swap them
		if looksLikeArtistName(track) && !looksLikeArtistName(artist) {
			artist, track = track, artist
		}

		result.Artist = cleanArtist(artist)
		result.Track = cleanTrack(track)
		return result
	}

	// 2. Try quoted format: Artist "Track"
	if match := quotedPattern.FindStringSubmatch(cleaned); match != nil {
		result.Artist = cleanArtist(strings.TrimSpace(match[1]))
		result.Track = cleanTrack(strings.TrimSpace(match[2]))
		return result
	}

	// 3. Try "Track by Artist" format
	if match := byPattern.FindStringSubmatch(cleaned); match != nil {
		result.Track = cleanTrack(strings.TrimSpace(match[1]))
		result.Artist = cleanArtist(strings.TrimSpace(match[2]))
		return result
	}

	// 4. Fallback: use entire cleaned title as track, no artist
	result.Track = cleanTrack(cleaned)

	return result
}

// cleanTitle removes common video suffixes and normalizes whitespace
func cleanTitle(title string) string {
	// Remove video-related suffixes
	cleaned := videoSuffixes.ReplaceAllString(title, "")

	// Normalize whitespace
	cleaned = multiSpace.ReplaceAllString(cleaned, " ")
	cleaned = strings.TrimSpace(cleaned)

	return cleaned
}

// extractFeaturing extracts featuring artists from the title
func extractFeaturing(title string) (string, []string) {
	var featuring []string
	cleaned := title

	for _, pattern := range featPatterns {
		matches := pattern.FindAllStringSubmatch(cleaned, -1)
		for _, match := range matches {
			if len(match) > 1 {
				// Split multiple featuring artists (e.g., "Artist1 & Artist2")
				featArtists := splitArtists(match[1])
				featuring = append(featuring, featArtists...)
			}
		}
		// Remove the featuring part from the title
		cleaned = pattern.ReplaceAllString(cleaned, "")
	}

	return strings.TrimSpace(cleaned), featuring
}

// splitArtists splits a string containing multiple artists
func splitArtists(artists string) []string {
	// Split on common delimiters
	delimiters := regexp.MustCompile(`\s*[,&]\s*|\s+and\s+`)
	parts := delimiters.Split(artists, -1)

	var result []string
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}

// cleanArtist cleans up an artist name
func cleanArtist(artist string) string {
	// Remove topic channel suffix
	artist = regexp.MustCompile(`(?i)\s*[-–—]\s*topic\s*$`).ReplaceAllString(artist, "")

	// Remove VEVO suffix
	artist = regexp.MustCompile(`(?i)VEVO\s*$`).ReplaceAllString(artist, "")

	// Normalize whitespace
	artist = multiSpace.ReplaceAllString(artist, " ")

	return strings.TrimSpace(artist)
}

// cleanTrack cleans up a track title
func cleanTrack(track string) string {
	// Remove year in parentheses at the end
	track = regexp.MustCompile(`\s*[\(\[]\d{4}[\)\]]\s*$`).ReplaceAllString(track, "")

	// Remove "Remastered" tags
	track = regexp.MustCompile(`(?i)\s*[\(\[]?\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*[\)\]]?\s*$`).ReplaceAllString(track, "")

	// Normalize whitespace
	track = multiSpace.ReplaceAllString(track, " ")

	return strings.TrimSpace(track)
}

// looksLikeArtistName uses heuristics to determine if a string looks like an artist name
func looksLikeArtistName(s string) bool {
	// Artist names tend to be shorter
	if len(s) > 40 {
		return false
	}

	// Check for common track-like patterns (these suggest it's NOT an artist)
	trackPatterns := []string{
		`(?i)remix`,
		`(?i)version`,
		`(?i)edit`,
		`(?i)mix`,
		`(?i)remaster`,
		`(?i)live`,
		`(?i)acoustic`,
		`(?i)instrumental`,
	}

	for _, pattern := range trackPatterns {
		if matched, _ := regexp.MatchString(pattern, s); matched {
			return false
		}
	}

	// Check for parenthetical content (more common in track names)
	if strings.Contains(s, "(") || strings.Contains(s, "[") {
		return false
	}

	return true
}
