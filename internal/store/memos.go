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
	// CreatedAt and UpdatedAt carry JSON tags so the API can serve store
	// structs directly; time.Time marshals as RFC3339.
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// CreateMemo inserts a memo owned by userID.
func (s *Store) CreateMemo(userID int64, title, body string) (*Memo, error) {
	ts := now()
	res, err := s.db.Exec(
		"INSERT INTO memos (user_id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
		userID, title, body, ts, ts,
	)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &Memo{
		ID:        id,
		UserID:    userID,
		Title:     title,
		Body:      body,
		CreatedAt: parseTime(ts),
		UpdatedAt: parseTime(ts),
	}, nil
}

// MemosByUser lists a user's memos, newest first.
func (s *Store) MemosByUser(userID int64) ([]Memo, error) {
	rows, err := s.db.Query(
		"SELECT id, user_id, title, body, created_at, updated_at FROM memos WHERE user_id = ? ORDER BY created_at DESC, id DESC",
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Memo
	for rows.Next() {
		var m Memo
		var created, updated string
		if err := rows.Scan(&m.ID, &m.UserID, &m.Title, &m.Body, &created, &updated); err != nil {
			return nil, err
		}
		m.CreatedAt = parseTime(created)
		m.UpdatedAt = parseTime(updated)
		out = append(out, m)
	}
	return out, rows.Err()
}

// MemoByID fetches one memo; userID scopes the lookup so another user's
// memo is indistinguishable from a missing one.
func (s *Store) MemoByID(userID, memoID int64) (*Memo, error) {
	var m Memo
	var created, updated string
	err := s.db.QueryRow(
		"SELECT id, user_id, title, body, created_at, updated_at FROM memos WHERE id = ? AND user_id = ?",
		memoID, userID,
	).Scan(&m.ID, &m.UserID, &m.Title, &m.Body, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	m.CreatedAt = parseTime(created)
	m.UpdatedAt = parseTime(updated)
	return &m, nil
}

// UpdateMemo rewrites title and body of a user's own memo.
func (s *Store) UpdateMemo(userID, memoID int64, title, body string) (*Memo, error) {
	res, err := s.db.Exec(
		"UPDATE memos SET title = ?, body = ?, updated_at = ? WHERE id = ? AND user_id = ?",
		title, body, now(), memoID, userID,
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
