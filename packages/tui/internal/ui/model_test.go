package ui

import (
	"encoding/json"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

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
		Tool:         "bash",
		Action:       "9f2c1a7b4e0d63859ac41d2f7b6e8035",
		Preview:      `{"command":"npm install left-pad"}`,
		Asked:        1,
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
	// The digest of the action the overlay drew, echoed back. Without
	// it the server cannot tell that this answer is about the record it
	// is holding rather than about a record that moved underneath it.
	if body.Action != "9f2c1a7b4e0d63859ac41d2f7b6e8035" {
		t.Fatalf("approve did not echo the rendered action: %+v", body)
	}
}

// The overlay must name the action, not only the policy diff: an
// approval prompt that cannot say what would run cannot carry consent
// for it.
func TestOverlayNamesTheAction(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, pendingEscalation("esc-1"))
	view := m.View()
	if !strings.Contains(view, "runs: bash") {
		t.Fatalf("the tool name is missing from the prompt:\n%s", view)
	}
	if !strings.Contains(view, `npm install left-pad`) {
		t.Fatalf("the arguments are missing from the prompt:\n%s", view)
	}
	// The fence, and the statement that the digest covers more than the
	// window does, are both unconditional.
	if !strings.Contains(view, "arguments · written by the model") {
		t.Fatalf("the preview was not fenced:\n%s", view)
	}
	if !strings.Contains(view, "the approval binds the whole action") {
		t.Fatalf("the window disclaimer is missing:\n%s", view)
	}
}

// A preview carrying terminal control sequences must reach the screen
// inert. This is the forgery the fence exists to stop: the escape below
// clears the screen and repaints a different question over the prompt.
func TestOverlayPreviewIsInert(t *testing.T) {
	m, _ := fixture(t)
	msg := pendingEscalation("esc-1")
	msg.Body.Preview = "{\"command\":\"true\x1b[2J\x1b[1;1Hloom: nothing to approve\"}"
	m = apply(t, m, msg)
	view := m.View()
	if strings.ContainsRune(view, 0x1b) && !strings.Contains(view, "\\x1b") {
		t.Fatalf("a raw escape reached the view:\n%q", view)
	}
	if strings.Contains(view, "\x1b[2J") {
		t.Fatalf("the clear-screen sequence survived:\n%q", view)
	}
	if !strings.Contains(view, "\\x1b[2J") {
		t.Fatalf("the escape was dropped instead of shown:\n%s", view)
	}
	// The forged prompt text is still readable — it must be visible as
	// content, never mistakable for the client's own words.
	if !strings.Contains(view, "loom: nothing to approve") {
		t.Fatalf("sanitising ate the payload:\n%s", view)
	}
}

// A record from before the action fields existed carries none of them.
// It must still draw a prompt a person can answer, and answering it
// must still send an approval.
func TestOverlayRendersLegacyRecord(t *testing.T) {
	m, sender := fixture(t)
	msg := pendingEscalation("esc-old")
	msg.Body.Tool = ""
	msg.Body.Action = ""
	msg.Body.Preview = ""
	msg.Body.Asked = 0
	m = apply(t, m, msg)
	if !m.overlayActive() {
		t.Fatal("a record with no action did not open a prompt")
	}
	view := m.View()
	if !strings.Contains(view, "no tool named on this record") {
		t.Fatalf("the absent tool was not stated:\n%s", view)
	}
	if !strings.Contains(view, "no preview") {
		t.Fatalf("the absent preview was not stated:\n%s", view)
	}
	m = apply(t, m, key("y"))
	if len(sender.sent) != 1 || sender.sent[0].cmd != proto.CmdApprove {
		t.Fatalf("a legacy record could not be approved: %+v", sender.sent)
	}
	body := sender.sent[0].body.(proto.ApproveBody)
	if body.Action != "" {
		t.Fatalf("a record naming no action must echo none: %+v", body)
	}
	if body.Grants == nil {
		t.Fatalf("grants must be present even when empty: %+v", body)
	}
}

