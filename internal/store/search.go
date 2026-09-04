package store

import (
	"database/sql"
	"strings"
	"unicode"
)

// Full-text search (T6) rides an FTS5 virtual table, memos_fts, with one
// column per searchable source — title, body, tags — so the query can keep
// phrases from crossing field boundaries. The rowid is the memo id.
//
// unicode61 has no CJK word segmentation: a whole run of Chinese becomes one
// token, so 学习 could never be found inside 英语学习笔记. Both sides of the
// index therefore space out every CJK character (spaced below), turning each
// one into a token; the query side rebuilds the user's terms into the same
// shape and quotes them as phrases, which recovers substring matching.
// FTS-special user input is neutralized by the quoting, so a search for
// `NEAR(a) *` is just a phrase, never syntax.

// The FTS5 table is created by the last migration in store.go. Every write
// path that touches a memo's indexed text — CreateMemo, UpdateMemo,
// PurgeMemo, DeleteUser's cascade — keeps it in sync via
// indexMemo/removeFromIndex; repairSearchIndex reindexes wholesale when the
// counts drift (the one-time backfill for databases that predate the table
// is exactly such a drift).

// memosFTSRow are the three indexed texts the way indexMemo fills them:
// CJK-spaced, tags joined into one space-separated string.
func memosFTSRow(title, body string, tags []string) (string, string, string) {
	return spaced(title), spaced(body), spaced(strings.Join(tags, " "))
}

// ftsInsert writes one row into memos_fts; all three texts must already be
// CJK-spaced. Shared by the incremental and the wholesale paths so the row
// shape lives in exactly one place.
func ftsInsert(w interface {
	Exec(query string, args ...any) (sql.Result, error)
}, memoID int64, spacedTitle, spacedBody, spacedTags string) error {
	_, err := w.Exec(
		"INSERT INTO memos_fts (rowid, title, body, tags) VALUES (?, ?, ?, ?)",
		memoID, spacedTitle, spacedBody, spacedTags,
	)
	return err
}

// indexMemo replaces one memo's row in the search index inside the caller's
// transaction. Every memo write path that changes title, body, or tags must
// call it, or search goes stale (T6 acceptance).
func indexMemo(tx *sql.Tx, memoID int64, title, body string, tags []string) error {
	if _, err := tx.Exec("DELETE FROM memos_fts WHERE rowid = ?", memoID); err != nil {
		return err
	}
	spacedTitle, spacedBody, spacedTags := memosFTSRow(title, body, tags)
	return ftsInsert(tx, memoID, spacedTitle, spacedBody, spacedTags)
}

// removeFromIndex drops a purged memo's index row inside the caller's
// transaction.
func removeFromIndex(tx *sql.Tx, memoID int64) error {
	_, err := tx.Exec("DELETE FROM memos_fts WHERE rowid = ?", memoID)
	return err
}

// spaced inserts a space wherever a CJK rune borders anything else, so each
// CJK character indexes as its own unicode61 token. Latin runs are left
// whole — "abandon" must stay one token.
func spaced(s string) string {
	var b strings.Builder
	var prev rune
	for i, r := range s {
		if i > 0 && (isCJK(r) || isCJK(prev)) {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
		prev = r
	}
	return b.String()
}

// isCJK reports whether r comes from a script written without spaces —
// Chinese, Japanese kana, Korean hangul — the ones unicode61 cannot segment.
func isCJK(r rune) bool {
	return unicode.Is(unicode.Han, r) ||
		unicode.Is(unicode.Hiragana, r) ||
		unicode.Is(unicode.Katakana, r) ||
		unicode.Is(unicode.Hangul, r)
}

// ftsMatchExpr turns the user's query into an FTS5 expression: one
// column-fanned-out phrase per whitespace-separated term, ANDed together.
// Empty input yields an empty expression — the caller then skips the query.
func ftsMatchExpr(query string) string {
	var blocks []string
	for _, term := range strings.Fields(query) {
		phrase := strings.ReplaceAll(spaced(term), `"`, `""`)
		blocks = append(blocks, `(title:"`+phrase+`" OR body:"`+phrase+`" OR tags:"`+phrase+`")`)
	}
	return strings.Join(blocks, " AND ")
}

// SearchMemos runs a full-text query over a user's live memos (T6), matching
// title, body, and tags — a tag hit counts even when the body never mentions
// the word, same rule as tag filtering (T4). tag additionally narrows the
// hits to memos carrying it. Newest first, like every memo listing.
func (s *Store) SearchMemos(userID int64, query, tag string) ([]Memo, error) {
	expr := ftsMatchExpr(query)
	if expr == "" {
		return []Memo{}, nil
	}
	sq := `SELECT ` + memoColumns + ` FROM memos
		WHERE user_id = ? AND deleted_at = ''
		AND id IN (SELECT rowid FROM memos_fts WHERE memos_fts MATCH ?)`
	args := []any{userID, expr}
	if tag != "" {
		sq += ` AND id IN (SELECT memo_id FROM memo_tags WHERE name = ?)`
		args = append(args, tag)
	}
	sq += ` ORDER BY created_at DESC, id DESC`
	rows, err := s.db.Query(sq, args...)
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

// repairSearchIndex rebuilds the search index from the memo table when its
// row count has drifted. Databases upgrading to T6 arrive with an empty
// memos_fts and leave here fully indexed; a healthy runtime instance never
// drifts, so this is a no-op for it.
func (s *Store) repairSearchIndex() error {
	var indexed, total int
	if err := s.db.QueryRow(
		"SELECT (SELECT COUNT(*) FROM memos_fts), (SELECT COUNT(*) FROM memos)",
	).Scan(&indexed, &total); err != nil {
		return err
	}
	if indexed == total {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM memos_fts"); err != nil {
		return err
	}
	rows, err := tx.Query(`
		SELECT m.id, m.title, m.body,
		       (SELECT group_concat(t.name, ' ') FROM memo_tags t WHERE t.memo_id = m.id)
		FROM memos m ORDER BY m.id`)
	if err != nil {
		return err
	}
	type indexedMemo struct {
		id          int64
		title, body string
		spacedTags  string
	}
	var backlog []indexedMemo
	for rows.Next() {
		var m indexedMemo
		var tags sql.NullString
		if err := rows.Scan(&m.id, &m.title, &m.body, &tags); err != nil {
			rows.Close()
			return err
		}
		m.spacedTags = spaced(tags.String)
		backlog = append(backlog, m)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, m := range backlog {
		if err := ftsInsert(tx, m.id, spaced(m.title), spaced(m.body), m.spacedTags); err != nil {
			return err
		}
	}
	return tx.Commit()
}
