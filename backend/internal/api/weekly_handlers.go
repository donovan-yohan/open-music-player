package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/weekly"
)

func (r *Router) withWeeklyAuth(next http.HandlerFunc) http.HandlerFunc {
	authenticated := r.withAuth(next)
	return func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		authenticated(w, req)
	}
}

type WeeklyHandlers struct {
	service *weekly.Service
	now     func() time.Time
}

func NewWeeklyHandlers(store weekly.Store, catalog weekly.Catalog) *WeeklyHandlers {
	return &WeeklyHandlers{weekly.NewService(store, catalog), time.Now}
}
func (h *WeeklyHandlers) actor(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	w.Header().Set("Cache-Control", "private, no-store")
	a := auth.GetUserFromContext(r.Context())
	if a == nil || a.UserID == uuid.Nil {
		writePlayEventError(w, 401, "UNAUTHORIZED", "authentication required")
		return uuid.Nil, false
	}
	if h == nil || h.service == nil {
		writePlayEventError(w, 503, "WEEKLY_UNAVAILABLE", "weekly discovery is unavailable")
		return uuid.Nil, false
	}
	return a.UserID, true
}
func weeklyResult(w http.ResponseWriter, v any, e error) {
	if e != nil {
		var c *weekly.Conflict
		var r *weekly.Refusal
		if errors.As(e, &c) {
			writePlayEventJSON(w, 409, c)
		} else if errors.As(e, &r) {
			writePlayEventError(w, r.Status, r.Code, r.Detail)
		} else {
			writePlayEventError(w, 503, "WEEKLY_UNAVAILABLE", "discovery preferences are unavailable")
		}
		return
	}
	b, e := json.Marshal(v)
	if e != nil || len(b) > weekly.MaxResponseBytes {
		writePlayEventError(w, 503, "WEEKLY_UNAVAILABLE", "response unavailable")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	w.Write(b)
}
func weeklyDecode(w http.ResponseWriter, r *http.Request, out any, required ...string) bool {
	if r.URL.RawQuery != "" {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "query parameters are not supported")
		return false
	}
	body, e := io.ReadAll(io.LimitReader(r.Body, 8193))
	if e != nil || len(body) > 8192 {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "request body exceeds bound")
		return false
	}
	var fields map[string]json.RawMessage
	if e = json.Unmarshal(body, &fields); e != nil || fields == nil {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "JSON object required")
		return false
	}
	for _, k := range required {
		v, ok := fields[k]
		if !ok || (string(v) == "null" && k != "batchId") {
			writePlayEventError(w, 400, "VALIDATION_ERROR", "required field missing or null")
			return false
		}
	}
	// All callers supply flat write DTOs. Check their exact JSON tags before
	// encoding/json's case-insensitive struct matching can overwrite a value.
	allowed := map[string]bool{}
	typ := reflect.TypeOf(out).Elem()
	for n := 0; n < typ.NumField(); n++ {
		name, _, _ := strings.Cut(typ.Field(n).Tag.Get("json"), ",")
		if name != "" && name != "-" {
			allowed[name] = true
		}
	}
	// Detect duplicate keys as well as unknown keys. Ordinary Unmarshal silently
	// accepts duplicate mutation/epoch fields, making payload identity ambiguous.
	dec := json.NewDecoder(bytes.NewReader(body))
	if _, e = dec.Token(); e != nil {
		return false
	}
	seen := map[string]bool{}
	for dec.More() {
		key, e := dec.Token()
		if e != nil {
			return false
		}
		k, ok := key.(string)
		if !ok || !allowed[k] || seen[k] {
			writePlayEventError(w, 400, "VALIDATION_ERROR", "unknown or duplicate JSON field")
			return false
		}
		seen[k] = true
		var value json.RawMessage
		if e = dec.Decode(&value); e != nil {
			writePlayEventError(w, 400, "VALIDATION_ERROR", "invalid JSON")
			return false
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if e = decoder.Decode(out); e != nil {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "invalid request fields")
		return false
	}
	return true
}
func (h *WeeklyHandlers) Weekly(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	if r.URL.RawQuery != "" {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "query parameters are not supported")
		return
	}
	v, e := h.service.Read(r.Context(), u, h.now)
	weeklyResult(w, v, e)
}
func (h *WeeklyHandlers) Preferences(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	q, queryError := url.ParseQuery(r.URL.RawQuery)
	if queryError != nil {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "malformed pagination query")
		return
	}
	for k, v := range q {
		if (k != "limit" && k != "feedbackCursor" && k != "artistCursor" && k != "preferenceRevision") || len(v) != 1 {
			writePlayEventError(w, 400, "VALIDATION_ERROR", "invalid pagination query")
			return
		}
	}
	query := weekly.PageQuery{FeedbackCursor: q.Get("feedbackCursor"), ArtistCursor: q.Get("artistCursor")}
	if raw := q.Get("limit"); raw != "" {
		n, e := strconv.Atoi(raw)
		if e != nil || n < 1 || n > 50 {
			writePlayEventError(w, 400, "VALIDATION_ERROR", "invalid limit")
			return
		}
		query.Limit = n
	}
	if raw := q.Get("preferenceRevision"); raw != "" {
		n, e := strconv.ParseInt(raw, 10, 64)
		if e != nil || n < 0 {
			writePlayEventError(w, 400, "VALIDATION_ERROR", "invalid preference revision")
			return
		}
		query.PreferenceRevision = &n
	}
	v, e := h.service.Preferences(r.Context(), u, query, h.now())
	weeklyResult(w, v, e)
}
func (h *WeeklyHandlers) GetFeedback(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	if r.URL.RawQuery != "" {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "query parameters are not supported")
		return
	}
	v, e := h.service.Feedback(r.Context(), u, r.PathValue("recordingMbid"))
	weeklyResult(w, v, e)
}
func (h *WeeklyHandlers) PutFeedback(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	var input weekly.FeedbackWrite
	if !weeklyDecode(w, r, &input, "vote", "mutationId", "expectedRevision", "profileEpoch", "batchId") {
		return
	}
	v, e := h.service.WriteFeedback(r.Context(), u, r.PathValue("recordingMbid"), input, h.now())
	weeklyResult(w, v, e)
}
func (h *WeeklyHandlers) PutPreferences(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	var input weekly.PreferenceWrite
	if !weeklyDecode(w, r, &input, "resource", "mutationId", "expectedRevision", "profileEpoch") {
		return
	}
	v, e := h.service.WritePreference(r.Context(), u, input, h.now())
	weeklyResult(w, v, e)
}
func (h *WeeklyHandlers) Reset(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	var input weekly.ResetWrite
	if !weeklyDecode(w, r, &input, "mutationId", "expectedRevision", "profileEpoch", "scope") {
		return
	}
	v, e := h.service.Reset(r.Context(), u, input)
	weeklyResult(w, v, e)
}
func (h *WeeklyHandlers) Export(w http.ResponseWriter, r *http.Request) {
	u, ok := h.actor(w, r)
	if !ok {
		return
	}
	if r.URL.RawQuery != "" {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "query parameters are not supported")
		return
	}
	v, e := h.service.Export(r.Context(), u)
	weeklyResult(w, v, e)
}