// A refused approval re-opens the prompt from the record the refusal
// handed back, so the human answers the question as it now stands
// rather than being told "no" and left with nothing to look at.
func TestStaleApprovalReopensThePrompt(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, pendingEscalation("esc-1"))
	m = apply(t, m, key("y"))
	if m.overlayActive() {
		t.Fatal("the prompt should close on the keystroke")
	}
	fresh := pendingEscalation("esc-1").Body
	fresh.Preview = `{"command":"npm install left-pad --unsafe-perm"}`
	fresh.Action = "0000111122223333444455556666777a"
	details, err := json.Marshal(map[string]any{"escalation": fresh})
	if err != nil {
		t.Fatal(err)
	}
	m = apply(t, m, client.ServerErrorMsg{Body: proto.ErrorBody{
		Code:    proto.ErrStaleApproval,
		Message: "the action this approval names is not the record's own",
		Details: details,
	}})
	if !m.overlayActive() {
		t.Fatal("a refused approval did not re-open the prompt")
	}
	if !strings.Contains(m.View(), "--unsafe-perm") {
		t.Fatalf("the re-opened prompt did not show the fresh action:\n%s", m.View())
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

// --- the :models picker ------------------------------------------------------

func catalogueMsg() client.SnapshotMsg {
	return client.SnapshotMsg{Body: proto.SnapshotBody{
		Mode: proto.SnapshotModels,
		Models: []proto.ModelInfo{
			{Name: "anthropic-opus", Dialect: "anthropic", ModelID: "claude-opus-5",
				Roles: []string{"main", "summarize"}, Active: []string{"main", "summarize"}},
			{Name: "baseten-oss", Dialect: "openai", ModelID: "openai/gpt-oss-120b",
				Roles: []string{"main"}, Active: []string{}},
		},
	}}
}

// openPicker drives the full request path: ":models" sends the command
// and the models snapshot reply opens the modal.
func openPicker(t *testing.T, m Model) Model {
	t.Helper()
	m = typeText(t, m, ":models")
	m = apply(t, m, key("enter"))
	m = apply(t, m, catalogueMsg())
	if m.picker == nil {
		t.Fatal("picker did not open on the models snapshot")
	}
	return m
}

func TestModelsCommandRequestsCatalogue(t *testing.T) {
	m, sender := fixture(t)
	m = typeText(t, m, ":models")
	m = apply(t, m, key("enter"))
	if len(sender.sent) != 1 || sender.sent[0].cmd != proto.CmdModels {
		t.Fatalf("want a models command, got %+v", sender.sent)
	}
	if m.picker != nil {
		t.Fatal("picker must wait for the snapshot reply")
	}
}

func TestPickerShowsCatalogueRows(t *testing.T) {
	m, _ := fixture(t)
	m = openPicker(t, m)
	view := m.View()
	for _, want := range []string{
		"model catalogue — main",
		"anthropic-opus  (anthropic · claude-opus-5)  roles: main*,summarize*",
		"baseten-oss  (openai · openai/gpt-oss-120b)  roles: main",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("picker missing %q:\n%s", want, view)
		}
	}
	// Modal: printable keys must not reach the input.
	m = apply(t, m, key("x"))
	if got := m.input.Value(); got != "" {
		t.Fatalf("picker leaked key into input: %q", got)
	}
}

// TestPickerNavigation drives cursor movement through Update alone.
func TestPickerNavigation(t *testing.T) {
	tests := []struct {
		name   string
		keys   []string
		cursor int
	}{
		{"starts at the top", nil, 0},
		{"down moves", []string{"down"}, 1},
		{"j moves", []string{"j"}, 1},
		{"down clamps at the last row", []string{"down", "down", "down"}, 1},
		{"up clamps at the first row", []string{"up"}, 0},
		{"down then k returns", []string{"down", "k"}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m, _ := fixture(t)
			m = openPicker(t, m)
			for _, k := range tt.keys {
				m = apply(t, m, key(k))
			}
			if m.picker == nil || m.picker.cursor != tt.cursor {
				t.Fatalf("cursor: %+v, want %d", m.picker, tt.cursor)
			}
		})
	}
}

