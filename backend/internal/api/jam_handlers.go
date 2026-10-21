package api

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/jam"
	"net"
	"net/http"
	"strings"
)

// Parent supplies generation-checked account context and actual Connect lease
// validation. A device UUID is never writer authorization. Nil fails closed.
type JamOwnerResolver func(*http.Request) (jam.Owner, error)
type JamWriterValidator func(context.Context, jam.Owner, jam.Proof) error
type JamHandlers struct {
	repo    *jam.Repository
	limiter jam.Limiter
	owner   JamOwnerResolver
	writer  JamWriterValidator
}

func NewJamHandlers(r *jam.Repository, l jam.Limiter, o JamOwnerResolver, v JamWriterValidator) *JamHandlers {
	return &JamHandlers{r, l, o, v}
}
func jamHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", "application/json")
}
func jamReply(w http.ResponseWriter, status int, v any) {
	w.WriteHeader(status)
	if v != nil {
		json.NewEncoder(w).Encode(v)
	}
}
func jamError(w http.ResponseWriter, e error) {
	status := 503
	code := "JAM_UNAVAILABLE"
	switch {
	case errors.Is(e, jam.ErrDenied):
		status = 403
		code = "JAM_UNAVAILABLE"
	case errors.Is(e, jam.ErrInvalid):
		status = 400
		code = "INVALID_JAM_INPUT"
	case errors.Is(e, jam.ErrConflict):
		status = 409
		code = "JAM_CONFLICT"
	case errors.Is(e, jam.ErrCapacity):
		status = 409
		code = "JAM_CAPACITY"
	case errors.Is(e, jam.ErrLimited):
		status = 429
		code = "JAM_RATE_LIMITED"
		w.Header().Set("Retry-After", "60")
	}
	jamReply(w, status, map[string]string{"code": code})
}
func jamID(r *http.Request) uuid.UUID {
	s := r.PathValue("jamId")
	id, e := uuid.Parse(s)
	if e != nil || id.String() != s {
		return uuid.Nil
	}
	return id
}
func jamBearer(r *http.Request) string {
	a := r.Header.Get("Authorization")
	if !strings.HasPrefix(a, "Bearer ") {
		return ""
	}
	s := strings.TrimPrefix(a, "Bearer ")
	if !jam.ValidSecret(s) {
		return ""
	}
	return s
}
func (h *JamHandlers) limit(r *http.Request, action string) error {
	ip, _, e := net.SplitHostPort(r.RemoteAddr)
	if e != nil {
		ip = r.RemoteAddr
	}
	return h.limiter.Allow(r.Context(), jam.LimitInput{Action: action, RemoteIP: ip, JamID: r.PathValue("jamId"), MemberSecret: jamBearer(r)})
}
func (h *JamHandlers) guest(action string, f func(http.ResponseWriter, *http.Request)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		jamHeaders(w)
		if r.URL.RawQuery != "" {
			jamError(w, jam.ErrInvalid)
			return
		}
		if h == nil || h.repo == nil || h.limiter == nil {
			jamError(w, jam.ErrUnavailable)
			return
		}
		if e := h.limit(r, action); e != nil {
			jamError(w, e)
			return
		}
		if jamID(r) == uuid.Nil {
			jamError(w, jam.ErrDenied)
			return
		}
		f(w, r)
	}
}
func (h *JamHandlers) host(f func(http.ResponseWriter, *http.Request, jam.Owner)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		jamHeaders(w)
		if r.URL.RawQuery != "" {
			jamError(w, jam.ErrInvalid)
			return
		}
		if h == nil || h.repo == nil || h.limiter == nil || h.owner == nil || h.writer == nil {
			jamError(w, jam.ErrUnavailable)
			return
		}
		o, e := h.owner(r)
		if e != nil || o.UserID == uuid.Nil {
			jamError(w, jam.ErrDenied)
			return
		}
		action := "hostWrite"
		if r.Method == http.MethodGet {
			action = "hostRead"
		} else if strings.HasSuffix(r.URL.Path, "/host") {
			action = "host"
		}
		if e = h.limit(r, action); e != nil {
			jamError(w, e)
			return
		}
		f(w, r, o)
	}
}
func (h *JamHandlers) validate(r *http.Request, o jam.Owner, p jam.Proof) error {
	if h.writer == nil {
		return jam.ErrUnavailable
	}
	if e := h.writer(r.Context(), o, p); e != nil {
		if errors.Is(e, jam.ErrUnavailable) {
			return jam.ErrUnavailable
		}
		return jam.ErrDenied
	}
	return nil
}
func jamBody(w http.ResponseWriter, r *http.Request, v any, n int64) bool {
	if e := jamDecode(w, r, v, n); e != nil {
		jamError(w, jam.ErrInvalid)
		return false
	}
	return true
}

