package api

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/imyifeng/meridian/internal/llm"
	"github.com/imyifeng/meridian/internal/store"
)

// The agent's tool set (T75, ADR-0009): six tools the model calls, the
// server executes — always as the signed-in user, through the same store
// functions the regular API uses. Creation never passes through here: the
// only way to make a memo is propose_draft, and the card it produces waits
// for its user; update and delete execute directly because the ticket says
// so, with the recycle bin as the safety net. No tool writes tags, ever
// (the glossary's Tag ban).

// agentToolMaxRounds bounds one turn's tool loop. A model stuck asking for
// tools cannot spin forever; the turn after the limit fails loudly.
const agentToolMaxRounds = 5

// agentSearchLimit is the compact result list's cap — enough for the model
// to reason over, never the user's whole database.
const agentSearchLimit = 10

// agentToolArgsLimit caps one tool call's arguments; a call beyond it is
// refused at the door as bad arguments instead of executed.
const agentToolArgsLimit = 16 << 10

// agentToolInternal is what a failed tool execution tells the model: that
// it failed, and nothing about why (the details are the instance's, not
// the model's business).
const agentToolInternal = "工具执行失败，请稍后重试"

// agentCategoryError points the model at the one legal source of
// categories.
const agentCategoryError = "分类不存在：category_id 必须来自 list_categories 返回的既有分类"

// agentDraft is the structured draft card (the glossary's Draft) a
// propose_draft round puts into the conversation. The client renders it as
// the miniature create form; on confirmation the client creates the memo
// through the regular API. There is deliberately no tags field: tags are
// never the model's to write.
type agentDraft struct {
	Title      string `json:"title"`
	Content    string `json:"content"`
	CategoryID int64  `json:"category_id"`
	// RemindAt is an RFC3339 time point, empty when the draft carries no
	// reminder. With RemindRule standing it is the next trigger time point
	// (T70) — the same shapes the memo API speaks.
	RemindAt   string          `json:"remind_at,omitempty"`
	RemindRule json.RawMessage `json:"remind_rule,omitempty"`
}

// agentToolOutcome is what one tool execution yields: result is the
// JSON-ready answer the model reads back, draft (propose_draft only) the
// card to persist with the round and emit — and err, when set, is the
// self-correction hint that replaces the result.
type agentToolOutcome struct {
	result any
	draft  *agentDraft
	err    string
}

// agentTool pairs the model-facing definition with its server-side
// executor. A failed execution is the model's problem to retry, not the
// user's to see: it comes back as an error result.
type agentTool struct {
	def     llm.Tool
	execute func(s *server, userID int64, args json.RawMessage) agentToolOutcome
}

// agentTools lists the definitions offered on every model request.
func agentTools() []llm.Tool {
	tools := make([]llm.Tool, 0, len(agentToolSet))
	for i := range agentToolSet {
		tools = append(tools, agentToolSet[i].def)
	}
	return tools
}

// executeAgentTool dispatches one model-requested call to its executor.
// An unknown tool, oversized arguments, or undecodable ones is an error
// result for the model to reconsider — nothing executes half-blind.
func executeAgentTool(s *server, userID int64, call llm.ToolCall) agentToolOutcome {
	for i := range agentToolSet {
		if agentToolSet[i].def.Name != call.Function.Name {
			continue
		}
		if len(call.Function.Arguments) > agentToolArgsLimit {
			return agentToolOutcome{err: "工具参数过大（上限 16KB），请精简后重新调用"}
		}
		args := json.RawMessage(call.Function.Arguments)
		if len(strings.TrimSpace(string(args))) == 0 {
			args = json.RawMessage("{}") // a bare tool name is an empty object
		}
		return agentToolSet[i].execute(s, userID, args)
	}
	return agentToolOutcome{err: "未知工具：" + call.Function.Name}
}

// decodeToolArgs decodes one call's arguments into the executor's target.
// The two failure modes read differently — the call was not even a JSON
// object, or a field had the wrong type — so the model can tell a mangled
// call from a mistyped field when it corrects itself.
func decodeToolArgs(args json.RawMessage, target any) string {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(args, &object); err != nil {
		return `参数应为 JSON 对象（如 {"id":1}）`
	}
	if err := json.Unmarshal(args, target); err != nil {
		return "参数字段类型不正确：" + err.Error()
	}
	return ""
}

