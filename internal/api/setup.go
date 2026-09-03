package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/imyifeng/meridian/internal/store"
)

// getInstance reports whether the instance has been initialized; the Setup
// Wizard drives off this flag.
func (s *server) getInstance(w http.ResponseWriter, r *http.Request) {
	initialized, err := s.st.IsInitialized()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"initialized": initialized})
}

// setupAdmin creates the instance's first administrator. Once the instance
// is initialized this endpoint is closed forever (ADR-0001): there is no
// self-registration, later users are created by an administrator.
func (s *server) setupAdmin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	if strings.TrimSpace(body.Username) == "" || body.Password == "" {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	u, token, err := s.st.SetupAdministrator(body.Username, body.Password)
	switch {
	case errors.Is(err, store.ErrAlreadyInitialized):
		writeError(w, http.StatusConflict, "already_initialized")
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"token": token, "user": u})
}

// login exchanges a username + password for a long-lived session token.
func (s *server) login(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if !decodeBody(w, r, &body) {
		return
	}
	u, token, err := s.st.Login(body.Username, body.Password)
	switch {
	case errors.Is(err, store.ErrInvalidCredentials):
		writeError(w, http.StatusUnauthorized, "invalid_credentials")
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "user": u})
}
