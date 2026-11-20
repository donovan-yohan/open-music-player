package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"golang.org/x/text/unicode/norm"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const (
	localEnrichmentPath          = "/api/v1/musicbrainz/local-enrichment/suggestions"
	localEnrichmentRequestBytes  = 4 << 10
	localEnrichmentFieldRunes    = 200
	localEnrichmentTotalRunes    = 450
	localEnrichmentMaxDurationMS = 86_400_000
	localEnrichmentMaxActive     = 4
	localEnrichmentBodyDeadline  = 2 * time.Second
	localEnrichmentDeadline      = 5 * time.Second
)

// Detect obvious identifiers, encoded paths, URIs and media filenames even
// inside allowed text fields. The terms are still user-reviewed free text;
// this is not a claim that arbitrary text can be classified by provenance.
var localEnrichmentSourceText = regexp.MustCompile(`(?i)(?:\b[a-z][a-z0-9+.-]*:[^\s]|\bwww\.|%[0-9a-f]{2}|\b[0-9a-f]{32,}\b|\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}\b|\.(?:mp3|m4a|mp4|m4b|aac|alac|flac|wav|wave|aif|aiff|aifc|ogg|oga|opus|wma|amr|ape|mka|mkv|webm|dsf|dff|m3u8?|pls)\b)`)

type localEnrichmentInput struct {
	title, artist, album string
	durationMS           int
}

type localEnrichmentCandidate struct {
	RecordingID    uuid.UUID  `json:"recordingMbid"`
	Title          string     `json:"title"`
	Artist         string     `json:"artist,omitempty"`
	Album          string     `json:"album,omitempty"`
	DurationMS     int        `json:"durationMs,omitempty"`
	ReleaseID      *uuid.UUID `json:"releaseMbid,omitempty"`
	ReleaseGroupID *uuid.UUID `json:"releaseGroupMbid,omitempty"`
}

type localEnrichmentResult struct {
	Status     string                     `json:"status"`
	Reason     string                     `json:"reason,omitempty"`
	Candidates []localEnrichmentCandidate `json:"candidates"`
}

// The only lookup dependency is the public metadata client. An active slot
// owns intake through lookup, stores no text and is removed on every exit.
type localEnrichmentHandler struct {
	client *musicbrainz.Client
	mu     sync.Mutex
	active map[uuid.UUID]struct{}
}

func (h *localEnrichmentHandler) admit(user uuid.UUID) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, waiting := h.active[user]; waiting || len(h.active) >= localEnrichmentMaxActive {
		return false
	}
	h.active[user] = struct{}{}
	return true
}

func (h *localEnrichmentHandler) release(user uuid.UUID) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.active, user)
}

func (h *localEnrichmentHandler) endpoint(authenticate func(http.HandlerFunc) http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		finishRead := func() error { return nil }
		if r.Body != nil && r.Body != http.NoBody {
			controller := http.NewResponseController(w)
			http1 := r.ProtoMajor == 1
			if http1 {
				// Do not let net/http drain a refused body before sending the
				// response. A fully consumed body may keep its connection.
				w.Header().Set("Connection", "close")
			}
			if err := controller.SetReadDeadline(time.Now().Add(localEnrichmentBodyDeadline)); err != nil {
				writeErrorResponse(w, http.StatusServiceUnavailable, "ENRICHMENT_UNAVAILABLE", "MusicBrainz enrichment is unavailable")
				return // never read a body if the writer cannot enforce its deadline
			}
			consumed := false
			defer func() {
				if http1 && !consumed {
					// finishRequest can still close/drain after the response.
					// If advancing the deadline fails, the installed bound remains.
					_ = controller.SetReadDeadline(time.Now())
				}
			}()
			finishRead = func() error {
				if err := controller.SetReadDeadline(time.Time{}); err != nil {
					return err
				}
				consumed = true
				if http1 {
					w.Header().Del("Connection")
				}
				return nil
			}
		}
		authenticate(func(w http.ResponseWriter, r *http.Request) { h.suggestions(w, r, finishRead) })(w, r)
	}
}

