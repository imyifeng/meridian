package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"
)

// Category is one member of the instance-wide taxonomy (ADR-0002). Only an
// administrator may add or remove members; 未分类 is built-in and permanent.
type Category struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	IsBuiltIn bool `json:"is_builtin"`
	// CreatedAt and UpdatedAt carry JSON tags so the API can serve store
	// structs directly, matching Memo and User.
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// ensureBuiltinCategory seeds 未分类 when missing. It runs on every open, so
// the built-in always exists no matter what happened to the database.
func (s *Store) ensureBuiltinCategory() error {
	_, err := s.db.Exec(
		"INSERT INTO categories (name, is_builtin, created_at, updated_at) SELECT '未分类', 1, ?, ? WHERE NOT EXISTS (SELECT 1 FROM categories WHERE is_builtin = 1)",
		now(), now(),
	)
	return err
}

// builtinCategoryID returns the id of the built-in 未分类.
func (s *Store) builtinCategoryID() (int64, error) {
	var id int64
	err := s.db.QueryRow("SELECT id FROM categories WHERE is_builtin = 1").Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	return id, err
}

// Categories lists the taxonomy, built-in first.
func (s *Store) Categories() ([]Category, error) {
	rows, err := s.db.Query(
		"SELECT id, name, is_builtin, created_at, updated_at FROM categories ORDER BY is_builtin DESC, id ASC",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Category
	for rows.Next() {
		var c Category
		var created, updated string
		var builtin int
		if err := rows.Scan(&c.ID, &c.Name, &builtin, &created, &updated); err != nil {
			return nil, err
		}
		c.IsBuiltIn = builtin == 1
		c.CreatedAt = parseTime(created)
		c.UpdatedAt = parseTime(updated)
		out = append(out, c)
	}
	return out, rows.Err()
}

// categoryExists reports whether id names a category.
func (s *Store) categoryExists(id int64) (bool, error) {
	var one int
	err := s.db.QueryRow("SELECT 1 FROM categories WHERE id = ?", id).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// CreateCategory adds a member to the taxonomy. Names are unique, so the
// built-in 未分类 can never be shadowed by a second category of that name.
func (s *Store) CreateCategory(name string) (*Category, error) {
	name = strings.TrimSpace(name)
	ts := now()
	res, err := s.db.Exec(
		"INSERT INTO categories (name, is_builtin, created_at, updated_at) VALUES (?, 0, ?, ?)",
		name, ts, ts,
	)
	if err != nil {
		// The single pooled connection serializes writes, so a unique
		// violation can only be a name that was already there.
		var one int
		if s.db.QueryRow("SELECT 1 FROM categories WHERE name = ?", name).Scan(&one) == nil {
			return nil, ErrCategoryNameTaken
		}
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &Category{ID: id, Name: name, CreatedAt: parseTime(ts), UpdatedAt: parseTime(ts)}, nil
}

// DeleteCategory removes a non-built-in category; its memos fall back to
// 未分类 in the same transaction, so no memo is ever left dangling.
func (s *Store) DeleteCategory(id int64) error {
	var builtin bool
	err := s.db.QueryRow("SELECT is_builtin FROM categories WHERE id = ?", id).Scan(&builtin)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if builtin {
		return ErrBuiltinCategory
	}
	fallback, err := s.builtinCategoryID()
	if err != nil {
		return err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("UPDATE memos SET category_id = ?, updated_at = ? WHERE category_id = ?", fallback, now(), id); err != nil {
		return err
	}
	if _, err := tx.Exec("DELETE FROM categories WHERE id = ?", id); err != nil {
		return err
	}
	return tx.Commit()
}
