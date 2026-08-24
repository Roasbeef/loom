package fake

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/roasbeef/loom/tui/internal/proto"
)

// Entry builders producing core-codec-shaped entry documents (the
// vocabulary in protocol.md: pi field names, camelCase). Tests and the
// demo script use these instead of hand-writing JSON.

func now() int64 { return time.Now().UnixMilli() }

func marshal(v any) json.RawMessage {
	raw, err := json.Marshal(v)
	if err != nil {
		panic(fmt.Sprintf("fake: marshal entry: %v", err))
	}
	return raw
}

// UserEntry builds a user message entry with one text block.
func UserEntry(id, text string) json.RawMessage {
	ts := now()
	return marshal(map[string]any{
		"id":        id,
		"parentId":  nil,
		"seq":       0,
		"timestamp": ts,
		"type":      "message",
		"message": map[string]any{
			"role":      "user",
			"content":   []map[string]any{{"type": "text", "text": text}},
			"timestamp": ts,
		},
	})
}

// AssistantEntry builds an assistant message entry from blocks (see
// TextBlock/ThinkingBlock/ToolCallBlock) with a plausible usage.
func AssistantEntry(id, stopReason string, usage proto.Usage, blocks ...map[string]any) json.RawMessage {
	ts := now()
	return marshal(map[string]any{
		"id":        id,
		"parentId":  nil,
		"seq":       0,
		"timestamp": ts,
		"type":      "message",
		"message": map[string]any{
			"role":       "assistant",
			"content":    blocks,
			"api":        "fake-messages",
			"provider":   "fake",
			"model":      "loom-fake-1",
			"usage":      usage,
			"stopReason": stopReason,
			"timestamp":  ts,
		},
	})
}

// ToolResultEntry builds a tool result entry with an exec-style
// exitCode detail.
func ToolResultEntry(id, callID, toolName, output string, exitCode int) json.RawMessage {
	ts := now()
	return marshal(map[string]any{
		"id":        id,
		"parentId":  nil,
		"seq":       0,
		"timestamp": ts,
		"type":      "message",
		"message": map[string]any{
			"role":       "toolResult",
			"toolCallId": callID,
			"toolName":   toolName,
			"content":    []map[string]any{{"type": "text", "text": output}},
			"details":    map[string]any{"exitCode": exitCode},
			"isError":    exitCode != 0,
			"timestamp":  ts,
		},
	})
}

// CompactionEntry builds a compaction entry.
func CompactionEntry(id, summary string, tokensBefore int64) json.RawMessage {
	return marshal(map[string]any{
		"id":           id,
		"parentId":     nil,
		"seq":          0,
		"timestamp":    now(),
		"type":         "compaction",
		"summary":      summary,
		"retainedTail": []any{},
		"tokensBefore": tokensBefore,
		"fromHook":     false,
	})
}

// TextBlock is an assistant text content block.
func TextBlock(text string) map[string]any {
	return map[string]any{"type": "text", "text": text}
}

// ThinkingBlock is an assistant thinking content block.
func ThinkingBlock(thinking string) map[string]any {
	return map[string]any{"type": "thinking", "thinking": thinking, "redacted": false}
}

// ToolCallBlock is an assistant tool-call content block.
func ToolCallBlock(callID, name string, arguments map[string]any) map[string]any {
	return map[string]any{
		"type": "toolCall",
		"toolCall": map[string]any{
			"id":        callID,
			"name":      name,
			"arguments": arguments,
		},
	}
}

// SmallUsage is a plausible usage for one fake response.
func SmallUsage(input, output int64) proto.Usage {
	return proto.Usage{
		Input:       input,
		Output:      output,
		CacheRead:   input / 2,
		TotalTokens: input + output,
		Cost: proto.UsageCost{
			Input:  float64(input) * 3e-6,
			Output: float64(output) * 15e-6,
			Total:  float64(input)*3e-6 + float64(output)*15e-6,
		},
	}
}
