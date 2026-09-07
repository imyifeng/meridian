// Package webclient hosts the Web 简易客户端's Flutter Web build, served by
// the meridian binary itself (ADR-0005), next to the management console.
// `make web-client` fills dist/ with `flutter build web`; the embedding and
// placeholder handling are shared with the console (internal/webui).
package webclient

import (
	"embed"
	"net/http"

	"github.com/imyifeng/meridian/internal/webui"
)

//go:embed all:dist
var distFS embed.FS

// Handler serves the web client SPA under /web/. Mount with StripPrefix:
//
//	mux.Handle("GET /web/", http.StripPrefix("/web", webclient.Handler()))
func Handler() http.Handler {
	return webui.Handler(distFS, "Web 简易客户端", "web-client")
}
