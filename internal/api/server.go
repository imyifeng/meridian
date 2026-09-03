// Package api exposes Meridian's HTTP JSON API. The HTTP surface is the
// project's server-side test seam: everything observable lives here.
package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/imyifeng/meridian/internal/store"
	"github.com/imyifeng/meridian/internal/webconsole"
)

// server wires handlers to the store.
type server struct {
	st *store.Store
}

// NewHandler builds the full API route table.
func NewHandler(st *store.Store) http.Handler {
	s := &server{st: st}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/instance", s.getInstance)
	mux.HandleFunc("POST /api/v1/setup/administrator", s.setupAdministrator)
	mux.HandleFunc("POST /api/v1/auth/login", s.login)
	mux.Handle("GET /api/v1/categories", s.requireAuth(http.HandlerFunc(s.listCategories)))
	mux.Handle("POST /api/v1/categories", s.requireAuth(s.requireAdministrator(http.HandlerFunc(s.createCategory))))
	mux.Handle("DELETE /api/v1/categories/{id}", s.requireAuth(s.requireAdministrator(http.HandlerFunc(s.deleteCategory))))
	mux.Handle("GET /api/v1/memos", s.requireAuth(http.HandlerFunc(s.listMemos)))
	mux.Handle("POST /api/v1/memos", s.requireAuth(http.HandlerFunc(s.createMemo)))
	mux.Handle("GET /api/v1/memos/{id}", s.requireAuth(http.HandlerFunc(s.getMemo)))
	mux.Handle("PUT /api/v1/memos/{id}", s.requireAuth(http.HandlerFunc(s.updateMemo)))
	mux.Handle("DELETE /api/v1/memos/{id}", s.requireAuth(http.HandlerFunc(s.deleteMemo)))
	mux.Handle("GET /api/v1/tags", s.requireAuth(http.HandlerFunc(s.listTags)))
	mux.Handle("GET /api/v1/users", s.requireAuth(s.requireAdministrator(http.HandlerFunc(s.listUsers))))
	mux.Handle("POST /api/v1/users", s.requireAuth(s.requireAdministrator(http.HandlerFunc(s.createUser))))
	mux.Handle("PUT /api/v1/users/{id}/password", s.requireAuth(s.requireAdministrator(http.HandlerFunc(s.resetPassword))))
	mux.Handle("DELETE /api/v1/users/{id}", s.requireAuth(s.requireAdministrator(http.HandlerFunc(s.deleteUser))))
	mux.Handle("GET /{$}", http.RedirectHandler("/console/", http.StatusFound))
	mux.Handle("GET /console", http.RedirectHandler("/console/", http.StatusFound))
	mux.Handle("GET /console/", http.StripPrefix("/console", webconsole.Handler()))
	return mux
}

type identityKey struct{}

// requireAuth resolves the Bearer token to a user or rejects the request.
func (s *server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		const prefix = "Bearer "
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), prefix)
		if !ok || token == "" {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		u, err := s.st.UserByToken(token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), identityKey{}, u)))
	})
}

// identity returns the authenticated user; only valid inside handlers
// wrapped by requireAuth.
func identity(r *http.Request) *store.User {
	return r.Context().Value(identityKey{}).(*store.User)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		json.NewEncoder(w).Encode(v)
	}
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

// decodeBody parses a JSON request body into out; anything other than a
// well-formed JSON object is a 400.
func decodeBody(w http.ResponseWriter, r *http.Request, out any) bool {
	if err := json.NewDecoder(r.Body).Decode(out); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return false
	}
	return true
}
