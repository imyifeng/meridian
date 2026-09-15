package llm_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/imyifeng/meridian/internal/llm"
)

// The Client is the seam to the model service: one Chat call per
// completion, always streaming, with errors classified into the kinds the
// 连接测试 (and later the agent) can speak. The fake servers here script the
// wire the way an OpenAI-compatible service speaks it.

func newClient(server *httptest.Server) *llm.Client {
	return &llm.Client{BaseURL: server.URL, APIKey: "sk-test-key"}
}

func chatRequest() llm.ChatRequest {
	return llm.ChatRequest{
		Model:    "meridian-mini",
		Messages: []llm.Message{{Role: "user", Content: "连接测试，请回复 OK"}},
	}
}

// captureRequest records what the client actually put on the wire.
type captureRequest struct {
	header http.Header
	body   map[string]any
}

func handleCapture(t *testing.T, captured *captureRequest, respond func(w http.ResponseWriter)) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("fake LLM: undecodable request body: %v", err)
		}
		*captured = captureRequest{header: r.Header.Clone(), body: body}
		respond(w)
	}
}

// Every Chat rides the SSE wire (ADR-0009): the client streams, assembles
// the increments in order, and puts the expected OpenAI-compatible request
// on the wire — bearer key, model, messages, stream on.
func TestChatStreaming(t *testing.T) {
	var captured captureRequest
	srv := httptest.NewServer(handleCapture(t, &captured, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		for _, payload := range []string{
			`{"choices":[{"delta":{"role":"assistant"}}]}`,
			`{"choices":[{"delta":{"content":"你"}}]}`,
			`{"choices":[{"delta":{"content":"好"}}]}`,
			`{"choices":[{"delta":{}}]}`,
			`[DONE]`,
		} {
			fmt.Fprintf(w, "data: %s\n\n", payload)
			flusher.Flush()
		}
	}))
	defer srv.Close()

	got, err := newClient(srv).Chat(context.Background(), chatRequest())
	if err != nil {
		t.Fatalf("Chat: %v", err)
	}
	if got != "你好" {
		t.Errorf("Chat = %q, want 你好", got)
	}
	if auth := captured.header.Get("Authorization"); auth != "Bearer sk-test-key" {
		t.Errorf("Authorization %q, want Bearer sk-test-key", auth)
	}
	if captured.body["model"] != "meridian-mini" {
		t.Errorf("request model %v, want meridian-mini", captured.body["model"])
	}
	if captured.body["stream"] != true {
		t.Errorf("request stream %v, want true", captured.body["stream"])
	}
}

// OnDelta is the streaming outlet: each increment reaches the caller as it
// arrives, so the agent can relay the reply onward mid-stream (ADR-0009)
// while Chat still assembles the full text.
func TestChatOnDelta(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		for _, payload := range []string{
			`{"choices":[{"delta":{"content":"你"}}]}`,
			`{"choices":[{"delta":{"content":"好"}}]}`,
			`[DONE]`,
		} {
			fmt.Fprintf(w, "data: %s\n\n", payload)
			flusher.Flush()
		}
	}))
	defer srv.Close()

	var deltas []string
	got, err := newClient(srv).Chat(context.Background(), llm.ChatRequest{
		Model:    "meridian-mini",
		Messages: []llm.Message{{Role: "user", Content: "连接测试，请回复 OK"}},
		OnDelta:  func(delta string) { deltas = append(deltas, delta) },
	})
	if err != nil {
		t.Fatalf("Chat: %v", err)
	}
	if got != "你好" {
		t.Errorf("Chat = %q, want 你好", got)
	}
	if strings.Join(deltas, "") != "你好" {
		t.Errorf("deltas %q, want them to concatenate to 你好", deltas)
	}
	if len(deltas) < 2 {
		t.Errorf("deltas arrived as one lump %q, want increments", deltas)
	}
}

func TestChatStatusError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprint(w, `{"error":{"message":"Incorrect API key"}}`)
	}))
	defer srv.Close()

	_, err := newClient(srv).Chat(context.Background(), chatRequest())
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) {
		t.Fatalf("Chat error %v, want *llm.Error", err)
	}
	if llmErr.Kind != llm.KindStatus {
		t.Errorf("kind %q, want status", llmErr.Kind)
	}
	if llmErr.Status != http.StatusUnauthorized {
		t.Errorf("status %d, want 401", llmErr.Status)
	}
	// The detail names the service's own words — that is what the
	// administrator needs to fix a wrong key.
	if !strings.Contains(llmErr.Detail, "Incorrect API key") {
		t.Errorf("detail %q, want it to carry the response body", llmErr.Detail)
	}
}

