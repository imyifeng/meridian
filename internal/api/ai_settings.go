package api

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/imyifeng/meridian/internal/llm"
	"github.com/imyifeng/meridian/internal/store"
)

// AI Settings (AI 设置) endpoints: the instance's single LLM access
// configuration (ADR-0009). Every route is administrator only, and the API
// key never leaves the server in plaintext — reads return a mask, writes
// keep the stored key unless the administrator typed a new one.

// aiSettingsView is the wire shape of a settings read. api_key carries the
// mask, never the stored plaintext (empty when no key is set).
type aiSettingsView struct {
	BaseURL string `json:"base_url"`
	Model   string `json:"model"`
	APIKey  string `json:"api_key"`
	Enabled bool   `json:"enabled"`
}

// maskAPIKey renders a stored key for display: its first three characters,
// an ellipsis, and its last four (sk-…abcd for sk-abcd's longer cousins). A
// key must be at least 12 characters to earn that treatment — anything
// shorter is masked outright, so nothing usable leaks; no key at all masks
// to an empty string.
func maskAPIKey(key string) string {
	if key == "" {
		return ""
	}
	if len(key) < 12 {
		return "••••"
	}
	return key[:3] + "…" + key[len(key)-4:]
}

func (s *server) getAISettings(w http.ResponseWriter, r *http.Request) {
	set, err := s.st.AISettings()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, aiSettingsView{
		BaseURL: set.BaseURL,
		Model:   set.Model,
		APIKey:  maskAPIKey(set.APIKey),
		Enabled: set.Enabled,
	})
}

// aiSettingsInput is a PUT body. api_key empty (or absent) keeps the stored
// key; any other value replaces it. The other fields replace wholesale.
type aiSettingsInput struct {
	BaseURL string `json:"base_url"`
	Model   string `json:"model"`
	APIKey  string `json:"api_key"`
	Enabled bool   `json:"enabled"`
}

// validAISettings applies the save rules: the enabled switch is the agent's
// master gate, so it only turns on over a complete configuration, and a
// base URL must be an absolute http(s) URL — it is what the server dials.
func validAISettings(settings store.AISettings) bool {
	if settings.Enabled && (settings.BaseURL == "" || settings.Model == "") {
		return false
	}
	if settings.BaseURL == "" {
		return true
	}
	u, err := url.Parse(settings.BaseURL)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

func (s *server) putAISettings(w http.ResponseWriter, r *http.Request) {
	var in aiSettingsInput
	if !decodeBody(w, r, &in) {
		return
	}
	set := store.AISettings{
		BaseURL: strings.TrimRight(strings.TrimSpace(in.BaseURL), "/"),
		Model:   strings.TrimSpace(in.Model),
		APIKey:  in.APIKey,
		Enabled: in.Enabled,
	}
	if !validAISettings(set) {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := s.st.SaveAISettings(set); err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	s.getAISettings(w, r)
}

// testAISettings dials the saved configuration with one minimal streaming
// request — the same wire the agent itself will use (ADR-0009) — and
// reports whether it worked. The answer is always 200: the HTTP status says
// the test ran, the body says whether the connection succeeded, so the
// console can show the reason text as-is. The dial runs with a tight cap
// (small reply, short deadline): a test should never hang on a slow service.
func (s *server) testAISettings(w http.ResponseWriter, r *http.Request) {
	set, err := s.st.AISettings()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	if set.BaseURL == "" || set.Model == "" {
		writeJSON(w, http.StatusOK, map[string]any{
			"success": false,
			"reason":  "尚未配置模型服务，请先填写 Base URL 与模型名并保存",
		})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), testDialTimeout)
	defer cancel()
	client := &llm.Client{BaseURL: set.BaseURL, APIKey: set.APIKey}
	_, err = client.Chat(ctx, llm.ChatRequest{
		Model: set.Model,
		Messages: []llm.Message{
			{Role: "user", Content: "连接测试，请回复 OK"},
		},
		MaxTokens: 16,
	})
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"success": false,
			"reason":  testFailureReason(err),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

// testDialTimeout bounds the one minimal request the connection test sends.
const testDialTimeout = 15 * time.Second

// testFailureReason turns a dial failure into the text the console shows.
// The key never enters any llm.Error detail, so it cannot leak from here.
func testFailureReason(err error) string {
	var e *llm.Error
	if !errors.As(err, &e) {
		return "连接测试失败：" + err.Error()
	}
	switch e.Kind {
	case llm.KindConnection:
		return "无法连接模型服务：" + e.Detail
	case llm.KindTimeout:
		return "模型服务响应超时，请检查地址或稍后再试"
	case llm.KindStatus:
		return "模型服务拒绝了请求（" + e.Detail + "）"
	case llm.KindStream:
		return "模型服务连接成功，但响应流异常：" + e.Detail
	default:
		return "连接测试失败：" + e.Error()
	}
}
