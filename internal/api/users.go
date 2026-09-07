package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/imyifeng/meridian/internal/store"
)

// User management is the console's second pillar: users come into being
// here (ADR-0001 — no self-registration), and every route is administrator
// only. The user list doubles as the data source for the delete confirmation
// dialog, which is why it carries memo_count.

func (s *server) listUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.st.Users()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": nonNil(users)})
}

type userInput struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// validPassword accepts anything non-blank that bcrypt will take: a password
// is never trimmed (spaces may be intentional) but an all-whitespace one is a
// typo, and over-length input would otherwise surface as a hashing error.
func validPassword(password string) bool {
	return strings.TrimSpace(password) != "" && len(password) <= store.MaxPasswordBytes
}

// validCredentials applies the same rules to a username + password pair
// wherever credentials enter the system: the setup wizard and user creation
// share it so their checks cannot drift apart again.
func validCredentials(username, password string) bool {
	return strings.TrimSpace(username) != "" && validPassword(password)
}

func (s *server) createUser(w http.ResponseWriter, r *http.Request) {
	var in userInput
	if !decodeBody(w, r, &in) {
		return
	}
	if !validCredentials(in.Username, in.Password) {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	u, err := s.st.CreateUser(in.Username, in.Password)
	if errors.Is(err, store.ErrUsernameTaken) {
		writeError(w, http.StatusConflict, "username_taken")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, u)
}

func (s *server) resetPassword(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	var in userInput
	if !decodeBody(w, r, &in) {
		return
	}
	if !validPassword(in.Password) {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	err := s.st.ResetPassword(id, in.Password)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) deleteUser(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	// The setup wizard is one-way (ADR-0001): an administrator who removed
	// their own user could never be replaced.
	if id == identity(r).ID {
		writeError(w, http.StatusConflict, "self_delete")
		return
	}
	err := s.st.DeleteUser(id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
