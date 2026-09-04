package store

import (
	"database/sql"
	"errors"
	"time"
)

type Memo struct {
	ID     int64  `json:"id"`
	UserID int64  `json:"user_id"`
	Title  string `json:"title"`
	Body   string `json:"body"`
	// CategoryID names the one taxonomy category this memo lives in
	// (ADR-0002). It is always set: never zero.
	CategoryID int64 `json:"category_id"`
	// Tags are the user's own short organizing hints (T4), in the order they
	// were saved; never nil.
	Tags []string `json:"tags"`
	// CreatedAt and UpdatedAt carry JSON tags so the API can serve store
	// structs directly; time.Time marshals as RFC3339.
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	// DeletedAt is zero for a live memo and the deletion time once it sits
	// in the recycle bin (T5); the zero value marshals as
	// 0001-01-01T00:00:00Z.
	DeletedAt time.Time `json:"deleted_at"`
	// RemindAt is the memo's one-shot reminder (T9): nil is no reminder and
	// marshals as null. It belongs to the memo, not to any device, so every
	// client that sees the memo sees the same reminder (ADR-0004).
	RemindAt *time.Time `json:"remind_at"`
}

const memoColumns = "id, user_id, category_id, title, body, created_at, updated_at, deleted_at, remind_at"

func scanMemo(row interface{ Scan(...any) error }) (Memo, error) {
	var m Memo
	var created, updated, deleted, remind string
	if err := row.Scan(&m.ID, &m.UserID, &m.CategoryID, &m.Title, &m.Body, &created, &updated, &deleted, &remind); err != nil {
		return Memo{}, err
	}
	m.CreatedAt = parseTime(created)
	m.UpdatedAt = parseTime(updated)
	m.DeletedAt = parseTime(deleted)
	m.RemindAt = remindAtPtr(remind)
	return m, nil
}

// remindAtPtr decodes the remind_at column: the empty string is no
// reminder.
func remindAtPtr(s string) *time.Time {
	if s == "" {
		return nil
	}
	t := parseTime(s)
	return &t
}

// formatRemindAt encodes the remind_at column; nil and the zero time (the
// API clear value) both encode as the empty string.
func formatRemindAt(t *time.Time) string {
	if t == nil || t.IsZero() {
		return ""
	}
	return t.UTC().Format(nowFormat)
}

