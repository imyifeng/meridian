package store

import (
	"database/sql"
	"errors"
	"strings"
	"unicode/utf8"
)

// maxTagRunes bounds a tag's length; the spec's "约 50 字内" is enforced as a
// hard rune limit so Chinese and Latin tags are measured alike.
const maxTagRunes = 50

var ErrInvalidTag = errors.New("invalid tag")

// normalizeTags trims each name, rejects blank or over-long ones, and
// dedupes preserving first occurrence. The result is never nil, so an empty
// input marshals as [].
func normalizeTags(names []string) ([]string, error) {
	out := make([]string, 0, len(names))
	seen := make(map[string]struct{}, len(names))
	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" || utf8.RuneCountInString(name) > maxTagRunes {
			return nil, ErrInvalidTag
		}
		if _, dup := seen[name]; dup {
			continue
		}
		seen[name] = struct{}{}
		out = append(out, name)
	}
	return out, nil
}

// insertMemoTags stores one memo's tags in input order. The caller has
// already normalized the names.
func insertMemoTags(tx *sql.Tx, memoID int64, names []string) error {
	for _, name := range names {
		if _, err := tx.Exec(
			"INSERT INTO memo_tags (memo_id, name) VALUES (?, ?)", memoID, name,
		); err != nil {
			return err
		}
	}
	return nil
}

// memoTags lists one memo's tags in saved order; never nil.
func (s *Store) memoTags(memoID int64) ([]string, error) {
	rows, err := s.db.Query(
		"SELECT name FROM memo_tags WHERE memo_id = ? ORDER BY rowid", memoID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	names := make([]string, 0)
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		names = append(names, name)
	}
	return names, rows.Err()
}

// TagNamesByUser lists the distinct tag names a user has used on live
// memos, sorted — the data source for tag autocomplete (T4). Trashed memos
// drop out until restored (T5). Tags never cross users.
func (s *Store) TagNamesByUser(userID int64) ([]string, error) {
	rows, err := s.db.Query(`
		SELECT DISTINCT t.name
		FROM memo_tags t JOIN memos m ON m.id = t.memo_id
		WHERE m.user_id = ? AND m.deleted_at = ''
		ORDER BY t.name`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, name)
	}
	return out, rows.Err()
}
