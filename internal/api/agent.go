package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/imyifeng/meridian/internal/llm"
	"github.com/imyifeng/meridian/internal/store"
)

// Agent (智能体) endpoints (ADR-0009): one resident conversation per user.
// The model is proxied entirely server-side — the API key never reaches a
// client — and the reply streams back as server-sent events.
//
// POST   /api/v1/agent/messages  send one user message, reply streams
// GET    /api/v1/agent/messages  the conversation's display record
// DELETE /api/v1/agent/messages  clear the conversation's record
//
// The reply protocol is SSE frames, one JSON object per "data:" frame:
//
//	data: {"type":"delta","text":"..."}          — the next increment of display text
//	data: {"type":"done","awaiting_input":true}  — the reply ended; whether the task still awaits user input
//	data: {"type":"error","message":"..."}       — the reply failed; the text is safe to show
//
// A request that passes body validation answers with 200 text/event-stream
// and speaks any failure through an error frame; problems before that (bad
// body, no auth) are the API's plain JSON errors.

// agentSystemPrompt is the fixed body of the system prompt (ADR-0009: the
// prompt is built into the server, not administrator-configurable). It
// declares who the agent is, demands the awaiting_input sentinel line that
// task segmentation runs on, and tells the model the user's local time
// rides along with every message. Later tickets grow this as the agent
// gains tools.
const agentSystemPrompt = `你是 Meridian 智能体：Meridian 备忘录应用内置的对话式助手，帮用户记录与查找备忘录。当前你还没有接入任何工具，无法真正读写备忘录——不要假装已经执行了任何操作。

每次回复的最后一行必须是单独一行的任务状态标记，二选一：
[AWAITING_INPUT=true] 表示任务未完成，你在等待用户补充信息或确认；
[AWAITING_INPUT=false] 表示任务已完成，没有要追问的。
这行标记由系统解析并移除，不会展示给用户，因此标记行之外不要再输出多余说明。

用户的每条消息都会附带其本地时间与时区，涉及"今天""明天"等相对时间时一律以该时间为准。`

// agentSystemPromptFor renders the system prompt for one request: the fixed
// body plus the client-supplied local time and timezone in the context
// section (ADR-0009: relative time resolves against the client's clock).
func agentSystemPromptFor(localTime, timezone string) string {
	return agentSystemPrompt + "\n\n当前用户本地时间：" + localTime + "（时区：" + timezone + "）"
}

// agentReplyTimeout bounds one model call. Streaming replies legitimately
// run long, so this is generous — but a wedged model service must not hold
// a handler forever.
const agentReplyTimeout = 120 * time.Second

// agentReplyFilter turns the model's raw reply stream into display text and
// the awaiting_input declaration. The sentinel line is this ticket's
// stopgap protocol: with no tool calling available yet, the model declares
// the task state as a lone "[AWAITING_INPUT=true|false]" line, which the
// filter strips from display text; #75 replaces it with the structured
// field of a tool call.
//
// A sentinel decides the task only as the reply's last word: stripped from
// the display wherever it appears, but honored for the task state only when
// no content-bearing line follows it. An open task keeps its context, so
// the conservative reading covers both a marker spoken too early and a
// marker never spoken at all. Trailing whitespace is withheld from the
// display and dropped when the reply ends, so the concatenation of
// everything streamed is byte-for-byte the text the conversation records.
type agentReplyFilter struct {
	pending  string // the partial line seen so far, not yet classifiable
	tail     string // trailing whitespace withheld from the display stream
	awaiting *bool  // nil until a sentinel line arrives
	sealed   bool   // a content line followed the last sentinel: it is no longer the reply's last word
}

// feed consumes one raw delta and returns the display text it completes.
// Lines are only emitted once finished: a sentinel is indistinguishable
// from ordinary text until its line is complete.
func (f *agentReplyFilter) feed(delta string) string {
	f.pending += delta
	out := &strings.Builder{}
	for {
		idx := strings.IndexByte(f.pending, '\n')
		if idx < 0 {
			break
		}
		line := f.pending[:idx]
		f.pending = f.pending[idx+1:]
		f.emitLine(line, out)
	}
	return f.drain(out.String())
}

