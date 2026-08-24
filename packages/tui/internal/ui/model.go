// Package ui is the bubbletea program: protocol events arrive as
// bubbletea messages (the client's typed Msg values), key presses turn
// into websocket commands through a Sender. Update is pure — sends are
// returned as tea.Cmd closures — so the whole interaction surface is
// table-testable without a terminal.
package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"

	"github.com/roasbeef/loom/tui/internal/client"
	"github.com/roasbeef/loom/tui/internal/proto"
)

// Sender issues protocol commands; the connection client implements
// it, tests capture with a stub.
type Sender interface {
	Send(cmd string, body any) (uint64, error)
}

// Config configures the program.
type Config struct {
	Session string
	Sender  Sender
	// PlainMarkdown skips glamour (headless tests render raw text).
	PlainMarkdown bool
}

// sendFailedMsg reports a Send that failed locally (queue full,
// closed); shown in the status line.
type sendFailedMsg struct{ err error }

// streamState accumulates one strand's live deltas.
type streamState struct {
	op       string
	thinking strings.Builder
	text     strings.Builder
	toolName string
	callID   string
	toolArgs strings.Builder
}

// Model is the bubbletea model.
type Model struct {
	cfg Config

	width  int
	height int
	ready  bool

	connState client.ConnState
	strands   []proto.Strand
	active    int

	transcripts map[string][]proto.Entry
	streams     map[string]*streamState
	usage       proto.Usage

	// escalations is the FIFO of pending escalations; the head is the
	// modal approval prompt. dismissed hides it until the next
	// escalation event (ctrl+e re-opens).
	escalations []proto.EscalationBody
	dismissed   bool

	showThinking bool
	statusNote   string
	quitting     bool

	input textarea.Model
	vp    viewport.Model

	md      *glamour.TermRenderer
	mdWidth int
}

// New builds the model.
func New(cfg Config) Model {
	input := textarea.New()
	input.Placeholder = "prompt — enter to send, : for commands"
	input.CharLimit = 0
	input.SetHeight(2)
	input.ShowLineNumbers = false
	input.Focus()
	return Model{
		cfg:         cfg,
		transcripts: make(map[string][]proto.Entry),
		streams:     make(map[string]*streamState),
		input:       input,
		connState:   client.StateConnecting,
	}
}

// Init implements tea.Model.
func (m Model) Init() tea.Cmd {
	return textarea.Blink
}

func (m *Model) activeStrand() string {
	if m.active >= 0 && m.active < len(m.strands) {
		return m.strands[m.active].ID
	}
	return ""
}

func (m *Model) contentWidth() int {
	if m.width <= 2 {
		return 78
	}
	return m.width - 2
}

// liveOp returns the running op id on a strand, if any.
func (m *Model) liveOp(strand string) string {
	for _, s := range m.strands {
		if s.ID == strand && s.LiveOp != nil {
			return s.LiveOp.Op
		}
	}
	return ""
}

// overlayActive reports whether the approval prompt is showing.
func (m *Model) overlayActive() bool {
	return len(m.escalations) > 0 && !m.dismissed
}

// send wraps a Sender call in a tea.Cmd so Update stays pure.
func (m *Model) send(cmd string, body any) tea.Cmd {
	sender := m.cfg.Sender
	return func() tea.Msg {
		if sender == nil {
			return nil
		}
		if _, err := sender.Send(cmd, body); err != nil {
			return sendFailedMsg{err: err}
		}
		return nil
	}
}

