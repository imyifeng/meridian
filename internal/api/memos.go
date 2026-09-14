package api

import (
	"bytes"
	"encoding/json"
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
	// RemindAt is the memo's reminder time point (T9), an RFC3339 timestamp.
	// nil means "not specified": create starts with none, update keeps the
	// standing one. The empty string clears it; anything unparseable is a
	// 400, never silently dropped. With a recurrence rule standing (T70) it
	// is the next trigger time point.
	RemindAt *string `json:"remind_at"`
	// RemindRule is the memo's recurrence rule (T70), an object. nil (or
	// JSON null) means "not specified": create starts with none, update
	// keeps the standing one. The empty string clears it — the reminder
	// time point is untouched, so dropping the recurrence turns the
	// standing time back into a one-shot. Anything else unparseable or
	// failing rule validation is a 400, never silently dropped.
	RemindRule *json.RawMessage `json:"remind_rule"`
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
	if in.RemindRule != nil {
		rule, err := decodeRemindRule(*in.RemindRule)
		if err != nil {
			return store.MemoInput{}, false
		}
		out.RemindRule = rule
	}
	return out, true
}

// remindRuleWire is the remind_rule object as the wire carries it; every
// field is optional until the mode says otherwise.
type remindRuleWire struct {
	Mode     *string `json:"mode"`
	Interval *int    `json:"interval"`
	Weekday  *int    `json:"weekday"`
	Day      *int    `json:"day"`
	Month    *int    `json:"month"`
	Hour     *int    `json:"hour"`
	Minute   *int    `json:"minute"`
}

// decodeRemindRule parses a remind_rule request value (T70). A nil raw is
// "not specified" — encoding/json nils the *json.RawMessage field for both
// an absent field and an explicit JSON null, so neither reaches here with
// bytes. The empty string is the clear value (the zero rule), and anything
// else must be a rule object valid for its mode — an absent or out-of-range
// field, or one the mode does not take, is an error, never silently
// dropped.
func decodeRemindRule(raw json.RawMessage) (*store.ReminderRule, error) {
	trimmed := bytes.TrimSpace(raw)
	if string(trimmed) == `""` {
		return &store.ReminderRule{}, nil
	}
	var w remindRuleWire
	if err := json.Unmarshal(trimmed, &w); err != nil {
		return nil, err
	}
	if w.Mode == nil {
		return nil, errors.New("mode missing")
	}
	taken := func(v *int) bool { return v != nil }
	rule := store.ReminderRule{Mode: *w.Mode}
	if w.Interval != nil {
		if *w.Interval < 1 {
			return nil, errors.New("interval out of range")
		}
		rule.Interval = *w.Interval
	} else {
		rule.Interval = 1
	}
	if w.Hour == nil || w.Minute == nil {
		return nil, errors.New("time of day missing")
	}
	if *w.Hour < 0 || *w.Hour > 23 || *w.Minute < 0 || *w.Minute > 59 {
		return nil, errors.New("time of day out of range")
	}
	rule.Hour, rule.Minute = *w.Hour, *w.Minute
	switch rule.Mode {
	case "daily":
		if taken(w.Weekday) || taken(w.Day) || taken(w.Month) {
			return nil, errors.New("field the mode does not take")
		}
	case "weekly":
		if w.Weekday == nil || *w.Weekday < 1 || *w.Weekday > 7 {
			return nil, errors.New("weekday missing or out of range")
		}
		rule.Weekday = *w.Weekday
		if taken(w.Day) || taken(w.Month) {
			return nil, errors.New("field the mode does not take")
		}
	case "monthly":
		if w.Day == nil || *w.Day < 1 || *w.Day > 31 {
			return nil, errors.New("day missing or out of range")
		}
		rule.Day = *w.Day
		if taken(w.Weekday) || taken(w.Month) {
			return nil, errors.New("field the mode does not take")
		}
	case "yearly":
		if w.Month == nil || *w.Month < 1 || *w.Month > 12 {
			return nil, errors.New("month missing or out of range")
		}
		if w.Day == nil || *w.Day < 1 || *w.Day > 31 {
			return nil, errors.New("day missing or out of range")
		}
		rule.Month, rule.Day = *w.Month, *w.Day
		if taken(w.Weekday) {
			return nil, errors.New("field the mode does not take")
		}
	default:
		return nil, errors.New("unknown mode")
	}
	return &rule, nil
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
	writeJSON(w, http.StatusOK, map[string]any{"memos": nonNil(memos)})
}

// listTags serves the signed-in user's own tag names — the autocomplete
// data source (T4). Tags never cross users.
func (s *server) listTags(w http.ResponseWriter, r *http.Request) {
	names, err := s.st.TagNamesByUser(identity(r).ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"tags": nonNil(names)})
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