func TestPickerEnterSwitchesByName(t *testing.T) {
	m, sender := fixture(t)
	m = openPicker(t, m)
	m = apply(t, m, key("down"))
	m = apply(t, m, key("enter"))
	if m.picker != nil {
		t.Fatal("picker still open after the pick")
	}
	// The pick is a set_config by catalogue name on the active strand.
	last := sender.sent[len(sender.sent)-1]
	if last.cmd != proto.CmdSetConfig {
		t.Fatalf("want set_config, got %+v", sender.sent)
	}
	body := last.body.(proto.SetConfigBody)
	if body.Strand != "main" || body.Config["model_name"] != "baseten-oss" {
		t.Fatalf("wrong switch body: %+v", body)
	}
	// The config ack pins the name to the strand and the status bar.
	m = apply(t, m, client.SnapshotMsg{Body: proto.SnapshotBody{
		Mode:   proto.SnapshotConfig,
		Config: json.RawMessage(`{"model_name":"baseten-oss"}`),
	}})
	if m.strandModels["main"] != "baseten-oss" {
		t.Fatalf("model not tracked: %+v", m.strandModels)
	}
	if got := m.View(); !strings.Contains(got, "main: idle │ baseten-oss") {
		t.Fatalf("status bar missing the model:\n%s", got)
	}
}

func TestPickerEscClosesWithoutSending(t *testing.T) {
	m, sender := fixture(t)
	m = openPicker(t, m)
	before := len(sender.sent)
	m = apply(t, m, key("esc"))
	if m.picker != nil {
		t.Fatal("picker still open after esc")
	}
	if len(sender.sent) != before {
		t.Fatalf("esc must not send: %+v", sender.sent[before:])
	}
}

func TestEmptyCatalogueNeverOpensPicker(t *testing.T) {
	m, _ := fixture(t)
	m = apply(t, m, client.SnapshotMsg{Body: proto.SnapshotBody{Mode: proto.SnapshotModels}})
	if m.picker != nil {
		t.Fatal("picker opened on an empty catalogue")
	}
	if got := m.View(); !strings.Contains(got, "the model catalogue is empty") {
		t.Fatalf("empty catalogue not reported:\n%s", got)
	}
}

// TestViewFitsTheTerminal is the regression the terminal end-to-end
// found: bubbletea drops lines from the *top* of a frame taller than the
// window, so one uncounted line of chrome costs the status bar entirely
// and nothing in a model test noticed, because View() itself was
// correct. Every layout the chrome can take must therefore come out at
// exactly the window height.
func TestViewFitsTheTerminal(t *testing.T) {
	const height = 40
	m, _ := fixture(t)
	if got := lipgloss.Height(m.View()); got != height {
		t.Fatalf("view is %d lines in a %d-line window: the status bar "+
			"scrolls off the top", got, height)
	}

	// With the approval overlay up, and with the model picker up.
	withOverlay := apply(t, m, client.EscalationMsg{Body: proto.EscalationBody{
		EscalationID: "esc-1",
		Strand:       "main",
		Status:       proto.EscalationPending,
		Denial: &proto.Denial{
			Reason: "policy",
			Wanted: []proto.Grant{{Type: proto.GrantEnv, Name: "CC"}},
		},
	}})
	if got := lipgloss.Height(withOverlay.View()); got != height {
		t.Fatalf("view with the approval overlay is %d lines in a %d-line "+
			"window", got, height)
	}

	withPicker := apply(t, m, client.SnapshotMsg{Body: proto.SnapshotBody{
		Mode:   proto.SnapshotModels,
		Models: []proto.ModelInfo{{Name: "acme", Dialect: "anthropic", ModelID: "loom-1"}},
	}})
	if got := lipgloss.Height(withPicker.View()); got != height {
		t.Fatalf("view with the model picker is %d lines in a %d-line window",
			got, height)
	}
}