// RegisterGuestRoutes must be on a separate public capability scope, NOT
// wrapped with account authentication or account refresh middleware.
func (h *JamHandlers) RegisterGuestRoutes(m *http.ServeMux) {
	base := "/api/v1/guest/jams/{jamId}"
	m.HandleFunc("POST "+base+"/members", h.guest("join", func(w http.ResponseWriter, r *http.Request) {
		var in jam.JoinInput
		if !jamBody(w, r, &in, 2048) {
			return
		}
		v, e := h.repo.Join(r.Context(), jamID(r), in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 201, v)
	}))
	m.HandleFunc("GET "+base, h.guest("read", func(w http.ResponseWriter, r *http.Request) {
		v, e := h.repo.GuestSnapshot(r.Context(), jamID(r), jamBearer(r))
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, v)
	}))
	m.HandleFunc("POST "+base+"/requests", h.guest("request", func(w http.ResponseWriter, r *http.Request) {
		var in jam.RequestInput
		if !jamBody(w, r, &in, 2048) {
			return
		}
		v, e := h.repo.AddRequest(r.Context(), jamID(r), jamBearer(r), in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 201, v)
	}))
	m.HandleFunc("PUT "+base+"/members/me", h.guest("member", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Sequence int64 `json:"sequence"`
		}
		if !jamBody(w, r, &in, 2048) {
			return
		}
		v, e := h.repo.MemberHeartbeat(r.Context(), jamID(r), jamBearer(r), in.Sequence)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, map[string]any{"memberExpiresAt": v})
	}))
	m.HandleFunc("DELETE "+base+"/members/me", h.guest("member", func(w http.ResponseWriter, r *http.Request) {
		if e := h.repo.Leave(r.Context(), jamID(r), jamBearer(r)); e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 204, nil)
	}))
}

// Host routes still require the parent's ordinary auth + Connect generation
// guard. owner resolver is explicit so this package never guesses JWT fields.
func (h *JamHandlers) RegisterHostRoutes(m *http.ServeMux) {
	m.HandleFunc("POST /api/v1/jams", h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		var in jam.CreateInput
		if !jamBody(w, r, &in, 8192) {
			return
		}
		if e := h.validate(r, o, in.Proof); e != nil {
			jamError(w, e)
			return
		}
		v, e := h.repo.Create(r.Context(), o, in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 201, v)
	}))
	base := "/api/v1/jams/{jamId}"
	m.HandleFunc("GET "+base, h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		v, e := h.repo.HostSnapshot(r.Context(), o, jamID(r))
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, v)
	}))
	m.HandleFunc("POST "+base+"/invites", h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		var in jam.Proof
		if !jamBody(w, r, &in, 2048) {
			return
		}
		if e := h.validate(r, o, in); e != nil {
			jamError(w, e)
			return
		}
		v, e := h.repo.RotateInvite(r.Context(), o, jamID(r), in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 201, v)
	}))
	m.HandleFunc("PUT "+base+"/host", h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		var in jam.HeartbeatInput
		if !jamBody(w, r, &in, 4096) {
			return
		}
		if e := h.validate(r, o, in.Proof); e != nil {
			jamError(w, e)
			return
		}
		v, e := h.repo.Heartbeat(r.Context(), o, jamID(r), in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, v)
	}))
	m.HandleFunc("PUT "+base+"/requests/{requestId}", h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		var in struct {
			jam.Proof
			jam.DecisionInput
		}
		if !jamBody(w, r, &in, 4096) {
			return
		}
		if e := h.validate(r, o, in.Proof); e != nil {
			jamError(w, e)
			return
		}
		qid, e := uuid.Parse(r.PathValue("requestId"))
		if e != nil || qid.String() != r.PathValue("requestId") {
			jamError(w, jam.ErrInvalid)
			return
		}
		v, e := h.repo.Decide(r.Context(), o, jamID(r), in.Proof, qid, in.DecisionInput)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, v)
	}))
	m.HandleFunc("DELETE "+base, h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		if e := h.repo.Close(r.Context(), o, jamID(r)); e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 204, nil)
	}))
}