// Update implements tea.Model.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		return m.onResize(msg), nil
	case tea.KeyMsg:
		return m.onKey(msg)

	case client.StateMsg:
		m.connState = msg.State
		if msg.Err != nil {
			m.statusNote = "connection: " + msg.Err.Error()
		}
		return m.refresh(), nil
	case client.SnapshotMsg:
		return m.onSnapshot(msg), nil
	case client.EntryMsg:
		return m.onEntry(msg), nil
	case client.OpTransitionMsg:
		return m.onOpTransition(msg), nil
	case client.StreamDeltaMsg:
		return m.onDelta(msg), nil
	case client.UsageMsg:
		m.usage.Add(msg.Body.Usage)
		return m.refresh(), nil
	case client.EscalationMsg:
		return m.onEscalation(msg), nil
	case client.StrandResultMsg:
		return m.onStrandResult(msg), nil
	case client.ServerErrorMsg:
		m.statusNote = fmt.Sprintf("server: %s (%s)", msg.Body.Message, msg.Body.Code)
		return m.refresh(), nil
	case client.DecodeErrorMsg:
		m.statusNote = "protocol: " + msg.Err.Error()
		return m.refresh(), nil
	case client.UnknownEventMsg:
		// Old client, new server: ignore quietly.
		return m, nil
	case sendFailedMsg:
		m.statusNote = "send failed: " + msg.err.Error()
		return m.refresh(), nil
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m Model) onResize(msg tea.WindowSizeMsg) Model {
	m.width, m.height = msg.Width, msg.Height
	m.input.SetWidth(msg.Width - 2)
	vpHeight := msg.Height - m.chromeHeight()
	if vpHeight < 1 {
		vpHeight = 1
	}
	if !m.ready {
		m.vp = viewport.New(msg.Width, vpHeight)
		m.ready = true
	} else {
		m.vp.Width = msg.Width
		m.vp.Height = vpHeight
	}
	m.md = nil // re-wrap markdown at the new width
	return m.refresh()
}

// chromeHeight is everything except the viewport: status bar, tabs,
// input, help, and the overlay when showing.
func (m *Model) chromeHeight() int {
	h := 1 + 1 + m.input.Height() + 1
	if m.overlayActive() {
		h += lipgloss.Height(m.renderOverlay())
	}
	return h
}

func (m Model) onKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// The approval prompt is modal: it swallows keys until decided or
	// dismissed.
	if m.overlayActive() {
		switch msg.String() {
		case "y", "Y":
			esc := m.escalations[0]
			m.escalations = m.escalations[1:]
			var grants []proto.Grant
			if esc.Denial != nil {
				grants = esc.Denial.Wanted
			}
			m.statusNote = "approved " + esc.EscalationID
			return m.refresh(), m.send(proto.CmdApprove, proto.ApproveBody{
				EscalationID: esc.EscalationID,
				Grants:       grants,
			})
		case "n", "N":
			esc := m.escalations[0]
			m.escalations = m.escalations[1:]
			m.statusNote = "denied " + esc.EscalationID
			return m.refresh(), m.send(proto.CmdDeny, proto.DenyBody{
				EscalationID: esc.EscalationID,
			})
		case "esc":
			m.dismissed = true
			m.statusNote = "escalation pending — ctrl+e to review"
			return m.refresh(), nil
		case "ctrl+c":
			m.quitting = true
			return m, tea.Quit
		default:
			return m, nil
		}
	}

	switch msg.String() {
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	case "tab":
		return m.cycleStrand(1), nil
	case "shift+tab":
		return m.cycleStrand(-1), nil
	case "ctrl+t":
		m.showThinking = !m.showThinking
		return m.refresh(), nil
	case "ctrl+e":
		if len(m.escalations) > 0 {
			m.dismissed = false
		}
		return m.refresh(), nil
	case "pgup", "pgdown":
		var cmd tea.Cmd
		m.vp, cmd = m.vp.Update(msg)
		return m, cmd
	case "enter":
		return m.onEnter()
	}

	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m Model) cycleStrand(dir int) Model {
	if len(m.strands) == 0 {
		return m
	}
	m.active = (m.active + dir + len(m.strands)) % len(m.strands)
	return m.refresh()
}

// onEnter sends the input line: ":"-prefixed input is a palette
// command; anything else is a prompt, or a steer when the active
// strand has a live operation.
func (m Model) onEnter() (tea.Model, tea.Cmd) {
	text := strings.TrimSpace(m.input.Value())
	if text == "" {
		return m, nil
	}
	m.input.Reset()
	if strings.HasPrefix(text, ":") {
		return m.onPalette(text)
	}
	strand := m.activeStrand()
	if strand == "" {
		m.statusNote = "no strand selected"
		return m.refresh(), nil
	}
	if op := m.liveOp(strand); op != "" {
		m.statusNote = "steering live run on " + strand
		return m.refresh(), m.send(proto.CmdSteer, proto.SteerBody{Strand: strand, Text: text})
	}
	return m.refresh(), m.send(proto.CmdPrompt, proto.PromptBody{Strand: strand, Text: text})
}