var agentToolSet = []agentTool{
	{
		def: llm.Tool{
			Name: "search_memos",
			Description: "按关键词全文检索当前用户的备忘录（不含回收站）。返回紧凑列表：" +
				"id、标题、分类、标签、更新时间与正文摘要；需要完整正文时再用 get_memo。",
			Parameters: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"query": map[string]any{"type": "string", "description": "检索关键词，可含多个词"},
				},
				"required": []string{"query"},
			},
		},
		execute: executeSearchMemos,
	},
	{
		def: llm.Tool{
			Name:        "get_memo",
			Description: "取一条备忘录的完整内容：标题、正文、分类、标签、提醒时间与循环规则。",
			Parameters: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"id": map[string]any{"type": "integer", "description": "备忘录 id（来自 search_memos）"},
				},
				"required": []string{"id"},
			},
		},
		execute: executeGetMemo,
	},
	{
		def: llm.Tool{
			Name: "update_memo",
			Description: "修改当前用户的一条备忘录：只提供要改的字段，未提供的保持不变。" +
				"标签不可修改。remind_at 传空字符串清除提醒；remind_rule 传空字符串清除循环。",
			Parameters: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"id":          map[string]any{"type": "integer", "description": "备忘录 id（来自 search_memos）"},
					"title":       map[string]any{"type": "string"},
					"body":        map[string]any{"type": "string"},
					"category_id": map[string]any{"type": "integer", "description": "必须是 list_categories 返回的既有分类 id"},
					"remind_at":   map[string]any{"type": "string", "description": "RFC3339 时间点，空字符串清除"},
					"remind_rule": agentRuleSchema("空字符串清除循环"),
				},
				"required": []string{"id"},
			},
		},
		execute: executeUpdateMemo,
	},
	{
		def: llm.Tool{
			Name:        "delete_memo",
			Description: "把当前用户的一条备忘录移入回收站（可恢复）。",
			Parameters: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"id": map[string]any{"type": "integer", "description": "备忘录 id（来自 search_memos）"},
				},
				"required": []string{"id"},
			},
		},
		execute: executeDeleteMemo,
	},
	{
		def: llm.Tool{
			Name: "propose_draft",
			Description: "提交一张备忘录草稿卡片，等用户确认；用户确认后由客户端真正创建，你永远不能直接创建备忘录。" +
				"category_id 只能来自 list_categories；没有提醒就省略 remind_at 与 remind_rule；没有标签这个字段。",
			Parameters: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"title":       map[string]any{"type": "string"},
					"content":     map[string]any{"type": "string"},
					"category_id": map[string]any{"type": "integer", "description": "必须是 list_categories 返回的既有分类 id；省略时归入未分类"},
					"remind_at":   map[string]any{"type": "string", "description": "RFC3339 时间点，如 2026-09-16T14:00:00+08:00"},
					"remind_rule": agentRuleSchema("循环提醒规则"),
				},
				"required": []string{"title"},
			},
		},
		execute: executeProposeDraft,
	},
	{
		def: llm.Tool{
			Name:        "list_categories",
			Description: "列出实例的全部既有分类（含未分类）。凡是需要分类的地方，category_id 只能从这里选。",
			Parameters:  map[string]any{"type": "object", "properties": map[string]any{}},
		},
		execute: executeListCategories,
	},
}

// agentRuleSchema renders the remind_rule parameter schema; the note rides
// in the description (T70's rule shape, as the memo API validates it).
func agentRuleSchema(note string) map[string]any {
	return map[string]any{
		"type":        "object",
		"description": note,
		"properties": map[string]any{
			"mode":     map[string]any{"type": "string", "enum": []string{"daily", "weekly", "monthly", "yearly"}},
			"interval": map[string]any{"type": "integer"},
			"weekday":  map[string]any{"type": "integer", "description": "weekly：1=周一 … 7=周日"},
			"day":      map[string]any{"type": "integer", "description": "monthly/yearly：几号"},
			"month":    map[string]any{"type": "integer", "description": "yearly：几月"},
			"hour":     map[string]any{"type": "integer"},
			"minute":   map[string]any{"type": "integer"},
		},
		"required": []string{"mode", "hour", "minute"},
	}
}

// agentMemoView is a memo as the model sees it — the store's record with
// the category resolved to its name and times as RFC3339 (UTC, the way the
// memo API serves them).
type agentMemoView struct {
	ID         int64               `json:"id"`
	Title      string              `json:"title"`
	Body       string              `json:"body"`
	CategoryID int64               `json:"category_id"`
	Category   string              `json:"category"`
	Tags       []string            `json:"tags"`
	RemindAt   string              `json:"remind_at,omitempty"`
	RemindRule *store.ReminderRule `json:"remind_rule,omitempty"`
	UpdatedAt  string              `json:"updated_at"`
}

// agentMemoHit is one search hit: the compact shape that lets the model
// judge whether a full read (get_memo) is worth it. The body appears only
// as a bounded excerpt.
type agentMemoHit struct {
	ID        int64    `json:"id"`
	Title     string   `json:"title"`
	Category  string   `json:"category"`
	Tags      []string `json:"tags"`
	UpdatedAt string   `json:"updated_at"`
	Excerpt   string   `json:"excerpt"`
}

