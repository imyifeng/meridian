package webui_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/imyifeng/meridian/internal/webui"
)

// dist returns a fake embed FS shaped like the real ones: a dist/ subtree
// holding whatever files are passed in.
func dist(files map[string]string) fstest.MapFS {
	m := fstest.MapFS{"dist/.gitignore": &fstest.MapFile{Data: []byte("*\n")}}
	for name, data := range files {
		m["dist/"+name] = &fstest.MapFile{Data: []byte(data)}
	}
	return m
}

// Handler serves one embedded Flutter Web build (ADR-0005): the built SPA
// when dist/ has it, a placeholder pointing at the make target otherwise.
// The real embed packages only ever reach the built state locally, so both
// dist states are exercised here against a fake FS — for both frontends'
// name/target pairings.
func TestHandlerPlaceholder(t *testing.T) {
	for _, tc := range []struct{ name, target, hint string }{
		{"Web 简易客户端", "web-client", "简易客户端"},
		{"Web 管理控制台", "web-console", "管理控制台"},
	} {
		h := webui.Handler(dist(nil), tc.name, tc.target)

		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s placeholder: status %d, want 200", tc.target, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
			t.Errorf("%s placeholder: content type %q, want text/html", tc.target, ct)
		}
		body := rec.Body.String()
		if !strings.Contains(body, tc.hint) || !strings.Contains(body, "make "+tc.target) {
			t.Errorf("%s placeholder: missing build hint, got %q", tc.target, body)
		}
	}
}

func TestHandlerBuiltIndex(t *testing.T) {
	h := webui.Handler(dist(map[string]string{
		"index.html": `<!doctype html><html><body>SPA</body></html>`,
	}), "Web 管理控制台", "web-console")

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("built index: status %d, want 200", rec.Code)
	}
	raw, err := io.ReadAll(rec.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if !strings.Contains(string(raw), "SPA") {
		t.Errorf("built index: want index.html served, got %q", raw)
	}
	if strings.Contains(string(raw), "尚未构建") {
		t.Errorf("built index: placeholder leaked, got %q", raw)
	}
}

func TestHandlerServesSubpath(t *testing.T) {
	h := webui.Handler(dist(map[string]string{
		"index.html":    "SPA",
		"assets/app.js": "console.log(1)",
	}), "Web 简易客户端", "web-client")

	// The server mounts with StripPrefix, so the handler sees /assets/...
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/assets/app.js", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("subpath: status %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); !strings.Contains(body, "console.log(1)") {
		t.Errorf("subpath: want asset served, got %q", body)
	}
}
