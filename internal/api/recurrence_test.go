package api_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// The recurrence rule (T70) rides the memo like the one-shot reminder: a
// property of the memo, not of any device (ADR-0004). The server stores and
// serves it; deriving the next trigger time is the client's job, so the
// rule needs no server-side interpretation — only validation.
func TestRecurrenceRuleSetModifyClear(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	var created struct {
		ID         int64           `json:"id"`
		RemindAt   *string         `json:"remind_at"`
		RemindRule *map[string]any `json:"remind_rule"`
	}
	resp := env.Call("POST", "/api/v1/memos", admin.Token, map[string]any{
		"title":     "晨会",
		"remind_at": "2026-09-07T00:30:00Z",
		"remind_rule": map[string]any{
			"mode": "weekly", "interval": 2, "weekday": 1,
			"hour": 8, "minute": 30,
		},
	}, &created)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create with recurrence: status %d, want 201", resp.StatusCode)
	}
	if created.RemindRule == nil {
		t.Fatal("create returned remind_rule null, want the rule")
	}
	rule := *created.RemindRule
	if rule["mode"] != "weekly" || rule["interval"] != float64(2) ||
		rule["weekday"] != float64(1) || rule["hour"] != float64(8) ||
		rule["minute"] != float64(30) {
		t.Errorf("create returned remind_rule %v", rule)
	}

	// A memo created without a rule has none, not an empty object.
	var plain struct {
		RemindRule *map[string]any `json:"remind_rule"`
	}
	env.Call("POST", "/api/v1/memos", admin.Token, map[string]any{"title": "无循环"}, &plain)
	if plain.RemindRule != nil {
		t.Errorf("create without rule returned remind_rule %v, want null", plain.RemindRule)
	}

	// An update that omits remind_rule keeps the standing one.
	var updated struct {
		RemindRule *map[string]any `json:"remind_rule"`
	}
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "晨会（改）"}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindRule == nil {
		t.Fatalf("update without rule: status %d remind_rule %v, want kept",
			resp.StatusCode, updated.RemindRule)
	}
	if (*updated.RemindRule)["mode"] != "weekly" {
		t.Errorf("update without rule changed the rule: %v", *updated.RemindRule)
	}

	// A new rule object replaces the old one; interval 1 is the default.
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token, map[string]any{
		"title": "晨会（改）",
		"remind_rule": map[string]any{
			"mode": "daily", "hour": 7, "minute": 0,
		},
	}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindRule == nil {
		t.Fatalf("replace rule: status %d remind_rule %v", resp.StatusCode, updated.RemindRule)
	}
	rule = *updated.RemindRule
	if rule["mode"] != "daily" || rule["interval"] != float64(1) ||
		rule["hour"] != float64(7) || rule["minute"] != float64(0) {
		t.Errorf("replaced remind_rule %v, want daily/1 at 07:00", rule)
	}

	// The empty string clears the rule; the next trigger time is untouched —
	// dropping the recurrence turns the standing time back into a one-shot.
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "晨会（改）", "remind_rule": ""}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindRule != nil {
		t.Fatalf("clear rule: status %d remind_rule %v, want null",
			resp.StatusCode, updated.RemindRule)
	}
	var got struct {
		RemindAt   *string `json:"remind_at"`
		RemindRule *string `json:"remind_rule"`
	}
	env.Call("GET", "/api/v1/memos/1", admin.Token, nil, &got)
	if got.RemindAt == nil || *got.RemindAt != "2026-09-07T00:30:00Z" {
		t.Errorf("clearing the rule moved remind_at: %v", got.RemindAt)
	}

	// Setting a rule back does not disturb the standing time either.
	env.Call("PUT", "/api/v1/memos/1", admin.Token, map[string]any{
		"title":       "晨会（改）",
		"remind_rule": map[string]any{"mode": "monthly", "day": 7, "hour": 8, "minute": 30},
	}, nil)

	// An explicit JSON null is "not specified", same as omitting the field:
	// the standing rule survives. (encoding/json nils the raw-message
	// pointer for null before any handler code runs.)
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "晨会（改）", "remind_rule": nil}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindRule == nil ||
		(*updated.RemindRule)["mode"] != "monthly" {
		t.Errorf("update with null rule: status %d remind_rule %v, want kept",
			resp.StatusCode, updated.RemindRule)
	}

	// Everything round-trips through the list.
	var list struct {
		Memos []struct {
			ID         int64           `json:"id"`
			RemindRule *map[string]any `json:"remind_rule"`
		} `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", admin.Token, nil, &list)
	for _, m := range list.Memos {
		if m.ID == 1 && (m.RemindRule == nil || (*m.RemindRule)["mode"] != "monthly") {
			t.Errorf("list shows remind_rule %v for memo 1", m.RemindRule)
		}
	}
}

func TestRecurrenceRuleValidation(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	bad := []any{
		"每天",             // not an object
		5,                // not an object
		map[string]any{}, // mode missing
		map[string]any{"mode": "hourly", "hour": 8, "minute": 0},               // unknown mode
		map[string]any{"mode": "daily", "hour": 24, "minute": 0},               // hour out of range
		map[string]any{"mode": "daily", "hour": 8, "minute": 60},               // minute out of range
		map[string]any{"mode": "daily", "hour": 8},                             // minute missing
		map[string]any{"mode": "daily", "minute": 30},                          // hour missing
		map[string]any{"mode": "daily", "interval": 0, "hour": 8, "minute": 0}, // interval < 1
		map[string]any{"mode": "daily", "weekday": 1, "hour": 8, "minute": 0},  // field the mode does not take
		map[string]any{"mode": "weekly", "hour": 8, "minute": 0},               // weekday missing
		map[string]any{"mode": "weekly", "weekday": 0, "hour": 8, "minute": 0}, // weekday out of range
		map[string]any{"mode": "weekly", "weekday": 8, "hour": 8, "minute": 0},
		map[string]any{"mode": "weekly", "weekday": 3, "day": 5, "hour": 8, "minute": 0}, // field the mode does not take
		map[string]any{"mode": "monthly", "hour": 8, "minute": 0},                        // day missing
		map[string]any{"mode": "monthly", "day": 0, "hour": 8, "minute": 0},              // day out of range
		map[string]any{"mode": "monthly", "day": 32, "hour": 8, "minute": 0},
		map[string]any{"mode": "monthly", "day": 5, "month": 3, "hour": 8, "minute": 0}, // field the mode does not take
		map[string]any{"mode": "yearly", "day": 15, "hour": 8, "minute": 0},             // month missing
		map[string]any{"mode": "yearly", "month": 13, "day": 15, "hour": 8, "minute": 0},
		map[string]any{"mode": "yearly", "month": 3, "day": 32, "hour": 8, "minute": 0},
	}
	for i, rule := range bad {
		resp := env.Call("POST", "/api/v1/memos", admin.Token,
			map[string]any{"title": "坏规则", "remind_rule": rule}, nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("bad rule #%d (%v): status %d, want 400", i, rule, resp.StatusCode)
			continue
		}
		var e struct {
			Error string `json:"error"`
		}
		json.NewDecoder(resp.Body).Decode(&e)
		if e.Error != "invalid_request" {
			t.Errorf("bad rule #%d (%v): error %q, want invalid_request", i, rule, e.Error)
		}
	}

	// The update path validates the same way; a well-formed one stands.
	env.Call("POST", "/api/v1/memos", admin.Token, map[string]any{"title": "正规则"}, nil)
	if resp := env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "正规则", "remind_rule": map[string]any{"mode": "weekly", "weekday": 9, "hour": 8, "minute": 0}},
		nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("update with bad rule: status %d, want 400", resp.StatusCode)
	}
	var got struct {
		RemindRule *string `json:"remind_rule"`
	}
	env.Call("GET", "/api/v1/memos/1", admin.Token, nil, &got)
	if got.RemindRule != nil {
		t.Errorf("a rejected rule stuck: remind_rule %v", got.RemindRule)
	}
}
