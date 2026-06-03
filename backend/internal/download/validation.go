package download

import (
	"fmt"
	"net/url"
	"strings"
)

// ValidateUserFacingURL rejects local/test-only schemes at authenticated API ingress.
// Internal worker tests may still create fixture:// or file:// jobs directly.
func ValidateUserFacingURL(raw string) error {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return fmt.Errorf("url is required")
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return fmt.Errorf("url must be an absolute http(s) URL")
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
		return nil
	default:
		return fmt.Errorf("url scheme %q is not allowed", parsed.Scheme)
	}
}
