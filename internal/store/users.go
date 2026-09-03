package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

type User struct {
	ID       int64  `json:"id"`
	Username string `json:"username"`
	Role     string `json:"role"`
}

type userRecord struct {
	User
	PasswordHash string
}

const nowFormat = time.RFC3339Nano

func now() string { return time.Now().UTC().Format(nowFormat) }

func parseTime(s string) time.Time {
	t, _ := time.Parse(nowFormat, s)
	return t
}

// HashPassword hashes a plaintext password for storage.
func HashPassword(password string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(h), err
}

// CreateUser adds a non-first user. The administrator user-management API
// is a later ticket; for now tests seed extra users through this method.
func (s *Store) CreateUser(username, password, role string) (*User, error) {
	username = strings.TrimSpace(username)
	hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}
	res, err := s.db.Exec(
		"INSERT INTO users (username, password_hash, role, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
		username, hash, role, now(), now(),
	)
	if err != nil {
		// The single pooled connection serializes writes, so a duplicate
		// can only be a username that was already there.
		if s.usernameExists(username) {
			return nil, ErrUsernameTaken
		}
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &User{ID: id, Username: username, Role: role}, nil
}

func (s *Store) usernameExists(username string) bool {
	var one int
	err := s.db.QueryRow("SELECT 1 FROM users WHERE username = ?", username).Scan(&one)
	return err == nil
}

// SetupAdministrator creates the instance's first user inside the same
// transaction that flips the initialized flag, so the wizard window closes
// atomically with the administrator coming into existence. Returns the user
// and a ready-to-use session token.
func (s *Store) SetupAdministrator(username, password string) (*User, string, error) {
	username = strings.TrimSpace(username)
	hash, err := HashPassword(password)
	if err != nil {
		return nil, "", err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()

	var initialized bool
	if err := tx.QueryRow("SELECT initialized FROM instance_state WHERE id = 1").Scan(&initialized); err != nil {
		return nil, "", err
	}
	if initialized {
		return nil, "", ErrAlreadyInitialized
	}
	res, err := tx.Exec(
		"INSERT INTO users (username, password_hash, role, created_at, updated_at) VALUES (?, ?, 'administrator', ?, ?)",
		username, hash, now(), now(),
	)
	if err != nil {
		return nil, "", err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, "", err
	}
	if _, err := tx.Exec("UPDATE instance_state SET initialized = 1 WHERE id = 1"); err != nil {
		return nil, "", err
	}
	token, err := insertSession(tx, id)
	if err != nil {
		return nil, "", err
	}
	if err := tx.Commit(); err != nil {
		return nil, "", err
	}
	return &User{ID: id, Username: username, Role: "administrator"}, token, nil
}

// Login verifies a username + password and returns the user with a fresh
// session token.
func (s *Store) Login(username, password string) (*User, string, error) {
	rec, err := s.userByUsername(strings.TrimSpace(username))
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			// Burn comparable time so unknown user and wrong password are
			// indistinguishable by latency.
			bcrypt.CompareHashAndPassword([]byte("$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5B0X0QeGv0eC5F8S1XBB0uRw1oGki"), []byte(password))
			return nil, "", ErrInvalidCredentials
		}
		return nil, "", err
	}
	if bcrypt.CompareHashAndPassword([]byte(rec.PasswordHash), []byte(password)) != nil {
		return nil, "", ErrInvalidCredentials
	}
	u := rec.User
	token, err := s.createSession(u.ID)
	if err != nil {
		return nil, "", err
	}
	return &u, token, nil
}

// UserByToken resolves a session token to its user.
func (s *Store) UserByToken(token string) (*User, error) {
	var u User
	err := s.db.QueryRow(
		`SELECT u.id, u.username, u.role FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ?`,
		token,
	).Scan(&u.ID, &u.Username, &u.Role)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &u, nil
}

func (s *Store) userByUsername(username string) (*userRecord, error) {
	var rec userRecord
	err := s.db.QueryRow(
		"SELECT id, username, role, password_hash FROM users WHERE username = ?", username,
	).Scan(&rec.ID, &rec.Username, &rec.Role, &rec.PasswordHash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &rec, nil
}

func (s *Store) createSession(userID int64) (string, error) {
	return insertSession(s.db, userID)
}

func insertSession(q interface {
	Exec(query string, args ...any) (sql.Result, error)
}, userID int64) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b)
	if _, err := q.Exec("INSERT INTO sessions (token, user_id, created_at) VALUES (?, ?, ?)", token, userID, now()); err != nil {
		return "", err
	}
	return token, nil
}
