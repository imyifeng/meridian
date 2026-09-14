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
