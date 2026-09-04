package api_test

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// The server hosts the Web 简易客户端's Flutter Web build itself (ADR-0005),
// next to the console. With assets unbuilt the route still answers: a
// redirect into /web/ and the placeholder page there.
func TestWebClientHosting(t *testing.T) {
	env := apitest.NewEnv(t)
	env.Administrator()

	resp := env.Call("GET", "/web", "", nil, nil)
	if resp.StatusCode != http.StatusFound {
		t.Errorf("GET /web: status %d, want 302", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != "/web/" {
		t.Errorf("GET /web: Location %q, want /web/", loc)
	}

	resp = env.Call("GET", "/web/", "", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /web/: status %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("GET /web/: content type %q, want text/html", ct)
	}
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read /web/ body: %v", err)
	}
	// The route must answer sensibly in both dist states: the placeholder on
	// a fresh checkout (assets are build output, not tracked), the built SPA
	// after `make web-client`.
	body := string(raw)
	if strings.Contains(body, "flutter_bootstrap.js") {
		if !strings.Contains(body, `base href="/web/"`) {
			t.Errorf("GET /web/: built index mounted under wrong base href")
		}
	} else if !strings.Contains(body, "简易客户端") ||
		!strings.Contains(body, "make web-client") {
		t.Errorf("GET /web/: placeholder missing build hint, got %q", body)
	}
}
