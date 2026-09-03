package api_test

import (
	"net/http"
	"strconv"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

func TestAdministratorManagesCategories(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	type category struct {
		ID        int64  `json:"id"`
		Name      string `json:"name"`
		IsBuiltin bool   `json:"is_builtin"`
	}
	type categoriesOut struct {
		Categories []category `json:"categories"`
	}

	var listed categoriesOut
	if resp := env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed); resp.StatusCode != http.StatusOK {
		t.Fatalf("list before any change: status %d, want 200", resp.StatusCode)
	}
	if len(listed.Categories) != 1 || listed.Categories[0].Name != "未分类" || !listed.Categories[0].IsBuiltin {
		t.Fatalf("fresh instance categories = %+v, want only built-in 未分类", listed.Categories)
	}

	for _, name := range []string{"工作", "学习", "生活"} {
		var created category
		resp := env.Call("POST", "/api/v1/categories", administrator.Token,
			map[string]string{"name": name}, &created)
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("create %s: status %d, want 201", name, resp.StatusCode)
		}
		if created.Name != name || created.IsBuiltin {
			t.Errorf("create %s returned %+v", name, created)
		}
	}

	// Names are unique within the instance.
	if resp := env.Call("POST", "/api/v1/categories", administrator.Token,
		map[string]string{"name": "工作"}, nil); resp.StatusCode != http.StatusConflict {
		t.Errorf("duplicate name: status %d, want 409", resp.StatusCode)
	}
	// The built-in name belongs to 未分类 forever.
	if resp := env.Call("POST", "/api/v1/categories", administrator.Token,
		map[string]string{"name": "未分类"}, nil); resp.StatusCode != http.StatusConflict {
		t.Errorf("recreate built-in name: status %d, want 409", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/categories", administrator.Token,
		map[string]string{"name": "  "}, nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("blank name: status %d, want 400", resp.StatusCode)
	}

	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed)
	if len(listed.Categories) != 4 {
		t.Fatalf("categories = %+v, want 4 (未分类 + 3 created)", listed.Categories)
	}

	// A category the administrator just created can be deleted again.
	lifeID := listed.Categories[3].ID
	if resp := env.Call("DELETE", "/api/v1/categories/9999", administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("delete missing category: status %d, want 404", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/categories/"+itoa(lifeID), administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Errorf("delete 生活: status %d, want 204", resp.StatusCode)
	}

	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed)
	if len(listed.Categories) != 3 {
		t.Errorf("categories after delete = %+v, want 3", listed.Categories)
	}
	for _, c := range listed.Categories {
		if c.ID == lifeID {
			t.Errorf("deleted category 生活 still listed: %+v", c)
		}
	}
}

// itoa formats a category id for a URL path.
func itoa(id int64) string {
	return strconv.FormatInt(id, 10)
}

func TestUncategorizedIsProtected(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	type categoriesOut struct {
		Categories []struct {
			ID        int64  `json:"id"`
			Name      string `json:"name"`
			IsBuiltin bool   `json:"is_builtin"`
		} `json:"categories"`
	}
	var listed categoriesOut
	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed)
	if len(listed.Categories) != 1 {
		t.Fatalf("fresh instance categories = %+v, want only 未分类", listed.Categories)
	}
	id := itoa(listed.Categories[0].ID)

	if resp := env.Call("DELETE", "/api/v1/categories/"+id, administrator.Token, nil, nil); resp.StatusCode != http.StatusConflict {
		t.Errorf("delete 未分类: status %d, want 409", resp.StatusCode)
	}

	// The built-in survives a restart: it always exists.
	env.Restart()
	listed = categoriesOut{}
	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed)
	if len(listed.Categories) != 1 || listed.Categories[0].Name != "未分类" {
		t.Errorf("categories after restart = %+v, want 未分类", listed.Categories)
	}
}

func TestOnlyAdministratorChangesTaxonomy(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	// No administrator user-management API yet (that is T3), so the fixture
	// seeds an ordinary user at the store layer and logs in for real.
	if _, err := env.Store().CreateUser("bob", "bob's password", "user"); err != nil {
		t.Fatalf("seed bob: %v", err)
	}
	_, bobToken, err := env.Store().Login("bob", "bob's password")
	if err != nil {
		t.Fatalf("login bob: %v", err)
	}

	// Reading the taxonomy is for everyone: clients need it to offer the
	// category picker.
	if resp := env.Call("GET", "/api/v1/categories", bobToken, nil, nil); resp.StatusCode != http.StatusOK {
		t.Errorf("bob GET categories: status %d, want 200", resp.StatusCode)
	}
	if resp := env.Call("GET", "/api/v1/categories", "", nil, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("anonymous GET categories: status %d, want 401", resp.StatusCode)
	}

	if resp := env.Call("POST", "/api/v1/categories", bobToken,
		map[string]string{"name": "bob 的分类"}, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob POST category: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/categories/1", bobToken, nil, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob DELETE category: status %d, want 403", resp.StatusCode)
	}

	// The administrator still can, so the rejection is about the role.
	if resp := env.Call("POST", "/api/v1/categories", administrator.Token,
		map[string]string{"name": "工作"}, nil); resp.StatusCode != http.StatusCreated {
		t.Errorf("administrator POST category: status %d, want 201", resp.StatusCode)
	}
}

