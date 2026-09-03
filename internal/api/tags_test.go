package api_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// tagsOf fetches one memo and returns its tag list.
func tagsOf(t *testing.T, env *apitest.Env, token, path string) []string {
	t.Helper()
	var memo struct {
		Tags []string `json:"tags"`
	}
	if resp := env.Call("GET", path, token, nil, &memo); resp.StatusCode != http.StatusOK {
		t.Fatalf("GET %s: status %d, want 200", path, resp.StatusCode)
	}
	return memo.Tags
}

func TestMemoTagsAddAndRemove(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	// A memo born with two tags: they come back in the order given.
	var created struct {
		ID   int64    `json:"id"`
		Tags []string `json:"tags"`
	}
	resp := env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "单词本", "body": "abandon", "tags": []string{"英语", "单词"}}, &created)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create with tags: status %d, want 201", resp.StatusCode)
	}
	if len(created.Tags) != 2 || created.Tags[0] != "英语" || created.Tags[1] != "单词" {
		t.Errorf("created tags = %v, want [英语 单词]", created.Tags)
	}

	// Duplicates collapse; a memo without tags has none.
	var deduped struct {
		Tags []string `json:"tags"`
	}
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "重复标签", "tags": []string{"英语", "英语"}}, &deduped)
	if len(deduped.Tags) != 1 || deduped.Tags[0] != "英语" {
		t.Errorf("deduped tags = %v, want [英语]", deduped.Tags)
	}
	var untagged struct {
		Tags []string `json:"tags"`
	}
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "无标签"}, &untagged)
	if len(untagged.Tags) != 0 {
		t.Errorf("untagged memo has tags %v, want empty", untagged.Tags)
	}

	// Saving with a shorter tag list removes the dropped ones (T4: 移除标签).
	var updated struct {
		Tags []string `json:"tags"`
	}
	resp = env.Call("PUT", "/api/v1/memos/1", administrator.Token,
		map[string]any{"title": "单词本", "body": "abandon", "tags": []string{"英语"}}, &updated)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("update removing a tag: status %d, want 200", resp.StatusCode)
	}
	if len(updated.Tags) != 1 || updated.Tags[0] != "英语" {
		t.Errorf("after removal tags = %v, want [英语]", updated.Tags)
	}

	// Saving without a tags field leaves the tags alone, same as the
	// category field.
	env.Call("PUT", "/api/v1/memos/1", administrator.Token,
		map[string]string{"title": "单词本", "body": "abandon v. 放弃"}, nil)
	if got := tagsOf(t, env, administrator.Token, "/api/v1/memos/1"); len(got) != 1 || got[0] != "英语" {
		t.Errorf("tags after update without tags field = %v, want [英语]", got)
	}

	// An empty tag list removes every tag.
	env.Call("PUT", "/api/v1/memos/1", administrator.Token,
		map[string]any{"title": "单词本", "body": "abandon", "tags": []string{}}, nil)
	if got := tagsOf(t, env, administrator.Token, "/api/v1/memos/1"); len(got) != 0 {
		t.Errorf("tags after clearing = %v, want empty", got)
	}
}

func TestTagValidation(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	longButOk := strings.Repeat("英", 50)
	tooLong := strings.Repeat("英", 51)
	cases := []struct {
		name string
		tags []string
		want int
	}{
		{"blank tag", []string{"  "}, http.StatusBadRequest},
		{"empty tag", []string{""}, http.StatusBadRequest},
		{"one over the limit", []string{tooLong}, http.StatusBadRequest},
		{"mixed good and empty", []string{"英语", ""}, http.StatusBadRequest},
		{"fifty runes is fine", []string{longButOk}, http.StatusCreated},
		{"chinese with spaces", []string{" 英语 单词 "}, http.StatusCreated},
	}
	for _, tc := range cases {
		resp := env.Call("POST", "/api/v1/memos", administrator.Token,
			map[string]any{"title": "标题", "tags": tc.tags}, nil)
		if resp.StatusCode != tc.want {
			t.Errorf("%s: status %d, want %d", tc.name, resp.StatusCode, tc.want)
		}
	}

	// Trimming happens server-side: the stored name has no edge spaces.
	var created struct {
		Tags []string `json:"tags"`
	}
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "空白处理", "tags": []string{" 英语 单词 "}}, &created)
	if len(created.Tags) != 1 || created.Tags[0] != "英语 单词" {
		t.Errorf("tags = %v, want [英语 单词]", created.Tags)
	}

	// A tag entry that is not a string is a malformed request.
	resp := env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "标题", "tags": []any{1}}, nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("non-string tag: status %d, want 400", resp.StatusCode)
	}

	// Tag changes count as memo changes.
	var before struct {
		UpdatedAt string `json:"updated_at"`
	}
	env.Call("POST", "/api/v1/memos", administrator.Token, map[string]string{"title": "原样"}, &before)
	var after struct {
		UpdatedAt string `json:"updated_at"`
	}
	env.Call("PUT", "/api/v1/memos/3", administrator.Token,
		map[string]any{"title": "原样", "tags": []string{"新标签"}}, &after)
	if after.UpdatedAt == before.UpdatedAt {
		t.Error("adding a tag did not bump updated_at")
	}
}

