package store_test

import (
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/imyifeng/meridian/internal/store"

	_ "modernc.org/sqlite"
)

// The T6 upgrade path: a database from before the search index existed
// opens with every pre-existing memo backfilled into it, so search works
// on first boot after upgrading. Not drivable through the HTTP seam — the
// surgery below stands in for the old binary's database.
func TestOpenBackfillsSearchIndexForPreexistingMemos(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "meridian.db")

	s, err := store.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	u, err := s.CreateUser("yifeng", "correct horse")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	if _, err := s.CreateMemo(u.ID, "升级前的旧笔记", "正文里没有关键词", 0, []string{"英语"}); err != nil {
		t.Fatalf("create memo: %v", err)
	}
	if _, err := s.CreateMemo(u.ID, "已删除的笔记", "", 0, nil); err != nil {
		t.Fatalf("create memo: %v", err)
	}
	if err := s.DeleteMemo(u.ID, 2); err != nil {
		t.Fatalf("trash memo: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Roll the file back to its pre-T6 shape: no index table, version 7.
	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatalf("open raw: %v", err)
	}
	if _, err := raw.Exec(`DROP TABLE memos_fts`); err != nil {
		t.Fatalf("drop fts: %v", err)
	}
	if _, err := raw.Exec(`PRAGMA user_version = 7`); err != nil {
		t.Fatalf("set version: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("close raw: %v", err)
	}

	// Reopening runs the FTS migration (the one after the version set
	// above) and backfills the index.
	reopened, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	live, err := reopened.SearchMemos(u.ID, "英语", "")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(live) != 1 || live[0].Title != "升级前的旧笔记" {
		t.Errorf("search after upgrade = %+v, want [升级前的旧笔记]", live)
	}
	trashed, err := reopened.SearchMemos(u.ID, "笔记", "")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(trashed) != 1 || trashed[0].Title != "升级前的旧笔记" {
		t.Errorf("trashed memo must not resurface, got %+v", trashed)
	}
}