func TestMemoDefaultsToUncategorizedAndCanBeMoved(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	type categoriesOut struct {
		Categories []struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"categories"`
	}
	var listed categoriesOut
	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed)
	if len(listed.Categories) != 1 {
		t.Fatalf("fresh instance categories = %+v", listed.Categories)
	}
	uncategorizedID := listed.Categories[0].ID

	var work struct {
		ID int64 `json:"id"`
	}
	env.Call("POST", "/api/v1/categories", administrator.Token, map[string]string{"name": "工作"}, &work)

	type memoOut struct {
		ID         int64  `json:"id"`
		Title      string `json:"title"`
		CategoryID int64  `json:"category_id"`
	}

	// A memo created without a category lands in 未分类.
	var memo memoOut
	resp := env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]string{"title": "随手记"}, &memo)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create memo: status %d, want 201", resp.StatusCode)
	}
	if memo.CategoryID != uncategorizedID {
		t.Errorf("new memo category_id = %d, want 未分类 (%d)", memo.CategoryID, uncategorizedID)
	}

	// The user can move it into an existing category…
	resp = env.Call("PUT", "/api/v1/memos/"+itoa(memo.ID), administrator.Token,
		map[string]any{"title": "随手记", "body": "", "category_id": work.ID}, &memo)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("move memo: status %d, want 200", resp.StatusCode)
	}
	if memo.CategoryID != work.ID {
		t.Errorf("memo category_id after move = %d, want 工作 (%d)", memo.CategoryID, work.ID)
	}

	// …and explicitly create one inside a category.
	var inWork memoOut
	resp = env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "工作事项", "category_id": work.ID}, &inWork)
	if resp.StatusCode != http.StatusCreated || inWork.CategoryID != work.ID {
		t.Errorf("create in 工作: status %d category %+v", resp.StatusCode, inWork)
	}

	// Assigning a category that does not exist is rejected on create and move.
	for name, body := range map[string]any{
		"create, missing id": map[string]any{"title": "x", "category_id": work.ID + 999},
		"create, zero id":    map[string]any{"title": "x", "category_id": 0},
		"create, negative":   map[string]any{"title": "x", "category_id": -1},
		"move, missing id":   map[string]any{"title": "随手记", "category_id": work.ID + 999},
		"move, zero id":      map[string]any{"title": "随手记", "category_id": 0},
	} {
		method, path := "POST", "/api/v1/memos"
		if name == "move, missing id" || name == "move, zero id" {
			method, path = "PUT", "/api/v1/memos/"+itoa(memo.ID)
		}
		if resp := env.Call(method, path, administrator.Token, body, nil); resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, resp.StatusCode)
		}
	}
}

func TestDeletingCategoryFallsMemosBackToUncategorized(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	type categoryOut struct {
		ID int64 `json:"id"`
	}
	var work, study categoryOut
	env.Call("POST", "/api/v1/categories", administrator.Token, map[string]string{"name": "工作"}, &work)
	env.Call("POST", "/api/v1/categories", administrator.Token, map[string]string{"name": "学习"}, &study)

	type categoriesOut struct {
		Categories []struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"categories"`
	}
	var listed categoriesOut
	env.Call("GET", "/api/v1/categories", administrator.Token, nil, &listed)
	var uncategorizedID int64
	for _, c := range listed.Categories {
		if c.Name == "未分类" {
			uncategorizedID = c.ID
		}
	}

	type memoOut struct {
		ID         int64 `json:"id"`
		CategoryID int64 `json:"category_id"`
	}
	var inWork, inStudy, stillUncategorized memoOut
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "工作备忘录", "category_id": work.ID}, &inWork)
	env.Call("POST", "/api/v1/memos", administrator.Token,
		map[string]any{"title": "学习备忘录", "category_id": study.ID}, &inStudy)
	env.Call("POST", "/api/v1/memos", administrator.Token, map[string]string{"title": "无主备忘录"}, &stillUncategorized)

	if resp := env.Call("DELETE", "/api/v1/categories/"+itoa(study.ID), administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete 学习: status %d, want 204", resp.StatusCode)
	}

	// Every memo of the deleted category fell back to 未分类 — nothing lost.
	type memosOut struct {
		Memos []memoOut `json:"memos"`
	}
	var memos memosOut
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &memos)
	if len(memos.Memos) != 3 {
		t.Fatalf("memos after category delete = %d, want 3 (no data loss)", len(memos.Memos))
	}
	byTitle := map[string]int64{}
	for _, m := range memos.Memos {
		byTitle[map[int64]string{inWork.ID: "工作备忘录", inStudy.ID: "学习备忘录", stillUncategorized.ID: "无主备忘录"}[m.ID]] = m.CategoryID
	}
	if got := byTitle["学习备忘录"]; got != uncategorizedID {
		t.Errorf("学习备忘录 category_id = %d, want 未分类 (%d)", got, uncategorizedID)
	}
	if got := byTitle["工作备忘录"]; got != work.ID {
		t.Errorf("工作备忘录 category_id = %d, want untouched 工作 (%d)", got, work.ID)
	}
	if got := byTitle["无主备忘录"]; got != uncategorizedID {
		t.Errorf("无主备忘录 category_id = %d, want 未分类 (%d)", got, uncategorizedID)
	}

	// The fallback holds through a restart too.
	env.Restart()
	memos = memosOut{}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &memos)
	for _, m := range memos.Memos {
		if m.ID == inStudy.ID && m.CategoryID != uncategorizedID {
			t.Errorf("after restart 学习备忘录 category_id = %d, want 未分类 (%d)", m.CategoryID, uncategorizedID)
		}
	}
}
