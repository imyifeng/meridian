package api_test

import (
	"net/http"
	"slices"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// createMemo is the test's way to plant one memo; it returns the id.
func createMemo(t *testing.T, env *apitest.Env, token string, title, body string, tags []string) int64 {
	t.Helper()
	var out struct {
		ID int64 `json:"id"`
	}
	resp := env.Call("POST", "/api/v1/memos", token,
		map[string]any{"title": title, "body": body, "tags": tags}, &out)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create %q: status %d, want 201", title, resp.StatusCode)
	}
	return out.ID
}

// search runs a query and returns the hit titles, newest first.
func search(t *testing.T, env *apitest.Env, token, q string) []string {
	t.Helper()
	var out struct {
		Memos []struct {
			Title string `json:"title"`
		} `json:"memos"`
	}
	resp := env.Call("GET", "/api/v1/memos?q="+q, token, nil, &out)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("search %q: status %d, want 200", q, resp.StatusCode)
	}
	titles := make([]string, 0, len(out.Memos))
	for _, m := range out.Memos {
		titles = append(titles, m.Title)
	}
	return titles
}

// The ticket's three sources each get a hit, users stay isolated, and the
// recycle bin stays out of the results (T6).
func TestSearchHitsTitleBodyAndTag(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bobToken := createUserAndLogin(t, env, administrator, "bob", "bob password").Token

	createMemo(t, env, administrator.Token, "英语学习笔记", "今天背了五十个词", []string{"日常"})
	createMemo(t, env, administrator.Token, "购物清单", "记得买 abandon 的练习册", nil)
	createMemo(t, env, administrator.Token, "周末安排", "睡个懒觉", []string{"英语"})
	// bob's memos must never surface in the administrator's search, even on
	// identical wording.
	createMemo(t, env, bobToken, "英语学习笔记", "今天背了五十个词", []string{"英语"})

	if got := search(t, env, administrator.Token, "英语学习"); len(got) != 1 || got[0] != "英语学习笔记" {
		t.Errorf("title hit = %v, want [英语学习笔记]", got)
	}
	if got := search(t, env, administrator.Token, "abandon"); len(got) != 1 || got[0] != "购物清单" {
		t.Errorf("body hit = %v, want [购物清单]", got)
	}
	if got := search(t, env, administrator.Token, "英语"); len(got) != 2 || !slices.Contains(got, "周末安排") || !slices.Contains(got, "英语学习笔记") {
		t.Errorf("tag+title hit = %v, want 周末安排 and 英语学习笔记", got)
	}
	if got := search(t, env, bobToken, "英语"); len(got) != 1 || got[0] != "英语学习笔记" {
		t.Errorf("bob search = %v, want only bob's own memo", got)
	}
	// A tag on top of the query narrows the hits further.
	var combined struct {
		Memos []struct {
			Title string `json:"title"`
		} `json:"memos"`
	}
	if resp := env.Call("GET", "/api/v1/memos?q=英语&tag=日常", administrator.Token, nil, &combined); resp.StatusCode != http.StatusOK {
		t.Fatalf("combined search: status %d, want 200", resp.StatusCode)
	}
	if len(combined.Memos) != 1 || combined.Memos[0].Title != "英语学习笔记" {
		t.Errorf("q+tag search = %+v, want only 英语学习笔记", combined.Memos)
	}
	if got := search(t, env, administrator.Token, "查无此词"); len(got) != 0 {
		t.Errorf("miss query = %v, want empty", got)
	}
}

// A tag hit must surface a memo whose body never mentions the word — the
// same rule as tag filtering (T4), now for search (T6).
func TestSearchTagHitWithBodyMissingWord(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	// Body has no 英语 anywhere; the tag alone must carry the hit.
	createMemo(t, env, administrator.Token, "购物", "牛奶、鸡蛋", []string{"英语"})
	if got := search(t, env, administrator.Token, "英语"); len(got) != 1 || got[0] != "购物" {
		t.Errorf("tag hit = %v, want [购物]", got)
	}

	// A mid-word query keeps working inside titles and bodies: 学 must
	// reach 学习 even though unicode61 would glue the run into one token.
	createMemo(t, env, administrator.Token, "英语学习笔记", "坚持学习", nil)
	if got := search(t, env, administrator.Token, "学习"); len(got) != 1 || got[0] != "英语学习笔记" {
		t.Errorf("mid-run hit = %v, want [英语学习笔记]", got)
	}
}

// The index must track every change path: edit, retag, trash, restore,
// purge — and a restart (T6).
func TestSearchStaysFreshAcrossChanges(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	id := createMemo(t, env, administrator.Token, "法语笔记", "动词变位", []string{"语言"})

	// Editing the body away from the keyword drops the memo out.
	update := func(body string, tags []string) {
		t.Helper()
		resp := env.Call("PUT", "/api/v1/memos/"+itoa(id), administrator.Token,
			map[string]any{"title": "法语笔记", "body": body, "tags": tags}, nil)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("update: status %d, want 200", resp.StatusCode)
		}
	}
	update("动词变位练习", []string{"语言"})
	if got := search(t, env, administrator.Token, "变位"); len(got) != 1 {
		t.Errorf("after body edit = %v, want still [法语笔记]", got)
	}
	update("改学日语了", []string{"语言"})
	if got := search(t, env, administrator.Token, "变位"); len(got) != 0 {
		t.Errorf("stale body hit = %v, want empty", got)
	}

	// Adding a tag makes the memo findable by it; removing it again does not
	// leave a ghost hit.
	update("改学日语了", []string{"语言", "放弃"})
	if got := search(t, env, administrator.Token, "放弃"); len(got) != 1 || got[0] != "法语笔记" {
		t.Errorf("tag added = %v, want [法语笔记]", got)
	}
	update("改学日语了", []string{"语言"})
	if got := search(t, env, administrator.Token, "放弃"); len(got) != 0 {
		t.Errorf("tag removed = %v, want empty", got)
	}

	// Trashed memos leave the search; restored ones come back; purged ones
	// are gone for good.
	env.Call("DELETE", "/api/v1/memos/"+itoa(id), administrator.Token, nil, nil)
	if got := search(t, env, administrator.Token, "语言"); len(got) != 0 {
		t.Errorf("trashed memo still searchable = %v, want empty", got)
	}
	env.Call("POST", "/api/v1/trash/"+itoa(id)+"/restore", administrator.Token, nil, nil)
	if got := search(t, env, administrator.Token, "语言"); len(got) != 1 || got[0] != "法语笔记" {
		t.Errorf("restored memo = %v, want [法语笔记]", got)
	}
	env.Call("DELETE", "/api/v1/memos/"+itoa(id), administrator.Token, nil, nil)
	env.Call("DELETE", "/api/v1/trash/"+itoa(id), administrator.Token, nil, nil)
	if got := search(t, env, administrator.Token, "语言"); len(got) != 0 {
		t.Errorf("purged memo still searchable = %v, want empty", got)
	}

	// The surviving index is on disk: a restart must not lose it.
	createMemo(t, env, administrator.Token, "重启后仍在", "索引随库落盘", nil)
	env.Restart()
	if got := search(t, env, administrator.Token, "落盘"); len(got) != 1 || got[0] != "重启后仍在" {
		t.Errorf("search after restart = %v, want [重启后仍在]", got)
	}
}
