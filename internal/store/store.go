// Package store owns the SQLite database: schema migrations and all
// persistence for users, sessions, and memos.
package store

import (
	"database/sql"
	"errors"
	"fmt"

	_ "modernc.org/sqlite"
)

var (
	ErrNotFound           = errors.New("not found")
	ErrAlreadyInitialized = errors.New("instance already initialized")
	ErrUsernameTaken      = errors.New("username taken")
	ErrInvalidCredentials = errors.New("invalid credentials")
	ErrCategoryNameTaken  = errors.New("category name taken")
	ErrBuiltinCategory    = errors.New("built-in category")
	ErrCategoryNotFound   = errors.New("category not found")
)

// Store is a handle to one Meridian instance's SQLite database.
type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	// WAL for durability with a concurrent reader; foreign keys enforced on
	// every connection the pool hands out; busy_timeout rides out writer
	// contention. One pooled connection serializes writes, which SQLite
	// requires anyway and this instance size does not need to parallelize.
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping %s: %w", path, err)
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate %s: %w", path, err)
	}
	// 未分类 must exist on every open: new memos and deleted-category
	// fallbacks depend on it (ADR-0002).
	if err := s.ensureBuiltinCategory(); err != nil {
		db.Close()
		return nil, fmt.Errorf("seed built-in category: %w", err)
	}
	// The search index backfills itself once: a database upgrading to T6
	// opens with an empty memos_fts and nonempty memos (T6).
	if err := s.repairSearchIndex(); err != nil {
		db.Close()
		return nil, fmt.Errorf("repair search index: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// IsInitialized reports whether the Setup Wizard has completed. It can only
// ever go one way: true is permanent.
func (s *Store) IsInitialized() (bool, error) {
	var initialized bool
	err := s.db.QueryRow("SELECT initialized FROM instance_state WHERE id = 1").Scan(&initialized)
	if err != nil {
		return false, err
	}
	return initialized, nil
}

var migrations = []string{
	`CREATE TABLE instance_state (
		id          INTEGER PRIMARY KEY CHECK (id = 1),
		initialized INTEGER NOT NULL DEFAULT 0
	);
	INSERT INTO instance_state (id) VALUES (1);`,
	`CREATE TABLE users (
		id            INTEGER PRIMARY KEY AUTOINCREMENT,
		username      TEXT NOT NULL UNIQUE,
		password_hash TEXT NOT NULL,
		role          TEXT NOT NULL,
		created_at    TEXT NOT NULL,
		updated_at    TEXT NOT NULL
	);`,
	`CREATE TABLE sessions (
		token      TEXT PRIMARY KEY,
		user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		created_at TEXT NOT NULL
	);`,
	`CREATE TABLE memos (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		title      TEXT NOT NULL,
		body       TEXT NOT NULL DEFAULT '',
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL
	);`,
	// ADR-0002: one instance-wide category taxonomy. The built-in 未分类 is
	// seeded with a fixed epoch timestamp — its timestamps are never shown.
	// Existing memos (pre-taxonomy) rebuild into the new shape, every row
	// falling back to 未分类.
	`CREATE TABLE categories (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		name       TEXT NOT NULL UNIQUE,
		is_builtin INTEGER NOT NULL DEFAULT 0,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL
	);
	INSERT INTO categories (name, is_builtin, created_at, updated_at)
	VALUES ('未分类', 1, '1970-01-01T00:00:00Z', '1970-01-01T00:00:00Z');
	ALTER TABLE memos RENAME TO memos_pre_taxonomy;
	CREATE TABLE memos (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		category_id INTEGER NOT NULL REFERENCES categories(id),
		title       TEXT NOT NULL,
		body        TEXT NOT NULL DEFAULT '',
		created_at  TEXT NOT NULL,
		updated_at  TEXT NOT NULL
	);
	INSERT INTO memos (id, user_id, category_id, title, body, created_at, updated_at)
	SELECT id, user_id, (SELECT id FROM categories WHERE is_builtin = 1), title, body, created_at, updated_at
	FROM memos_pre_taxonomy;
	DROP TABLE memos_pre_taxonomy;`,
	// T4: user-authored tags. The join table keeps input order via rowid and
	// rides memos' ON DELETE CASCADE, so tags have no recycle bin of their
	// own; the name carries no per-user table — a tag belongs to whoever's
	// memo carries it, and identical names across users are mere coincidences.
	`CREATE TABLE memo_tags (
		memo_id INTEGER NOT NULL REFERENCES memos(id) ON DELETE CASCADE,
		name    TEXT NOT NULL,
		PRIMARY KEY (memo_id, name)
	);`,
	// T5: the recycle bin. deleted_at is '' for a live memo and the deletion
	// timestamp once trashed; restoring clears it, purging removes the row.
	// The bin is never emptied automatically — an aging-out policy belongs
	// to a later ticket.
	`ALTER TABLE memos ADD COLUMN deleted_at TEXT NOT NULL DEFAULT '';`,
	// T6: the full-text index over title, body, and tags (one column each, so
	// a phrase can never span two sources). rowid is the memo id; the write
	// paths in search.go keep it in sync, and Open backfills it below on the
	// first boot after this migration.
	`CREATE VIRTUAL TABLE memos_fts USING fts5(title, body, tags, tokenize='unicode61');`,
	// T9: the one-shot reminder, '' for none. It rides the memo row — a
	// property of the memo, not of any device (ADR-0004) — so every client
	// that can read the memo can schedule the same notification.
	`ALTER TABLE memos ADD COLUMN remind_at TEXT NOT NULL DEFAULT '';`,
}

func (s *Store) migrate() error {
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return err
	}
	for i, m := range migrations {
		v := i + 1
		if version >= v {
			continue
		}
		tx, err := s.db.Begin()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(m); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: %w", v, err)
		}
		if _, err := tx.Exec(fmt.Sprintf("PRAGMA user_version = %d", v)); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: set version: %w", v, err)
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}
