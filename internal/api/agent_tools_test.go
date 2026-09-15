package api_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// The agent's tool loop (T75), driven through the HTTP seam: the fake LLM
// scripts tool calls, the server executes them as the signed-in user,
// records the roundtrip, and feeds the results back. What the tests pin is
// what ADR-0009 promises — the user's own data moves, the model never
// creates a memo directly, and the conversation record stays clean of
// protocol chatter.

// createMemoViaAPI creates one memo through the regular API and returns the
// stored record (the tool loop must reach exactly the same data).
func createMemoViaAPI(t *testing.T, env *apitest.Env, token string, body map[string]any) map[string]any {
	t.Helper()
	var memo map[string]any
	resp := env.Call("POST", "/api/v1/memos", token, body, &memo)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create memo: status %d, want 201", resp.StatusCode)
	}
	return memo
}

// createCategoryViaAPI adds one taxonomy category (administrator-only) and
// returns its record.
func createCategoryViaAPI(t *testing.T, env *apitest.Env, name string) map[string]any {
	t.Helper()
	var category map[string]any
	resp := env.Call("POST", "/api/v1/categories", env.Administrator().Token, map[string]string{"name": name}, &category)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create category %q: status %d, want 201", name, resp.StatusCode)
	}
	return category
}

// toolResultOf decodes the i-th message of a captured model request as a
// tool result's JSON content.
func toolResultOf(t *testing.T, body map[string]any, i int) map[string]any {
	t.Helper()
	msgs := chatMessages(t, body)
	raw, ok := msgs[i]["content"].(string)
	if !ok {
		t.Fatalf("context message %d carries no string content: %+v", i, msgs[i])
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("context message %d content %q is not JSON: %v", i, raw, err)
	}
	return out
}

// draftOf pulls the draft object out of a draft SSE frame.
func draftOf(t *testing.T, frame map[string]any) map[string]any {
	t.Helper()
	if frame["type"] != "draft" {
		t.Fatalf("frame %#v, want a draft frame", frame)
	}
	draft, ok := frame["draft"].(map[string]any)
	if !ok {
		t.Fatalf("draft frame %#v carries no draft object", frame)
	}
	return draft
}

// A search tool call runs the user's own full-text search and hands the
// model a compact result list — ids and excerpts, never the full bodies —
// and the roundtrip replays in the next request's context.
func TestAgentToolSearchRoundTrip(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "search_memos", `{"query":"会议"}`)),
		textReply("找到了 1 条\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()
	work := createCategoryViaAPI(t, env, "工作")
	categoryID := int64(work["id"].(float64))
	secretBody := strings.Repeat("机密内容", 60) // 360 runes: never fits an excerpt
	createMemoViaAPI(t, env, administrator.Token, map[string]any{
		"title": "团队会议记录", "body": secretBody, "category_id": categoryID, "tags": []string{"例会"},
	})
	createMemoViaAPI(t, env, administrator.Token, map[string]any{"title": "购物清单"})

	resp := sendAgentMessage(t, env, administrator.Token, "帮我找一下会议记录")
	frames := readSSEFrames(t, resp.Body)
	if done := frames[len(frames)-1]; done["type"] != "done" || done["awaiting_input"] != false {
		t.Fatalf("last frame %#v, want done with awaiting_input=false", done)
	}

	// The second model call replays the round: assistant tool_calls, then
	// the tool result with the compact hits of this user's search.
	msgs := chatMessages(t, llm.request(1))
	if len(msgs) != 4 {
		t.Fatalf("second request carried %d messages, want system+user+assistant(tool_calls)+tool: %+v", len(msgs), msgs)
	}
	if _, ok := msgs[2]["tool_calls"]; !ok {
		t.Errorf("context message 2 %+v, want the assistant's tool_calls", msgs[2])
	}
	result := toolResultOf(t, llm.request(1), 3)
	rawResults, ok := result["results"].([]any)
	if !ok || len(rawResults) != 1 {
		t.Fatalf("tool result %+v, want exactly the one meeting memo", result)
	}
	hit := rawResults[0].(map[string]any)
	if hit["title"] != "团队会议记录" {
		t.Errorf("hit %+v, want the meeting memo", hit)
	}
	if hit["category"] != "工作" {
		t.Errorf("hit category %v, want 工作", hit["category"])
	}
	if tags := fmt.Sprint(hit["tags"]); !strings.Contains(tags, "例会") {
		t.Errorf("hit tags %v, want 例会", hit["tags"])
	}
	excerpt, _ := hit["excerpt"].(string)
	if n := utf8.RuneCountInString(excerpt); n > 81 {
		t.Errorf("excerpt is %d runes, want at most 80 plus the ellipsis", n)
	}
	if strings.Contains(excerpt, "机密内容机密内容机密内容机密内容机密") && utf8.RuneCountInString(excerpt) > 81 {
		t.Error("excerpt carries more body than the compact shape allows")
	}
}

