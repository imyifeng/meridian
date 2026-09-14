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

// Message is one turn of a chat conversation.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest is one chat-completions call. Every call rides the SSE wire
// (ADR-0009: the model's final replies always stream); Chat assembles the
// increments into the full reply text before returning.
type ChatRequest struct {
	Model     string
	Messages  []Message
	MaxTokens int
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
	payload, err := json.Marshal(req.body())
	if err != nil {
		return "", &Error{Kind: KindConnection, Detail: "构造请求失败"}
	}
	url := strings.TrimRight(c.BaseURL, "/") + "/chat/completions"
	hreq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", &Error{Kind: KindConnection, Detail: "Base URL 无效"}
	}
	hreq.Header.Set("Content-Type", "application/json")
	hreq.Header.Set("Authorization", "Bearer "+c.APIKey)

	hresp, err := http.DefaultClient.Do(hreq)
	if err != nil {
		if ctx.Err() != nil || errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
			return "", &Error{Kind: KindTimeout, Detail: "等待模型服务响应超时"}
		}
		return "", &Error{Kind: KindConnection, Detail: err.Error()}
	}
	defer hresp.Body.Close()
	if hresp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(hresp.Body, 1<<20))
		return "", &Error{
			Kind:   KindStatus,
			Status: hresp.StatusCode,
			Detail: fmt.Sprintf("HTTP %d：%s", hresp.StatusCode, summarize(body)),
		}
	}
	return readStream(hresp.Body)
}

// readStream consumes a 200 SSE body: data events' delta contents concatenate
// into the reply. The parser is the single authority on SSE framing — the
// read side only hands it raw chunks. A stream that breaks before [DONE] —
// or speaks nonsense — is KindStream, never a quiet success.
func readStream(body io.Reader) (string, error) {
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
