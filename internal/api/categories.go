package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/imyifeng/meridian/internal/store"
)

// requireAdministrator gates a handler to administrators; the taxonomy is
// the one thing only they may change (ADR-0002). Must run behind requireAuth.
func (s *server) requireAdministrator(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if identity(r).Role != "administrator" {
			writeError(w, http.StatusForbidden, "administrator_only")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// listCategories serves the instance taxonomy to every authenticated user:
// clients need it to offer the category picker.
func (s *server) listCategories(w http.ResponseWriter, r *http.Request) {
	categories, err := s.st.Categories()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if categories == nil {
		categories = []store.Category{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"categories": categories})
}

type categoryInput struct {
	Name string `json:"name"`
}

func (s *server) createCategory(w http.ResponseWriter, r *http.Request) {
	var in categoryInput
	if !decodeBody(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	c, err := s.st.CreateCategory(in.Name)
	if errors.Is(err, store.ErrCategoryNameTaken) {
		writeError(w, http.StatusConflict, "name_taken")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, c)
}

func (s *server) deleteCategory(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	err := s.st.DeleteCategory(id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found")
	case errors.Is(err, store.ErrBuiltinCategory):
		// Even the administrator cannot remove 未分类: it is the floor under
		// every memo (ADR-0002).
		writeError(w, http.StatusConflict, "builtin_category")
	case err != nil:
		writeError(w, http.StatusInternalServerError, "internal")
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