// get_memo hands back one memo's full text — the step after a search hit
// that needs the whole body.
func TestAgentToolGetMemo(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()

	memo := createMemoViaAPI(t, env, administrator.Token, map[string]any{
		"title": "密码说明", "body": "完整正文在这里", "remind_at": "2026-09-20T09:00:00+08:00",
	})
	id := int64(memo["id"].(float64))

	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "get_memo", fmt.Sprintf(`{"id":%d}`, id))),
		textReply("这是全文\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")

	resp := sendAgentMessage(t, env, administrator.Token, "看看那条密码说明")
	readSSEFrames(t, resp.Body)

	result := toolResultOf(t, llm.request(1), 3)
	if result["title"] != "密码说明" || result["body"] != "完整正文在这里" {
		t.Errorf("tool result %+v, want the memo's full text", result)
	}
	if result["remind_at"] != "2026-09-20T01:00:00Z" {
		// Times serve the way the memo API serves them: RFC3339 in UTC —
		// the model converts using the user's injected clock and zone.
		t.Errorf("tool result remind_at %v, want the reminder carried", result["remind_at"])
	}
}

// Mutations execute as the signed-in user: update rewrites, delete lands in
// the recycle bin — and no user can reach another user's memo through the
// model.
func TestAgentToolMutationsExecuteAsUser(t *testing.T) {
	t.Run("update rewrites the user's own memo", func(t *testing.T) {
		env := apitest.NewEnv(t)
		administrator := env.Administrator()
		memo := createMemoViaAPI(t, env, administrator.Token, map[string]any{
			"title": "旧标题", "body": "正文不动", "tags": []string{"旧标签"},
		})
		id := int64(memo["id"].(float64))

		llm := newFakeToolLLM(
			toolReply(toolCall("call_1", "update_memo", fmt.Sprintf(`{"id":%d,"title":"新标题"}`, id))),
			textReply("已修改\n[AWAITING_INPUT=false]\n"),
		)
		defer llm.Close()
		saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")

		resp := sendAgentMessage(t, env, administrator.Token, "把那条备忘录改名成新标题")
		readSSEFrames(t, resp.Body)

		var updated map[string]any
		if resp := env.Call("GET", fmt.Sprintf("/api/v1/memos/%d", id), administrator.Token, nil, &updated); resp.StatusCode != http.StatusOK {
			t.Fatalf("memo vanished: status %d", resp.StatusCode)
		}
		if updated["title"] != "新标题" {
			t.Errorf("title %v, want 新标题 (the tool really wrote)", updated["title"])
		}
		if updated["body"] != "正文不动" {
			t.Errorf("body %v, want it untouched (only the title was offered)", updated["body"])
		}
		if tags := fmt.Sprint(updated["tags"]); !strings.Contains(tags, "旧标签") {
			t.Errorf("tags %v, want them untouched — the model never writes tags", updated["tags"])
		}
	})

	t.Run("delete lands in the recycle bin", func(t *testing.T) {
		env := apitest.NewEnv(t)
		administrator := env.Administrator()
		memo := createMemoViaAPI(t, env, administrator.Token, map[string]any{"title": "要删的"})
		id := int64(memo["id"].(float64))

		llm := newFakeToolLLM(
			toolReply(toolCall("call_1", "delete_memo", fmt.Sprintf(`{"id":%d}`, id))),
			textReply("已删除\n[AWAITING_INPUT=false]\n"),
		)
		defer llm.Close()
		saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")

		resp := sendAgentMessage(t, env, administrator.Token, "删掉那条备忘录")
		readSSEFrames(t, resp.Body)

		if resp := env.Call("GET", fmt.Sprintf("/api/v1/memos/%d", id), administrator.Token, nil, nil); resp.StatusCode != http.StatusNotFound {
			t.Errorf("memo still live: status %d, want 404", resp.StatusCode)
		}
		var trash struct {
			Memos []map[string]any `json:"memos"`
		}
		env.Call("GET", "/api/v1/trash", administrator.Token, nil, &trash)
		if len(trash.Memos) != 1 {
			t.Errorf("recycle bin holds %d memos, want the deleted one", len(trash.Memos))
		}
	})

	t.Run("another user's memo is out of reach", func(t *testing.T) {
		env := apitest.NewEnv(t)
		administrator := env.Administrator()
		memo := createMemoViaAPI(t, env, administrator.Token, map[string]any{
			"title": "管理员的秘密", "body": "只有管理员能碰",
		})
		id := int64(memo["id"].(float64))

		var bob struct {
			ID int64 `json:"id"`
		}
		env.Call("POST", "/api/v1/users", administrator.Token,
			map[string]string{"username": "bob", "password": "bob's password"}, &bob)
		var bobSession struct {
			Token string `json:"token"`
		}
		env.Call("POST", "/api/v1/auth/login", "",
			map[string]string{"username": "bob", "password": "bob's password"}, &bobSession)

		llm := newFakeToolLLM(
			toolReply(toolCall("call_1", "search_memos", `{"query":"管理员的秘密"}`)),
			textReply("什么也没找到\n[AWAITING_INPUT=false]\n"),
			toolReply(toolCall("call_2", "delete_memo", fmt.Sprintf(`{"id":%d}`, id))),
			textReply("无能为力\n[AWAITING_INPUT=false]\n"),
		)
		defer llm.Close()
		saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")

		resp := sendAgentMessage(t, env, bobSession.Token, "找一下管理员的秘密")
		readSSEFrames(t, resp.Body)
		search := toolResultOf(t, llm.request(1), 3)
		if hits, _ := search["results"].([]any); len(hits) != 0 {
			t.Errorf("bob's search saw %+v, want nothing of the administrator's", hits)
		}

		resp = sendAgentMessage(t, env, bobSession.Token, "删掉它")
		readSSEFrames(t, resp.Body)
		deletion := toolResultOf(t, llm.request(3), 3)
		if deletion["error"] == "" {
			t.Errorf("bob's delete %+v, want an error result", deletion)
		}

		var intact map[string]any
		if resp := env.Call("GET", fmt.Sprintf("/api/v1/memos/%d", id), administrator.Token, nil, &intact); resp.StatusCode != http.StatusOK {
			t.Fatalf("administrator's memo: status %d, want it untouched", resp.StatusCode)
		}
		var trash struct {
			Memos []map[string]any `json:"memos"`
		}
		env.Call("GET", "/api/v1/trash", administrator.Token, nil, &trash)
		if len(trash.Memos) != 0 {
			t.Error("the administrator's memo ended up in a trash can it never chose")
		}
	})
}

