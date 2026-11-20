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
		started := time.Now()
		ctx, cancel := context.WithDeadline(req.Context(), started.Add(50*time.Second))
		defer cancel()
		controller := http.NewResponseController(w)
		// Set limits before auth and admission: net/http can drain unread bodies
		// even when the handler rejects them without touching the body itself.
		// The preview handler only extends writes after a verified on-demand clip
		// is ready. Bad input, auth failures and mounted clips keep this bound.
		_ = controller.SetReadDeadline(started.Add(3 * time.Second))
		_ = controller.SetWriteDeadline(started.Add(15 * time.Second))
		authorized(w, req.WithContext(ctx))
	})
}