// finish ends the stream: the trailing partial line is a line too, and the
// withheld trailing whitespace dies here — the reply's display text is
// exactly what has been streamed so far.
func (f *agentReplyFilter) finish() string {
	line := f.pending
	f.pending = ""
	out := &strings.Builder{}
	f.emitLine(line, out)
	return f.drain(out.String())
}

// drain splits fresh filter output into display text and trailing
// whitespace: the whitespace waits until more content proves it mid-reply,
// and whatever is left when the reply ends is simply not part of it.
func (f *agentReplyFilter) drain(fresh string) string {
	content := strings.TrimRight(fresh, " \t\n\r")
	if content == "" {
		f.tail += fresh
		return ""
	}
	text := f.tail + content
	f.tail = fresh[len(content):]
	return text
}

func (f *agentReplyFilter) emitLine(line string, out *strings.Builder) {
	if awaiting, ok := parseAwaitingSentinel(line); ok {
		f.awaiting = &awaiting
		f.sealed = false // so far, this is still the reply's last word
		return
	}
	if strings.TrimSpace(line) != "" {
		f.sealed = true // content after the sentinel: the marker spoke too early
	}
	out.WriteString(line)
	out.WriteString("\n")
}

// awaitingInput reports whether the task is still waiting for user input.
// A model that never speaks the sentinel keeps its task open — forgetting
// the marker must not lose an in-progress task's context — and so does a
// sentinel that spoke mid-reply, with content after it. A sentinel that is
// the reply's last word speaks for itself.
func (f *agentReplyFilter) awaitingInput() bool {
	if f.awaiting == nil || f.sealed {
		return true
	}
	return *f.awaiting
}

// parseAwaitingSentinel recognizes the one line the protocol reserves.
func parseAwaitingSentinel(line string) (awaiting, ok bool) {
	switch strings.TrimSpace(line) {
	case "[AWAITING_INPUT=true]":
		return true, true
	case "[AWAITING_INPUT=false]":
		return false, true
	}
	return false, false
}