func TestChatConnectionError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	srv.Close() // the address now refuses connections

	_, err := newClient(srv).Chat(context.Background(), chatRequest())
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) {
		t.Fatalf("Chat error %v, want *llm.Error", err)
	}
	if llmErr.Kind != llm.KindConnection {
		t.Errorf("kind %q, want connection", llmErr.Kind)
	}
}

func TestChatTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		fmt.Fprint(w, `{"choices":[]}`)
	}))
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := newClient(srv).Chat(ctx, chatRequest())
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) {
		t.Fatalf("Chat error %v, want *llm.Error", err)
	}
	if llmErr.Kind != llm.KindTimeout {
		t.Errorf("kind %q, want timeout", llmErr.Kind)
	}
}

// A stream cut off before its [DONE] is an interrupted stream, not a
// success — the agent would show a truncated reply.
func TestChatStreamInterrupted(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"只说一半")
		// connection drops mid-line: no [DONE], no trailing newline
		conn, buf, _ := w.(http.Hijacker).Hijack()
		buf.Flush()
		conn.Close()
	}))
	defer srv.Close()

	_, err := newClient(srv).Chat(context.Background(), chatRequest())
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) {
		t.Fatalf("Chat error %v, want *llm.Error", err)
	}
	if llmErr.Kind != llm.KindStream {
		t.Errorf("kind %q, want stream", llmErr.Kind)
	}
}

// Tool calling (T75) rides the same client: ChatWithTools offers the server's
// tools and reads a non-streaming completion back. Tool rounds are resolved
// server-side and silently; only the final text ever reaches the user, so the
// whole agent turn goes non-streaming — the streamed tool_calls increments
// are where OpenAI-compatible deployments disagree, and none of it is user
// visible anyway.

// searchTool is the one tool the tests offer.
func searchTool() llm.Tool {
	return llm.Tool{
		Name:        "search_memos",
		Description: "全文检索备忘录",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"query": map[string]any{"type": "string"},
			},
		},
	}
}

// The tools request puts the OpenAI function-calling shape on the wire:
// stream off, the tools array in type/function form, bearer key as ever.
func TestChatWithToolsRequestShape(t *testing.T) {
	var captured captureRequest
	srv := httptest.NewServer(handleCapture(t, &captured, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":"好"}}]}`)
	}))
	defer srv.Close()

	_, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model:    "meridian-mini",
		Messages: []llm.Message{{Role: "user", Content: "找一下"}},
		Tools:    []llm.Tool{searchTool()},
	})
	if err != nil {
		t.Fatalf("ChatWithTools: %v", err)
	}
	if captured.body["stream"] != false {
		t.Errorf("request stream %v, want false (tool rounds are non-streaming)", captured.body["stream"])
	}
	rawTools, ok := captured.body["tools"].([]any)
	if !ok || len(rawTools) != 1 {
		t.Fatalf("request tools %+v, want one tool", captured.body["tools"])
	}
	tool := rawTools[0].(map[string]any)
	if tool["type"] != "function" {
		t.Errorf("tool type %v, want function", tool["type"])
	}
	fn := tool["function"].(map[string]any)
	if fn["name"] != "search_memos" || fn["description"] != "全文检索备忘录" {
		t.Errorf("tool function %+v, want name/description carried", fn)
	}
	if fn["parameters"] == nil {
		t.Error("tool function misses its parameters schema")
	}
}

// A completion that answers in text comes back as Content with no tool calls.
func TestChatWithToolsTextReply(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":"找到了 2 条"}}]}`)
	}))
	defer srv.Close()

	resp, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model: "meridian-mini", Tools: []llm.Tool{searchTool()},
		Messages: []llm.Message{{Role: "user", Content: "找一下"}},
	})
	if err != nil {
		t.Fatalf("ChatWithTools: %v", err)
	}
	if resp.Content != "找到了 2 条" {
		t.Errorf("content %q, want 找到了 2 条", resp.Content)
	}
	if len(resp.ToolCalls) != 0 {
		t.Errorf("tool calls %+v, want none", resp.ToolCalls)
	}
}

