package discovery

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/validators"
)

// resolveURLMaxRequestBodyBytes caps the resolve-url request body before JSON
// decoding. The body is a single pasted URL, so 64 KiB is generous while still
// rejecting abusive payloads.
const resolveURLMaxRequestBodyBytes = 64 * 1024

// Resolver failure codes. They are deliberately distinct from the provider
// search codes (ErrProvider*) so callers such as #75 assist and #76 UI can
// branch on resolver-specific outcomes without colliding with search errors.
const (
	ErrResolveURLRequired    = "RESOLVE_URL_REQUIRED"
	ErrResolveInvalidURL     = "RESOLVE_INVALID_URL"
	ErrResolveUnsupportedURL = "RESOLVE_UNSUPPORTED_URL"
)

// ResolveError is a typed resolver failure carrying a stable machine code so the
// HTTP layer (and future assist callers) can map outcomes without string
// matching. A non-nil ResolveError always means no candidate was produced, so
// nothing downstream can be enqueued or downloaded from a rejected URL.
type ResolveError struct {
	Code    string
	Message string
}

func (e *ResolveError) Error() string { return e.Message }

func newResolveError(code, message string) *ResolveError {
	return &ResolveError{Code: code, Message: message}
}

// URLResolver turns a single user-pasted source URL into a grounded discovery
// candidate. It reuses the existing URL validators for provider detection and
// download.ValidateUserFacingURL for scheme/safety gating, so it never invents a
// source the rest of the pipeline could not already accept. It performs no
// network calls and holds no queue or download dependency: by construction it
// cannot start a download or mutate the queue.
type URLResolver struct {
	registry *validators.Registry
}

// NewURLResolver builds a resolver over the given validator registry, falling
// back to the default YouTube/SoundCloud registry when nil.
func NewURLResolver(registry *validators.Registry) *URLResolver {
	if registry == nil {
		registry = validators.DefaultRegistry()
	}
	return &URLResolver{registry: registry}
}

// validatorRegistry returns the configured registry, falling back to the default
// registry when the resolver is zero-valued (registry nil). This keeps a
// var-declared URLResolver safe to call without NewURLResolver.
func (r *URLResolver) validatorRegistry() *validators.Registry {
	if r.registry != nil {
		return r.registry
	}
	return validators.DefaultRegistry()
}

// Resolve normalizes a pasted URL into one non-playable, downloadable candidate.
// The candidate is queueable through the existing POST /api/v1/queue/items
// contract but is never queued here. Failures are typed *ResolveError values.
func (r *URLResolver) Resolve(rawURL string) (Candidate, error) {
	trimmed := strings.TrimSpace(rawURL)
	if trimmed == "" {
		return Candidate{}, newResolveError(ErrResolveURLRequired, "url is required")
	}
	// Gate on the same validation the queue ingress uses so any candidate this
	// resolver emits is guaranteed to pass the queue's URL check. This rejects
	// non-http(s), unsafe, relative, protocol-relative, and malformed URLs.
	if err := download.ValidateUserFacingURL(trimmed); err != nil {
		return Candidate{}, newResolveError(ErrResolveInvalidURL, "url must be an absolute http(s) URL")
	}

	result := r.validatorRegistry().Validate(trimmed)
	if result.SourceType == validators.SourceUnknown {
		return Candidate{}, newResolveError(ErrResolveUnsupportedURL, "url is not a supported source")
	}
	if !result.Valid {
		message := strings.TrimSpace(result.Error)
		if message == "" {
			message = "url could not be resolved to a source"
		}
		return Candidate{}, newResolveError(ErrResolveUnsupportedURL, message)
	}

	provider := string(result.SourceType)
	// A valid validators result always carries a canonical absolute https URL, so
	// the stored source URL is clean and stable rather than the raw pasted form.
	sourceURL := result.Canonical
	return Candidate{
		CandidateID:  buildCandidateID(provider, result.MediaID, sourceURL),
		Provider:     provider,
		SourceID:     result.MediaID,
		SourceURL:    sourceURL,
		Title:        resolveTitle(result),
		Downloadable: true,
		Playable:     false,
		Metadata: map[string]interface{}{
			"resolvedFrom":  "direct_url",
			"mediaType":     result.MediaType,
			"titleResolved": false,
		},
	}, nil
}

// resolveTitle derives a best-effort, offline display title from the parsed URL.
// It is never authoritative (metadata.titleResolved is false); the real title is
// fetched by the download worker only after the user explicitly queues the
// candidate. It always returns a non-empty string so the candidate stays
// queueable (the queue requires a title).
func resolveTitle(result validators.ValidationResult) string {
	segment := lastSegment(result.MediaID)
	// SoundCloud media IDs end in a human-readable slug (e.g. "artist/track-name").
	// YouTube IDs are opaque, so we leave them as-is rather than mangling them.
	if result.SourceType == validators.SourceSoundCloud {
		if title := humanizeSlug(segment); title != "" {
			return title
		}
	}
	if segment != "" {
		return segment
	}
	return "Pasted source"
}

// humanizeSlug turns a hyphen/underscore separated slug into a spaced title. It
// returns "" for slugs with no separators so callers fall back to a non-derived
// placeholder instead of presenting an opaque ID as a title.
func humanizeSlug(slug string) string {
	if !strings.ContainsAny(slug, "-_") {
		return ""
	}
	fields := strings.FieldsFunc(slug, func(r rune) bool { return r == '-' || r == '_' })
	return strings.Join(fields, " ")
}

func lastSegment(mediaID string) string {
	trimmed := strings.Trim(strings.TrimSpace(mediaID), "/")
	if trimmed == "" {
		return ""
	}
	parts := strings.Split(trimmed, "/")
	return parts[len(parts)-1]
}

// ResolveURLRequest is the POST /api/v1/discovery/resolve-url request body.
type ResolveURLRequest struct {
	URL string `json:"url"`
}

// ResolveURLResponse wraps the single resolved candidate. It is intentionally a
// thin envelope so #75/#76 can grow the response without a breaking change.
type ResolveURLResponse struct {
	Candidate Candidate `json:"candidate"`
}

// ResolveURL handles POST /api/v1/discovery/resolve-url. It converts one pasted
// source URL into a downloadable, non-playable candidate. It starts no download
// and mutates no queue. Resolver failures are contained here and never affect
// GET /api/v1/discovery/search, which runs through a separate code path.
func (h *Handlers) ResolveURL(w http.ResponseWriter, r *http.Request) {
	if h.resolver == nil {
		writeError(w, http.StatusServiceUnavailable, "RESOLVER_DISABLED", "url resolver is unavailable")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, resolveURLMaxRequestBodyBytes)
	var req ResolveURLRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	candidate, err := h.resolver.Resolve(req.URL)
	if err != nil {
		var resolveErr *ResolveError
		if errors.As(err, &resolveErr) {
			status := http.StatusUnprocessableEntity
			if resolveErr.Code == ErrResolveURLRequired {
				status = http.StatusBadRequest
			}
			writeError(w, status, resolveErr.Code, resolveErr.Message)
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to resolve url")
		return
	}

	writeJSON(w, http.StatusOK, ResolveURLResponse{Candidate: candidate})
}
