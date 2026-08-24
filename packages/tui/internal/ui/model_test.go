package ui

import (
	"encoding/json"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/roasbeef/loom/tui/internal/client"
	"github.com/roasbeef/loom/tui/internal/proto"
)

// captureSender records every command the model issues.
type captureSender struct {
	sent []sentCommand
}

type sentCommand struct {
	cmd  string
	body any
}

func (c *captureSender) Send(cmd string, body any) (uint64, error) {
	c.sent = append(c.sent, sentCommand{cmd: cmd, body: body})
	return uint64(len(c.sent)), nil
}

// fixture builds a sized model with a captured sender and a two-strand
// snapshot applied.
func fixture(t *testing.T) (Model, *captureSender) {
	t.Helper()
	sender := &captureSender{}
	m := New(Config{Session: "demo", Sender: sender, PlainMarkdown: true})
	m = apply(t, m, tea.WindowSizeMsg{Width: 100, Height: 40})
	m = apply(t, m, client.SnapshotMsg{Body: proto.SnapshotBody{
		Mode:    proto.SnapshotFull,
		Session: "demo",
		NextSeq: 1,
		Strands: []proto.Strand{
			{ID: "main", Name: "main"},
			{ID: "research", Name: "research"},
		},
	}})
	return m, sender
}

// apply runs one message through Update. Send commands returned by
// Update (m.send closures) execute immediately so they land in the
// capture; anything else a bubbles component returned (cursor blink
// ticks, viewport commands) is dropped — executing a tea.Tick in a
// test would block on its timer.
func apply(t *testing.T, m Model, msg tea.Msg) Model {
	t.Helper()
	action := isActionKey(&m, msg)
	next, cmd := m.Update(msg)
	model := next.(Model)
	if action && cmd != nil {
		if out := cmd(); out != nil {
			if _, isQuit := out.(tea.QuitMsg); !isQuit {
				next, _ = model.Update(out)
				model = next.(Model)
			}
		}
	}
	return model
}

// isActionKey reports whether msg is a key that can produce a send:
// enter, or an approval decision while the overlay is up.
func isActionKey(m *Model, msg tea.Msg) bool {
	k, ok := msg.(tea.KeyMsg)
	if !ok {
		return false
	}
	switch k.String() {
	case "enter":
		return true
	case "y", "Y", "n", "N":
		return m.overlayActive()
	default:
		return false
	}
}

func key(s string) tea.KeyMsg {
	switch s {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "tab":
		return tea.KeyMsg{Type: tea.KeyTab}
	case "shift+tab":
		return tea.KeyMsg{Type: tea.KeyShiftTab}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEscape}
	case "ctrl+t":
		return tea.KeyMsg{Type: tea.KeyCtrlT}
	case "ctrl+e":
		return tea.KeyMsg{Type: tea.KeyCtrlE}
	case "ctrl+c":
		return tea.KeyMsg{Type: tea.KeyCtrlC}
	default:
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	}
}

