package ui

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/charmbracelet/glamour"

	"github.com/roasbeef/loom/tui/internal/proto"
)

// renderMarkdown renders assistant markdown through glamour, falling
// back to the raw text if rendering is unavailable (headless tests,
// renderer failure).
func (m *Model) renderMarkdown(text string) string {
	if m.cfg.PlainMarkdown {
		return text
	}
	if m.md == nil || m.mdWidth != m.contentWidth() {
		renderer, err := glamour.NewTermRenderer(
			glamour.WithAutoStyle(),
			glamour.WithWordWrap(m.contentWidth()),
		)
		if err != nil {
			return text
		}
		m.md = renderer
		m.mdWidth = m.contentWidth()
	}
	out, err := m.md.Render(text)
	if err != nil {
		return text
	}
	return strings.TrimRight(out, "\n")
}

// renderTranscript builds the viewport content for the active strand:
// settled entries first, then the live streaming tail.
func (m *Model) renderTranscript() string {
	var b strings.Builder
	strand := m.activeStrand()
	for _, it := range m.transcripts[strand] {
		b.WriteString(m.renderEntry(it))
		b.WriteString("\n\n")
	}
	if s := m.streams[strand]; s != nil {
		b.WriteString(m.renderStream(s))
		b.WriteString("\n")
	}
	if b.Len() == 0 {
		return styleDim.Render("(no entries yet — type a prompt below)")
	}
	return strings.TrimRight(b.String(), "\n")
}

func (m *Model) renderEntry(entry proto.Entry) string {
	switch entry.Type {
	case proto.EntryMessage:
		return m.renderMessage(entry.Message)
	case proto.EntryCompaction:
		return styleCompaction.Render(fmt.Sprintf(
			"── compacted (%s tokens before) ─ %s", tokens(entry.TokensBefore), entry.Summary))
	case proto.EntryBranchSummary:
		return styleCompaction.Render("── branch summary ─ " + entry.Summary)
	case proto.EntryCustom:
		return styleDim.Render("[" + entry.CustomType + "]")
	default:
		return styleDim.Render("[" + entry.Type + " entry]")
	}
}

func (m *Model) renderMessage(msg *proto.Message) string {
	switch msg.Role {
	case proto.RoleUser:
		return styleUser.Render("you ❯ ") + blocksText(msg.Content)
	case proto.RoleAssistant:
		return m.renderAssistant(msg)
	case proto.RoleToolResult:
		return m.renderToolResult(msg)
	case proto.RoleCustom:
		return styleDim.Render("[custom message: " + msg.Schema + "]")
	default:
		return styleDim.Render("[" + msg.Role + " message]")
	}
}

func (m *Model) renderAssistant(msg *proto.Message) string {
	var parts []string
	tag := styleAssistantTag.Render("loom")
	if msg.Model != "" {
		tag += styleDim.Render(" · " + msg.Model)
	}
	parts = append(parts, tag)
	for _, block := range msg.Content {
		switch block.Type {
		case proto.BlockThinking:
			parts = append(parts, m.renderThinking(block.Thinking, block.Redacted))
		case proto.BlockText:
			parts = append(parts, m.renderMarkdown(block.Text))
		case proto.BlockToolCall:
			if block.ToolCall != nil {
				parts = append(parts, renderToolCall(block.ToolCall))
			}
		case proto.BlockImage:
			parts = append(parts, styleDim.Render("[image "+block.MimeType+"]"))
		}
	}
	if msg.StopReason == "error" {
		parts = append(parts, styleError.Render("response error: "+msg.ErrorMessage))
	}
	if msg.StopReason == "aborted" {
		parts = append(parts, styleDim.Render("(aborted)"))
	}
	return strings.Join(parts, "\n")
}

// renderThinking collapses reasoning to one dim line by default;
// ctrl+t expands it.
func (m *Model) renderThinking(thinking string, redacted bool) string {
	if redacted {
		return styleThinking.Render("∴ thinking (redacted)")
	}
	if !m.showThinking {
		return styleThinking.Render(fmt.Sprintf(
			"∴ thinking (%d chars — ctrl+t to expand)", len(thinking)))
	}
	return styleThinking.Render("∴ " + thinking)
}

func renderToolCall(call *proto.ToolCall) string {
	return styleToolCall.Render("⚒ " + call.Name + " " + compactArgs(call.Arguments))
}

func (m *Model) renderToolResult(msg *proto.Message) string {
	head := "→ " + msg.ToolName
	if code, ok := msg.ExitCode(); ok {
		badge := styleExitOK.Render(fmt.Sprintf("exit %d", code))
		if code != 0 {
			badge = styleExitBad.Render(fmt.Sprintf("exit %d", code))
		}
		head += " " + badge
	} else if msg.IsError {
		head += " " + styleExitBad.Render("error")
	}
	body := clipLines(blocksText(msg.Content), 12)
	if body == "" {
		return styleToolResult.Render(head)
	}
	return styleToolResult.Render(head + "\n" + body)
}

// renderStream renders the live, ephemeral tail: thinking and text so
// far, plus any tool call being assembled. Settled entries replace it.
func (m *Model) renderStream(s *streamState) string {
	var parts []string
	parts = append(parts, styleAssistantTag.Render("loom")+styleDim.Render(" · streaming…"))
	if s.thinking.Len() > 0 {
		if m.showThinking {
			parts = append(parts, styleThinking.Render("∴ "+s.thinking.String()))
		} else {
			parts = append(parts, styleThinking.Render(fmt.Sprintf(
				"∴ thinking… (%d chars)", s.thinking.Len())))
		}
	}
	if s.text.Len() > 0 {
		// Plain text while streaming; glamour renders the settled entry.
		parts = append(parts, s.text.String()+"▌")
	}
	if s.toolName != "" {
		parts = append(parts, styleToolCall.Render("⚒ "+s.toolName+" "+s.toolArgs.String()+"…"))
	}
	return strings.Join(parts, "\n")
}

// blocksText joins the text of content blocks.
func blocksText(blocks []proto.Block) string {
	var parts []string
	for _, b := range blocks {
		if b.Type == proto.BlockText && b.Text != "" {
			parts = append(parts, b.Text)
		}
		if b.Type == proto.BlockImage {
			parts = append(parts, "[image "+b.MimeType+"]")
		}
	}
	return strings.Join(parts, "\n")
}

// compactArgs renders tool arguments one-line: a lone "command" string
// shows bare, anything else as compact JSON.
func compactArgs(raw json.RawMessage) string {
	var args map[string]json.RawMessage
	if err := json.Unmarshal(raw, &args); err == nil && len(args) == 1 {
		if cmd, ok := args["command"]; ok {
			var s string
			if err := json.Unmarshal(cmd, &s); err == nil {
				return s
			}
		}
	}
	out := string(raw)
	if len(out) > 120 {
		out = out[:117] + "…"
	}
	return out
}

func clipLines(s string, max int) string {
	lines := strings.Split(s, "\n")
	if len(lines) <= max {
		return s
	}
	kept := lines[:max]
	return strings.Join(kept, "\n") + "\n" +
		styleDim.Render(fmt.Sprintf("… (%d more lines)", len(lines)-max))
}

// tokens humanizes a token count (1500 -> 1.5k).
func tokens(n int64) string {
	switch {
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.1fk", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}
