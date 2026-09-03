package api_test

import (
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// helper: create a user through the API under test and log in with the
// issued credentials, standing in for the new user's client.
func createUserAndLogin(t *testing.T, env *apitest.Env, admin *apitest.Credentials, username, password string) apitest.Credentials {
	t.Helper()
	var created struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/users", admin.Token,
		map[string]string{"username": username, "password": password}, &created); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create %s: status %d, want 201", username, resp.StatusCode)
	}
	return loginAs(t, env, username, password, created.ID)
}

func loginAs(t *testing.T, env *apitest.Env, username, password string, wantID int64) apitest.Credentials {
	t.Helper()
	var out struct {
		Token string `json:"token"`
		User  struct {
			ID       int64  `json:"id"`
			Username string `json:"username"`
			Role     string `json:"role"`
		} `json:"user"`
	}
	resp := env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": username, "password": password}, &out)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login %s with %q: status %d, want 200", username, password, resp.StatusCode)
	}
	if out.User.ID != wantID || out.User.Username != username {
		t.Errorf("login returned user %+v, want id %d username %s", out.User, wantID, username)
	}
	return apitest.Credentials{Username: username, Password: password, Token: out.Token, ID: out.User.ID}
}

func TestAdministratorCreatesUsers(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	// The user list starts with just the administrator, who owns no memos.
	var listed struct {
		Users []struct {
			ID        int64  `json:"id"`
			Username  string `json:"username"`
			Role      string `json:"role"`
			MemoCount int64  `json:"memo_count"`
		} `json:"users"`
	}
	if resp := env.Call("GET", "/api/v1/users", administrator.Token, nil, &listed); resp.StatusCode != http.StatusOK {
		t.Fatalf("list users: status %d, want 200", resp.StatusCode)
	}
	if len(listed.Users) != 1 || listed.Users[0].Username != "admin" || listed.Users[0].Role != "administrator" || listed.Users[0].MemoCount != 0 {
		t.Fatalf("fresh user list = %+v, want only the administrator", listed.Users)
	}

	bob := createUserAndLogin(t, env, administrator, "bob", "bob's password")
	if bob.ID == 0 {
		t.Fatal("created user has no id")
	}

	// A user created through the console can log in at once with the issued
	// credentials, and the token works like any other session.
	if resp := env.Call("GET", "/api/v1/memos", bob.Token, nil, nil); resp.StatusCode != http.StatusOK {
		t.Errorf("new user GET memos: status %d, want 200", resp.StatusCode)
	}

	// Usernames are unique.
	if resp := env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": "bob", "password": "x"}, nil); resp.StatusCode != http.StatusConflict {
		t.Errorf("duplicate username: status %d, want 409", resp.StatusCode)
	}
	// The administrator's own name is taken too.
	if resp := env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": " admin ", "password": "x"}, nil); resp.StatusCode != http.StatusConflict {
		t.Errorf("recreate administrator name: status %d, want 409", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": "  ", "password": "x"}, nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("blank username: status %d, want 400", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": "carol", "password": ""}, nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("blank password: status %d, want 400", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/users", administrator.Token,
		map[string]string{"username": "carol", "password": "   "}, nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("whitespace password: status %d, want 400", resp.StatusCode)
	}

	// Everyone created this way is an ordinary user: only the setup wizard
	// makes administrators (ADR-0001).
	env.Call("GET", "/api/v1/users", administrator.Token, nil, &listed)
	if len(listed.Users) != 2 {
		t.Fatalf("user list = %+v, want 2", listed.Users)
	}
	for _, u := range listed.Users {
		if u.Username == "bob" && u.Role != "user" {
			t.Errorf("bob role = %q, want user", u.Role)
		}
	}
}

func TestAdministratorResetsAnyPassword(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bob := createUserAndLogin(t, env, administrator, "bob", "old password")
	alice := createUserAndLogin(t, env, administrator, "alice", "alice's password")

	if resp := env.Call("PUT", "/api/v1/users/"+itoa(bob.ID)+"/password", administrator.Token,
		map[string]string{"password": "new password"}, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("reset bob password: status %d, want 204", resp.StatusCode)
	}

	// The old password stops working…
	if resp := env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": "bob", "password": "old password"}, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("login with old password: status %d, want 401", resp.StatusCode)
	}
	// …and the new one is accepted.
	loginAs(t, env, "bob", "new password", bob.ID)

	// Resetting also ends sessions issued under the old password; alice is
	// untouched by bob's reset.
	if resp := env.Call("GET", "/api/v1/memos", bob.Token, nil, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("bob's pre-reset token after reset: status %d, want 401", resp.StatusCode)
	}
	if resp := env.Call("GET", "/api/v1/memos", alice.Token, nil, nil); resp.StatusCode != http.StatusOK {
		t.Errorf("alice's token after bob's reset: status %d, want 200", resp.StatusCode)
	}

	// Other users' passwords survive: only bob was reset.
	if resp := env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": "alice", "password": "alice's password"}, nil); resp.StatusCode != http.StatusOK {
		t.Errorf("alice login after bob's reset: status %d, want 200", resp.StatusCode)
	}

	if resp := env.Call("PUT", "/api/v1/users/"+itoa(bob.ID)+"/password", administrator.Token,
		map[string]string{"password": "  "}, nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("reset to blank password: status %d, want 400", resp.StatusCode)
	}
	if resp := env.Call("PUT", "/api/v1/users/9999/password", administrator.Token,
		map[string]string{"password": "x"}, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("reset missing user: status %d, want 404", resp.StatusCode)
	}

	// A reset password works through a restart: it lives in the database.
	env.Restart()
	loginAs(t, env, "bob", "new password", bob.ID)
}