func typeText(t *testing.T, m Model, text string) Model {
	t.Helper()
	for _, r := range text {
		m = apply(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	return m
}

func entryMsg(t *testing.T, strand string, raw string) client.EntryMsg {
	t.Helper()
	entry, err := proto.ParseEntry(json.RawMessage(raw))
	if err != nil {
		t.Fatalf("bad test entry: %v", err)
	}
	return client.EntryMsg{Strand: strand, Entry: entry, Raw: json.RawMessage(raw)}
}

func assistantEntry(t *testing.T, id, text string) client.EntryMsg {
	t.Helper()
	return entryMsg(t, "main",
		`{"id":"`+id+`","seq":1,"timestamp":0,"type":"message","message":{"role":"assistant",`+
			`"content":[{"type":"text","text":"`+text+`"}],"api":"x","provider":"x","model":"m1",`+
			`"stopReason":"stop","timestamp":0}}`)
}

func pendingEscalation(id string) client.EscalationMsg {
	return client.EscalationMsg{Body: proto.EscalationBody{
		EscalationID: id,
		Op:           "op-1",
		Strand:       "main",
		Status:       proto.EscalationPending,
		Denial: &proto.Denial{
			Reason: "connect to registry.npmjs.org:443 blocked by policy",
			Source: proto.DenialPolicy,
			Wanted: []proto.Grant{{
				Type:    proto.GrantNetwork,
				Network: &proto.Network{Mode: proto.NetworkProxy, Allow: []string{"registry.npmjs.org"}},
			}},
		},
	}}
}

func TestEnterSendsPromptWhenIdle(t *testing.T) {
	m, sender := fixture(t)
	m = typeText(t, m, "hello there")
	m = apply(t, m, key("enter"))

	if len(sender.sent) != 1 {
		t.Fatalf("want 1 send, got %+v", sender.sent)
	}
	if sender.sent[0].cmd != proto.CmdPrompt {
		t.Fatalf("want prompt, got %s", sender.sent[0].cmd)
	}
	body := sender.sent[0].body.(proto.PromptBody)
	if body.Strand != "main" || body.Text != "hello there" {
		t.Fatalf("wrong body: %+v", body)
	}
	if got := m.input.Value(); got != "" {
		t.Fatalf("input not cleared: %q", got)
	}
}

func TestEnterSendsSteerWhenLive(t *testing.T) {
	m, sender := fixture(t)
	m = apply(t, m, client.OpTransitionMsg{Body: proto.OpTransitionBody{
		Op: "op-1", Strand: "main", Phase: proto.PhaseAssistant,
	}})
	m = typeText(t, m, "go left")
	m = apply(t, m, key("enter"))

	if len(sender.sent) != 1 || sender.sent[0].cmd != proto.CmdSteer {
		t.Fatalf("want steer, got %+v", sender.sent)
	}
	body := sender.sent[0].body.(proto.SteerBody)
	if body.Text != "go left" {
		t.Fatalf("wrong steer body: %+v", body)
	}
}

func TestEmptyEnterSendsNothing(t *testing.T) {
	m, sender := fixture(t)
	apply(t, m, key("enter"))
	if len(sender.sent) != 0 {
		t.Fatalf("empty enter sent %+v", sender.sent)
	}
}

func TestStrandSwitching(t *testing.T) {
	m, _ := fixture(t)
	if m.activeStrand() != "main" {
		t.Fatalf("initial strand: %s", m.activeStrand())
	}
	m = apply(t, m, key("tab"))
	if m.activeStrand() != "research" {
		t.Fatalf("after tab: %s", m.activeStrand())
	}
	m = apply(t, m, key("tab"))
	if m.activeStrand() != "main" {
		t.Fatalf("tab did not wrap: %s", m.activeStrand())
	}
	m = apply(t, m, key("shift+tab"))
	if m.activeStrand() != "research" {
		t.Fatalf("after shift+tab: %s", m.activeStrand())
	}
	// Prompts go to the active strand.
	m = typeText(t, m, "x")
	m = apply(t, m, key("enter"))
	sender := m.cfg.Sender.(*captureSender)
	if body := sender.sent[0].body.(proto.PromptBody); body.Strand != "research" {
		t.Fatalf("prompt went to %s", body.Strand)
	}
}

func TestEscalationFlowApprove(t *testing.T) {
	m, sender := fixture(t)
	m = apply(t, m, pendingEscalation("esc-1"))

	if !m.overlayActive() {
		t.Fatal("overlay not shown")
	}
	view := m.View()
	if !strings.Contains(view, "wants: network to registry.npmjs.org") {
		t.Fatalf("policy diff not shown verbatim:\n%s", view)
	}
	// The overlay is modal: printable keys must not reach the input.
	m = apply(t, m, key("x"))
	if got := m.input.Value(); got != "" {
		t.Fatalf("overlay leaked key into input: %q", got)
	}

	m = apply(t, m, key("y"))
	if m.overlayActive() {
		t.Fatal("overlay still up after approval")
	}
	if len(sender.sent) != 1 || sender.sent[0].cmd != proto.CmdApprove {
		t.Fatalf("want approve, got %+v", sender.sent)
	}
	body := sender.sent[0].body.(proto.ApproveBody)
	if body.EscalationID != "esc-1" {
		t.Fatalf("wrong escalation: %+v", body)
	}
	if len(body.Grants) != 1 || body.Grants[0].Type != proto.GrantNetwork {
		t.Fatalf("grants must echo the wanted diff: %+v", body.Grants)
	}
}

func TestEscalationFlowDeny(t *testing.T) {
	m, sender := fixture(t)
	m = apply(t, m, pendingEscalation("esc-2"))
	m = apply(t, m, key("n"))
	if len(sender.sent) != 1 || sender.sent[0].cmd != proto.CmdDeny {
		t.Fatalf("want deny, got %+v", sender.sent)
	}
	if body := sender.sent[0].body.(proto.DenyBody); body.EscalationID != "esc-2" {
		t.Fatalf("wrong body: %+v", body)
	}
}

func TestEscalationDismissAndReview(t *testing.T) {
	m, sender := fixture(t)
	m = apply(t, m, pendingEscalation("esc-3"))
	m = apply(t, m, key("esc"))
	if m.overlayActive() {
		t.Fatal("esc did not dismiss")
	}
	if len(sender.sent) != 0 {
		t.Fatalf("dismiss must not decide: %+v", sender.sent)
	}
	m = apply(t, m, key("ctrl+e"))
	if !m.overlayActive() {
		t.Fatal("ctrl+e did not reopen")
	}
	// A server-side decision (another client approved) clears it.
	m = apply(t, m, client.EscalationMsg{Body: proto.EscalationBody{
		EscalationID: "esc-3", Op: "op-1", Strand: "main", Status: proto.EscalationApproved,
	}})
	if m.overlayActive() {
		t.Fatal("decided escalation still pending")
	}
}

func TestDeltaThenSettledReplacement(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, client.StreamDeltaMsg{Body: proto.StreamDeltaBody{
		Strand: "main", Op: "op-1", Ephemeral: true, Kind: proto.DeltaText, Text: "partial str",
	}})
	m = apply(t, m, client.StreamDeltaMsg{Body: proto.StreamDeltaBody{
		Strand: "main", Op: "op-1", Ephemeral: true, Kind: proto.DeltaText, Text: "eaming answer",
	}})
	if got := m.renderTranscript(); !strings.Contains(got, "partial streaming answer") {
		t.Fatalf("live deltas not rendered:\n%s", got)
	}

	m = apply(t, m, assistantEntry(t, "a1", "the settled answer"))
	got := m.renderTranscript()
	if strings.Contains(got, "partial streaming answer") {
		t.Fatalf("stream not replaced by settled entry:\n%s", got)
	}
	if !strings.Contains(got, "the settled answer") {
		t.Fatalf("settled entry missing:\n%s", got)
	}
}

func TestThinkingCollapsedByDefault(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, entryMsg(t, "main",
		`{"id":"a2","seq":1,"timestamp":0,"type":"message","message":{"role":"assistant",`+
			`"content":[{"type":"thinking","thinking":"secret reasoning about retries","redacted":false},`+
			`{"type":"text","text":"visible answer"}],"api":"x","provider":"x","model":"m1",`+
			`"stopReason":"stop","timestamp":0}}`))
	got := m.renderTranscript()
	if strings.Contains(got, "secret reasoning") {
		t.Fatalf("thinking expanded by default:\n%s", got)
	}
	if !strings.Contains(got, "thinking (") {
		t.Fatalf("no collapsed thinking marker:\n%s", got)
	}
	m = apply(t, m, key("ctrl+t"))
	if got := m.renderTranscript(); !strings.Contains(got, "secret reasoning") {
		t.Fatalf("ctrl+t did not expand thinking:\n%s", got)
	}
}

