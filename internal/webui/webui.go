// Package webui serves the embedded Flutter Web builds shared by Meridian's
// two frontends (ADR-0005): internal/webconsole and internal/webclient each
// embed their own dist/ and hand it here. Until `make` fills dist/ on a
// fresh checkout, it holds only a placeholder and the handler says so
// instead of serving a broken app.
package webui

import (
	"io"
	"io/fs"
	"net/http"
)

// Handler serves the Flutter Web build in dist's dist/ subtree. name is the
// frontend's glossary name for the placeholder copy; makeTarget is the Make
// target that fills dist/ and is quoted in the build hint. Mount with
// StripPrefix:
//
//	mux.Handle("GET /console/", http.StripPrefix("/console", h))
func Handler(dist fs.FS, name, makeTarget string) http.Handler {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		panic("webui: embedded dist missing for " + name + ": " + err.Error())
	}
	files := http.FileServerFS(sub)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" || r.URL.Path == "" {
			if _, err := sub.Open("index.html"); err != nil {
				// Built assets absent: point whoever is looking at a browser
				// (or a test) at the build step.
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(http.StatusOK)
				io.WriteString(w, placeholderHTML(name, makeTarget))
				return
			}
		}
		files.ServeHTTP(w, r)
	})
}

func placeholderHTML(name, makeTarget string) string {
	return `<!doctype html>
<html lang="zh">
<head><meta charset="utf-8"><title>Meridian ` + name + `未构建</title></head>
<body style="font-family: sans-serif; max-width: 40em; margin: 4em auto;">
<h1>` + name + `尚未构建</h1>
<p>此 Meridian 二进制在编译时未打包 ` + name + `资源。</p>
<p>在仓库根目录运行 <code>make ` + makeTarget + `</code> 后重新编译即可。</p>
</body>
</html>
`
}
