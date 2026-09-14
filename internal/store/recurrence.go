package store

import (
	"encoding/json"
	"fmt"
)

// ReminderRule is the structured recurrence of a repeating reminder (T70):
// a preset pattern — daily, a weekday, a day of the month, or a yearly
// month-day — plus interval and time of day, no end date. Deliberately not
// an RRULE string: the preset modes are all the product offers. The
// instance stores and serves the rule verbatim; deriving the next trigger
// time is the client's job (ADR-0004), so nothing server-side interprets
// it — the API layer validates shape, the store persists.
type ReminderRule struct {
	// Mode is one of "daily", "weekly", "monthly", "yearly".
	Mode string `json:"mode"`
	// Interval is how many of the mode's unit pass between occurrences;
	// at least 1.
	Interval int `json:"interval"`
	// Weekday is the weekly mode's day, 1=周一 … 7=周日 (the client's
	// numbering); 0 in every other mode.
	Weekday int `json:"weekday,omitempty"`
	// Day is the day of the month for the monthly mode and the day of the
	// month for the yearly mode. A month without that day (the 31st in
	// February) fires on the month's last day — a client-side decision,
	// fixed in the client's recurrence tests.
	Day int `json:"day,omitempty"`
	// Month is the yearly mode's month, 1..12.
	Month int `json:"month,omitempty"`
	// Hour and Minute are the local time of day every occurrence fires at.
	Hour   int `json:"hour"`
	Minute int `json:"minute"`
}

// reminderRuleJSON encodes the remind_rule column; nil and the zero rule
// (the API clear value) both encode as the empty string.
func reminderRuleJSON(r *ReminderRule) string {
	if r == nil || r.Mode == "" {
		return ""
	}
	b, err := json.Marshal(r)
	if err != nil {
		// The rule is one string and plain ints; marshaling cannot fail.
		panic(fmt.Sprintf("encode reminder rule: %v", err))
	}
	return string(b)
}

// reminderRulePtr decodes the remind_rule column: the empty string is no
// rule. The column is only ever written from a validated rule, so a value
// that fails to parse is corruption and comes back as an error.
func reminderRulePtr(s string) (*ReminderRule, error) {
	if s == "" {
		return nil, nil
	}
	var r ReminderRule
	if err := json.Unmarshal([]byte(s), &r); err != nil {
		return nil, fmt.Errorf("decode reminder rule %q: %w", s, err)
	}
	return &r, nil
}
