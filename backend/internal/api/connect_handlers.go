package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/connect"
)

type ConnectHandlers struct{ service *connect.Service }

func NewConnectHandlers(service *connect.Service) *ConnectHandlers {
	return &ConnectHandlers{service: service}
}
func connectError(w http.ResponseWriter, err error) {
	status, code := http.StatusServiceUnavailable, "SERVICE_DISABLED"
	switch {
	case errors.Is(err, connect.ErrInvalid):
		status, code = 400, "INVALID_DEVICE_REQUEST"
	case errors.Is(err, connect.ErrConflict):
		status, code = 409, "DEVICE_CONFLICT"
	case errors.Is(err, connect.ErrCapacity):
		status, code = 409, "DEVICE_LIMIT_REACHED"
	case errors.Is(err, connect.ErrGone):
		status, code = 410, "DEVICE_GONE"
	case errors.Is(err, connect.ErrWriter):
		status, code = 403, "DEVICE_WRITER_MISMATCH"
	case errors.Is(err, connect.ErrStale):
		status, code = 409, "STALE_DEVICE_REPORT"
	case errors.Is(err, connect.ErrRate):
		status, code = 429, "DEVICE_RATE_LIMITED"
		w.Header().Set("Retry-After", "1")
	case errors.Is(err, auth.ErrInvalidToken):
		status, code = 401, "CONNECT_SESSION_REVOKED"
	}
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"code": code})
}
func connectBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil {
		var max *http.MaxBytesError
		if errors.As(err, &max) {
			w.WriteHeader(413)
			_ = json.NewEncoder(w).Encode(map[string]string{"code": "INVALID_DEVICE_REQUEST"})
		} else {
			connectError(w, connect.ErrInvalid)
		}
		return nil, false
	}
	return raw, true
}
func (h *ConnectHandlers) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		connectError(w, auth.ErrInvalidToken)
		return
	}
	if r.URL.RawQuery != "" {
		connectError(w, connect.ErrInvalid)
		return
	}
	if h == nil || h.service == nil {
		connectError(w, connect.ErrUnavailable)
		return
	}
	switch r.Method {
	case http.MethodGet:
		devices, now, err := h.service.List(r.Context(), user.UserID, user.ConnectGeneration)
		if err != nil {
			connectError(w, err)
			return
		}
		_ = json.NewEncoder(w).Encode(struct {
			Devices    []connect.Device `json:"devices"`
			ServerTime time.Time        `json:"serverTime"`
		}{devices, now})
	case http.MethodPost:
		raw, ok := connectBody(w, r)
		if !ok {
			return
		}
		req, err := connect.DecodeRegister(raw)
		if err != nil {
			connectError(w, err)
			return
		}
		device, err := h.service.Register(r.Context(), user.UserID, user.ConnectGeneration, req)
		if err != nil {
			connectError(w, err)
			return
		}
		w.WriteHeader(201)
		_ = json.NewEncoder(w).Encode(map[string]connect.Device{"device": device})
	case http.MethodPut:
		raw, ok := connectBody(w, r)
		if !ok {
			return
		}
		req, err := connect.DecodeReport(raw)
		if err != nil {
			connectError(w, err)
			return
		}
		device, err := h.service.Report(r.Context(), user.UserID, user.ConnectGeneration, r.PathValue("id"), req)
		if err != nil {
			connectError(w, err)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]connect.Device{"device": device})
	case http.MethodDelete:
		raw, ok := connectBody(w, r)
		if !ok {
			return
		}
		req, err := connect.DecodeProof(raw)
		if err != nil {
			connectError(w, err)
			return
		}
		if err = h.service.Remove(r.Context(), user.UserID, user.ConnectGeneration, r.PathValue("id"), req); err != nil {
			connectError(w, err)
			return
		}
		w.WriteHeader(204)
	}
}

// A bounded feature-local response buffer prevents emitting success before the
// generation transaction finishes and keeps auth errors JSON without changing
// legacy middleware's response semantics.
type connectResponse struct {
	header http.Header
	body   bytes.Buffer
	status int
}

func (w *connectResponse) Header() http.Header { return w.header }
func (w *connectResponse) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *connectResponse) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.status = 200
	}
	return w.body.Write(data)
}

// Authentication precedes availability. Hold the feature's shared SQL lock
// through the bounded Redis operation so successful logout is a revocation barrier.
func (r *Router) withConnect(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		response := &connectResponse{header: make(http.Header)}
		ctx, cancel := context.WithTimeout(req.Context(), 5*time.Second)
		defer cancel()
		req = req.WithContext(ctx)
		r.withAuth(func(buffer http.ResponseWriter, request *http.Request) {
			user := auth.GetUserFromContext(request.Context())
			err := r.authService.WithConnectGeneration(request.Context(), user.UserID, user.ConnectGeneration, func() error { next(buffer, request); return nil })
			if err != nil {
				response.body.Reset()
				response.status = 0
				response.header = make(http.Header)
				connectError(response, err)
			}
		})(response, req)
		for name, values := range response.header {
			w.Header()[name] = values
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		if response.status == 0 {
			response.status = 200
		}
		w.WriteHeader(response.status)
		if response.status != 204 {
			_, _ = w.Write(response.body.Bytes())
		}
	}
}
