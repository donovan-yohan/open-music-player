package api

import (
	"net/http"

	"github.com/openmusicplayer/backend/internal/jam"
)

func (h *JamHandlers) registerAcquisitionGuest(m *http.ServeMux) {
	base := "/api/v1/guest/jams/{jamId}"
	m.HandleFunc("POST "+base+"/search", h.guest("search", func(w http.ResponseWriter, r *http.Request) {
		var in jam.SearchInput
		if !jamBody(w, r, &in, 2048) {
			return
		}
		out, e := h.repo.Search(r.Context(), jamID(r), jamBearer(r), in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, out)
	}))
	m.HandleFunc("POST "+base+"/source-requests", h.guest("request", func(w http.ResponseWriter, r *http.Request) {
		var in jam.SourceRequestInput
		if !jamBody(w, r, &in, 2048) {
			return
		}
		out, e := h.repo.AddSourceRequest(r.Context(), jamID(r), jamBearer(r), in)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 201, out)
	}))
}
func (h *JamHandlers) registerAcquisitionHost(m *http.ServeMux) {
	m.HandleFunc("POST /api/v1/jams/{jamId}/requests/{requestId}/approval", h.host(func(w http.ResponseWriter, r *http.Request, o jam.Owner) {
		var in struct {
			jam.Proof
			jam.ApprovalInput
		}
		if !jamBody(w, r, &in, 2048) {
			return
		}
		if e := h.validate(r, o, in.Proof); e != nil {
			jamError(w, e)
			return
		}
		out, e := h.repo.Approve(r.Context(), o, jamID(r), in.Proof, jamNamedID(r, "requestId"), in.ApprovalInput)
		if e != nil {
			jamError(w, e)
			return
		}
		jamReply(w, 200, out)
	}))
}
