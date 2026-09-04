package api_test

import (
	"fmt"
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// TestMemoTrashLifecycle walks one memo through all three trash states
// (T5): deleted — in the bin, invisible to every normal surface; restored —
// back in its original category with its tags; purged — gone for good.
func TestMemoTrashLifecycle(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	var work struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/categories", administrator.Token,
		map[string]string{"name": "工作"}, &work); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create category: status %d, want 201", resp.StatusCode)
	}

	var created struct {
		ID int64 `json:"id"`
	}
	resp := env.Call("POST", "/api/v1/memos", administrator.Token, map[string]any{
		"title":       "会议纪要",
		"body":        "下周一交付",
		"category_id": work.ID,
		"tags":        []string{"英语"},
	}, &created)
	if resp.StatusCode != http.StatusCreated || created.ID == 0 {
		t.Fatalf("create memo: status %d id %d", resp.StatusCode, created.ID)
	}
	path := "/api/v1/memos/1"

	// --- 删除 → 从正常视图消失，出现在回收站 ---
	if resp := env.Call("DELETE", path, administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete memo: status %d, want 204", resp.StatusCode)
	}

	var list struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if len(list.Memos) != 0 {
		t.Errorf("list after delete has %d memos, want 0", len(list.Memos))
	}
	env.Call("GET", "/api/v1/memos?tag=英语", administrator.Token, nil, &list)
	if len(list.Memos) != 0 {
		t.Errorf("tag search after delete has %d memos, want 0", len(list.Memos))
	}
	if resp := env.Call("GET", path, administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("get deleted memo: status %d, want 404", resp.StatusCode)
	}
	if resp := env.Call("PUT", path, administrator.Token,
		map[string]string{"title": "改", "body": ""}, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("update deleted memo: status %d, want 404", resp.StatusCode)
	}
	var tags struct {
		Tags []string `json:"tags"`
	}
	env.Call("GET", "/api/v1/tags", administrator.Token, nil, &tags)
	if len(tags.Tags) != 0 {
		t.Errorf("tag autocomplete after delete = %v, want empty", tags.Tags)
	}

	var trash struct {
		Memos []struct {
			ID         int64  `json:"id"`
			Title      string `json:"title"`
			CategoryID int64  `json:"category_id"`
			DeletedAt  string `json:"deleted_at"`
		} `json:"memos"`
	}
	resp = env.Call("GET", "/api/v1/trash", administrator.Token, nil, &trash)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("trash list: status %d, want 200", resp.StatusCode)
	}
	if len(trash.Memos) != 1 {
		t.Fatalf("trash has %d memos, want 1", len(trash.Memos))
	}
	trashed := trash.Memos[0]
	if trashed.ID != created.ID || trashed.Title != "会议纪要" {
		t.Errorf("trashed memo = %+v", trashed)
	}
	if trashed.CategoryID != work.ID {
		t.Errorf("trashed memo category_id = %d, want original %d", trashed.CategoryID, work.ID)
	}
	if trashed.DeletedAt == "" || trashed.DeletedAt == "0001-01-01T00:00:00Z" {
		t.Errorf("trashed memo deleted_at = %q, want a timestamp", trashed.DeletedAt)
	}

	// --- 恢复 → 回到原分类，标签随行 ---
	if resp := env.Call("POST", "/api/v1/trash/1/restore", administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("restore: status %d, want 204", resp.StatusCode)
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if len(list.Memos) != 1 {
		t.Fatalf("list after restore has %d memos, want 1", len(list.Memos))
	}
	if got := list.Memos[0]["category_id"].(float64); int64(got) != work.ID {
		t.Errorf("restored memo category_id = %v, want original %d", list.Memos[0]["category_id"], work.ID)
	}
	if got, _ := list.Memos[0]["tags"].([]any); len(got) != 1 || got[0] != "英语" {
		t.Errorf("restored memo tags = %v, want [英语]", got)
	}
	env.Call("GET", "/api/v1/trash", administrator.Token, nil, &trash)
	if len(trash.Memos) != 0 {
		t.Errorf("trash after restore has %d memos, want 0", len(trash.Memos))
	}

	// --- 彻底删除 → 不可恢复 ---
	if resp := env.Call("DELETE", path, administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete again: status %d, want 204", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/trash/1", administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("purge: status %d, want 204", resp.StatusCode)
	}
	env.Call("GET", "/api/v1/trash", administrator.Token, nil, &trash)
	if len(trash.Memos) != 0 {
		t.Errorf("trash after purge has %d memos, want 0", len(trash.Memos))
	}
	if resp := env.Call("POST", "/api/v1/trash/1/restore", administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("restore purged memo: status %d, want 404", resp.StatusCode)
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if len(list.Memos) != 0 {
		t.Errorf("list after purge has %d memos, want 0", len(list.Memos))
	}
}

// 回收站永不自动清空: a memo still sits in the bin after a process restart.
func TestTrashSurvivesRestart(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "稍后处理", "body": "重启后还在回收站"}, nil)
	env.Call("DELETE", "/api/v1/memos/1", administrator.Token, nil, nil)

	env.Restart()

	var trash struct {
		Memos []struct {
			Title string `json:"title"`
		} `json:"memos"`
	}
	resp := env.Call("GET", "/api/v1/trash", administrator.Token, nil, &trash)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("trash after restart: status %d, want 200", resp.StatusCode)
	}
	if len(trash.Memos) != 1 || trash.Memos[0].Title != "稍后处理" {
		t.Errorf("trash after restart = %+v, want the deleted memo", trash)
	}
}