// validTimezone applies the basic sanity bounds on the client-declared IANA
// zone name: present, short, printable, one line. It is embedded verbatim
// in the system prompt's context section, so anything that could forge a
// prompt line — a newline above all — is rejected outright, not sanitized.
func validTimezone(tz string) bool {
	if tz == "" || len(tz) > 64 {
		return false
	}
	for _, r := range tz {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

type agentMessageInput struct {
	Content string `json:"content"`
	// LocalTime is the client's clock at send time, RFC3339 with offset.
	// Timezone is the client's IANA zone name. Both ride along so relative
	// time ("明天") resolves server-side (ADR-0009).
	LocalTime string `json:"local_time"`
	Timezone  string `json:"timezone"`
}

func (s *server) sendAgentMessage(w http.ResponseWriter, r *http.Request) {
	u := identity(r)
	var in agentMessageInput
	if !decodeBody(w, r, &in) {
		return
	}
	content := strings.TrimSpace(in.Content)
	if content == "" || in.LocalTime == "" || !validTimezone(in.Timezone) {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if _, err := time.Parse(time.RFC3339, in.LocalTime); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	set, err := s.st.AISettings()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}

	// Streaming is this endpoint's whole point: a ResponseWriter without a
	// Flusher would hold every frame in the response buffer and hand the
	// client the whole reply in one lump, which is not the protocol. Under
	// net/http every live ResponseWriter flushes, so reaching this is a
	// wiring mistake, not a client condition — fail explicitly before any
	// SSE header goes out rather than degrade silently. (Deliberately not
	// covered by a test: the HTTP seam runs on httptest, whose writer
	// always flushes, so the path cannot be reached from there.)
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	writeFrame := func(v any) {
		b, err := json.Marshal(v)
		if err != nil {
			return
		}
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}
	sendError := func(message string) {
		writeFrame(map[string]string{"type": "error", "message": message})
	}

	// The gate speaks SSE: the client is already reading a stream, so an
	// unavailable agent is an error frame, not a status code. A never-
	// configured instance is seeded disabled too, so the missing
	// configuration is the more specific diagnosis and speaks first.
	if set.BaseURL == "" || set.Model == "" || set.APIKey == "" {
		sendError("智能体尚未配置，请联系管理员在 Web Console 中完成 AI 设置")
		return
	}
	if !set.Enabled {
		sendError("智能体已停用，请联系管理员在 Web Console 中开启 AI 设置")
		return
	}

	if _, err := s.st.AppendMessage(u.ID, store.RoleUser, content, false); err != nil {
		sendError("消息保存失败")
		return
	}
	task, err := s.st.OpenTaskMessages(u.ID)
	if err != nil {
		sendError("会话读取失败")
		return
	}
	messages := make([]llm.Message, 0, len(task)+1)
	messages = append(messages, llm.Message{Role: "system", Content: agentSystemPromptFor(in.LocalTime, in.Timezone)})
	for _, m := range task {
		messages = append(messages, llm.Message{Role: m.Role, Content: m.Content})
	}

	filter := &agentReplyFilter{}
	display := &strings.Builder{}
	emit := func(text string) {
		if text == "" {
			return
		}
		display.WriteString(text)
		writeFrame(map[string]string{"type": "delta", "text": text})
	}
	ctx, cancel := context.WithTimeout(r.Context(), agentReplyTimeout)
	defer cancel()
	client := &llm.Client{BaseURL: set.BaseURL, APIKey: set.APIKey}
	_, err = client.Chat(ctx, llm.ChatRequest{
		Model:    set.Model,
		Messages: messages,
		OnDelta:  func(delta string) { emit(filter.feed(delta)) },
	})
	if err != nil {
		sendError(agentFailureReason(err))
		return
	}
	emit(filter.finish())

	awaiting := filter.awaitingInput()
	// The filter already withheld the trailing whitespace, so what was
	// streamed is exactly what the record stores: what the user saw is
	// what the conversation keeps.
	if _, err := s.st.AppendMessage(u.ID, store.RoleAssistant, display.String(), awaiting); err != nil {
		sendError("回复保存失败")
		return
	}
	writeFrame(map[string]any{"type": "done", "awaiting_input": awaiting})
}

func (s *server) listAgentMessages(w http.ResponseWriter, r *http.Request) {
	u := identity(r)
	msgs, err := s.st.ConversationMessages(u.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": nonNil(msgs)})
}

// clearAgentMessages wipes the conversation's display record (the session
// itself is resident and stays). 204 whether or not anything was there.
func (s *server) clearAgentMessages(w http.ResponseWriter, r *http.Request) {
	if err := s.st.ClearConversation(identity(r).ID); err != nil {
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// agentRecoveryHint is what a user can do about a failed model call; the
// dial itself is the administrator's to fix.
const agentRecoveryHint = "，请稍后重试或联系管理员检查 AI 设置"

// agentFailureReason turns a failed model call into the text an ordinary
// user sees in the error frame. The key never enters any llm.Error detail,
// so it cannot leak from here.
func agentFailureReason(err error) string {
	var e *llm.Error
	if !errors.As(err, &e) {
		return "回复生成失败" + agentRecoveryHint
	}
	switch e.Kind {
	case llm.KindConnection:
		return "无法连接模型服务" + agentRecoveryHint
	case llm.KindTimeout:
		return "模型服务响应超时" + agentRecoveryHint
	case llm.KindStatus:
		return "模型服务拒绝了请求" + agentRecoveryHint
	case llm.KindStream:
		return "模型回复中断，本次回复不完整" + agentRecoveryHint
	default:
		return "回复生成失败" + agentRecoveryHint
	}
}