// A completion that wants tools comes back as typed tool calls with raw JSON
// arguments for the server to execute.
func TestChatWithToolsToolCallReply(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":null,
			"tool_calls":[{"id":"call_1","type":"function","function":{"name":"search_memos","arguments":"{\"query\":\"会议\"}"}}]}}]}`)
	}))
	defer srv.Close()

	resp, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model: "meridian-mini", Tools: []llm.Tool{searchTool()},
		Messages: []llm.Message{{Role: "user", Content: "找一下会议记录"}},
	})
	if err != nil {
		t.Fatalf("ChatWithTools: %v", err)
	}
	if len(resp.ToolCalls) != 1 {
		t.Fatalf("tool calls %+v, want one", resp.ToolCalls)
	}
	call := resp.ToolCalls[0]
	if call.ID != "call_1" || call.Function.Name != "search_memos" {
		t.Errorf("tool call %+v, want call_1/search_memos", call)
	}
	if call.Function.Arguments != `{"query":"会议"}` {
		t.Errorf("arguments %q, want the raw JSON string", call.Function.Arguments)
	}
}

// The tool loop replays its rounds in the OpenAI protocol shape: the
// assistant's tool_calls message, then each tool result keyed by tool_call_id.
func TestChatWithToolsReplayShape(t *testing.T) {
	var captured captureRequest
	srv := httptest.NewServer(handleCapture(t, &captured, func(w http.ResponseWriter) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[{"message":{"role":"assistant","content":"好的"}}]}`)
	}))
	defer srv.Close()

	call := llm.ToolCall{ID: "call_9", Type: "function"}
	call.Function.Name = "search_memos"
	call.Function.Arguments = `{"query":"会议"}`
	_, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model: "meridian-mini", Tools: []llm.Tool{searchTool()},
		Messages: []llm.Message{
			{Role: "user", Content: "找一下会议记录"},
			{Role: "assistant", Content: "", ToolCalls: []llm.ToolCall{call}},
			{Role: "tool", Content: `{"results":[]}`, ToolCallID: "call_9"},
		},
	})
	if err != nil {
		t.Fatalf("ChatWithTools: %v", err)
	}
	msgs := captured.body["messages"].([]any)
	if len(msgs) != 3 {
		t.Fatalf("request carried %d messages, want 3", len(msgs))
	}
	assistant := msgs[1].(map[string]any)
	rawCalls, ok := assistant["tool_calls"].([]any)
	if !ok || len(rawCalls) != 1 {
		t.Fatalf("assistant message %+v, want one tool_call", assistant)
	}
	wire := rawCalls[0].(map[string]any)
	if wire["id"] != "call_9" || wire["type"] != "function" {
		t.Errorf("wire tool_call %+v, want id/type carried", wire)
	}
	fn := wire["function"].(map[string]any)
	if fn["name"] != "search_memos" || fn["arguments"] != `{"query":"会议"}` {
		t.Errorf("wire function %+v, want name/arguments carried", fn)
	}
	toolMsg := msgs[2].(map[string]any)
	if toolMsg["role"] != "tool" || toolMsg["tool_call_id"] != "call_9" || toolMsg["content"] != `{"results":[]}` {
		t.Errorf("tool message %+v, want role/tool_call_id/content carried", toolMsg)
	}
}

// A 200 that speaks nonsense is an interrupted answer, not a quiet success.
func TestChatWithToolsMalformedBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `这不是JSON`)
	}))
	defer srv.Close()

	_, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model: "meridian-mini", Tools: []llm.Tool{searchTool()},
		Messages: []llm.Message{{Role: "user", Content: "找一下"}},
	})
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) {
		t.Fatalf("ChatWithTools error %v, want *llm.Error", err)
	}
	if llmErr.Kind != llm.KindStream {
		t.Errorf("kind %q, want stream", llmErr.Kind)
	}
}

// A 200 with no choices at all is the same story.
func TestChatWithToolsEmptyChoices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[]}`)
	}))
	defer srv.Close()

	_, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model: "meridian-mini", Tools: []llm.Tool{searchTool()},
		Messages: []llm.Message{{Role: "user", Content: "找一下"}},
	})
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) || llmErr.Kind != llm.KindStream {
		t.Fatalf("error %v, want *llm.Error kind stream", err)
	}
}

// Status failures classify the same way streaming ones do.
func TestChatWithToolsStatusError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		fmt.Fprint(w, `{"error":{"message":"Incorrect API key"}}`)
	}))
	defer srv.Close()

	_, err := newClient(srv).ChatWithTools(context.Background(), llm.ToolsRequest{
		Model: "meridian-mini", Tools: []llm.Tool{searchTool()},
		Messages: []llm.Message{{Role: "user", Content: "找一下"}},
	})
	var llmErr *llm.Error
	if !errors.As(err, &llmErr) {
		t.Fatalf("error %v, want *llm.Error", err)
	}
	if llmErr.Kind != llm.KindStatus || llmErr.Status != http.StatusUnauthorized {
		t.Errorf("error %+v, want status 401", llmErr)
	}
}
