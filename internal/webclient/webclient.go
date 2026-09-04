// Package webclient hosts the Web 简易客户端's Flutter Web build, served by
// the meridian binary itself (ADR-0005), next to the management console.
// `make web-client` fills dist/ with `flutter build web`; until that runs on
// a fresh checkout, dist/ holds only a placeholder and the handler says so
// instead of serving a broken app.
package webclient

import (
	"embed"
	"io"
	"io/fs"
	"net/http"
)

//go:embed all:dist
var distFS embed.FS

// Handler serves the web client SPA under /web/. Mount with StripPrefix:
//
//	mux.Handle("GET /web/", http.StripPrefix("/web", webclient.Handler()))
func Handler() http.Handler {
	sub, err := fs.Sub(distFS, "dist")
	if err != nil {
		panic("webclient: embedded dist missing: " + err.Error())
	}
	files := http.FileServerFS(sub)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			if _, err := sub.Open("index.html"); err != nil {
				// Built assets absent: point whoever is looking at a browser
				// (or a test) at the build step.
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(http.StatusOK)
				io.WriteString(w, placeholderHTML)
				return
			}
		}
		files.ServeHTTP(w, r)
	})
}

const placeholderHTML = `<!doctype html>
<html lang="zh">
<head><meta charset="utf-8"><title>Meridian 简易客户端未构建</title></head>
<body style="font-family: sans-serif; max-width: 40em; margin: 4em auto;">
<h1>Web 简易客户端尚未构建</h1>
<p>此 Meridian 二进制在编译时未打包 Flutter Web 简易客户端资源。</p>
<p>在仓库根目录运行 <code>make web-client</code> 后重新编译即可。</p>
</body>
</html>
`
