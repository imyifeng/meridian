package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/imyifeng/meridian/internal/store"
)

type memoInput struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

func (in memoInput) validate() (title, body string, ok bool) {
	title = strings.TrimSpace(in.Title)
	if title == "" {
		return "", "", false
	}
	return title, in.Body, true
}

func (s *server) createMemo(w http.ResponseWriter, r *http.Request) {
	var in memoInput
	if !decodeBody(w, r, &in) {
		return
	}
	title, body, ok := in.validate()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	m, err := s.st.CreateMemo(identity(r).ID, title, body)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

func (s *server) listMemos(w http.ResponseWriter, r *http.Request) {
	memos, err := s.st.MemosByUser(identity(r).ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if memos == nil {
		memos = []store.Memo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"memos": memos})
}

func (s *server) memoID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func (s *server) getMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := s.memoID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	m, err := s.st.MemoByID(identity(r).ID, id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, m)
}

func (s *server) updateMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := s.memoID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	var in memoInput
	if !decodeBody(w, r, &in) {
		return
	}
	title, body, ok := in.validate()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	m, err := s.st.UpdateMemo(identity(r).ID, id, title, body)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, m)
}

func (s *server) deleteMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := s.memoID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	err := s.st.DeleteMemo(identity(r).ID, id)
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