// agentExcerpt trims a body to its first ~80 runes.
func agentExcerpt(body string) string {
	runes := []rune(body)
	if len(runes) > 80 {
		return string(runes[:80]) + "…"
	}
	return string(runes)
}

// categoryNames maps category id → name in one read, so every view a tool
// hands the model can carry the human name.
func (s *server) categoryNames() (map[int64]string, error) {
	cats, err := s.st.Categories()
	if err != nil {
		return nil, err
	}
	names := make(map[int64]string, len(cats))
	for _, c := range cats {
		names[c.ID] = c.Name
	}
	return names, nil
}

// memoViewOf renders one memo for the model, resolving the category name.
// A failed name lookup is an internal failure — the taxonomy always
// contains every memo's category.
func (s *server) memoViewOf(m *store.Memo) (agentMemoView, string) {
	names, err := s.categoryNames()
	if err != nil {
		return agentMemoView{}, agentToolInternal
	}
	tags := m.Tags
	if tags == nil {
		tags = []string{}
	}
	view := agentMemoView{
		ID:         m.ID,
		Title:      m.Title,
		Body:       m.Body,
		CategoryID: m.CategoryID,
		Category:   names[m.CategoryID],
		Tags:       tags,
		UpdatedAt:  m.UpdatedAt.UTC().Format(time.RFC3339),
		RemindRule: m.RemindRule,
	}
	if m.RemindAt != nil {
		view.RemindAt = m.RemindAt.UTC().Format(time.RFC3339)
	}
	return view, ""
}

// agentMemoByID fetches one live memo of the user's for a tool call —
// another user's memo, a missing one, or one already in the recycle bin is
// the same miss to the model.
func (s *server) agentMemoByID(userID, id int64) (*store.Memo, string) {
	if id <= 0 {
		return nil, "备忘录 id 不合法"
	}
	memo, err := s.st.MemoByID(userID, id)
	if errors.Is(err, store.ErrNotFound) {
		return nil, "备忘录不存在（可能不属于你，或已在回收站）"
	}
	if err != nil {
		return nil, agentToolInternal
	}
	return memo, ""
}

func executeSearchMemos(s *server, userID int64, args json.RawMessage) agentToolOutcome {
	var in struct {
		Query string `json:"query"`
	}
	if toolErr := decodeToolArgs(args, &in); toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	query := strings.TrimSpace(in.Query)
	if query == "" {
		return agentToolOutcome{err: "检索词不能为空"}
	}
	memos, err := s.st.Memos(userID, store.MemoFilter{Query: query})
	if err != nil {
		return agentToolOutcome{err: agentToolInternal}
	}
	if len(memos) > agentSearchLimit {
		memos = memos[:agentSearchLimit]
	}
	names, err := s.categoryNames()
	if err != nil {
		return agentToolOutcome{err: agentToolInternal}
	}
	hits := make([]agentMemoHit, 0, len(memos))
	for _, m := range memos {
		tags := m.Tags
		if tags == nil {
			tags = []string{}
		}
		hits = append(hits, agentMemoHit{
			ID:        m.ID,
			Title:     m.Title,
			Category:  names[m.CategoryID],
			Tags:      tags,
			UpdatedAt: m.UpdatedAt.UTC().Format(time.RFC3339),
			Excerpt:   agentExcerpt(m.Body),
		})
	}
	return agentToolOutcome{result: map[string]any{"results": hits}}
}

func executeGetMemo(s *server, userID int64, args json.RawMessage) agentToolOutcome {
	var in struct {
		ID int64 `json:"id"`
	}
	if toolErr := decodeToolArgs(args, &in); toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	memo, toolErr := s.agentMemoByID(userID, in.ID)
	if toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	view, toolErr := s.memoViewOf(memo)
	if toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	return agentToolOutcome{result: view}
}

