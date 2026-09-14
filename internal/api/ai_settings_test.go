package api_test

import (
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// AI Settings (AI 设置) is the instance's single LLM access configuration
// (ADR-0009): administrators read and write it here, nobody else touches it,
// and the API key only ever leaves the server masked.

// A fresh instance has an empty configuration: the agent gate is off until
// an administrator fills it in.
func TestAISettingsDefaults(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	var got struct {
		BaseURL string `json:"base_url"`
		Model   string `json:"model"`
		APIKey  string `json:"api_key"`
		Enabled bool   `json:"enabled"`
	}
	resp := env.Call("GET", "/api/v1/ai/settings", admin.Token, nil, &got)
	if resp.StatusCode != 200 {
		t.Fatalf("GET: status %d, want 200", resp.StatusCode)
	}
	if got.BaseURL != "" || got.Model != "" || got.APIKey != "" || got.Enabled {
		t.Errorf("GET: fresh settings %+v, want all empty and disabled", got)
	}
}

// Saving stores the configuration and the read hands back the key masked:
// the plaintext never round-trips to any client.
func TestAISettingsSaveMasksKey(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	resp := env.Call("PUT", "/api/v1/ai/settings", admin.Token, map[string]any{
		"base_url": "https://llm.example.com/v1",
		"model":    "meridian-mini",
		"api_key":  "sk-secret-abcd1234",
		"enabled":  true,
	}, nil)
	if resp.StatusCode != 200 {
		t.Fatalf("PUT: status %d, want 200", resp.StatusCode)
	}

	var got struct {
		BaseURL string `json:"base_url"`
		Model   string `json:"model"`
		APIKey  string `json:"api_key"`
		Enabled bool   `json:"enabled"`
	}
	env.Call("GET", "/api/v1/ai/settings", admin.Token, nil, &got)
	if got.BaseURL != "https://llm.example.com/v1" || got.Model != "meridian-mini" || !got.Enabled {
		t.Errorf("GET: non-secret fields %+v, want the saved values", got)
	}
	if got.APIKey == "sk-secret-abcd1234" {
		t.Errorf("GET: api_key %q comes back in plaintext", got.APIKey)
	}
	// Mask shape: a recognizable prefix, the ellipsis, and the last four
	// characters — enough to identify the key, not enough to use it.
	if got.APIKey != "sk-…1234" {
		t.Errorf("GET: api_key %q, want the mask sk-…1234", got.APIKey)
	}
}

// A key must be at least 12 characters before the mask shows its first
// three and last four; anything shorter is masked outright. Exactly 12 is
// the boundary: three plus four leaves five characters hidden.
func TestAISettingsKeyMaskThreshold(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	cases := []struct {
		key  string
		want string
	}{
		{"abc", "••••"},              // far too short
		{"abcdefghijk", "••••"},      // 11: one short of the line
		{"abcdefghijkl", "abc…ijkl"}, // exactly 12: 5 characters stay hidden
		{"sk-secret-abcd1234", "sk-…1234"},
	}
	for _, tc := range cases {
		env.Call("PUT", "/api/v1/ai/settings", admin.Token, map[string]any{
			"base_url": "https://llm.example.com/v1",
			"model":    "m",
			"api_key":  tc.key,
			"enabled":  false,
		}, nil)
		var got struct {
			APIKey string `json:"api_key"`
		}
		env.Call("GET", "/api/v1/ai/settings", admin.Token, nil, &got)
		if got.APIKey != tc.want {
			t.Errorf("key %q (len %d): mask %q, want %q", tc.key, len(tc.key), got.APIKey, tc.want)
		}
	}
}

// The key's three states: PUT without one (empty or omitted) keeps the
// stored key, PUT with one replaces it, and reads only ever show the mask.
func TestAISettingsKeyKeepAndReplace(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	put := env.Call("PUT", "/api/v1/ai/settings", admin.Token, map[string]any{
		"base_url": "https://llm.example.com/v1",
		"model":    "meridian-mini",
		"api_key":  "sk-first-abcd1234",
		"enabled":  true,
	}, nil)
	if put.StatusCode != 200 {
		t.Fatalf("initial PUT: status %d, want 200", put.StatusCode)
	}

	// An update that leaves the key out keeps the stored one.
	env.Call("PUT", "/api/v1/ai/settings", admin.Token, map[string]any{
		"base_url": "https://llm.example.com/v1",
		"model":    "meridian-max",
		"enabled":  true,
	}, nil)
	var got struct {
		Model  string `json:"model"`
		APIKey string `json:"api_key"`
	}
	env.Call("GET", "/api/v1/ai/settings", admin.Token, nil, &got)
	if got.Model != "meridian-max" {
		t.Errorf("GET: model %q, want meridian-max", got.Model)
	}
	if got.APIKey != "sk-…1234" {
		t.Errorf("GET: api_key %q, want the old key's mask sk-…1234", got.APIKey)
	}

	// A new key replaces the old one.
	env.Call("PUT", "/api/v1/ai/settings", admin.Token, map[string]any{
		"base_url": "https://llm.example.com/v1",
		"model":    "meridian-max",
		"api_key":  "sk-second-9999zzzz",
		"enabled":  true,
	}, nil)
	env.Call("GET", "/api/v1/ai/settings", admin.Token, nil, &got)
	if got.APIKey != "sk-…zzzz" {
		t.Errorf("GET: api_key %q, want the new key's mask sk-…zzzz", got.APIKey)
	}
}

// Every AI settings route is administrator only. A signed-in ordinary user
// gets 403 — no field of the configuration, not even its existence, leaks —
// and an anonymous caller gets 401 like everywhere else.
func TestAISettingsAdministratorOnly(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	bob := createUserAndLogin(t, env, administrator, "bob", "bob's password")

	body := map[string]any{"base_url": "https://llm.example.com/v1", "model": "m", "enabled": true}
	if resp := env.Call("GET", "/api/v1/ai/settings", bob.Token, nil, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob GET: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("PUT", "/api/v1/ai/settings", bob.Token, body, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob PUT: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("POST", "/api/v1/ai/settings/test", bob.Token, nil, nil); resp.StatusCode != http.StatusForbidden {
		t.Errorf("bob POST test: status %d, want 403", resp.StatusCode)
	}
	if resp := env.Call("GET", "/api/v1/ai/settings", "", nil, nil); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("anonymous GET: status %d, want 401", resp.StatusCode)
	}
}

// Validation: the enabled switch is the agent's master gate, so it can only
// be turned on over a complete configuration, and a base URL must at least
// be an http(s) URL.
func TestAISettingsValidation(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	cases := []struct {
		name string
		body map[string]any
	}{
		{"enabled without base_url", map[string]any{"model": "m", "enabled": true}},
		{"enabled without model", map[string]any{"base_url": "https://llm.example.com", "enabled": true}},
		{"non-http base_url", map[string]any{"base_url": "ftp://llm.example.com", "model": "m"}},
		{"garbage base_url", map[string]any{"base_url": "not a url", "model": "m"}},
	}
	for _, tc := range cases {
		resp := env.Call("PUT", "/api/v1/ai/settings", admin.Token, tc.body, nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", tc.name, resp.StatusCode)
		}
	}
}