func TestToolResultExitCodes(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, entryMsg(t, "main",
		`{"id":"t1","seq":1,"timestamp":0,"type":"message","message":{"role":"toolResult",`+
			`"toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"it worked"}],`+
			`"details":{"exitCode":0},"isError":false,"timestamp":0}}`))
	m = apply(t, m, entryMsg(t, "main",
		`{"id":"t2","seq":2,"timestamp":0,"type":"message","message":{"role":"toolResult",`+
			`"toolCallId":"c2","toolName":"bash","content":[{"type":"text","text":"it broke"}],`+
			`"details":{"exitCode":127},"isError":true,"timestamp":0}}`))
	got := m.renderTranscript()
	for _, want := range []string{"exit 0", "exit 127", "it worked", "it broke"} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in:\n%s", want, got)
		}
	}
}

func TestPaletteCommands(t *testing.T) {
	tests := []struct {
		name     string
		typed    string
		wantCmd  string
		wantBody func(t *testing.T, body any)
	}{
		{
			name: "fork default scope", typed: ":fork", wantCmd: proto.CmdFork,
			wantBody: func(t *testing.T, body any) {
				b := body.(proto.ForkBody)
				if b.Strand != "main" || b.Scope != proto.ForkScopeBranch {
					t.Fatalf("fork body: %+v", b)
				}
			},
		},
		{
			name: "fork tree named", typed: ":fork tree alt", wantCmd: proto.CmdFork,
			wantBody: func(t *testing.T, body any) {
				b := body.(proto.ForkBody)
				if b.Scope != proto.ForkScopeTree || b.Name != "alt" {
					t.Fatalf("fork body: %+v", b)
				}
			},
		},
		{
			name: "compact with instructions", typed: ":compact keep decisions", wantCmd: proto.CmdCompact,
			wantBody: func(t *testing.T, body any) {
				b := body.(proto.CompactBody)
				if b.Strand != "main" || b.Instructions != "keep decisions" {
					t.Fatalf("compact body: %+v", b)
				}
			},
		},
		{
			name: "abort", typed: ":abort", wantCmd: proto.CmdAbort,
			wantBody: func(t *testing.T, body any) {
				if b := body.(proto.AbortBody); b.Strand != "main" {
					t.Fatalf("abort body: %+v", b)
				}
			},
		},
		{
			name: "create strand", typed: ":strand ideas", wantCmd: proto.CmdCreateStrand,
			wantBody: func(t *testing.T, body any) {
				if b := body.(proto.CreateStrandBody); b.Name != "ideas" {
					t.Fatalf("create body: %+v", b)
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m, sender := fixture(t)
			m = typeText(t, m, tt.typed)
			apply(t, m, key("enter"))
			if len(sender.sent) != 1 || sender.sent[0].cmd != tt.wantCmd {
				t.Fatalf("want %s, got %+v", tt.wantCmd, sender.sent)
			}
			tt.wantBody(t, sender.sent[0].body)
		})
	}
}

func TestPaletteQuit(t *testing.T) {
	m, _ := fixture(t)
	m = typeText(t, m, ":quit")
	next, cmd := m.Update(key("enter"))
	if cmd == nil {
		t.Fatal("no quit command returned")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal(":quit did not quit")
	}
	if !next.(Model).quitting {
		t.Fatal("model not marked quitting")
	}
}

func TestPaletteUnknown(t *testing.T) {
	m, sender := fixture(t)
	m = typeText(t, m, ":frob")
	m = apply(t, m, key("enter"))
	if len(sender.sent) != 0 {
		t.Fatalf("unknown palette command sent %+v", sender.sent)
	}
	if !strings.Contains(m.statusNote, "unknown command") {
		t.Fatalf("no feedback: %q", m.statusNote)
	}
}

func TestUsageAccumulates(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, client.SnapshotMsg{Body: proto.SnapshotBody{
		Mode:    proto.SnapshotFull,
		Session: "demo",
		Strands: []proto.Strand{{ID: "main"}},
		Usage:   &proto.Usage{TotalTokens: 1000, Cost: proto.UsageCost{Total: 0.01}},
	}})
	m = apply(t, m, client.UsageMsg{Body: proto.UsageBody{
		Strand: "main",
		Usage:  proto.Usage{TotalTokens: 500, Cost: proto.UsageCost{Total: 0.005}},
	}})
	if m.usage.TotalTokens != 1500 {
		t.Fatalf("tokens: %d", m.usage.TotalTokens)
	}
	if got := m.View(); !strings.Contains(got, "1.5k tok") {
		t.Fatalf("status bar missing usage:\n%s", got)
	}
}