func TestDeletingUserCascadesHard(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bob := createUserAndLogin(t, env, administrator, "bob", "bob's password")

	var bobMemo struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/memos", bob.Token, map[string]string{"title": "bob 的备忘录"}, &bobMemo); resp.StatusCode != http.StatusCreated {
		t.Fatalf("bob create memo: status %d, want 201", resp.StatusCode)
	}

	// The confirmation dialog's number comes from the user list.
	var listed struct {
		Users []struct {
			ID        int64  `json:"id"`
			Username  string `json:"username"`
			MemoCount int64  `json:"memo_count"`
		} `json:"users"`
	}
	env.Call("GET", "/api/v1/users", administrator.Token, nil, &listed)
	for _, u := range listed.Users {
		if u.Username == "bob" && u.MemoCount != 1 {
			t.Fatalf("bob memo_count = %d, want 1", u.MemoCount)
		}
	}

	if resp := env.Call("DELETE", "/api/v1/users/"+itoa(bob.ID), administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("delete bob: status %d, want 204", resp.StatusCode)
	}

	// The account can no longer log in…
	if resp := env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": "bob", "password": "bob's password"}, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("deleted user login: status %d, want 401", resp.StatusCode)
	}
	// …and its sessions die with it.
	if resp := env.Call("GET", "/api/v1/memos", bob.Token, nil, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("deleted user's token: status %d, want 401", resp.StatusCode)
	}

	// The deletion survives a restart.
	env.Restart()
	if resp := env.Call("POST", "/api/v1/auth/login", "",
		map[string]string{"username": "bob", "password": "bob's password"}, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("deleted user login after restart: status %d, want 401", resp.StatusCode)
	}

	// …and its data is really gone: the name is free again, and the fresh
	// account starts from zero.
	bob2 := createUserAndLogin(t, env, administrator, "bob", "bob's password")
	var list struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", bob2.Token, nil, &list)
	if len(list.Memos) != 0 {
		t.Errorf("recreated bob sees %d memos, want 0 (old data hard-deleted)", len(list.Memos))
	}

	// The administrator cannot delete their own account: the setup wizard is
	// one-way, so that would leave the instance permanently unmanageable.
	if resp := env.Call("DELETE", "/api/v1/users/"+itoa(administrator.ID), administrator.Token, nil, nil); resp.StatusCode != http.StatusConflict {
		t.Errorf("administrator deletes self: status %d, want 409", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/users/9999", administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Errorf("delete missing user: status %d, want 404", resp.StatusCode)
	}
}

func TestOnlyAdministratorManagesUsers(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bob := createUserAndLogin(t, env, administrator, "bob", "bob's password")

	if resp := env.Call("GET", "/api/v1/users", bob.Token, nil, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob GET users: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/users", bob.Token,
		map[string]string{"username": "carol", "password": "x"}, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob POST users: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("PUT", "/api/v1/users/"+itoa(administrator.ID)+"/password", bob.Token,
		map[string]string{"password": "x"}, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob resets administrator password: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("DELETE", "/api/v1/users/"+itoa(administrator.ID), bob.Token, nil, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob deletes administrator: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("GET", "/api/v1/users", "", nil, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("anonymous GET users: status %d, want 401", resp.StatusCode)
	}
}

func TestUserDatasAreFullyIsolated(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	alice := createUserAndLogin(t, env, administrator, "alice", "alice's password")
	bob := createUserAndLogin(t, env, administrator, "bob", "bob's password")

	var aliceMemo, bobMemo struct {
		ID int64 `json:"id"`
	}
	if resp := env.Call("POST", "/api/v1/memos", alice.Token, map[string]string{"title": "alice 的"}, &aliceMemo); resp.StatusCode != http.StatusCreated {
		t.Fatalf("alice create memo: status %d, want 201", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/memos", bob.Token, map[string]string{"title": "bob 的"}, &bobMemo); resp.StatusCode != http.StatusCreated {
		t.Fatalf("bob create memo: status %d, want 201", resp.StatusCode)
	}

	// Each list holds only its owner's memo.
	var list struct {
		Memos []struct {
			ID    int64  `json:"id"`
			Title string `json:"title"`
		} `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", alice.Token, nil, &list)
	if len(list.Memos) != 1 || list.Memos[0].ID != aliceMemo.ID {
		t.Errorf("alice's list = %+v, want only her memo", list.Memos)
	}
	env.Call("GET", "/api/v1/memos", bob.Token, nil, &list)
	if len(list.Memos) != 1 || list.Memos[0].ID != bobMemo.ID {
		t.Errorf("bob's list = %+v, want only his memo", list.Memos)
	}

	// Across accounts everything looks missing, never forbidden.
	for _, c := range []struct {
		name   string
		token  string
		target int64
	}{
		{"alice reads bob's", alice.Token, bobMemo.ID},
		{"bob reads alice's", bob.Token, aliceMemo.ID},
	} {
		if resp := env.Call("GET", "/api/v1/memos/"+itoa(c.target), c.token, nil, nil); resp.StatusCode != http.StatusNotFound {
			t.Errorf("%s memo: status %d, want 404", c.name, resp.StatusCode)
		}
	}
}
