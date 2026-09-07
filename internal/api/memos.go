package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/imyifeng/meridian/internal/store"
)

type memoInput struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	// CategoryID nil means "not specified": create defaults to 未分类, update
	// keeps the current category. An explicit non-positive id is invalid.
	CategoryID *int64 `json:"category_id"`
	// Tags nil means "not specified": create starts with no tags, update
	// keeps the current ones. Present (even empty) replaces the whole set.
	Tags *[]string `json:"tags"`
	// RemindAt is the memo's one-shot reminder (T9), an RFC3339 timestamp.
	// nil means "not specified": create starts with none, update keeps the
	// standing one. The empty string clears it; anything unparseable is a
	// 400, never silently dropped.
	RemindAt *string `json:"remind_at"`
}

func (in memoInput) validate() (store.MemoInput, bool) {
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return store.MemoInput{}, false
	}
	out := store.MemoInput{Title: title, Body: in.Body}
	if in.CategoryID != nil {
		if *in.CategoryID <= 0 {
			return store.MemoInput{}, false
		}
		out.CategoryID = *in.CategoryID
	}
	if in.Tags != nil {
		out.Tags = *in.Tags
	}
	if in.RemindAt != nil {
		if *in.RemindAt == "" {
			// A zero time is the "clear" value: the store writes '' for it.
			clear := time.Time{}
			out.RemindAt = &clear
		} else {
			t, err := time.Parse(time.RFC3339, *in.RemindAt)
			if err != nil {
				return store.MemoInput{}, false
			}
			out.RemindAt = &t
		}
	}
	return out, true
}

// writeMemoError maps the domain errors memo creation and update share to
// their HTTP responses, reporting whether err was one of them. Handler-only
// errors (a missing memo, for one) stay with their handlers.
func writeMemoError(w http.ResponseWriter, err error) bool {
	switch {
	case errors.Is(err, store.ErrCategoryNotFound):
		writeError(w, http.StatusBadRequest, "unknown_category")
	case errors.Is(err, store.ErrInvalidTag):
		writeError(w, http.StatusBadRequest, "invalid_tag")
	default:
		return false
	}
	return true
}

func (s *server) createMemo(w http.ResponseWriter, r *http.Request) {
	var raw memoInput
	if !decodeBody(w, r, &raw) {
		return
	}
	in, ok := raw.validate()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	m, err := s.st.CreateMemo(identity(r).ID, in)
	if writeMemoError(w, err) {
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

func (s *server) listMemos(w http.ResponseWriter, r *http.Request) {
	f := store.MemoFilter{
		// q non-empty turns the list into a full-text search (T6); tag and
		// category, when also given, narrow the hits.
		Query: strings.TrimSpace(r.URL.Query().Get("q")),
		Tag:   r.URL.Query().Get("tag"),
	}
	// category_id narrows the list to one taxonomy category (T14); the
	// built-in 未分类 is a normal choice here. A malformed or non-positive
	// id is a client bug and a 400; a well-formed unknown id is simply a
	// miss, like a tag no memo carries.
	if raw := r.URL.Query().Get("category_id"); raw != "" {
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 {
			writeError(w, http.StatusBadRequest, "invalid_request")
			return
		}
		f.CategoryID = id
	}
	memos, err := s.st.Memos(identity(r).ID, f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if memos == nil {
		memos = []store.Memo{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"memos": memos})
}

// listTags serves the signed-in user's own tag names — the autocomplete
// data source (T4). Tags never cross users.
func (s *server) listTags(w http.ResponseWriter, r *http.Request) {
	names, err := s.st.TagNamesByUser(identity(r).ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if names == nil {
		names = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"tags": names})
}

func (s *server) getMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
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
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	var raw memoInput
	if !decodeBody(w, r, &raw) {
		return
	}
	in, ok := raw.validate()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	m, err := s.st.UpdateMemo(identity(r).ID, id, in)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if writeMemoError(w, err) {
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, m)
}

func (s *server) deleteMemo(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
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
