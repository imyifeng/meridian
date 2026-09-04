package api

import (
	"errors"
	"net/http"

	"github.com/imyifeng/meridian/internal/store"
)

// The recycle bin (T5): the trashed side of the memo surface. Listing is a
// plain GET; restore and purge act on trash entries, so the live-memo
// routes never touch a trashed memo.

func (s *server) listTrash(w http.ResponseWriter, r *http.Request) {
	memos, err := s.st.TrashedMemos(identity(r).ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if memos == nil {
		memos = []store.Memo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"memos": memos})
}

func (s *server) restoreMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := s.memoID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err := s.st.RestoreMemo(identity(r).ID, id); errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) purgeMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := s.memoID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err := s.st.PurgeMemo(identity(r).ID, id); errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
