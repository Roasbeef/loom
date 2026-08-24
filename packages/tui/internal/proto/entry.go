package proto

import (
	"encoding/json"
	"fmt"
)

// The types below parse the durable values the gateway embeds verbatim:
// entries and messages in the core codec's JSON vocabulary (pi field
// names, camelCase — see packages/core/src/core/codec.gleam). The TUI
// parses only what it renders; unknown fields pass through untouched
// because EntryBody keeps the raw encoding.

// Entry kinds (core codec "type").
const (
	EntryMessage       = "message"
	EntryCompaction    = "compaction"
	EntryBranchSummary = "branch_summary"
	EntryCustom        = "custom"
)

// Message roles (core codec "role").
const (
	RoleUser       = "user"
	RoleAssistant  = "assistant"
	RoleToolResult = "toolResult"
	RoleCustom     = "custom"
)

// Block kinds (core codec content "type").
const (
	BlockText     = "text"
	BlockThinking = "thinking"
	BlockImage    = "image"
	BlockToolCall = "toolCall"
)

// Entry is the renderable view of a core codec entry.
type Entry struct {
	ID        string `json:"id"`
	ParentID  string `json:"parentId,omitempty"`
	Seq       int64  `json:"seq"`
	Timestamp int64  `json:"timestamp"`
	Type      string `json:"type"`

	// Message entries.
	Message   *Message `json:"message,omitempty"`
	Terminate bool     `json:"terminate,omitempty"`

	// Compaction / branch-summary entries.
	Summary      string `json:"summary,omitempty"`
	TokensBefore int64  `json:"tokensBefore,omitempty"`
	FromID       string `json:"fromId,omitempty"`

	// Custom entries.
	CustomType string          `json:"customType,omitempty"`
	Data       json.RawMessage `json:"data,omitempty"`
}

// Message is the renderable view of a core codec AgentMessage,
// discriminated by Role.
type Message struct {
	Role    string  `json:"role"`
	Content []Block `json:"content,omitempty"`

	// Assistant fields.
	Provider     string `json:"provider,omitempty"`
	Model        string `json:"model,omitempty"`
	StopReason   string `json:"stopReason,omitempty"`
	ErrorMessage string `json:"errorMessage,omitempty"`
	Usage        *Usage `json:"usage,omitempty"`

	// Tool-result fields. Details is tool-specific; the TUI looks for
	// an "exitCode" number when rendering exec-shaped results.
	ToolCallID string          `json:"toolCallId,omitempty"`
	ToolName   string          `json:"toolName,omitempty"`
	IsError    bool            `json:"isError,omitempty"`
	Details    json.RawMessage `json:"details,omitempty"`

	// Custom fields.
	Schema  string          `json:"schema,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`

	Timestamp int64 `json:"timestamp,omitempty"`
}

// Block is one content block, discriminated by Type.
type Block struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`

	Thinking string `json:"thinking,omitempty"`
	Redacted bool   `json:"redacted,omitempty"`

	ToolCall *ToolCall `json:"toolCall,omitempty"`

	// Image blocks; Data is base64 and not rendered by the TUI.
	MimeType string `json:"mimeType,omitempty"`
	Data     string `json:"data,omitempty"`
}

// ToolCall is one tool invocation requested by the model.
type ToolCall struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

// Usage is the core codec Usage shape, verbatim (camelCase).
type Usage struct {
	Input        int64     `json:"input"`
	Output       int64     `json:"output"`
	CacheRead    int64     `json:"cacheRead"`
	CacheWrite   int64     `json:"cacheWrite"`
	CacheWrite1h *int64    `json:"cacheWrite1h,omitempty"`
	Reasoning    *int64    `json:"reasoning,omitempty"`
	TotalTokens  int64     `json:"totalTokens"`
	Cost         UsageCost `json:"cost"`
}

// UsageCost is the dollar-cost breakdown of a Usage.
type UsageCost struct {
	Input      float64 `json:"input"`
	Output     float64 `json:"output"`
	CacheRead  float64 `json:"cacheRead"`
	CacheWrite float64 `json:"cacheWrite"`
	Total      float64 `json:"total"`
}

// Add accumulates other into u (cost included). The running status-bar
// total is a client-side sum of snapshot baseline plus usage events.
func (u *Usage) Add(other Usage) {
	u.Input += other.Input
	u.Output += other.Output
	u.CacheRead += other.CacheRead
	u.CacheWrite += other.CacheWrite
	u.TotalTokens += other.TotalTokens
	u.Cost.Input += other.Cost.Input
	u.Cost.Output += other.Cost.Output
	u.Cost.CacheRead += other.Cost.CacheRead
	u.Cost.CacheWrite += other.Cost.CacheWrite
	u.Cost.Total += other.Cost.Total
}

// ParseEntry decodes a core codec entry. It validates the discriminator
// and the presence of the message on message entries; everything else
// is tolerant.
func ParseEntry(raw json.RawMessage) (Entry, error) {
	var e Entry
	if err := json.Unmarshal(raw, &e); err != nil {
		return Entry{}, fmt.Errorf("proto: parse entry: %w", err)
	}
	if e.ID == "" {
		return Entry{}, fmt.Errorf("proto: entry missing id")
	}
	switch e.Type {
	case EntryMessage:
		if e.Message == nil {
			return Entry{}, fmt.Errorf("proto: message entry %s missing message", e.ID)
		}
	case EntryCompaction, EntryBranchSummary, EntryCustom:
	case "":
		return Entry{}, fmt.Errorf("proto: entry %s missing type", e.ID)
	}
	return e, nil
}

// ExitCode extracts an exec-style exit code from a tool result's
// details, returning ok=false when none is present.
func (m *Message) ExitCode() (int, bool) {
	if len(m.Details) == 0 {
		return 0, false
	}
	var details struct {
		ExitCode *int `json:"exitCode"`
	}
	if err := json.Unmarshal(m.Details, &details); err != nil || details.ExitCode == nil {
		return 0, false
	}
	return *details.ExitCode, true
}

// UnmarshalJSON accepts pi's bare-string content form ("content":
// "hi") alongside the block-list form the codec always emits, mirroring
// the codec's own tolerance.
func (m *Message) UnmarshalJSON(data []byte) error {
	type alias Message
	var shadow struct {
		alias
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(data, &shadow); err != nil {
		return err
	}
	*m = Message(shadow.alias)
	m.Content = nil
	if len(shadow.Content) == 0 {
		return nil
	}
	var text string
	if err := json.Unmarshal(shadow.Content, &text); err == nil {
		m.Content = []Block{{Type: BlockText, Text: text}}
		return nil
	}
	var blocks []Block
	if err := json.Unmarshal(shadow.Content, &blocks); err != nil {
		return fmt.Errorf("content is neither string nor block list: %w", err)
	}
	m.Content = blocks
	return nil
}
