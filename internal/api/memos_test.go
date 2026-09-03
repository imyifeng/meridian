package api_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

func TestMemoCRUD(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	var created struct {
		ID        int64  `json:"id"`
		Title     string `json:"title"`
		Body      string `json:"body"`
		CreatedAt string `json:"created_at"`
		UpdatedAt string `json:"updated_at"`
	}
	resp := env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "购物清单", "body": "牛奶、鸡蛋"}, &created)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create: status %d, want 201", resp.StatusCode)
	}
	if created.ID == 0 || created.Title != "购物清单" || created.Body != "牛奶、鸡蛋" {
		t.Errorf("create returned %+v", created)
	}
	if created.CreatedAt == "" || created.UpdatedAt == "" {
		t.Errorf("create returned missing timestamps: %+v", created)
	}

	var list struct {
		Memos []map[string]any `json:"memos"`
	}
	resp = env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list: status %d, want 200", resp.StatusCode)
	}
	if len(list.Memos) != 1 {
		t.Fatalf("list has %d memos, want 1", len(list.Memos))
	}

	var got struct {
		ID    int64  `json:"id"`
		Title string `json:"title"`
	}
	resp = env.Call("GET", "/api/v1/memos/1", administrator.Token, nil, &got)
	if resp.StatusCode != http.StatusOK || got.Title != "购物清单" {
		t.Errorf("get: status %d title %q", resp.StatusCode, got.Title)
	}

	var updated struct {
		Title     string `json:"title"`
		Body      string `json:"body"`
		UpdatedAt string `json:"updated_at"`
	}
	resp = env.Call("PUT", "/api/v1/memos/1", administrator.Token,
		map[string]string{"title": "购物清单（改）", "body": "牛奶、鸡蛋、面包"}, &updated)
	if resp.StatusCode != http.StatusOK || updated.Title != "购物清单（改）" || updated.Body != "牛奶、鸡蛋、面包" {
		t.Errorf("update: status %d body %+v", resp.StatusCode, updated)
	}
	if updated.UpdatedAt == created.UpdatedAt {
		t.Error("update did not bump updated_at")
	}

	if resp := env.Call("DELETE", "/api/v1/memos/1", administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Errorf("delete: status %d, want 204", resp.StatusCode)
	}
	if resp := env.Call("GET", "/api/v1/memos/1", administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("get after delete: status %d, want 404", resp.StatusCode)
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if len(list.Memos) != 0 {
		t.Errorf("list after delete has %d memos, want 0", len(list.Memos))
	}
}

func TestMemoValidation(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	cases := map[string]any{
		"blank title":    map[string]string{"title": "  ", "body": "x"},
		"missing title":  map[string]string{"body": "x"},
		"no body at all": nil,
	}
	for name, body := range cases {
		if resp := env.Call("POST", "/api/v1/memos", administrator.Token, body, nil); resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, resp.StatusCode)
		}
	}

	env.Call("POST", "/api/v1/memos", administrator.Token, map[string]string{"title": "只标题"}, nil)
	var list struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if len(list.Memos) != 1 {
		t.Fatalf("list has %d memos, want 1", len(list.Memos))
	}
	if got, _ := list.Memos[0]["body"].(string); got != "" {
		t.Errorf("body = %q, want empty string", got)
	}
}

func TestMemosAreScopedToTheirOwner(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "管理员的备忘录", "body": "私密"}, nil)

	// A second user, created and logged in through the real API (T3).
	var bob struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": "bob", "password": "bob's password"}, &bob); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create bob: status %d, want 201", resp.StatusCode)
	}
	var bobSession struct {
		Token string `json:"token"`
	}
	env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": "bob", "password": "bob's password"}, &bobSession)
	bobToken := bobSession.Token

	// bob cannot read, change, or delete the administrator's memo: it looks like it
	// does not exist.
	if resp := env.Call("GET", "/api/v1/memos/1", bobToken, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("bob GET administrator memo: status %d, want 404", resp.StatusCode)
	}
	if resp := env.Call("PUT", "/api/v1/memos/1", bobToken,
		map[string]string{"title": "劫持", "body": ""}, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("bob PUT administrator memo: status %d, want 404", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/memos/1", bobToken, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("bob DELETE administrator memo: status %d, want 404", resp.StatusCode)
	}

	var list struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", bobToken, nil, &list)
	if len(list.Memos) != 0 {
		t.Errorf("bob's list has %d memos, want 0", len(list.Memos))
	}

	// bob's own memo lives in his scope, and IDs do not collide across
	// users' views.
	var bobMemo struct {
		ID int64 `json:"id"`
	}
	env.Call("POST", "/api/v1/memos", bobToken, map[string]string{"title": "bob 的"}, &bobMemo)
	if bobMemo.ID == 0 {
		t.Fatal("bob's create failed")
	}
	if resp := env.Call("GET", "/api/v1/memos/1", administrator.Token, nil, nil); resp.StatusCode != http.StatusOK {
		t.Errorf("administrator lost access to own memo: status %d", resp.StatusCode)
	}
}

func TestMemoNotFoundShapes(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	if resp := env.Call("GET", "/api/v1/memos/999", administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("missing memo: status %d, want 404", resp.StatusCode)
	}
	if resp := env.Call("GET", "/api/v1/memos/notanumber", administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("non-numeric id: status %d, want 404", resp.StatusCode)
	}
}

func TestDataSurvivesRestart(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "重启前", "body": "重启后还在"}, nil)

	env.Restart()

	// The credential is long-lived: the same token works after restart.
	var list struct {
		Memos []struct {
			Title string `json:"title"`
			Body  string `json:"body"`
		} `json:"memos"`
	}
	resp := env.Call("GET", "/api/v1/memos", administrator.Token, nil, &list)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list after restart: status %d, want 200", resp.StatusCode)
	}
	if len(list.Memos) != 1 || list.Memos[0].Title != "重启前" || list.Memos[0].Body != "重启后还在" {
		b, _ := json.Marshal(list)
		t.Errorf("memos after restart: %s", b)
	}

	// And the password still authenticates against the restarted instance.
	var out struct {
		Token string `json:"token"`
	}
	resp = env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": administrator.Username, "password": administrator.Password}, &out)
	if resp.StatusCode != http.StatusOK || out.Token == "" {
		t.Errorf("login after restart: status %d token %q", resp.StatusCode, out.Token)
	}
}
