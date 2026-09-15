package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Message is one turn of a chat conversation. The tool-calling fields
// (T75) replay a function-calling round in the OpenAI protocol shape: an
// assistant message may carry tool_calls, and each tool result answers one
// of them by tool_call_id.
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
}

// Tool is one function the server offers to the model: a name, a plain-text
// description of when to use it, and a JSON Schema for its arguments.
type Tool struct {
	Name        string
	Description string
	Parameters  map[string]any
}

// ToolCall is the model's request to invoke one tool, in the OpenAI wire
// shape (kept verbatim so a persisted round replays byte-identical). The
// arguments are the raw JSON string — the server, not this package, decodes
// them against the tool's schema.
type ToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
}

// ToolsRequest is one chat-completions call with tools offered. Unlike Chat
// it is non-streaming: a completion under tools may answer with tool_calls
// or with text, and the streamed incremental form of tool_calls is exactly
// where OpenAI-compatible deployments disagree — while both answers, once
// complete, are plain JSON. The agent's tool rounds resolve silently
// server-side either way (ADR-0009: the user only ever sees final text), so
// the whole agent turn goes non-streaming and the final text is relayed to
// the client over the existing delta frames.
type ToolsRequest struct {
	Model     string
	Messages  []Message
	Tools     []Tool
	MaxTokens int
}

// ChatResponse is one complete non-streaming completion: display text
// and/or tool calls. Both non-empty at once is treated by the caller as a
// tool round — the text of such a round is protocol chatter, not reply.
type ChatResponse struct {
	Content   string
	ToolCalls []ToolCall
}

// ChatRequest is one chat-completions call. Every call rides the SSE wire
// (ADR-0009: the model's final replies always stream); Chat assembles the
// increments into the full reply text before returning.
type ChatRequest struct {
	Model     string
	Messages  []Message
	MaxTokens int
	// OnDelta, when non-nil, receives each increment of reply text as it
	// arrives, so a caller can relay the reply onward mid-stream. Chat still
	// returns the assembled text either way.
	OnDelta func(string)
}

func (r ChatRequest) body() map[string]any {
	b := map[string]any{
		"model":    r.Model,
		"messages": r.Messages,
		"stream":   true,
	}
	if r.MaxTokens > 0 {
		b["max_tokens"] = r.MaxTokens
	}
	return b
}

// Kind classifies a Chat failure: where it happened and whose fault it is.
type Kind string

const (
	KindConnection Kind = "connection" // could not reach or talk to the service
	KindTimeout    Kind = "timeout"    // the call outlived its deadline
	KindStatus     Kind = "status"     // the service answered, and not with 200
	KindStream     Kind = "stream"     // a 200 stream broke or made no sense
)

// Error is a failed Chat. Detail is safe to show an administrator: it never
// carries the API key (which travels only in a request header).
type Error struct {
	Kind   Kind
	Status int    // HTTP status when Kind is KindStatus, else 0
	Detail string // human-readable specifics
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Kind)
	}
	return fmt.Sprintf("%s: %s", e.Kind, e.Detail)
}

// Client talks to one OpenAI-compatible deployment: a base URL (through the
// chat/completions endpoint) and the bearer key. Safe for concurrent use.
type Client struct {
	BaseURL string
	APIKey  string
}

// Chat runs the request over the SSE wire and returns the assistant's full
// reply text. The context bounds the whole call — dial, headers, and every
// chunk read.
func (c *Client) Chat(ctx context.Context, req ChatRequest) (string, error) {
	hresp, err := c.post(ctx, req.body())
	if err != nil {
		return "", err
	}
	defer hresp.Body.Close()
	if hresp.StatusCode != http.StatusOK {
		return "", statusError(hresp)
	}
	return readStream(hresp.Body, req.OnDelta)
}

// ChatWithTools offers req.Tools and reads one complete non-streaming
// completion back (see ToolsRequest for why not streaming). The context
// bounds the whole call.
func (c *Client) ChatWithTools(ctx context.Context, req ToolsRequest) (ChatResponse, error) {
	body := map[string]any{
		"model":    req.Model,
		"messages": req.Messages,
		"tools":    toolsWire(req.Tools),
		"stream":   false,
	}
	if req.MaxTokens > 0 {
		body["max_tokens"] = req.MaxTokens
	}
	hresp, err := c.post(ctx, body)
	if err != nil {
		return ChatResponse{}, err
	}
	defer hresp.Body.Close()
	if hresp.StatusCode != http.StatusOK {
		return ChatResponse{}, statusError(hresp)
	}
	raw, err := io.ReadAll(io.LimitReader(hresp.Body, 8<<20))
	if err != nil {
		return ChatResponse{}, &Error{Kind: KindStream, Detail: "响应读取失败：" + err.Error()}
	}
	return parseCompletion(raw)
}

