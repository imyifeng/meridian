// Package webconsole hosts the Web 管理控制台's Flutter Web build, served by
// the meridian binary itself (ADR-0005). `make web-console` fills dist/ with
// `flutter build web`; the embedding and placeholder handling are shared
// with the web client (internal/webui).
package webconsole

import (
	"embed"
	"net/http"

	"github.com/imyifeng/meridian/internal/webui"
)

//go:embed all:dist
var distFS embed.FS

// Handler serves the console SPA under /console/. Mount with StripPrefix:
//
//	mux.Handle("GET /console/", http.StripPrefix("/console", webconsole.Handler()))
func Handler() http.Handler {
	return webui.Handler(distFS, "Web 管理控制台", "web-console")
}
