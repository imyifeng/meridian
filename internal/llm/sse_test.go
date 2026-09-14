package llm_test

import (
	"strings"
	"testing"

	"github.com/imyifeng/meridian/internal/llm"
)

// The SSE parser is the byte-stream-to-events seam of the streaming client:
// feed it network chunks in any split, it hands back the events those chunks
// completed. OpenAI-compatible chat completions stream `data: {...}` lines
// terminated by `data: [DONE]`; every other line (comments, keep-alives) is
// noise. The tests drive it the way the network does — arbitrary chunk
// boundaries, partial lines left dangling mid-read.

func TestParserEmitsDataEvents(t *testing.T) {
	cases := []struct {
		name   string
		chunks []string
		want   []llm.Event
	}{
		{
			name:   "one event in one chunk",
			chunks: []string{"data: {\"delta\":\"你\"}\n\n"},
			want:   []llm.Event{{Data: "{\"delta\":\"你\"}"}},
		},
		{
			name:   "no space after the colon",
			chunks: []string{"data:{\"delta\":\"a\"}\n\n"},
			want:   []llm.Event{{Data: "{\"delta\":\"a\"}"}},
		},
		{
			name:   "line split across two chunks",
			chunks: []string{"data: {\"del", "ta\":\"hi\"}\n\n"},
			want:   []llm.Event{{Data: "{\"delta\":\"hi\"}"}},
		},
		{
			name:   "CRLF line endings",
			chunks: []string{"data: {\"a\":1}\r\n\r\n"},
			want:   []llm.Event{{Data: "{\"a\":1}"}},
		},
		{
			name:   "several events in one chunk",
			chunks: []string{"data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"},
			want:   []llm.Event{{Data: "{\"a\":1}"}, {Data: "{\"b\":2}"}},
		},
		{
			name:   "comments and empty lines are noise",
			chunks: []string{": keep-alive\n\ndata: {\"a\":1}\n\nevent: ping\n\n"},
			want:   []llm.Event{{Data: "{\"a\":1}"}},
		},
		{
			name:   "dangling partial line yields nothing until completed",
			chunks: []string{"data: {\"a\":", "1}\n\n"},
			want:   []llm.Event{{Data: "{\"a\":1}"}},
		},
		{
			name:   "done sentinel",
			chunks: []string{"data: [DONE]\n\n"},
			want:   []llm.Event{{Done: true}},
		},
		{
			name:   "events then done in one chunk",
			chunks: []string{"data: {\"a\":1}\n\ndata: [DONE]\n\n"},
			want:   []llm.Event{{Data: "{\"a\":1}"}, {Done: true}},
		},
		{
			name:   "nothing after done",
			chunks: []string{"data: [DONE]\n\ndata: {\"late\":true}\n\n"},
			want:   []llm.Event{{Done: true}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := &llm.Parser{}
			var got []llm.Event
			for _, chunk := range tc.chunks {
				got = append(got, p.Feed([]byte(chunk))...)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("events %q, want %q", formatEvents(got), formatEvents(tc.want))
			}
			for i, ev := range got {
				if ev != tc.want[i] {
					t.Errorf("event %d = %+v, want %+v", i, ev, tc.want[i])
				}
			}
		})
	}
}

// Byte-at-a-time feeding is the harshest chunk split there is; the parser
// must buffer until every line completes.
func TestParserByteAtATime(t *testing.T) {
	p := &llm.Parser{}
	var got []llm.Event
	for _, b := range []byte("data: {\"a\":1}\n\ndata: [DONE]\n") {
		got = append(got, p.Feed([]byte{b})...)
	}
	want := []llm.Event{{Data: "{\"a\":1}"}, {Done: true}}
	if len(got) != len(want) {
		t.Fatalf("events %q, want %q", formatEvents(got), formatEvents(want))
	}
	for i, ev := range got {
		if ev != want[i] {
			t.Errorf("event %d = %+v, want %+v", i, ev, want[i])
		}
	}
}

func formatEvents(evs []llm.Event) string {
	parts := make([]string, len(evs))
	for i, ev := range evs {
		if ev.Done {
			parts[i] = "[DONE]"
		} else {
			parts[i] = ev.Data
		}
	}
	return strings.Join(parts, " | ")
}