// The draft flow (ADR-0009): propose_draft puts a structured card into the
// conversation — category and reminder included, tags never — emits a draft
// frame before the final text, creates nothing, and holds the task open for
// the user's confirmation no matter what the model's sentinel claimed.
func TestAgentToolDraftCard(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "propose_draft",
			`{"title":"周会","content":"每周同步进展","category_id":2,`+
				`"remind_at":"2026-09-16T14:00:00+08:00",`+
				`"remind_rule":{"mode":"weekly","weekday":3,"hour":14,"minute":0}}`)),
		textReply("草稿已生成，请确认\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()
	createCategoryViaAPI(t, env, "工作")

	resp := sendAgentMessage(t, env, administrator.Token, "每周三下午两点提醒我开周会")
	frames := readSSEFrames(t, resp.Body)
	if frames[0]["type"] != "draft" {
		t.Fatalf("first frame %#v, want the draft frame (the card precedes the text)", frames[0])
	}
	draft := draftOf(t, frames[0])
	if draft["title"] != "周会" || draft["content"] != "每周同步进展" {
		t.Errorf("draft %+v, want title/content carried", draft)
	}
	if id, _ := draft["category_id"].(float64); id != 2 {
		t.Errorf("draft category_id %v, want 2 (工作)", draft["category_id"])
	}
	if draft["remind_at"] != "2026-09-16T14:00:00+08:00" {
		t.Errorf("draft remind_at %v, want the one-shot time point", draft["remind_at"])
	}
	rule, ok := draft["remind_rule"].(map[string]any)
	if !ok || rule["mode"] != "weekly" || rule["weekday"] != float64(3) || rule["hour"] != float64(14) {
		t.Errorf("draft remind_rule %+v, want the weekly rule carried", draft["remind_rule"])
	}
	if _, has := draft["tags"]; has {
		t.Error("draft carries a tags field — tags are never the model's")
	}

	done := frames[len(frames)-1]
	if done["type"] != "done" || done["awaiting_input"] != true {
		t.Errorf("done frame %#v, want awaiting_input=true — a draft waits for its user", done)
	}

	var out struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &out)
	if len(out.Memos) != 0 {
		t.Errorf("the draft created %d memos — the model must never create directly", len(out.Memos))
	}

	var record struct {
		Messages []map[string]any `json:"messages"`
	}
	env.Call("GET", "/api/v1/agent/messages", administrator.Token, nil, &record)
	if len(record.Messages) != 3 {
		t.Fatalf("conversation record has %d rows, want user + draft + reply: %+v", len(record.Messages), record.Messages)
	}
	stored, ok := record.Messages[1]["draft"].(map[string]any)
	if !ok || stored["title"] != "周会" {
		t.Errorf("recorded draft %+v, want the structured card persisted", record.Messages[1]["draft"])
	}

	// The roundtrip replays for the model: its tool_calls, then the result.
	msgs := chatMessages(t, llm.request(1))
	if len(msgs) != 4 {
		t.Fatalf("second request carried %d messages, want the replayed tool round: %+v", len(msgs), msgs)
	}
	result := toolResultOf(t, llm.request(1), 3)
	if result["drafted"] != true {
		t.Errorf("tool result %+v, want drafted=true", result)
	}
}