func TestOpPhaseInStatusBar(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, client.OpTransitionMsg{Body: proto.OpTransitionBody{
		Op: "op-1", Strand: "main", Phase: proto.PhaseTools,
	}})
	if got := m.View(); !strings.Contains(got, "main: tools") {
		t.Fatalf("phase not shown:\n%s", got)
	}
	m = apply(t, m, client.OpTransitionMsg{Body: proto.OpTransitionBody{
		Op: "op-1", Strand: "main", Phase: proto.PhaseDone,
	}})
	if got := m.View(); !strings.Contains(got, "main: idle") {
		t.Fatalf("phase not cleared:\n%s", got)
	}
}

func TestStrandsSnapshotUpdatesSwitcher(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, client.SnapshotMsg{Body: proto.SnapshotBody{
		Mode: proto.SnapshotStrands,
		Strands: []proto.Strand{
			{ID: "main", Name: "main"},
			{ID: "research", Name: "research"},
			{ID: "alt", Name: "alt"},
		},
	}})
	if len(m.strands) != 3 || m.strands[2].ID != "alt" {
		t.Fatalf("strands not replaced: %+v", m.strands)
	}
	if got := m.View(); !strings.Contains(got, "alt") {
		t.Fatalf("new strand not in tabs:\n%s", got)
	}
}
