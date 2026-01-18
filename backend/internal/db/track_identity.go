package db

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"
	"unicode"

	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"
)

// TrackIdentity contains the normalized components used for identity hash calculation.
type TrackIdentity struct {
	Artist     string
	Title      string
	Album      string
	DurationMs int
	Version    string
}

// VersionInfo contains parsed version information from a track title.
type VersionInfo struct {
	CleanTitle string
	Version    string
}

// Common version patterns found in track titles.
var versionPatterns = []*regexp.Regexp{
	// Parentheses patterns
	regexp.MustCompile(`(?i)\s*\(radio\s*edit\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(extended\s*mix\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(extended\s*version\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(remix\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(([^)]+\s+)?remix\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(remaster(ed)?\)\s*$`),
	regexp.MustCompile(`(?i)\s*\((\d{4}\s+)?remaster(ed)?\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(live\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(live[^)]*\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(acoustic\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(acoustic\s*version\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(unplugged\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(instrumental\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(original\s*mix\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(club\s*mix\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(dub\s*mix\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(single\s*version\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(album\s*version\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(explicit\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(clean\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(bonus\s*track\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(deluxe\s*edition\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(feat\.\s*[^)]+\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(featuring\s+[^)]+\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(ft\.\s*[^)]+\)\s*$`),
	regexp.MustCompile(`(?i)\s*\(with\s+[^)]+\)\s*$`),

	// Bracket patterns
	regexp.MustCompile(`(?i)\s*\[radio\s*edit\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[extended\s*mix\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[remix\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[([^\]]+\s+)?remix\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[remaster(ed)?\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[live\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[live[^\]]*\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[acoustic\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[instrumental\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[original\s*mix\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[explicit\]\s*$`),
	regexp.MustCompile(`(?i)\s*\[clean\]\s*$`),

	// Dash patterns
	regexp.MustCompile(`(?i)\s+-\s*radio\s*edit\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*extended\s*mix\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*remix\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*.+\s+remix\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*remaster(ed)?\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*live\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*live\s+.+\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*acoustic\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*instrumental\s*$`),
	regexp.MustCompile(`(?i)\s+-\s*original\s*mix\s*$`),
}

// versionNormalization maps extracted version strings to canonical forms.
var versionNormalization = map[string]string{
	"radio edit":       "radio edit",
	"extended mix":     "extended mix",
	"extended version": "extended mix",
	"remix":            "remix",
	"remaster":         "remaster",
	"remastered":       "remaster",
	"live":             "live",
	"acoustic":         "acoustic",
	"acoustic version": "acoustic",
	"unplugged":        "acoustic",
	"instrumental":     "instrumental",
	"original mix":     "",
	"club mix":         "club mix",
	"dub mix":          "dub mix",
	"single version":   "",
	"album version":    "",
	"explicit":         "",
	"clean":            "clean",
	"bonus track":      "",
	"deluxe edition":   "",
}

// ExtractVersion parses a track title to extract version information.
// Returns the clean title (without version suffix) and the normalized version string.
// "Original Mix" and similar non-distinctive versions return empty string.
func ExtractVersion(title string) VersionInfo {
	if title == "" {
		return VersionInfo{CleanTitle: "", Version: ""}
	}

	cleanTitle := title
	var extractedVersion string

	// Try each pattern in order
	for _, pattern := range versionPatterns {
		if loc := pattern.FindStringIndex(cleanTitle); loc != nil {
			matched := cleanTitle[loc[0]:loc[1]]
			cleanTitle = strings.TrimSpace(cleanTitle[:loc[0]])
			extractedVersion = normalizeVersion(matched)
			break
		}
	}

	return VersionInfo{
		CleanTitle: cleanTitle,
		Version:    extractedVersion,
	}
}

