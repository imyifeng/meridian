package store

import (
	"database/sql"
	"encoding/json"
)

// Agent conversation persistence (ADR-0009): one Conversation per user,
// created on first use; messages are the persistent display record and
// nothing else — the model's context is rebuilt per request from the
// still-open task, never from the whole history.
//
// Tool roundtrips (T75) live in the same table in the shape the OpenAI
// protocol replay needs: an assistant row may carry tool_calls (a JSON
// array of calls), and each tool result row answers one call by
// tool_call_id. A propose_draft round stores the structured draft on its
// assistant row's draft column — the model never writes the memos table
// directly, the client renders the draft and creates through the regular
// API on confirmation.

// Message roles. The user writes, the assistant answers, and the tool rows
// (T75) are the protocol record of what the model's tool calls did.
const (
	RoleUser      = "user"
	RoleAssistant = "assistant"
	RoleTool      = "tool"
)

// Message is one turn of a user's conversation. AwaitingInput is the task
// boundary flag (ADR-0009): on the assistant message that declared it —
// true means the task was still waiting for user input, false means the
// task ended with this reply. It is always false on user and tool messages.
type Message struct {
	ID            int64  `json:"id"`
	Role          string `json:"role"`
	Content       string `json:"content"`
	AwaitingInput bool   `json:"awaiting_input"`
	CreatedAt     string `json:"created_at"`
	// Draft is the structured草稿卡片 this assistant row proposed (T75),
	// nil on every other row. It is part of the display record: the client
	// renders it as the confirmation card.
	Draft json.RawMessage `json:"draft,omitempty"`
	// ToolCalls and ToolCallID are the replay-only internals (T75): the
	// assistant row's tool_calls JSON and the tool result row's call id.
	// Marked json-"-" so the display record never leaks protocol chatter.
	ToolCalls  string `json:"-"`
	ToolCallID string `json:"-"`
}

// messageColumns names every column a full message row reads back with; the
// display and the replay queries share it so the two views can never drift.
const messageColumns = "id, role, content, awaiting_input, created_at, draft, tool_calls, tool_call_id"

// conversationID returns the user's conversation, creating it on first
// use — the glossary's Conversation is a single resident session per user,
// so there is nothing to choose and no separate "create" step.
func (s *Store) conversationID(userID int64) (int64, error) {
	if _, err := s.db.Exec(
		"INSERT INTO conversations (user_id, created_at, updated_at) VALUES (?, ?, ?) ON CONFLICT (user_id) DO NOTHING",
		userID, now(), now(),
	); err != nil {
		return 0, err
	}
	var id int64
	err := s.db.QueryRow("SELECT id FROM conversations WHERE user_id = ?", userID).Scan(&id)
	return id, err
}

