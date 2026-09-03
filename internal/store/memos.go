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
	// CreatedAt and UpdatedAt carry JSON tags so the API can serve store
	// structs directly; time.Time marshals as RFC3339.
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

const memoColumns = "id, user_id, category_id, title, body, created_at, updated_at"

func scanMemo(row interface{ Scan(...any) error }) (Memo, error) {
	var m Memo
	var created, updated string
	if err := row.Scan(&m.ID, &m.UserID, &m.CategoryID, &m.Title, &m.Body, &created, &updated); err != nil {
		return Memo{}, err
	}
	m.CreatedAt = parseTime(created)
	m.UpdatedAt = parseTime(updated)
	return m, nil
}

// CreateMemo inserts a memo owned by userID. categoryID 0 means "no explicit
// category": the memo falls back to the built-in 未分类. Any other value must
// name an existing category, or ErrCategoryNotFound comes back.
func (s *Store) CreateMemo(userID int64, title, body string, categoryID int64) (*Memo, error) {
	if categoryID == 0 {
		var err error
		if categoryID, err = s.builtinCategoryID(); err != nil {
			return nil, err
		}
	} else if ok, err := s.categoryExists(categoryID); err != nil {
		return nil, err
	} else if !ok {
		return nil, ErrCategoryNotFound
	}
	ts := now()
	res, err := s.db.Exec(
		"INSERT INTO memos (user_id, category_id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
		userID, categoryID, title, body, ts, ts,
	)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &Memo{
		ID:         id,
		UserID:     userID,
		Title:      title,
		Body:       body,
		CategoryID: categoryID,
		CreatedAt:  parseTime(ts),
		UpdatedAt:  parseTime(ts),
	}, nil
}

// MemosByUser lists a user's memos, newest first.
func (s *Store) MemosByUser(userID int64) ([]Memo, error) {
	rows, err := s.db.Query(
		"SELECT "+memoColumns+" FROM memos WHERE user_id = ? ORDER BY created_at DESC, id DESC",
		userID,
	)
	if err != nil {
		return nil, err
	}
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

// MemoByID fetches one memo; userID scopes the lookup so another user's
// memo is indistinguishable from a missing one.
func (s *Store) MemoByID(userID, memoID int64) (*Memo, error) {
	m, err := scanMemo(s.db.QueryRow(
		"SELECT "+memoColumns+" FROM memos WHERE id = ? AND user_id = ?",
		memoID, userID,
	))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// UpdateMemo rewrites title and body of a user's own memo, and moves it to
// categoryID when that is nonzero (it must exist); 0 leaves the category as
// it was.
func (s *Store) UpdateMemo(userID, memoID int64, title, body string, categoryID int64) (*Memo, error) {
	if categoryID != 0 {
		if ok, err := s.categoryExists(categoryID); err != nil {
			return nil, err
		} else if !ok {
			return nil, ErrCategoryNotFound
		}
	}
	res, err := s.db.Exec(
		"UPDATE memos SET title = ?, body = ?, category_id = CASE WHEN ? = 0 THEN category_id ELSE ? END, updated_at = ? WHERE id = ? AND user_id = ?",
		title, body, categoryID, categoryID, now(), memoID, userID,
	)
	if err != nil {
		return nil, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return nil, err
	} else if n == 0 {
		return nil, ErrNotFound
	}
	return s.MemoByID(userID, memoID)
}

// DeleteMemo removes a memo outright; the recycle bin arrives in a later
// ticket and will replace this hard delete with a soft one.
func (s *Store) DeleteMemo(userID, memoID int64) error {
	res, err := s.db.Exec("DELETE FROM memos WHERE id = ? AND user_id = ?", memoID, userID)
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
