// Package apitest boots the real HTTP API against a temporary SQLite file
// for seam tests. The HTTP surface — not the store — is the contract under test.
package apitest

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/imyifeng/meridian/internal/api"
	"github.com/imyifeng/meridian/internal/store"
)

// Env is one Meridian instance under test: a real API handler on a real
// TCP socket, backed by a SQLite file in a temp dir. Restart closes and
// reopens the database on the same file, standing in for a process restart.
type Env struct {
	t             *testing.T
	dir           string
	st            *store.Store
	srv           *httptest.Server
	administrator *Credentials
}

type Credentials struct {
	Username string
	Password string
	Token    string
	ID       int64
}

func NewEnv(t *testing.T) *Env {
	t.Helper()
	e := &Env{t: t, dir: t.TempDir()}
	e.open()
	t.Cleanup(e.Close)
	return e
}

func (e *Env) open() {
	st, err := store.Open(filepath.Join(e.dir, "meridian.db"))
	if err != nil {
		e.t.Fatalf("open store: %v", err)
	}
	e.st = st
	e.srv = httptest.NewServer(api.NewHandler(st))
	// Redirects are part of the API surface: return them instead of
	// silently following.
	e.srv.Client().CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
}

func (e *Env) Close() {
	e.srv.Close()
	e.st.Close()
}

func (e *Env) URL() string { return e.srv.URL }

func (e *Env) Restart() {
	e.srv.Close()
	if err := e.st.Close(); err != nil {
		e.t.Fatalf("close store: %v", err)
	}
	e.open()
}

// Call issues a JSON request against the running server and decodes the
// response body into out when non-nil. Missing Authorization means the
// header is absent entirely.
func (e *Env) Call(method, path, token string, body, out any) *http.Response {
	e.t.Helper()
	var rd *bytes.Reader
	if body == nil {
		rd = bytes.NewReader(nil)
	} else {
		b, err := json.Marshal(body)
		if err != nil {
			e.t.Fatalf("marshal body: %v", err)
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, e.srv.URL+path, rd)
	if err != nil {
		e.t.Fatalf("new request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatalf("%s %s: %v", method, path, err)
	}
	e.t.Cleanup(func() { resp.Body.Close() })
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			e.t.Fatalf("%s %s: decode response: %v", method, path, err)
		}
	}
	return resp
}

// SetupAdministrator runs the setup wizard once and remembers the resulting
// administrator.
func (e *Env) SetupAdministrator(username, password string) *Credentials {
	e.t.Helper()
	if e.administrator != nil {
		e.t.Fatal("SetupAdministrator called twice on one Env")
	}
	var out struct {
		Token string `json:"token"`
		User  struct {
			ID int64 `json:"id"`
		} `json:"user"`
	}
	resp := e.Call("POST", "/api/v1/setup/administrator", "", map[string]string{"username": username, "password": password}, &out)
	if resp.StatusCode != http.StatusCreated {
		e.t.Fatalf("setup admin: status %d, want 201", resp.StatusCode)
	}
	e.administrator = &Credentials{Username: username, Password: password, Token: out.Token, ID: out.User.ID}
	return e.administrator
}

// Admin returns the instance's administrator, creating it on first use.
func (e *Env) Administrator() *Credentials {
	e.t.Helper()
	if e.administrator == nil {
		return e.SetupAdministrator("admin", "correct horse")
	}
	return e.administrator
}