// onPalette executes a ":" command: :fork [branch|tree] [name],
// :compact [instructions], :abort, :strand [name], :quit.
func (m Model) onPalette(text string) (tea.Model, tea.Cmd) {
	fields := strings.Fields(strings.TrimPrefix(text, ":"))
	if len(fields) == 0 {
		m.statusNote = "empty command"
		return m.refresh(), nil
	}
	strand := m.activeStrand()
	switch fields[0] {
	case "q", "quit":
		m.quitting = true
		return m, tea.Quit
	case "fork":
		scope := proto.ForkScopeBranch
		name := ""
		if len(fields) > 1 {
			if fields[1] == proto.ForkScopeTree || fields[1] == proto.ForkScopeBranch {
				scope = fields[1]
				if len(fields) > 2 {
					name = fields[2]
				}
			} else {
				name = fields[1]
			}
		}
		m.statusNote = "forking " + strand
		return m.refresh(), m.send(proto.CmdFork, proto.ForkBody{Strand: strand, Scope: scope, Name: name})
	case "compact":
		instructions := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(text, ":"), "compact"))
		m.statusNote = "compacting " + strand
		return m.refresh(), m.send(proto.CmdCompact, proto.CompactBody{Strand: strand, Instructions: instructions})
	case "abort":
		m.statusNote = "aborting " + strand
		return m.refresh(), m.send(proto.CmdAbort, proto.AbortBody{Strand: strand})
	case "strand":
		name := ""
		if len(fields) > 1 {
			name = fields[1]
		}
		return m.refresh(), m.send(proto.CmdCreateStrand, proto.CreateStrandBody{Name: name})
	default:
		m.statusNote = "unknown command :" + fields[0]
		return m.refresh(), nil
	}
}

func (m Model) onSnapshot(msg client.SnapshotMsg) Model {
	body := msg.Body
	switch body.Mode {
	case proto.SnapshotFull:
		m.strands = body.Strands
		if m.active >= len(m.strands) {
			m.active = 0
		}
		m.transcripts = make(map[string][]proto.Entry)
		m.streams = make(map[string]*streamState)
		for _, eb := range body.Entries {
			entry, err := proto.ParseEntry(eb.Entry)
			if err != nil {
				m.statusNote = "snapshot: " + err.Error()
				continue
			}
			m.transcripts[eb.Strand] = append(m.transcripts[eb.Strand], entry)
		}
		m.escalations = nil
		for _, esc := range body.Escalations {
			if esc.Status == proto.EscalationPending {
				m.escalations = append(m.escalations, esc)
			}
		}
		m.dismissed = false
		if body.Usage != nil {
			m.usage = *body.Usage
		}
	case proto.SnapshotStrands:
		m.strands = body.Strands
		if m.active >= len(m.strands) {
			m.active = 0
		}
	case proto.SnapshotResume, proto.SnapshotConfig:
		// Resume is followed by replayed events; config acks carry no
		// state the transcript shows.
	}
	return m.refresh()
}

func (m Model) onEntry(msg client.EntryMsg) Model {
	m.transcripts[msg.Strand] = append(m.transcripts[msg.Strand], msg.Entry)
	// A settled assistant entry supersedes the strand's live stream.
	if msg.Entry.Type == proto.EntryMessage && msg.Entry.Message.Role == proto.RoleAssistant {
		delete(m.streams, msg.Strand)
	}
	m.setLeaf(msg.Strand, msg.Entry.ID)
	return m.refresh()
}

func (m *Model) setLeaf(strand, id string) {
	for i := range m.strands {
		if m.strands[i].ID == strand {
			m.strands[i].Leaf = id
		}
	}
}

func (m Model) onOpTransition(msg client.OpTransitionMsg) Model {
	for i := range m.strands {
		if m.strands[i].ID == msg.Body.Strand {
			if msg.Body.Phase == proto.PhaseDone {
				m.strands[i].LiveOp = nil
			} else {
				m.strands[i].LiveOp = &proto.LiveOp{Op: msg.Body.Op, Phase: msg.Body.Phase}
			}
		}
	}
	return m.refresh()
}

func (m Model) onDelta(msg client.StreamDeltaMsg) Model {
	body := msg.Body
	s := m.streams[body.Strand]
	if s == nil || s.op != body.Op {
		s = &streamState{op: body.Op}
		m.streams[body.Strand] = s
	}
	switch body.Kind {
	case proto.DeltaThinking:
		s.thinking.WriteString(body.Text)
	case proto.DeltaText:
		s.text.WriteString(body.Text)
	case proto.DeltaToolCall:
		if body.ToolName != "" {
			s.toolName = body.ToolName
		}
		if body.CallID != "" {
			s.callID = body.CallID
		}
		s.toolArgs.WriteString(body.ArgumentsFragment)
	}
	return m.refresh()
}

