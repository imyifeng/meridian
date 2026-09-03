package api_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// The server hosts the Web 管理控制台's Flutter Web build itself (ADR-0005).
// With assets unbuilt the route still answers: a redirect from the root and
// the placeholder page under /console/.
func TestConsoleHosting(t *testing.T) {
	env := apitest.NewEnv(t)
	env.Administrator()

	resp := env.Call("GET", "/", "", nil, nil)
	if resp.StatusCode != http.StatusFound {
		t.Errorf("GET /: status %d, want 302", resp.StatusCode)
	}
	if loc := resp.Header.Get("Location"); loc != "/console/" {
		t.Errorf("GET /: Location %q, want /console/", loc)
	}

	resp = env.Call("GET", "/console", "", nil, nil)
	if resp.StatusCode != http.StatusFound {
		t.Errorf("GET /console: status %d, want 302", resp.StatusCode)
	}

	resp = env.Call("GET", "/console/", "", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /console/: status %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("GET /console/: content type %q, want text/html", ct)
	}
}