func (h *localEnrichmentHandler) suggestions(w http.ResponseWriter, r *http.Request, finishRead func() error) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writeErrorResponse(w, http.StatusUnauthorized, "UNAUTHORIZED", "Authentication is required")
		return
	}
	if r.URL.RawQuery != "" || r.URL.ForceQuery || r.URL.EscapedPath() != localEnrichmentPath {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ENRICHMENT_REQUEST", "Send only the enrichment JSON body")
		return
	}
	media, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	charset, hasCharset := params["charset"]
	if err != nil || media != "application/json" || len(r.Header.Values("Content-Type")) != 1 || len(r.Header.Values("Content-Encoding")) != 0 ||
		len(params) > 1 || (len(params) == 1 && (!hasCharset || !strings.EqualFold(charset, "utf-8"))) {
		writeErrorResponse(w, http.StatusUnsupportedMediaType, "INVALID_ENRICHMENT_MEDIA", "Send uncompressed UTF-8 JSON")
		return
	}
	if r.ContentLength > localEnrichmentRequestBytes {
		writeErrorResponse(w, http.StatusRequestEntityTooLarge, "ENRICHMENT_REQUEST_TOO_LARGE", "Enrichment request is too large")
		return
	}
	if !h.admit(user.UserID) {
		writeErrorResponse(w, http.StatusTooManyRequests, "ENRICHMENT_BUSY", "MusicBrainz enrichment is busy")
		return
	}
	defer h.release(user.UserID)
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, localEnrichmentRequestBytes))
	var over *http.MaxBytesError
	if errors.As(err, &over) {
		writeErrorResponse(w, http.StatusRequestEntityTooLarge, "ENRICHMENT_REQUEST_TOO_LARGE", "Enrichment request is too large")
		return
	}
	if errors.Is(err, os.ErrDeadlineExceeded) {
		writeErrorResponse(w, http.StatusRequestTimeout, "ENRICHMENT_BODY_TIMEOUT", "Enrichment request body timed out")
		return
	}
	if err == nil {
		if err := finishRead(); err != nil {
			writeErrorResponse(w, http.StatusServiceUnavailable, "ENRICHMENT_UNAVAILABLE", "MusicBrainz enrichment is unavailable")
			return
		}
	}
	input, ok := decodeLocalEnrichment(body)
	if err != nil || !ok {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ENRICHMENT_REQUEST", "Provide valid title, artist, album and duration terms only")
		return
	}
	if h.client == nil {
		writeErrorResponse(w, http.StatusServiceUnavailable, "ENRICHMENT_UNAVAILABLE", "MusicBrainz enrichment is unavailable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), localEnrichmentDeadline)
	defer cancel()

	recordings, err := h.client.SearchLocalEnrichment(ctx, input.title, input.artist)
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		writeErrorResponse(w, http.StatusGatewayTimeout, "ENRICHMENT_TIMEOUT", "MusicBrainz enrichment timed out")
	case errors.Is(err, context.Canceled):
		writeErrorResponse(w, http.StatusRequestTimeout, "ENRICHMENT_CANCELED", "MusicBrainz enrichment was canceled")
	case err != nil:
		writeErrorResponse(w, http.StatusServiceUnavailable, "ENRICHMENT_UNAVAILABLE", "MusicBrainz enrichment is unavailable")
	default:
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(rankLocalEnrichment(input, recordings))
	}
}

func decodeLocalEnrichment(body []byte) (localEnrichmentInput, bool) {
	var input localEnrichmentInput
	if !utf8.Valid(body) {
		return input, false
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if start, err := dec.Token(); err != nil || start != json.Delim('{') {
		return input, false
	}
	seen := make(map[string]bool, 4)
	total := 0
	for dec.More() {
		token, err := dec.Token()
		key, isString := token.(string)
		if err != nil || !isString || seen[key] {
			return input, false
		}
		seen[key] = true
		value, err := dec.Token()
		if err != nil {
			return input, false
		}
		switch key {
		case "title", "artist", "album":
			text, isString := value.(string)
			if !isString || !validLocalEnrichmentText(text) {
				return input, false
			}
			total += utf8.RuneCountInString(text)
			text = strings.TrimSpace(text)
			if text == "" || !strings.ContainsFunc(text, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsNumber(r) }) {
				return input, false
			}
			folded := norm.NFKC.String(text)
			if strings.ContainsAny(folded, `/\∕⁄⧵`) || localEnrichmentSourceText.MatchString(folded) {
				return input, false
			}
			switch key {
			case "title":
				input.title = text
			case "artist":
				input.artist = text
			case "album":
				input.album = text
			}
		case "durationMs":
			n, ok := value.(json.Number)
			if !ok {
				return input, false
			}
			ms, err := strconv.Atoi(n.String())
			if err != nil || ms <= 0 || ms > localEnrichmentMaxDurationMS {
				return input, false
			}
			input.durationMS = ms
		default:
			return input, false
		}
	}
	if end, err := dec.Token(); err != nil || end != json.Delim('}') {
		return input, false
	}
	_, err := dec.Token()
	return input, err == io.EOF && input.title != "" && total <= localEnrichmentTotalRunes
}