// normalizeVersion converts an extracted version string to its canonical form.
func normalizeVersion(version string) string {
	// Remove brackets, parentheses, and leading dash
	cleaned := strings.ToLower(version)
	cleaned = strings.TrimSpace(cleaned)
	cleaned = strings.TrimPrefix(cleaned, "(")
	cleaned = strings.TrimSuffix(cleaned, ")")
	cleaned = strings.TrimPrefix(cleaned, "[")
	cleaned = strings.TrimSuffix(cleaned, "]")
	cleaned = strings.TrimPrefix(cleaned, "-")
	cleaned = strings.TrimSpace(cleaned)

	// Check for known versions
	if canonical, ok := versionNormalization[cleaned]; ok {
		return canonical
	}

	// Check for remix patterns (e.g., "Artist Name Remix")
	if strings.HasSuffix(cleaned, " remix") {
		return "remix"
	}

	// Check for live patterns (e.g., "Live at Wembley")
	if strings.HasPrefix(cleaned, "live") {
		return "live"
	}

	// Check for remaster patterns (e.g., "2020 Remastered")
	if strings.Contains(cleaned, "remaster") {
		return "remaster"
	}

	// Check for featuring patterns - don't treat as version
	if strings.HasPrefix(cleaned, "feat") || strings.HasPrefix(cleaned, "featuring") ||
		strings.HasPrefix(cleaned, "ft.") || strings.HasPrefix(cleaned, "with ") {
		return ""
	}

	return cleaned
}

// NormalizeString applies all normalization rules to a string:
// - Lowercase
// - Remove leading/trailing whitespace
// - Collapse multiple spaces
// - Remove common prefixes ("The ")
// - Transliterate accents
func NormalizeString(s string) string {
	if s == "" {
		return ""
	}

	// Transliterate accents to ASCII equivalents
	s = transliterate(s)

	// Collapse multiple spaces and trim first
	s = collapseSpaces(s)

	// Lowercase
	s = strings.ToLower(s)

	// Remove common prefixes (must happen after lowercase)
	s = removeCommonPrefixes(s)

	// Final trim
	s = strings.TrimSpace(s)

	return s
}

// transliterate converts accented characters to their ASCII equivalents.
func transliterate(s string) string {
	// Create a transformer that decomposes characters and removes combining marks
	t := transform.Chain(
		norm.NFD,
		runes.Remove(runes.In(unicode.Mn)), // Mn: Mark, Nonspacing
		norm.NFC,
	)

	result, _, err := transform.String(t, s)
	if err != nil {
		return s
	}
	return result
}

// removeCommonPrefixes removes "The " and similar prefixes from the beginning.
func removeCommonPrefixes(s string) string {
	prefixes := []string{"the ", "a ", "an "}
	lower := strings.ToLower(s)
	for _, prefix := range prefixes {
		if strings.HasPrefix(lower, prefix) {
			return s[len(prefix):]
		}
	}
	return s
}

// collapseSpaces replaces multiple consecutive spaces with a single space and trims.
func collapseSpaces(s string) string {
	// Use regexp to collapse multiple spaces
	space := regexp.MustCompile(`\s+`)
	return strings.TrimSpace(space.ReplaceAllString(s, " "))
}

// DurationBucket rounds duration to the nearest bucket for fuzzy matching.
// This allows tracks with slightly different durations to match.
func DurationBucket(durationMs, bucketSizeMs int) int {
	if durationMs <= 0 || bucketSizeMs <= 0 {
		return 0
	}
	return (durationMs / bucketSizeMs) * bucketSizeMs
}

// CalculateIdentityHash generates a unique identity hash for a track.
// The hash is based on normalized artist, title, album, duration bucket, and version.
// Returns a 16-character hex string (first 16 chars of SHA256).
func CalculateIdentityHash(artist, title, album string, durationMs int, version string) string {
	normalized := fmt.Sprintf("%s|%s|%s|%d|%s",
		NormalizeString(artist),
		NormalizeString(title),
		NormalizeString(album),
		DurationBucket(durationMs, 5000), // 5 second buckets
		NormalizeString(version),
	)

	hash := sha256.Sum256([]byte(normalized))
	return hex.EncodeToString(hash[:])[:16]
}

// CalculateIdentityHashFromTrack calculates the identity hash from a TrackIdentity struct.
func CalculateIdentityHashFromTrack(t TrackIdentity) string {
	return CalculateIdentityHash(t.Artist, t.Title, t.Album, t.DurationMs, t.Version)
}

// ParseTrackMetadata extracts identity components from raw track metadata.
// It normalizes the title by extracting version info.
func ParseTrackMetadata(artist, title, album string, durationMs int) TrackIdentity {
	versionInfo := ExtractVersion(title)
	return TrackIdentity{
		Artist:     artist,
		Title:      versionInfo.CleanTitle,
		Album:      album,
		DurationMs: durationMs,
		Version:    versionInfo.Version,
	}
}