// scanMemos drains a memo query; tags are attached separately by attachTags.
func scanMemos(rows *sql.Rows) ([]Memo, error) {
	defer rows.Close()
	var out []Memo
	for rows.Next() {
		m, err := scanMemo(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// attachTags fills in each memo's tag list with one query, preserving the
// saved order. Lists are never nil.
func (s *Store) attachTags(userID int64, memos []Memo) error {
	for i := range memos {
		memos[i].Tags = []string{}
	}
	if len(memos) == 0 {
		return nil
	}
	rows, err := s.db.Query(`
		SELECT t.memo_id, t.name
		FROM memo_tags t JOIN memos m ON m.id = t.memo_id
		WHERE m.user_id = ?
		ORDER BY t.rowid`, userID)
	if err != nil {
		return err
	}
	defer rows.Close()
	index := make(map[int64]int, len(memos))
	for i := range memos {
		index[memos[i].ID] = i
	}
	for rows.Next() {
		var memoID int64
		var name string
		if err := rows.Scan(&memoID, &name); err != nil {
			return err
		}
		if i, ok := index[memoID]; ok {
			memos[i].Tags = append(memos[i].Tags, name)
		}
	}
	return rows.Err()
}

// CreateMemo inserts a memo owned by userID. categoryID 0 means "no explicit
// category": the memo falls back to the built-in 未分类. Any other value must
// name an existing category, or ErrCategoryNotFound comes back. tags may be
// nil (no tags) and is normalized; ErrInvalidTag reports bad names. remindAt
// nil starts with no reminder (T9).
func (s *Store) CreateMemo(userID int64, title, body string, categoryID int64, tags []string, remindAt *time.Time) (*Memo, error) {
	names, err := normalizeTags(tags)
	if err != nil {
		return nil, err
	}
	if categoryID == 0 {
		if categoryID, err = s.builtinCategoryID(); err != nil {
			return nil, err
		}
	} else if ok, err := s.categoryExists(categoryID); err != nil {
		return nil, err
	} else if !ok {
		return nil, ErrCategoryNotFound
	}
	remind := formatRemindAt(remindAt)
	ts := now()
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(
		"INSERT INTO memos (user_id, category_id, title, body, remind_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
		userID, categoryID, title, body, remind, ts, ts,
	)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	if err := insertMemoTags(tx, id, names); err != nil {
		return nil, err
	}
	if err := indexMemo(tx, id, title, body, names); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	m := &Memo{
		ID:         id,
		UserID:     userID,
		Title:      title,
		Body:       body,
		CategoryID: categoryID,
		Tags:       names,
		CreatedAt:  parseTime(ts),
		UpdatedAt:  parseTime(ts),
		RemindAt:   remindAtPtr(remind),
	}
	return m, nil
}

// MemosByUser lists a user's live memos, newest first; trashed ones stay in
// the recycle bin (T5).
func (s *Store) MemosByUser(userID int64) ([]Memo, error) {
	rows, err := s.db.Query(
		"SELECT "+memoColumns+" FROM memos WHERE user_id = ? AND deleted_at = '' ORDER BY created_at DESC, id DESC",
		userID,
	)
	if err != nil {
		return nil, err
	}
	memos, err := scanMemos(rows)
	if err != nil {
		return nil, err
	}
	if err := s.attachTags(userID, memos); err != nil {
		return nil, err
	}
	return memos, nil
}

// MemosByUserAndTag lists a user's memos carrying tag, newest first; a tag
// no memo carries is simply a miss. The match is on the tag alone — the body
// never has to mention the word (T4).
func (s *Store) MemosByUserAndTag(userID int64, tag string) ([]Memo, error) {
	rows, err := s.db.Query(
		"SELECT "+memoColumns+" FROM memos WHERE user_id = ? AND deleted_at = '' AND id IN (SELECT memo_id FROM memo_tags WHERE name = ?) ORDER BY created_at DESC, id DESC",
		userID, tag,
	)
	if err != nil {
		return nil, err
	}
	memos, err := scanMemos(rows)
	if err != nil {
		return nil, err
	}
	if err := s.attachTags(userID, memos); err != nil {
		return nil, err
	}
	return memos, nil
}

// MemoByID fetches one live memo; userID scopes the lookup so another
// user's memo — or one of their trashed ones — is indistinguishable from a
// missing one.
func (s *Store) MemoByID(userID, memoID int64) (*Memo, error) {
	m, err := scanMemo(s.db.QueryRow(
		"SELECT "+memoColumns+" FROM memos WHERE id = ? AND user_id = ? AND deleted_at = ''",
		memoID, userID,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	names, err := memoTags(s.db, m.ID)
	if err != nil {
		return nil, err
	}
	m.Tags = names
	return &m, nil
}

// UpdateMemo rewrites title and body of a user's own live memo, moves it to
// categoryID when that is nonzero (it must exist; 0 leaves the category as
// it was), replaces the tag set when tags is non-nil — an empty list
// removes every tag, nil leaves the tags as they were — and sets the
// reminder when remindAt is non-nil (a zero time clears it; nil keeps the
// standing one, T9). A trashed memo is out of reach until restored (T5).
func (s *Store) UpdateMemo(userID, memoID int64, title, body string, categoryID int64, tags []string, remindAt *time.Time) (*Memo, error) {
	var names []string
	if tags != nil {
		var err error
		if names, err = normalizeTags(tags); err != nil {
			return nil, err
		}
	}
	if categoryID != 0 {
		if ok, err := s.categoryExists(categoryID); err != nil {
			return nil, err
		} else if !ok {
			return nil, ErrCategoryNotFound
		}
	}
	var remindArg any // nil keeps the standing remind_at (COALESCE)
	if remindAt != nil {
		remindArg = formatRemindAt(remindAt)
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(
		"UPDATE memos SET title = ?, body = ?, category_id = CASE WHEN ? = 0 THEN category_id ELSE ? END, remind_at = COALESCE(?, remind_at), updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at = ''",
		title, body, categoryID, categoryID, remindArg, now(), memoID, userID,
	)
	if err != nil {
		return nil, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return nil, err
	} else if n == 0 {
		return nil, ErrNotFound
	}
	if names != nil {
		if _, err := tx.Exec("DELETE FROM memo_tags WHERE memo_id = ?", memoID); err != nil {
			return nil, err
		}
		if err := insertMemoTags(tx, memoID, names); err != nil {
			return nil, err
		}
	}
	// The index tracks title, body, and tags, so it reindexes here even when
	// only the tags or the category moved (T6).
	finalTags := names
	if finalTags == nil {
		if finalTags, err = memoTags(tx, memoID); err != nil {
			return nil, err
		}
	}
	if err := indexMemo(tx, memoID, title, body, finalTags); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.MemoByID(userID, memoID)
}

// DeleteMemo moves a memo to the recycle bin (T5): a soft delete that
// stamps deleted_at, keeping the row — its category and tags included —
// until it is restored or purged. Deleting it again (or touching it at all
// through the live-memo paths) reports ErrNotFound.
func (s *Store) DeleteMemo(userID, memoID int64) error {
	return s.execOneMemo("UPDATE memos SET deleted_at = ? WHERE id = ? AND user_id = ? AND deleted_at = ''",
		now(), memoID, userID)
}

// RestoreMemo takes a memo out of the recycle bin. Its category and tags
// were never touched, so it reappears exactly as it went in.
func (s *Store) RestoreMemo(userID, memoID int64) error {
	return s.execOneMemo("UPDATE memos SET deleted_at = '' WHERE id = ? AND user_id = ? AND deleted_at != ''",
		memoID, userID)
}

// PurgeMemo removes a trashed memo and its tags (via the foreign key)
// outright; there is no way back. Its search index row goes in the same
// transaction (T6).
func (s *Store) PurgeMemo(userID, memoID int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.Exec("DELETE FROM memos WHERE id = ? AND user_id = ? AND deleted_at != ''",
		memoID, userID)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrNotFound
	}
	if err := removeFromIndex(tx, memoID); err != nil {
		return err
	}
	return tx.Commit()
}

// execOneMemo runs a one-memo state change and reports ErrNotFound when it
// matched nothing — another user's memo, a missing one, or one on the wrong
// side of the trash line.
func (s *Store) execOneMemo(query string, args ...any) error {
	res, err := s.db.Exec(query, args...)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err != nil {
		return err
	} else if n == 0 {
		return ErrNotFound
	}
	return nil
}

// TrashedMemos lists a user's recycle bin, most recently deleted first.
func (s *Store) TrashedMemos(userID int64) ([]Memo, error) {
	rows, err := s.db.Query(
		"SELECT "+memoColumns+" FROM memos WHERE user_id = ? AND deleted_at != '' ORDER BY deleted_at DESC, id DESC",
		userID,
	)
	if err != nil {
		return nil, err
	}
	memos, err := scanMemos(rows)
	if err != nil {
		return nil, err
	}
	if err := s.attachTags(userID, memos); err != nil {
		return nil, err
	}
	return memos, nil
}
