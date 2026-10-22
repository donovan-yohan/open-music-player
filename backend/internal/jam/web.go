package jam

import "embed"

// Only the three public assets are embedded; test/source files are never served.
//
//go:embed web/index.html web/app.css web/app.js
var GuestWeb embed.FS