// AppendMessage adds one display turn to the user's conversation, creating
// the conversation on first use.
func (s *Store) AppendMessage(userID int64, role, content string, awaitingInput bool) (Message, error) {
	convID, err := s.conversationID(userID)
	if err != nil {
		return Message{}, err
	}
	createdAt := now()
	res, err := s.db.Exec(
		"INSERT INTO messages (conversation_id, role, content, awaiting_input, created_at) VALUES (?, ?, ?, ?, ?)",
		convID, role, content, awaitingInput, createdAt,
	)
	if err != nil {
		return Message{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return Message{}, err
	}
	if _, err := s.db.Exec("UPDATE conversations SET updated_at = ? WHERE id = ?", createdAt, convID); err != nil {
		return Message{}, err
	}
	return Message{ID: id, Role: role, Content: content, AwaitingInput: awaitingInput, CreatedAt: createdAt}, nil
}

// ToolResult is one tool result row recorded with its round: which call it
// answers, and the JSON the model reads back.
type ToolResult struct {
	ToolCallID string
	Content    string
}

// AppendToolRound records one complete tool round (T75) in a single
// transaction: the assistant row carrying its tool calls (and any draft it
// proposed), then every tool result answering those calls. All or nothing —
// a failed write never strands half a round, which the protocol replay
// could not speak. The conversation's updated_at moves with the round like
// it does with every other turn.
func (s *Store) AppendToolRound(userID int64, content, toolCalls, draft string, results []ToolResult) error {
	convID, err := s.conversationID(userID)
	if err != nil {
		return err
	}
	createdAt := now()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(
		"INSERT INTO messages (conversation_id, role, content, tool_calls, draft, created_at) VALUES (?, ?, ?, ?, ?, ?)",
		convID, RoleAssistant, content, toolCalls, draft, createdAt,
	); err != nil {
		return err
	}
	for _, r := range results {
		if _, err := tx.Exec(
			"INSERT INTO messages (conversation_id, role, content, tool_call_id, created_at) VALUES (?, ?, ?, ?, ?)",
			convID, RoleTool, r.Content, r.ToolCallID, createdAt,
		); err != nil {
			return err
		}
	}
	if _, err := tx.Exec("UPDATE conversations SET updated_at = ? WHERE id = ?", createdAt, convID); err != nil {
		return err
	}
	return tx.Commit()
}

// ConversationMessages lists the user's conversation as its display record
// (ADR-0009): the user's turns, the assistant's replies, and the draft
// rounds a client renders — the tool protocol rows stay internal. Oldest
// first; an empty result is a conversation with no turns yet (or none at
// all) and is not an error.
func (s *Store) ConversationMessages(userID int64) ([]Message, error) {
	rows, err := s.db.Query(
		`SELECT `+messageColumns+` FROM messages
		 WHERE conversation_id = `+conversationOf+`
		   AND (role = ? OR (role = ? AND (tool_calls = '' OR draft != '')))
		 ORDER BY id`,
		userID, RoleUser, RoleAssistant,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMessages(rows)
}

// conversationOf is the SQL fragment naming a user's conversation row —
// spelled once here instead of in every query that needs it. Each use in a
// statement consumes one ? argument (the user id).
const conversationOf = "(SELECT id FROM conversations WHERE user_id = ?)"

// OpenTaskMessages returns the messages of the user's still-open task
// (ADR-0009): everything after the last plain assistant message that ended
// its task (awaiting_input = 0). Tool rows ride along — the model context
// replays them in the protocol shape — but a tool_calls row never ends a
// task: only a display reply speaks the sentinel. A fresh conversation — or
// one whose last task is still open — puts every message in play; a cleared
// conversation starts empty. This, not the full history, is what each model
// request carries.
func (s *Store) OpenTaskMessages(userID int64) ([]Message, error) {
	rows, err := s.db.Query(
		`SELECT `+messageColumns+` FROM messages
		 WHERE conversation_id = `+conversationOf+`
		 AND id > COALESCE((SELECT MAX(id) FROM messages
		   WHERE conversation_id = `+conversationOf+`
		   AND role = ? AND awaiting_input = 0 AND tool_calls = ''), 0)
		 ORDER BY id`,
		userID, userID, RoleAssistant,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanMessages(rows)
}

// ClearConversation deletes every message of the user's conversation. The
// conversation row stays: the session is resident, only its record is
// wiped. Clearing a conversation that does not exist does nothing.
func (s *Store) ClearConversation(userID int64) error {
	_, err := s.db.Exec(
		"DELETE FROM messages WHERE conversation_id = "+conversationOf,
		userID,
	)
	return err
}

func scanMessages(rows *sql.Rows) ([]Message, error) {
	var out []Message
	for rows.Next() {
		var m Message
		var draft string
		if err := rows.Scan(&m.ID, &m.Role, &m.Content, &m.AwaitingInput, &m.CreatedAt, &draft, &m.ToolCalls, &m.ToolCallID); err != nil {
			return nil, err
		}
		if draft != "" {
			m.Draft = json.RawMessage(draft)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
