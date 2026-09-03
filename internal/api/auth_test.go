package api_test

import (
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

func TestUninitializedInstanceOnlyExposesSetup(t *testing.T) {
	env := apitest.NewEnv(t)

	var instance struct {
		Initialized bool `json:"initialized"`
	}
	if resp := env.Call("GET", "/api/v1/instance", "", nil, &instance); resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /instance: status %d, want 200", resp.StatusCode)
	}
	if instance.Initialized {
		t.Fatal("fresh instance reports initialized")
	}

	if resp := env.Call("GET", "/api/v1/memos", "", nil, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("GET /memos before setup: status %d, want 401", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/auth/login", "", map[string]string{"username": "admin", "password": "x"}, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("login before setup: status %d, want 401", resp.StatusCode)
	}
}

func TestSetupWizardCreatesFirstAdministrator(t *testing.T) {
	env := apitest.NewEnv(t)

	var out struct {
		Token string `json:"token"`
		User  struct {
			ID       int64  `json:"id"`
			Username string `json:"username"`
			Role     string `json:"role"`
		} `json:"user"`
	}
	resp := env.Call("POST", "/api/v1/setup/administrator", "", map[string]string{"username": "yifeng", "password": "correct horse"}, &out)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("setup: status %d, want 201", resp.StatusCode)
	}
	if out.Token == "" {
		t.Error("setup returned no token")
	}
	if out.User.Username != "yifeng" || out.User.Role != "administrator" {
		t.Errorf("setup returned user %+v", out.User)
	}

	var instance struct {
		Initialized bool `json:"initialized"`
	}
	env.Call("GET", "/api/v1/instance", "", nil, &instance)
	if !instance.Initialized {
		t.Error("instance still uninitialized after setup")
	}

	// The token issued at setup is immediately usable.
	type memosOut struct {
		Memos []map[string]any `json:"memos"`
	}
	if resp := env.Call("GET", "/api/v1/memos", out.Token, nil, &memosOut{}); resp.StatusCode != http.StatusOK {
		t.Errorf("GET /memos with setup token: status %d, want 200", resp.StatusCode)
	}
}

func TestSetupWizardLocksForeverAfterCompletion(t *testing.T) {
	env := apitest.NewEnv(t)
	env.SetupAdministrator("yifeng", "correct horse")

	if resp := env.Call("POST", "/api/v1/setup/administrator", "", map[string]string{"username": "latecomer", "password": "x"}, nil); resp.StatusCode != http.StatusConflict {
		t.Fatalf("second setup: status %d, want 409", resp.StatusCode)
	}

	// Still locked after a restart: closure is permanent, not in-memory.
	env.Restart()
	if resp := env.Call("POST", "/api/v1/setup/administrator", "", map[string]string{"username": "latecomer", "password": "x"}, nil); resp.StatusCode != http.StatusConflict {
		t.Fatalf("setup after restart: status %d, want 409", resp.StatusCode)
	}
}

func TestSetupWizardRejectsBlankFields(t *testing.T) {
	env := apitest.NewEnv(t)

	cases := map[string]map[string]string{
		"blank username": {"username": "  ", "password": "x"},
		"blank password": {"username": "yifeng", "password": ""},
	}
	for name, body := range cases {
		if resp := env.Call("POST", "/api/v1/setup/administrator", "", body, nil); resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, resp.StatusCode)
		}
	}
}

func TestLogin(t *testing.T) {
	env := apitest.NewEnv(t)
	env.SetupAdministrator("yifeng", "correct horse")

	var out struct {
		Token string `json:"token"`
		User  struct {
			Username string `json:"username"`
		} `json:"user"`
	}
	resp := env.Call("POST", "/api/v1/auth/login", "", map[string]string{"username": "yifeng", "password": "correct horse"}, &out)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login: status %d, want 200", resp.StatusCode)
	}
	if out.Token == "" || out.User.Username != "yifeng" {
		t.Errorf("login returned token=%q user=%+v", out.Token, out.User)
	}
}

func TestLoginRejectsBadCredentials(t *testing.T) {
	env := apitest.NewEnv(t)
	env.SetupAdministrator("yifeng", "correct horse")

	cases := map[string]map[string]string{
		"wrong password": {"username": "yifeng", "password": "wrong"},
		"unknown user":   {"username": "nobody", "password": "correct horse"},
	}
	for name, body := range cases {
		if resp := env.Call("POST", "/api/v1/auth/login", "", body, nil); resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: status %d, want 401", name, resp.StatusCode)
		}
	}
}

func TestRequestsRequireValidToken(t *testing.T) {
	env := apitest.NewEnv(t)
	env.SetupAdministrator("yifeng", "correct horse")

	cases := map[string]struct {
		method string
		path   string
		token  string
	}{
		"no token":       {method: "GET", path: "/api/v1/memos", token: ""},
		"unknown token":  {method: "GET", path: "/api/v1/memos", token: "deadbeef"},
		"garbage header": {method: "GET", path: "/api/v1/memos", token: "not a bearer token"},
	}
	for name, c := range cases {
		if resp := env.Call(c.method, c.path, c.token, nil, nil); resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: status %d, want 401", name, resp.StatusCode)
		}
	}
}
