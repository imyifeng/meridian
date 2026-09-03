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
	ErrNotFound            = errors.New("not found")
	ErrAlreadyInitialized  = errors.New("instance already initialized")
	ErrUsernameTaken       = errors.New("username taken")
	ErrInvalidCredentials  = errors.New("invalid credentials")
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
