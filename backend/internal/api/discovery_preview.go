package api

import (
	"context"
	"net/http"
	"time"
)

const discoveryPreviewPattern = "POST /api/v1/discovery/preview"

func (r *Router) registerDiscoveryPreview() {
	authorized := r.withAuth(r.discoveryPreview.ServeHTTP)
	r.mux.HandleFunc(discoveryPreviewPattern, func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		ctx, cancel := context.WithTimeout(req.Context(), 15*time.Second)
		defer cancel()
		controller := http.NewResponseController(w)
		// Set limits before auth and admission: net/http can drain unread bodies
		// even when the handler rejects them without touching the body itself.
		deadline, _ := ctx.Deadline()
		_ = controller.SetReadDeadline(time.Now().Add(3 * time.Second))
		_ = controller.SetWriteDeadline(deadline)
		authorized(w, req.WithContext(ctx))
	})
}