func TestTagSuggestionsUseOnlyOwnTags(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bobToken := createUserAndLogin(t, env, administrator, "bob", "bob password").Token

	// The administrator tags with 英语 and 单词; bob tags with 英语 and 法语.
	// The same name may exist for both — tags are not shared, only names may
	// coincide.
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "admin 的", "tags": []string{"英语", "单词"}}, nil)
	env.Call("POST", "/api/v1/memos", bobToken,
		map[string]any{"title": "bob 的", "tags": []string{"英语", "法语"}}, nil)

	fetch := func(token string) []string {
		var out struct {
			Tags []string `json:"tags"`
		}
		if resp := env.Call("GET", "/api/v1/tags", token, nil, &out); resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /api/v1/tags: status %d, want 200", resp.StatusCode)
		}
		return out.Tags
	}

	adminTags := fetch(administrator.Token)
	if len(adminTags) != 2 || adminTags[0] != "单词" || adminTags[1] != "英语" {
		t.Errorf("administrator suggestions = %v, want [单词 英语]", adminTags)
	}
	bobTags := fetch(bobToken)
	if len(bobTags) != 2 || bobTags[0] != "法语" || bobTags[1] != "英语" {
		t.Errorf("bob suggestions = %v, want [法语 英语]", bobTags)
	}
}

func TestFilterMemosByTag(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bobToken := createUserAndLogin(t, env, administrator, "bob", "bob password").Token

	// A carries 英语 but its body never mentions the word — the filter must
	// still hit it (T4: 正文没该词、标签有).
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "购物", "body": "牛奶、鸡蛋", "tags": []string{"英语"}}, nil)
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "笔记", "body": "英语课上抄的"}, nil)
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "另一条", "tags": []string{"单词"}}, nil)
	env.Call("POST", "/api/v1/memos", bobToken,
		map[string]any{"title": "bob 的", "tags": []string{"英语"}}, nil)

	titles := func(token, tag string) []string {
		path := "/api/v1/memos"
		if tag != "" {
			path += "?tag=" + tag
		}
		var out struct {
			Memos []struct {
				Title string `json:"title"`
			} `json:"memos"`
		}
		if resp := env.Call("GET", path, token, nil, &out); resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s: status %d, want 200", path, resp.StatusCode)
		}
		got := make([]string, 0, len(out.Memos))
		for _, m := range out.Memos {
			got = append(got, m.Title)
		}
		return got
	}

	if got := titles(administrator.Token, "英语"); len(got) != 1 || got[0] != "购物" {
		t.Errorf("filter 英语 = %v, want [购物]", got)
	}
	if got := titles(administrator.Token, "单词"); len(got) != 1 || got[0] != "另一条" {
		t.Errorf("filter 单词 = %v, want [另一条]", got)
	}
	if got := titles(administrator.Token, "不存在"); len(got) != 0 {
		t.Errorf("filter 不存在 = %v, want empty", got)
	}
	if got := titles(administrator.Token, ""); len(got) != 3 {
		t.Errorf("unfiltered = %v, want all 3", got)
	}

	// bob's filter sees bob's 英语 memo, never the administrator's.
	if got := titles(bobToken, "英语"); len(got) != 1 || got[0] != "bob 的" {
		t.Errorf("bob filter 英语 = %v, want [bob 的]", got)
	}

	// The tags survive a restart like every other data.
	env.Restart()
	if got := tagsOf(t, env, administrator.Token, "/api/v1/memos/1"); len(got) != 1 || got[0] != "英语" {
		t.Errorf("tags after restart = %v, want [英语]", got)
	}
}
