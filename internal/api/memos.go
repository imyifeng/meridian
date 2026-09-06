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

func (in memoInput) validate() (title, body string, categoryID int64, tags []string, remindAt *time.Time, ok bool) {
	title = strings.TrimSpace(in.Title)
	if title == "" {
		return "", "", 0, nil, nil, false
	}
	if in.CategoryID != nil {
		if *in.CategoryID <= 0 {
			return "", "", 0, nil, nil, false
		}
		categoryID = *in.CategoryID
	}
	if in.Tags != nil {
		tags = *in.Tags
	}
	if in.RemindAt != nil {
		if *in.RemindAt == "" {
			// A zero time is the "clear" value: the store writes '' for it.
			clear := time.Time{}
			remindAt = &clear
		} else {
			t, err := time.Parse(time.RFC3339, *in.RemindAt)
			if err != nil {
				return "", "", 0, nil, nil, false
			}
			remindAt = &t
		}
	}
	return title, in.Body, categoryID, tags, remindAt, true
}

func (s *server) createMemo(w http.ResponseWriter, r *http.Request) {
	var in memoInput
	if !decodeBody(w, r, &in) {
		return
	}
	title, body, categoryID, tags, remindAt, ok := in.validate()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	m, err := s.st.CreateMemo(identity(r).ID, title, body, categoryID, tags, remindAt)
	if errors.Is(err, store.ErrCategoryNotFound) {
		writeError(w, http.StatusBadRequest, "unknown_category")
		return
	}
	if errors.Is(err, store.ErrInvalidTag) {
		writeError(w, http.StatusBadRequest, "invalid_tag")
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
	title, body, categoryID, tags, remindAt, ok := in.validate()
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	m, err := s.st.UpdateMemo(identity(r).ID, id, title, body, categoryID, tags, remindAt)
	if errors.Is(err, store.ErrCategoryNotFound) {
		writeError(w, http.StatusBadRequest, "unknown_category")
		return
	}
	if errors.Is(err, store.ErrInvalidTag) {
		writeError(w, http.StatusBadRequest, "invalid_tag")
		return
	}
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