// post puts one chat-completions request on the wire: the shared dial,
// headers, and error classification of both the streaming and the
// tool-calling call. The caller owns the response body.
func (c *Client) post(ctx context.Context, body map[string]any) (*http.Response, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, &Error{Kind: KindConnection, Detail: "构造请求失败"}
	}
	url := strings.TrimRight(c.BaseURL, "/") + "/chat/completions"
	hreq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return nil, &Error{Kind: KindConnection, Detail: "Base URL 无效"}
	}
	hreq.Header.Set("Content-Type", "application/json")
	hreq.Header.Set("Authorization", "Bearer "+c.APIKey)

	hresp, err := http.DefaultClient.Do(hreq)
	if err != nil {
		if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
			return nil, &Error{Kind: KindTimeout, Detail: "等待模型服务响应超时"}
		}
		return nil, &Error{Kind: KindConnection, Detail: err.Error()}
	}
	return hresp, nil
}

// statusError classifies a non-200 answer; the body rides the detail so an
// administrator can see the service's own words.
func statusError(hresp *http.Response) *Error {
	body, _ := io.ReadAll(io.LimitReader(hresp.Body, 1<<20))
	return &Error{
		Kind:   KindStatus,
		Status: hresp.StatusCode,
		Detail: fmt.Sprintf("HTTP %d：%s", hresp.StatusCode, summarize(body)),
	}
}

// toolsWire renders the offered tools in the OpenAI function-calling shape.
func toolsWire(tools []Tool) []map[string]any {
	out := make([]map[string]any, 0, len(tools))
	for _, t := range tools {
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"parameters":  t.Parameters,
			},
		})
	}
	return out
}

// parseCompletion decodes one non-streaming completion body. A 200 that
// speaks nonsense — unparseable, or carrying no choice at all — is
// KindStream, never a quiet success.
func parseCompletion(raw []byte) (ChatResponse, error) {
	var doc struct {
		Choices []struct {
			Message struct {
				Content   string     `json:"content"`
				ToolCalls []ToolCall `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return ChatResponse{}, &Error{Kind: KindStream, Detail: "响应不是有效的完成结果：" + summarize(raw)}
	}
	if len(doc.Choices) == 0 {
		return ChatResponse{}, &Error{Kind: KindStream, Detail: "响应里没有任何候选回复"}
	}
	msg := doc.Choices[0].Message
	return ChatResponse{Content: msg.Content, ToolCalls: msg.ToolCalls}, nil
}

// readStream consumes a 200 SSE body: data events' delta contents concatenate
// into the reply, and each non-empty increment is handed to onDelta as it
// arrives (nil onDelta just assembles). The parser is the single authority
// on SSE framing — the read side only hands it raw chunks. A stream that
// breaks before [DONE] — or speaks nonsense — is KindStream, never a quiet
// success.
func readStream(body io.Reader, onDelta func(string)) (string, error) {
	parser := &Parser{}
	reader := bufio.NewReader(body)
	buf := make([]byte, 32*1024)
	text := ""
	for {
		n, readErr := reader.Read(buf)
		for _, ev := range parser.Feed(buf[:n]) {
			if ev.Done {
				return text, nil
			}
			delta, err := deltaContent(ev.Data)
			if err != nil {
				return "", &Error{Kind: KindStream, Detail: err.Error()}
			}
			text += delta
			if delta != "" && onDelta != nil {
				onDelta(delta)
			}
		}
		if readErr == io.EOF {
			return "", &Error{Kind: KindStream, Detail: "响应流在结束标记（[DONE]）前中断"}
		}
		if readErr != nil {
			return "", &Error{Kind: KindStream, Detail: "响应流读取失败：" + readErr.Error()}
		}
	}
}

// deltaContent extracts one increment of reply text from a streamed data
// payload. Payloads without choices (role-only, usage-only) carry no text.
func deltaContent(data string) (string, error) {
	var chunk struct {
		Choices []struct {
			Delta struct {
				Content string `json:"content"`
			} `json:"delta"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(data), &chunk); err != nil {
		return "", fmt.Errorf("响应流里出现无法解析的数据：%s", summarize([]byte(data)))
	}
	if len(chunk.Choices) == 0 {
		return "", nil
	}
	return chunk.Choices[0].Delta.Content, nil
}

// summarize renders a response body as a one-line, bounded excerpt: enough
// to recognize an error message, never enough to flood the console.
func summarize(body []byte) string {
	const maxRunes = 200
	line := strings.Join(strings.Fields(string(body)), " ")
	runes := []rune(line)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes]) + "…"
	}
	return line
}

// isTimeout reports whether a transport error is a deadline problem.
func isTimeout(err error) bool {
	var netErr interface{ Timeout() bool }
	return (errors.As(err, &netErr) && netErr.Timeout()) ||
		errors.Is(err, context.DeadlineExceeded)
}
