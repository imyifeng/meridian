package api_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// 连接测试 dials the saved configuration with one minimal request and
// reports what happened. The dial happens server-side — the key never
// leaves the instance — so the scripted fake LLM here stands in for the
// model service the administrator pointed Meridian at.

type testOutcome struct {
	Success bool   `json:"success"`
	Reason  string `json:"reason"`
}

func saveAIConfig(t *testing.T, env *apitest.Env, baseURL, model, key string) {
	t.Helper()
	resp := env.Call("PUT", "/api/v1/ai/settings", env.Administrator().Token, map[string]any{
		"base_url": baseURL,
		"model":    model,
		"api_key":  key,
		"enabled":  true,
	}, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("save AI settings: status %d, want 200", resp.StatusCode)
	}
}

// A well-formed SSE stream means the configuration works end to end: URL
// reachable, key accepted (as far as the test can see), model answered.
func TestAIConnectionTestSucceeds(t *testing.T) {
	var auth string
	var body map[string]any
	llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")

	var out testOutcome
	resp := env.Call("POST", "/api/v1/ai/settings/test", env.Administrator().Token, nil, &out)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("test: status %d, want 200", resp.StatusCode)
	}
	if !out.Success {
		t.Fatalf("test: success=false, reason=%q", out.Reason)
	}
	if auth != "Bearer sk-live-secret99" {
		t.Errorf("fake LLM saw Authorization %q, want the stored key as bearer", auth)
	}
	if body["model"] != "meridian-mini" {
		t.Errorf("fake LLM saw model %v, want meridian-mini", body["model"])
	}
	if body["stream"] != true {
		t.Errorf("fake LLM saw stream %v, want true (the agent's wire, ADR-0009)", body["stream"])
	}
}

func TestAIConnectionTestFailures(t *testing.T) {
	t.Run("unreachable address", func(t *testing.T) {
		dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
		dead.Close() // now refuses connections

		env := apitest.NewEnv(t)
		saveAIConfig(t, env, dead.URL, "m", "sk-live-secret99")

		var out testOutcome
		env.Call("POST", "/api/v1/ai/settings/test", env.Administrator().Token, nil, &out)
		if out.Success {
			t.Fatal("test: success=true for a dead address")
		}
		if out.Reason == "" {
			t.Fatal("test: no reason given")
		}
		if strings.Contains(out.Reason, "sk-live-secret99") {
			t.Errorf("reason %q leaks the API key", out.Reason)
		}
	})

	t.Run("service rejects with a status", func(t *testing.T) {
		llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprint(w, `{"error":"模型服务内部错误"}`)
		}))
		defer llm.Close()

		env := apitest.NewEnv(t)
		saveAIConfig(t, env, llm.URL, "m", "sk-live-secret99")

		var out testOutcome
		env.Call("POST", "/api/v1/ai/settings/test", env.Administrator().Token, nil, &out)
		if out.Success {
			t.Fatal("test: success=true for a 500ing service")
		}
		if !strings.Contains(out.Reason, "500") {
			t.Errorf("reason %q, want it to name HTTP 500", out.Reason)
		}
		if strings.Contains(out.Reason, "sk-live-secret99") {
			t.Errorf("reason %q leaks the API key", out.Reason)
		}
	})

	t.Run("nothing configured yet", func(t *testing.T) {
		env := apitest.NewEnv(t)
		env.Administrator()

		var out testOutcome
		env.Call("POST", "/api/v1/ai/settings/test", env.Administrator().Token, nil, &out)
		if out.Success {
			t.Fatal("test: success=true for an unconfigured instance")
		}
		if out.Reason == "" {
			t.Fatal("test: no reason given")
		}
	})
}