func (m Model) onEscalation(msg client.EscalationMsg) Model {
	body := msg.Body
	if body.Status == proto.EscalationPending {
		m.escalations = append(m.escalations, body)
		m.dismissed = false
		return m.refresh()
	}
	// Any decision or consumption clears the pending prompt for that id.
	kept := m.escalations[:0]
	for _, esc := range m.escalations {
		if esc.EscalationID != body.EscalationID {
			kept = append(kept, esc)
		}
	}
	m.escalations = kept
	return m.refresh()
}

func (m Model) onStrandResult(msg client.StrandResultMsg) Model {
	delete(m.streams, msg.Body.Strand)
	for i := range m.strands {
		if m.strands[i].ID == msg.Body.Strand {
			m.strands[i].LiveOp = nil
		}
	}
	switch msg.Body.Status {
	case proto.ResultFailed:
		if msg.Body.Error != nil {
			m.statusNote = "run failed: " + msg.Body.Error.Message
		} else {
			m.statusNote = "run failed"
		}
	case proto.ResultAborted:
		m.statusNote = "run aborted"
	}
	return m.refresh()
}

// refresh recomputes the viewport content and follows the tail.
func (m Model) refresh() Model {
	if !m.ready {
		return m
	}
	m.vp.Height = m.height - m.chromeHeight()
	if m.vp.Height < 1 {
		m.vp.Height = 1
	}
	atBottom := m.vp.AtBottom()
	m.vp.SetContent(m.renderTranscript())
	if atBottom {
		m.vp.GotoBottom()
	}
	return m
}

// View implements tea.Model.
func (m Model) View() string {
	if m.quitting {
		return ""
	}
	if !m.ready {
		return "starting…"
	}
	sections := []string{
		m.renderStatusBar(),
		m.renderTabs(),
		m.vp.View(),
	}
	if m.overlayActive() {
		sections = append(sections, m.renderOverlay())
	}
	sections = append(sections, m.input.View(), m.renderHelp())
	return strings.Join(sections, "\n")
}

func (m *Model) renderStatusBar() string {
	strand := m.activeStrand()
	phase := "idle"
	for _, s := range m.strands {
		if s.ID == strand && s.LiveOp != nil {
			phase = s.LiveOp.Phase
		}
	}
	left := fmt.Sprintf("loom │ %s │ %s │ %s: %s │ %s tok $%.4f",
		m.cfg.Session, m.connState, strand, phase,
		tokens(m.usage.TotalTokens), m.usage.Cost.Total)
	bar := styleStatusBar.Render(left)
	if m.statusNote != "" {
		bar += " " + styleStatusNote.Render(m.statusNote)
	}
	return bar
}

func (m *Model) renderTabs() string {
	if len(m.strands) == 0 {
		return styleDim.Render("(no strands)")
	}
	var tabs []string
	for i, s := range m.strands {
		label := s.Name
		if label == "" {
			label = s.ID
		}
		if s.LiveOp != nil {
			label += " ●"
		}
		switch {
		case i == m.active:
			tabs = append(tabs, styleTabActive.Render(label))
		case s.LiveOp != nil:
			tabs = append(tabs, styleTabLive.Render(label))
		default:
			tabs = append(tabs, styleTab.Render(label))
		}
	}
	return lipgloss.JoinHorizontal(lipgloss.Bottom, tabs...)
}

// renderOverlay is the escalation approval prompt: the exact wanted
// policy diff, verbatim, decided with y/n.
func (m *Model) renderOverlay() string {
	esc := m.escalations[0]
	var b strings.Builder
	b.WriteString(styleOverlayTitle.Render("sandbox escalation on "+esc.Strand) + "\n")
	if esc.Denial != nil {
		b.WriteString(esc.Denial.Reason + "\n")
		for _, grant := range esc.Denial.Wanted {
			b.WriteString(styleWant.Render("wants: "+grant.Display()) + "\n")
		}
		for _, line := range esc.Denial.Enforcement {
			b.WriteString(styleDim.Render(line) + "\n")
		}
	}
	b.WriteString(styleHelp.Render("y approve · n deny · esc later"))
	return styleOverlay.MaxWidth(m.contentWidth()).Render(strings.TrimRight(b.String(), "\n"))
}

func (m *Model) renderHelp() string {
	return styleHelp.Render(
		" enter send · tab strand · ctrl+t thinking · :fork :compact :abort :quit · ctrl+c exit")
}
