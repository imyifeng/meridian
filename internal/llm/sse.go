// Package llm is Meridian's OpenAI-compatible chat-completions client
// (ADR-0009): the one place that knows how to talk to the configured model
// service. Standard library only — net/http for the wire, a small parser
// for the SSE stream. Error kinds are part of the contract: callers branch
// on them (the console's 连接测试 turns each kind into readable text).
package llm

import (
	"bytes"
	"strings"
)

// Event is one parsed server-sent event from a streaming completion: a
// data payload, or the [DONE] sentinel that ends the stream.
type Event struct {
	Data string
	Done bool
}

// Parser turns a byte stream into server-sent events. It is a pure
// byte→event machine with no I/O: feed it the chunks as they arrive, in any
// split, and it hands back the events those chunks completed, buffering any
// partial line for the next feed. After the [DONE] sentinel it stays quiet.
type Parser struct {
	pending []byte
	done    bool
}

// Feed consumes one chunk of the stream and returns the events it completed.
func (p *Parser) Feed(chunk []byte) []Event {
	if p.done {
		return nil
	}
	p.pending = append(p.pending, chunk...)
	var events []Event
	for {
		idx := bytes.IndexByte(p.pending, '\n')
		if idx < 0 {
			break
		}
		line := string(p.pending[:idx])
		p.pending = p.pending[idx+1:]
		line = strings.TrimSuffix(line, "\r")
		if ev, ok := parseLine(line); ok {
			if ev.Done {
				p.done = true
			}
			events = append(events, ev)
			if p.done {
				break
			}
		}
	}
	return events
}

// parseLine classifies one complete SSE line. Only data lines are events;
// comments, field lines the protocol doesn't need, and blanks are noise.
func parseLine(line string) (Event, bool) {
	rest, ok := strings.CutPrefix(line, "data:")
	if !ok {
		return Event{}, false
	}
	rest = strings.TrimPrefix(rest, " ")
	if rest == "[DONE]" {
		return Event{Done: true}, true
	}
	return Event{Data: rest}, true
}
