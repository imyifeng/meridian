package api_test

import (
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// Story 10: browse memos by category. The list endpoint takes category_id
// alongside tag and q (T14); the built-in 未分类 is a normal choice — it is
// where new memos start and where deleted categories' memos fall back.
func TestFilterMemosByCategory(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bobToken := createUserAndLogin(t, env, administrator, "bob", "bob password").Token

	workID, studyID, builtinID := createCategory(t, env, administrator.Token, "工作"),
		createCategory(t, env, administrator.Token, "学习"),
		builtinCategoryID(t, env, administrator.Token)

	// 购物's text never mentions 工作 — the category alone must surface it,
	// the same rule as tag filtering (T4): the filter rides the assignment,
	// not the words.
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "购物", "body": "牛奶、鸡蛋", "category_id": workID}, nil)
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "随手记", "body": "晨会记录", "tags": []string{"英语"}}, nil) // 未分类 by default
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "复习", "category_id": studyID}, nil)
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "晨会", "category_id": workID, "tags": []string{"英语"}}, nil)
	env.Call("POST", "/api/v1/memos", bobToken,
		map[string]any{"title": "bob 的", "category_id": workID}, nil)

	titles := func(token, query string) []string {
		var out struct {
			Memos []struct {
				Title string `json:"title"`
			} `json:"memos"`
		}
		if resp := env.Call("GET", "/api/v1/memos"+query, token, nil, &out); resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status %d, want 200", query, resp.StatusCode)
		}
		got := make([]string, 0, len(out.Memos))
		for _, m := range out.Memos {
			got = append(got, m.Title)
		}
		return got
	}

	if got := titles(administrator.Token, "?category_id="+itoa(workID)); len(got) != 2 || got[0] != "晨会" || got[1] != "购物" {
		t.Errorf("filter 工作 = %v, want [晨会 购物] (newest first, bob's memo invisible)", got)
	}
	if got := titles(administrator.Token, "?category_id="+itoa(studyID)); len(got) != 1 || got[0] != "复习" {
		t.Errorf("filter 学习 = %v, want [复习]", got)
	}
	uncategorized := titles(administrator.Token, "?category_id="+itoa(builtinID))
	if len(uncategorized) != 1 || uncategorized[0] != "随手记" {
		t.Errorf("filter 未分类 = %v, want [随手记]", uncategorized)
	}

	// Deleting 学习 drops 复习 into 未分类; the filter follows the memos there.
	env.Call("DELETE", "/api/v1/categories/"+itoa(studyID), administrator.Token, nil, nil)
	if got := titles(administrator.Token, "?category_id="+itoa(builtinID)); len(got) != 2 {
		t.Errorf("filter 未分类 after deleting 学习 = %v, want [复习 随手记]", got)
	}

	// The filters are orthogonal: each narrows the others, and neither
	// category nor tag needs a textual trace in the memo. The bare tag and
	// search both hit 随手记 too, so the category is what narrows these.
	if got := titles(administrator.Token, "?category_id="+itoa(workID)+"&tag=英语"); len(got) != 1 || got[0] != "晨会" {
		t.Errorf("filter 工作+英语 = %v, want [晨会]", got)
	}
	if got := titles(administrator.Token, "?category_id="+itoa(workID)+"&q=晨会"); len(got) != 1 || got[0] != "晨会" {
		t.Errorf("filter 工作 + search 晨会 = %v, want [晨会]", got)
	}

	// A well-formed unknown id is a miss, like a tag no memo carries.
	if got := titles(administrator.Token, "?category_id=9999"); len(got) != 0 {
		t.Errorf("filter unknown category = %v, want empty", got)
	}

	// A malformed or non-positive id is a client bug, not a miss.
	for _, bad := range []string{"abc", "0", "-1"} {
		resp := env.Call("GET", "/api/v1/memos?category_id="+bad, administrator.Token, nil, nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("category_id=%s: status %d, want 400", bad, resp.StatusCode)
		}
	}

	// No parameter at all still lists everything.
	if got := titles(administrator.Token, ""); len(got) != 4 {
		t.Errorf("unfiltered = %v, want all 4", got)
	}
}

func createCategory(t *testing.T, env *apitest.Env, token, name string) int64 {
	t.Helper()
	var out struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/categories", token, map[string]string{"name": name}, &out); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create category %s: status %d, want 201", name, resp.StatusCode)
	}
	return out.ID
}

// builtinCategoryID looks up the built-in 未分类 through the API — the id
// is whatever the instance seeded, never assumed.
func builtinCategoryID(t *testing.T, env *apitest.Env, token string) int64 {
	t.Helper()
	var out struct {
		Categories []struct {
			ID        int64 `json:"id"`
			IsBuiltIn bool  `json:"is_builtin"`
		} `json:"categories"`
	}
	if resp := env.Call("GET", "/api/v1/categories", token, nil, &out); resp.StatusCode != http.StatusOK {
		t.Fatalf("list categories: status %d, want 200", resp.StatusCode)
	}
	for _, c := range out.Categories {
		if c.IsBuiltIn {
			return c.ID
		}
	}
	t.Fatal("no built-in category")
	return 0
}
