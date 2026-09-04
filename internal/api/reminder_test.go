package api_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/imyifeng/meridian/internal/api/apitest"
)

// The reminder is a property of the memo (T9), not of any device: whatever
// session reads the memo sees the same remind_at, so one device setting it
// makes every other logged-in client schedule the same notification.
func TestReminderSetModifyCancel(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	var created struct {
		ID       int64   `json:"id"`
		RemindAt *string `json:"remind_at"`
	}
	resp := env.Call("POST", "/api/v1/memos", admin.Token,
		map[string]any{"title": "买奶茶", "remind_at": "2026-09-05T08:30:00+08:00"}, &created)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create with reminder: status %d, want 201", resp.StatusCode)
	}
	// A non-UTC offset normalizes to the same instant in UTC.
	if created.RemindAt == nil || *created.RemindAt != "2026-09-05T00:30:00Z" {
		t.Errorf("create returned remind_at %v, want 2026-09-05T00:30:00Z", created.RemindAt)
	}

	// A memo created without one has none, not an epoch zero.
	var plain struct {
		RemindAt *string `json:"remind_at"`
	}
	env.Call("POST", "/api/v1/memos", admin.Token, map[string]any{"title": "无提醒"}, &plain)
	if plain.RemindAt != nil {
		t.Errorf("create without reminder returned remind_at %v, want null", plain.RemindAt)
	}

	// Modify: a new time replaces the old one.
	var updated struct {
		RemindAt *string `json:"remind_at"`
	}
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "买奶茶", "remind_at": "2026-09-06T18:00:00Z"}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindAt == nil || *updated.RemindAt != "2026-09-06T18:00:00Z" {
		t.Errorf("modify reminder: status %d remind_at %v", resp.StatusCode, updated.RemindAt)
	}

	// An update that omits remind_at keeps the standing reminder.
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "买奶茶（改）"}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindAt == nil || *updated.RemindAt != "2026-09-06T18:00:00Z" {
		t.Errorf("update without remind_at: status %d remind_at %v, want kept", resp.StatusCode, updated.RemindAt)
	}

	// Cancel: the empty string clears it.
	resp = env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "买奶茶（改）", "remind_at": ""}, &updated)
	if resp.StatusCode != http.StatusOK || updated.RemindAt != nil {
		t.Errorf("cancel reminder: status %d remind_at %v, want null", resp.StatusCode, updated.RemindAt)
	}

	// The cleared reminder stays cleared everywhere it is served.
	var list struct {
		Memos []struct {
			ID       int64   `json:"id"`
			RemindAt *string `json:"remind_at"`
		} `json:"memos"`
	}
	env.Call("GET", "/api/v1/memos", admin.Token, nil, &list)
	for _, m := range list.Memos {
		if m.ID == 1 && m.RemindAt != nil {
			t.Errorf("list shows remind_at %v for the cancelled memo", *m.RemindAt)
		}
	}
}

func TestReminderValidation(t *testing.T) {
	env := apitest.NewEnv(t)
	admin := env.Administrator()

	for _, bad := range []string{"明天下午", "2026-13-40T00:00:00Z", "1726000000"} {
		resp := env.Call("POST", "/api/v1/memos", admin.Token,
			map[string]any{"title": "坏提醒", "remind_at": bad}, nil)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("create with remind_at %q: status %d, want 400", bad, resp.StatusCode)
		}
		var e struct {
			Error string `json:"error"`
		}
		json.NewDecoder(resp.Body).Decode(&e)
		if e.Error != "invalid_request" {
			t.Errorf("create with remind_at %q: error %q, want invalid_request", bad, e.Error)
		}
	}

	var id struct {
		ID int64 `json:"id"`
	}
	env.Call("POST", "/api/v1/memos", admin.Token, map[string]any{"title": "正提醒"}, &id)
	if resp := env.Call("PUT", "/api/v1/memos/1", admin.Token,
		map[string]any{"title": "正提醒", "remind_at": "not-a-time"}, nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("update with bad remind_at: status %d, want 400", resp.StatusCode)
	}
}

func TestReminderSyncsAcrossSessions(t *testing.T) {
	env := apitest.NewEnv(t)
	env.Administrator() // seeds the admin the two sessions log in as

	// A second session of the same user — another device, in domain terms.
	var firstLogin, secondLogin struct {
		Token string `json:"token"`
	}
	env.Call("POST", "/api/v1/auth/login", "", map[string]string{"username": "admin", "password": "correct horse"}, &firstLogin)
	env.Call("POST", "/api/v1/auth/login", "", map[string]string{"username": "admin", "password": "correct horse"}, &secondLogin)

	env.Call("POST", "/api/v1/memos", firstLogin.Token,
		map[string]any{"title": "跨端提醒", "remind_at": "2026-09-10T09:00:00Z"}, nil)

	var seen struct {
		Memos []struct {
			Title    string  `json:"title"`
			RemindAt *string `json:"remind_at"`
		} `json:"memos"`
	}
	resp := env.Call("GET", "/api/v1/memos", secondLogin.Token, nil, &seen)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list on second session: status %d, want 200", resp.StatusCode)
	}
	var found bool
	for _, m := range seen.Memos {
		if m.Title == "跨端提醒" {
			found = m.RemindAt != nil && *m.RemindAt == "2026-09-10T09:00:00Z"
		}
	}
	if !found {
		t.Error("second session does not see the reminder set by the first")
	}
}