// A draft that fails validation never persists: the tool result names the
// problem, the model corrects itself, and only the valid card reaches the
// conversation.
func TestAgentToolDraftInvalidSelfCorrects(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "propose_draft", `{"title":"备忘","category_id":999}`)),
		toolReply(toolCall("call_2", "propose_draft", `{"title":"备忘"}`)),
		textReply("这次好了，请确认\n[AWAITING_INPUT=true]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()

	resp := sendAgentMessage(t, env, administrator.Token, "记一条备忘")
	frames := readSSEFrames(t, resp.Body)
	drafts := 0
	for _, frame := range frames {
		if frame["type"] == "draft" {
			drafts++
		}
	}
	if drafts != 1 {
		t.Errorf("streamed %d draft frames, want only the valid card", drafts)
	}

	rejected := toolResultOf(t, llm.request(1), 3)
	if msg, _ := rejected["error"].(string); !strings.Contains(msg, "分类") {
		t.Errorf("rejected draft result %+v, want the error to name the category", rejected)
	}
	// The corrected round's result rides the third call's context, after
	// the rejected round it follows.
	accepted := toolResultOf(t, llm.request(2), 5)
	if accepted["drafted"] != true {
		t.Errorf("corrected draft result %+v, want drafted=true", accepted)
	}

	var out struct {
		Memos []map[string]any `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", administrator.Token, nil, &out)
	if len(out.Memos) != 0 {
		t.Errorf("invalid draft rounds created %d memos", len(out.Memos))
	}
}

// list_categories shows the model the taxonomy it may choose from — the
// instance's existing categories, nothing invented.
func TestAgentToolListCategories(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "list_categories", `{}`)),
		textReply("有这些分类\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()
	createCategoryViaAPI(t, env, "工作")
	createCategoryViaAPI(t, env, "生活")

	resp := sendAgentMessage(t, env, administrator.Token, "都有什么分类")
	readSSEFrames(t, resp.Body)

	result := toolResultOf(t, llm.request(1), 3)
	rawCats, ok := result["categories"].([]any)
	if !ok {
		t.Fatalf("tool result %+v, want a categories list", result)
	}
	names := map[string]bool{}
	for _, raw := range rawCats {
		cat := raw.(map[string]any)
		names[cat["name"].(string)] = true
		if cat["id"] == nil {
			t.Errorf("category %+v carries no id", cat)
		}
	}
	for _, want := range []string{"未分类", "工作", "生活"} {
		if !names[want] {
			t.Errorf("categories %v miss %q", names, want)
		}
	}
}

// A model stuck calling tools cannot spin forever: after the round limit
// the turn fails loudly — an error frame, never a done — the executed
// rounds stay recorded, and no assistant reply is invented.
func TestAgentToolLoopLimit(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "search_memos", `{"query":"会议"}`)),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()

	resp := sendAgentMessage(t, env, administrator.Token, "帮我找会议记录")
	frames := readSSEFrames(t, resp.Body)
	if len(frames) != 1 || frames[0]["type"] != "error" {
		t.Fatalf("frames %+v, want a single error frame", frames)
	}
	// Five tool rounds executed, and the sixth tool-call answer refused.
	if n := len(llm.requests); n != 6 {
		t.Errorf("model was called %d times, want 5 tool rounds plus the refused 6th", n)
	}

	var record struct {
		Messages []map[string]any `json:"messages"`
	}
	env.Call("GET", "/api/v1/agent/messages", administrator.Token, nil, &record)
	if len(record.Messages) != 1 {
		t.Errorf("display record has %d rows, want only the user's message", len(record.Messages))
	}
}

// Task segmentation survives tool roundtrips (ADR-0009): the still-open
// task replays its rounds in protocol shape, and once a reply closes the
// task the rounds — like the rest of it — leave every later context.
func TestAgentTaskSegmentationWithToolRounds(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "propose_draft", `{"title":"周会","content":"同步"}`)),
		textReply("草稿已生成，请确认\n[AWAITING_INPUT=true]\n"),
		textReply("收到，等你确认\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()

	resp := sendAgentMessage(t, env, administrator.Token, "帮我建周会备忘录")
	frames := readSSEFrames(t, resp.Body)
	if done := frames[len(frames)-1]; done["awaiting_input"] != true {
		t.Errorf("done %#v, want awaiting_input=true (the draft is pending)", done)
	}
	resp = sendAgentMessage(t, env, administrator.Token, "好，我确认了")
	readSSEFrames(t, resp.Body)

	// The open task's context replays the whole roundtrip in order.
	msgs := chatMessages(t, llm.request(2))
	if len(msgs) != 6 {
		t.Fatalf("second turn carried %d messages, want system + the open task's 5 turns: %+v", len(msgs), msgs)
	}
	want := []string{"system", "user", "assistant", "tool", "assistant", "user"}
	for i, role := range want {
		if msgs[i]["role"] != role {
			t.Errorf("context message %d role %v, want %s", i, msgs[i]["role"], role)
		}
	}
	if _, ok := msgs[2]["tool_calls"]; !ok {
		t.Errorf("context message 2 %+v, want the assistant's tool_calls replayed", msgs[2])
	}
	if msgs[3]["tool_call_id"] != "call_1" {
		t.Errorf("context message 3 %+v, want the tool result keyed to call_1", msgs[3])
	}

	// A closed task takes its tool rounds with it.
	resp = sendAgentMessage(t, env, administrator.Token, "今天天气怎么样")
	readSSEFrames(t, resp.Body)
	msgs = chatMessages(t, llm.request(3))
	if len(msgs) != 2 {
		t.Errorf("fresh task carried %d messages, want system + the new message only: %+v", len(msgs), msgs)
	}
}

// The recycle bin is invisible to the agent's read tools too: a trashed
// memo is neither searched nor fetchable — at the agent seam, not just in
// the store (T5, T75).
func TestAgentToolReadsExcludeTrash(t *testing.T) {
	env := apitest.NewEnv(t)
	administrator := env.Administrator()
	memo := createMemoViaAPI(t, env, administrator.Token, map[string]any{
		"title": "已进回收站的笔记", "body": "删掉的不再是可检索的",
	})
	id := int64(memo["id"].(float64))
	if resp := env.Call("DELETE", fmt.Sprintf("/api/v1/memos/%d", id), administrator.Token, nil, nil); resp.StatusCode != http.StatusNoContent {
		t.Fatalf("trash memo: status %d, want 204", resp.StatusCode)
	}

	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "search_memos", `{"query":"回收站"}`)),
		toolReply(toolCall("call_2", "get_memo", fmt.Sprintf(`{"id":%d}`, id))),
		textReply("回收站里的东西我看不见\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")

	resp := sendAgentMessage(t, env, administrator.Token, "找一下回收站里的笔记")
	readSSEFrames(t, resp.Body)

	search := toolResultOf(t, llm.request(1), 3)
	if hits, _ := search["results"].([]any); len(hits) != 0 {
		t.Errorf("search saw %+v, want the trashed memo invisible", hits)
	}
	fetch := toolResultOf(t, llm.request(2), 3)
	if fetch["error"] == "" {
		t.Errorf("get_memo on trashed memo %+v, want an error result", fetch)
	}
}

// A mangled tool call gets a precise self-correction hint: not-a-JSON-object
// and wrong-field-type read differently, so the model can tell what broke.
func TestAgentToolBadArguments(t *testing.T) {
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "search_memos", `{"query":123}`)),
		toolReply(toolCall("call_2", "get_memo", `"只要一个id"`)),
		textReply("明白了，重新调用\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()

	resp := sendAgentMessage(t, env, administrator.Token, "随便找点什么")
	readSSEFrames(t, resp.Body)

	typed := toolResultOf(t, llm.request(1), 3)
	if msg, _ := typed["error"].(string); !strings.Contains(msg, "类型不正确") {
		t.Errorf("wrong-typed arguments %+v, want a type-specific hint", typed)
	}
	// The second call's result rides the third call's context, after the
	// first round it follows.
	shaped := toolResultOf(t, llm.request(2), 5)
	if msg, _ := shaped["error"].(string); !strings.Contains(msg, "JSON 对象") {
		t.Errorf("non-object arguments %+v, want the not-an-object hint", shaped)
	}
}

// A tool call whose arguments blow the size cap is refused at the door —
// as a bad-arguments error for the model to slim down, never executed.
func TestAgentToolOversizedArguments(t *testing.T) {
	huge := `{"query":"` + strings.Repeat("长", 20*1024) + `"}`
	llm := newFakeToolLLM(
		toolReply(toolCall("call_1", "search_memos", huge)),
		textReply("好的，我换个问法\n[AWAITING_INPUT=false]\n"),
	)
	defer llm.Close()

	env := apitest.NewEnv(t)
	saveAIConfig(t, env, llm.URL, "meridian-mini", "sk-live-secret99")
	administrator := env.Administrator()

	resp := sendAgentMessage(t, env, administrator.Token, "帮我找东西")
	readSSEFrames(t, resp.Body)

	refused := toolResultOf(t, llm.request(1), 3)
	if msg, _ := refused["error"].(string); !strings.Contains(msg, "过大") {
		t.Errorf("oversized arguments %+v, want a too-large error result", refused)
	}
}
