package store_test

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/imyifeng/meridian/internal/store"
)

func openStore(t *testing.T) (*store.Store, error) {
	t.Helper()
	return store.Open(filepath.Join(t.TempDir(), "meridian.db"))
}

// Tool roundtrips (T75) live in the same messages table as the display
// record, in the shape the model context replay needs: the assistant's
// tool_calls row, one tool result per call keyed by tool_call_id — and the
// display record stays clean of the protocol chatter, while the draft a
// tool round proposed rides along for the client to render.

func appendToolRound(t *testing.T, s *store.Store, userID int64) {
	t.Helper()
	calls := `[{"id":"call_1","type":"function","function":{"name":"search_memos","arguments":"{\"query\":\"会议\"}"}}]`
	if err := s.AppendToolRound(userID, "", calls, "", []store.ToolResult{
		{ToolCallID: "call_1", Content: `{"results":[]}`},
	}); err != nil {
		t.Fatalf("append tool round: %v", err)
	}
}

// The replay view (OpenTaskMessages) carries every row of the still-open
// task in order — tool rounds included — and only a plain assistant reply
// that declared the task done closes it. A tool_calls row never does, no
// matter what its awaiting flag says: it speaks no sentinel.
func TestOpenTaskReplayIncludesToolRounds(t *testing.T) {
	s, err := openStore(t)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	u, err := s.CreateUser("yifeng", "correct horse")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	s.AppendMessage(u.ID, store.RoleUser, "找一下会议记录", false)
	appendToolRound(t, s, u.ID)
	s.AppendMessage(u.ID, store.RoleAssistant, "没找到，要不要换个词？", true)

	task, err := s.OpenTaskMessages(u.ID)
	if err != nil {
		t.Fatalf("open task: %v", err)
	}
	if len(task) != 4 {
		t.Fatalf("open task has %d messages, want all 4 including the tool round: %+v", len(task), task)
	}
	wantRoles := []string{store.RoleUser, store.RoleAssistant, store.RoleTool, store.RoleAssistant}
	for i, role := range wantRoles {
		if task[i].Role != role {
			t.Errorf("task message %d role %q, want %q", i, task[i].Role, role)
		}
	}
	if task[1].ToolCalls == "" {
		t.Error("assistant tool_calls row lost its tool_calls")
	}
	if task[2].ToolCallID != "call_1" {
		t.Errorf("tool result tool_call_id %q, want call_1", task[2].ToolCallID)
	}
	if task[2].Content != `{"results":[]}` {
		t.Errorf("tool result content %q, want the result JSON", task[2].Content)
	}

	// The task closes only on the plain assistant reply; a new task starts
	// from scratch afterwards.
	s.AppendMessage(u.ID, store.RoleAssistant, "好的", false)
	task, err = s.OpenTaskMessages(u.ID)
	if err != nil {
		t.Fatalf("open task after close: %v", err)
	}
	if len(task) != 0 {
		t.Errorf("closed task still has %d messages, want none", len(task))
	}
}

// A tool_calls assistant row does not close a task even though its stored
// awaiting flag is the default false — the sentinel protocol belongs to the
// display replies alone.
func TestToolCallsRowNeverClosesTask(t *testing.T) {
	s, err := openStore(t)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	u, err := s.CreateUser("yifeng", "correct horse")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	s.AppendMessage(u.ID, store.RoleUser, "记一件事", false)
	appendToolRound(t, s, u.ID)

	task, err := s.OpenTaskMessages(u.ID)
	if err != nil {
		t.Fatalf("open task: %v", err)
	}
	if len(task) != 3 {
		t.Errorf("open task has %d messages, want 3 (the tool round never closed the task)", len(task))
	}
}

// The display record shows the conversation, not the protocol: user turns,
// plain assistant replies, and draft-bearing tool rounds (the client renders
// the draft) — tool results and bare tool_calls rows stay internal, and no
// row leaks its replay-only fields through the display JSON.
func TestConversationDisplayFiltersToolRounds(t *testing.T) {
	s, err := openStore(t)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	u, err := s.CreateUser("yifeng", "correct horse")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	draft := json.RawMessage(`{"title":"周会","content":"每周同步","category_id":0}`)
	s.AppendMessage(u.ID, store.RoleUser, "帮我建一张周会备忘录", false)
	calls := `[{"id":"call_2","type":"function","function":{"name":"propose_draft","arguments":"{}"}}]`
	if err := s.AppendToolRound(u.ID, "", calls, string(draft), []store.ToolResult{
		{ToolCallID: "call_2", Content: `{"drafted":true}`},
	}); err != nil {
		t.Fatalf("append draft round: %v", err)
	}
	s.AppendMessage(u.ID, store.RoleAssistant, "草稿已生成，请确认", true)

	msgs, err := s.ConversationMessages(u.ID)
	if err != nil {
		t.Fatalf("conversation: %v", err)
	}
	if len(msgs) != 3 {
		t.Fatalf("display record has %d rows, want user + draft round + reply: %+v", len(msgs), msgs)
	}
	if msgs[1].Role != store.RoleAssistant {
		t.Errorf("draft row role %q, want assistant", msgs[1].Role)
	}
	if string(msgs[1].Draft) != string(draft) {
		t.Errorf("draft row carries %s, want the draft JSON", msgs[1].Draft)
	}
	// The replay-only fields never enter the display JSON.
	for i, m := range msgs {
		raw, err := json.Marshal(m)
		if err != nil {
			t.Fatalf("marshal message %d: %v", i, err)
		}
		for _, leaked := range []string{"tool_calls", "tool_call_id"} {
			if jsonContains(raw, leaked) {
				t.Errorf("display message %d leaks %s: %s", i, leaked, raw)
			}
		}
	}
}

func jsonContains(raw []byte, substr string) bool {
	return strings.Contains(string(raw), substr)
}
