package store

import "database/sql"

// Agent conversation persistence (ADR-0009): one Conversation per user,
// created on first use; messages are the persistent display record and
// nothing else — the model's context is rebuilt per request from the
// still-open task, never from the whole history.

// Message roles. The agent conversation has no other speakers: the user
// writes, the assistant answers.
const (
	RoleUser      = "user"
	RoleAssistant = "assistant"
)

// Message is one turn of a user's conversation. AwaitingInput is the task
// boundary flag (ADR-0009): on the assistant message that declared it —
// true means the task was still waiting for user input, false means the
// task ended with this reply. It is always false on user messages.
type Message struct {
	ID            int64  `json:"id"`
	Role          string `json:"role"`
	Content       string `json:"content"`
	AwaitingInput bool   `json:"awaiting_input"`
	CreatedAt     string `json:"created_at"`
}

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

// AppendMessage adds one turn to the user's conversation, creating the
// conversation on first use.
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

// ConversationMessages lists the user's conversation, oldest first. An
// empty result is a conversation with no turns yet (or none at all) and is
// not an error.
func (s *Store) ConversationMessages(userID int64) ([]Message, error) {
	rows, err := s.db.Query(
		`SELECT m.id, m.role, m.content, m.awaiting_input, m.created_at
		 FROM messages m JOIN conversations c ON c.id = m.conversation_id
		 WHERE c.user_id = ? ORDER BY m.id`,
		userID,
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
// (ADR-0009): everything after the last assistant message that ended its
// task (awaiting_input = 0). A fresh conversation — or one whose last task
// is still open — puts every message in play; a cleared conversation starts
// empty. This, not the full history, is what each model request carries.
func (s *Store) OpenTaskMessages(userID int64) ([]Message, error) {
	rows, err := s.db.Query(
		`SELECT id, role, content, awaiting_input, created_at FROM messages
		 WHERE conversation_id = `+conversationOf+`
		 AND id > COALESCE((SELECT MAX(id) FROM messages
		   WHERE conversation_id = `+conversationOf+`
		   AND role = ? AND awaiting_input = 0), 0)
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
		if err := rows.Scan(&m.ID, &m.Role, &m.Content, &m.AwaitingInput, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