// 回收站与一切数据一样按账号隔离：another user's trashed memo is
// indistinguishable from a missing one.
func TestTrashIsScopedToItsOwner(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "管理员的", "body": "私密"}, nil)
	env.Call("DELETE", "/api/v1/memos/1", administrator.Token, nil, nil)

	env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": "bob", "password": "bob's password"}, nil)
	var bobSession struct {
		Token string `json:"token"`
	}
	env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": "bob", "password": "bob's password"}, &bobSession)
	bob := bobSession.Token

	var trash struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/trash", bob, nil, &trash)
	if len(trash.Memos) != 0 {
		t.Errorf("bob sees %d trashed memos, want 0", len(trash.Memos))
	}
	if resp := env.Call("POST", "/api/v1/trash/1/restore", bob, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("bob restore: status %d, want 404", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/trash/1", bob, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("bob purge: status %d, want 404", resp.StatusCode)
	}
}

// 恢复回"原分类"以原分类仍然存在为前提：a category deleted while its memo
// sits in the bin takes the memo to 未分类 with it (ADR-0002 fallback), so
// restoring never lands the memo on a dangling category.
func TestCategoryDeletedUnderTrashedMemoFallsBackToUncategorized(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	var work struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/categories", administrator.Token,
		map[string]string{"name": "工作"}, &work); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create category: status %d, want 201", resp.StatusCode)
	}
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "纪要", "category_id": work.ID}, nil)
	env.Call("DELETE", "/api/v1/memos/1", administrator.Token, nil, nil)
	env.Call("DELETE", fmt.Sprintf("/api/v1/categories/%d", work.ID), administrator.Token, nil, nil)

	if resp := env.Call("POST", "/api/v1/trash/1/restore", administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("restore: status %d, want 204", resp.StatusCode)
	}
	var cats struct {
		Categories []struct {
			ID        int64 `json:"id"`
			IsBuiltIn bool  `json:"is_builtin"`
		} `json:"categories"`
	}
	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &cats)
	var uncategorizedID int64
	for _, c := range cats.Categories {
		if c.IsBuiltIn {
			uncategorizedID = c.ID
		}
	}
	var list struct {
		Memos []struct {
			CategoryID int64 `json:"category_id"`
		} `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if len(list.Memos) != 1 {
		t.Fatalf("list after restore has %d memos, want 1", len(list.Memos))
	}
	if list.Memos[0].CategoryID != uncategorizedID {
		t.Errorf("restored memo category_id = %d, want built-in 未分类 %d",
			list.Memos[0].CategoryID, uncategorizedID)
	}
}