func executeUpdateMemo(s *server, userID int64, args json.RawMessage) agentToolOutcome {
	var in struct {
		ID         int64           `json:"id"`
		Title      *string         `json:"title"`
		Body       *string         `json:"body"`
		CategoryID *int64          `json:"category_id"`
		RemindAt   *string         `json:"remind_at"`
		RemindRule json.RawMessage `json:"remind_rule"`
	}
	if toolErr := decodeToolArgs(args, &in); toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	current, toolErr := s.agentMemoByID(userID, in.ID)
	if toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	// The update starts from the memo as it stands and applies only what
	// the model offered. Tags have no offered form at all — they stay.
	next := store.MemoInput{
		Title:      current.Title,
		Body:       current.Body,
		CategoryID: current.CategoryID,
	}
	if in.Title != nil {
		title := strings.TrimSpace(*in.Title)
		if title == "" {
			return agentToolOutcome{err: "标题不能为空"}
		}
		next.Title = title
	}
	if in.Body != nil {
		next.Body = *in.Body
	}
	if in.CategoryID != nil {
		if *in.CategoryID <= 0 {
			return agentToolOutcome{err: agentCategoryError}
		}
		next.CategoryID = *in.CategoryID
	}
	if in.RemindAt != nil {
		if *in.RemindAt == "" {
			clear := time.Time{}
			next.RemindAt = &clear // the zero time is the memo API's clear value
		} else {
			t, err := time.Parse(time.RFC3339, *in.RemindAt)
			if err != nil {
				return agentToolOutcome{err: "提醒时间格式应为 RFC3339（例如 2026-09-16T14:00:00+08:00）"}
			}
			next.RemindAt = &t
		}
	}
	if len(in.RemindRule) > 0 {
		rule, err := decodeRemindRule(in.RemindRule)
		if err != nil {
			return agentToolOutcome{err: "循环提醒规则不合法：" + err.Error()}
		}
		next.RemindRule = rule
	}
	memo, err := s.st.UpdateMemo(userID, current.ID, next)
	if errors.Is(err, store.ErrCategoryNotFound) {
		return agentToolOutcome{err: agentCategoryError}
	}
	if err != nil {
		return agentToolOutcome{err: agentToolInternal}
	}
	view, toolErr := s.memoViewOf(memo)
	if toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	return agentToolOutcome{result: view}
}

func executeDeleteMemo(s *server, userID int64, args json.RawMessage) agentToolOutcome {
	var in struct {
		ID int64 `json:"id"`
	}
	if toolErr := decodeToolArgs(args, &in); toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	memo, toolErr := s.agentMemoByID(userID, in.ID)
	if toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	if err := s.st.DeleteMemo(userID, memo.ID); err != nil {
		return agentToolOutcome{err: agentToolInternal}
	}
	return agentToolOutcome{result: map[string]any{"deleted": true, "id": memo.ID}}
}

func executeProposeDraft(s *server, userID int64, args json.RawMessage) agentToolOutcome {
	var in struct {
		Title      string          `json:"title"`
		Content    string          `json:"content"`
		CategoryID *int64          `json:"category_id"`
		RemindAt   string          `json:"remind_at"`
		RemindRule json.RawMessage `json:"remind_rule"`
	}
	if toolErr := decodeToolArgs(args, &in); toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		return agentToolOutcome{err: "草稿标题不能为空"}
	}
	var categoryID int64
	if in.CategoryID != nil {
		categoryID = *in.CategoryID
		if categoryID <= 0 {
			return agentToolOutcome{err: agentCategoryError}
		}
	}
	// The draft may only name an existing category (ADR-0002: the taxonomy
	// is the administrator's); an omitted one falls back to 未分类 at
	// creation, exactly like the regular API.
	if categoryID != 0 {
		names, err := s.categoryNames()
		if err != nil {
			return agentToolOutcome{err: agentToolInternal}
		}
		if _, ok := names[categoryID]; !ok {
			return agentToolOutcome{err: agentCategoryError}
		}
	}
	remindAt := ""
	if in.RemindAt != "" {
		if _, err := time.Parse(time.RFC3339, in.RemindAt); err != nil {
			return agentToolOutcome{err: "提醒时间格式应为 RFC3339（例如 2026-09-16T14:00:00+08:00）"}
		}
		remindAt = in.RemindAt
	}
	var rule json.RawMessage
	if len(in.RemindRule) > 0 {
		decoded, err := decodeRemindRule(in.RemindRule)
		if err != nil {
			return agentToolOutcome{err: "循环提醒规则不合法：" + err.Error()}
		}
		if decoded.Mode != "" { // the API's clear value has no business in a fresh draft
			b, err := json.Marshal(decoded)
			if err != nil {
				return agentToolOutcome{err: agentToolInternal}
			}
			rule = b
		}
	}
	return agentToolOutcome{
		result: map[string]any{"drafted": true},
		draft: &agentDraft{
			Title:      title,
			Content:    in.Content,
			CategoryID: categoryID,
			RemindAt:   remindAt,
			RemindRule: rule,
		},
	}
}

func executeListCategories(s *server, _ int64, args json.RawMessage) agentToolOutcome {
	if toolErr := decodeToolArgs(args, &struct{}{}); toolErr != "" {
		return agentToolOutcome{err: toolErr}
	}
	cats, err := s.st.Categories()
	if err != nil {
		return agentToolOutcome{err: agentToolInternal}
	}
	type categoryChoice struct {
		ID   int64  `json:"id"`
		Name string `json:"name"`
	}
	choices := make([]categoryChoice, 0, len(cats))
	for _, c := range cats {
		choices = append(choices, categoryChoice{ID: c.ID, Name: c.Name})
	}
	return agentToolOutcome{result: map[string]any{"categories": choices}}
}