// Go's JSON decoder substitutes U+FFFD for unpaired escaped surrogates.
// Reject that sentinel rather than silently changing approved text. The same
// rune bound on response text keeps three encoded candidates well under 32 KiB.
func validLocalEnrichmentText(text string) bool {
	return utf8.RuneCountInString(text) <= localEnrichmentFieldRunes && !strings.ContainsFunc(text, func(r rune) bool {
		return r == utf8.RuneError || !unicode.IsPrint(r)
	})
}

func localEnrichmentDisplay(text string) string {
	if !validLocalEnrichmentText(text) {
		return ""
	}
	return strings.TrimSpace(text)
}

func localEnrichmentMBID(raw string) *uuid.UUID {
	id, err := uuid.Parse(raw)
	if err != nil || id == uuid.Nil || id.String() != raw {
		return nil
	}
	return &id
}

func rankLocalEnrichment(input localEnrichmentInput, recordings []musicbrainz.LocalRecording) localEnrichmentResult {
	type ranked struct {
		candidate localEnrichmentCandidate
		score     float64
	}
	parsed := &matcher.ParsedTitle{Track: input.title, Artist: input.artist}
	// Explicit tags are text evidence, not a stream title/uploader heuristic.
	weights := matcher.DefaultWeights
	if input.artist == "" {
		weights.TrackWeight += weights.ArtistWeight
		weights.ArtistWeight = 0
	}
	if input.durationMS == 0 {
		weights.TrackWeight += weights.DurationWeight
		weights.DurationWeight = 0
	}
	rankedCandidates := make([]ranked, 0, len(recordings))
	for _, r := range recordings {
		id, title := localEnrichmentMBID(r.ID), localEnrichmentDisplay(r.Title)
		if id == nil || title == "" {
			continue
		}
		artist, album := localEnrichmentDisplay(r.Artist), localEnrichmentDisplay(r.Album)
		duration := r.DurationMS
		if duration < 0 || duration > localEnrichmentMaxDurationMS {
			duration = 0
		}
		score := matcher.CalculateScore(parsed, artist, title, input.durationMS, duration, 0, weights)
		if score.TrackScore < 75 || score.Overall < 65 {
			continue
		}
		value := score.Overall
		if input.album != "" && album != "" {
			albumScore := matcher.CalculateScore(&matcher.ParsedTitle{Track: input.album}, "", album, 0, 0, 0, matcher.ScoreWeights{TrackWeight: 1})
			value += albumScore.TrackScore * 0.10
		}
		rankedCandidates = append(rankedCandidates, ranked{localEnrichmentCandidate{
			RecordingID: *id, Title: title, Artist: artist, Album: album, DurationMS: duration,
			ReleaseID: localEnrichmentMBID(r.ReleaseID), ReleaseGroupID: localEnrichmentMBID(r.ReleaseGroupID),
		}, value})
	}
	sort.SliceStable(rankedCandidates, func(i, j int) bool {
		a, b := rankedCandidates[i], rankedCandidates[j]
		if a.score != b.score {
			return a.score > b.score
		}
		return a.candidate.RecordingID.String() < b.candidate.RecordingID.String()
	})
	out := localEnrichmentResult{Status: "no_match", Candidates: make([]localEnrichmentCandidate, 0, 3)}
	seen := make(map[uuid.UUID]bool, 3)
	for _, r := range rankedCandidates {
		if seen[r.candidate.RecordingID] {
			continue
		}
		seen[r.candidate.RecordingID] = true
		if len(out.Candidates) == 0 {
			out.Status = "suggestions"
		} else if len(out.Candidates) == 1 && rankedCandidates[0].score-r.score <= 8 {
			out.Status, out.Reason = "ambiguous", "similar_candidates"
		}
		out.Candidates = append(out.Candidates, r.candidate)
		if len(out.Candidates) == 3 {
			break
		}
	}
	return out
}
