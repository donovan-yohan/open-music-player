package api

import (
	"github.com/openmusicplayer/backend/internal/jam"
	"net/http"
)

func (h *JamHandlers) RegisterGuestWebRoutes(m *http.ServeMux) {
	for path, asset := range map[string]string{"/join": "index.html", "/join/app.css": "app.css", "/join/app.js": "app.js"} {
		asset := asset
		m.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) {
			jamHeaders(w)
			w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
			w.Header().Set("Permissions-Policy", "camera=(), microphone=(), autoplay=(), geolocation=()")
			b, e := jam.GuestWeb.ReadFile("web/" + asset)
			if e != nil {
				http.NotFound(w, r)
				return
			}
			switch asset {
			case "index.html":
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
			case "app.css":
				w.Header().Set("Content-Type", "text/css; charset=utf-8")
			case "app.js":
				w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
			}
			w.Write(b)
		})
	}
}
