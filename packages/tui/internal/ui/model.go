// Package ui is the bubbletea program: protocol events arrive as
// bubbletea messages (the client's typed Msg values), key presses turn
// into websocket commands through a Sender. Update is pure — sends are
// returned as tea.Cmd closures — so the whole interaction surface is
// table-testable without a terminal.
package ui

import (
	"encoding/json"
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

// modelPicker is the :models modal: the catalogue rows the gateway
// listed and a cursor over them.
type modelPicker struct {
	models []proto.ModelInfo
	cursor int
}

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

	// picker is the :models modal while open. strandModels remembers
	// each strand's catalogue model name as config acks report it;
	// pendingModelStrand attributes the next config ack to the strand
	// whose switch we sent (the ack body does not name it).
	picker             *modelPicker
	strandModels       map[string]string
	pendingModelStrand string

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
		cfg:          cfg,
		transcripts:  make(map[string][]proto.Entry),
		streams:      make(map[string]*streamState),
		strandModels: make(map[string]string),
		input:        input,
		connState:    client.StateConnecting,
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
		if msg.Body.Code == proto.ErrStaleApproval {
			return m.onStaleApproval(msg.Body), nil
		}
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
// input, help, and the overlays when showing.
//
// The tab row is measured rather than assumed: the active tab carries a
// bottom border, so it is two lines tall whenever there is a strand and
// one line tall before the first snapshot. Counting it as one made the
// whole view one line taller than the terminal, and bubbletea drops
// lines from the *top* of an oversized frame — which silently cost the
// status bar on every real terminal that had a strand.
func (m *Model) chromeHeight() int {
	h := 1 + lipgloss.Height(m.renderTabs()) + m.input.Height() + 1
	if m.overlayActive() {
		h += lipgloss.Height(m.renderOverlay())
	}
	if m.picker != nil {
		h += lipgloss.Height(m.renderPicker())
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
			// The echo is of what this overlay actually drew: the
			// wanted diff it rendered line by line, and the digest of
			// the action it rendered beside it. The server checks both
			// against the record it is about to approve, so a record
			// that moved between the prompt and this keystroke is
			// refused and re-asked rather than approved on the human's
			// behalf.
			grants := []proto.Grant{}
			if esc.Denial != nil {
				grants = esc.Denial.Wanted
			}
			m.statusNote = "approved " + esc.EscalationID
			return m.refresh(), m.send(proto.CmdApprove, proto.ApproveBody{
				EscalationID: esc.EscalationID,
				Grants:       grants,
				Action:       esc.Action,
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

	// The :models picker is modal too, one notch below the approval
	// prompt: it swallows keys until a pick or dismissal.
	if m.picker != nil {
		return m.onPickerKey(msg)
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

// onPickerKey drives the :models modal: j/k or arrows move, enter
// switches the active strand to the highlighted catalogue name via
// set_config, esc closes without touching anything.
func (m Model) onPickerKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	p := m.picker
	switch msg.String() {
	case "up", "k":
		if p.cursor > 0 {
			p.cursor--
		}
		return m.refresh(), nil
	case "down", "j":
		if p.cursor < len(p.models)-1 {
			p.cursor++
		}
		return m.refresh(), nil
	case "enter":
		strand := m.activeStrand()
		if strand == "" || p.cursor >= len(p.models) {
			m.picker = nil
			return m.refresh(), nil
		}
		name := p.models[p.cursor].Name
		m.picker = nil
		m.pendingModelStrand = strand
		m.statusNote = "switching " + strand + " to " + name
		return m.refresh(), m.send(proto.CmdSetConfig, proto.SetConfigBody{
			Strand: strand,
			Config: map[string]any{"model_name": name},
		})
	case "esc":
		m.picker = nil
		return m.refresh(), nil
	case "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	default:
		return m, nil
	}
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
// :compact [instructions], :abort, :strand [name], :models, :quit.
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
	case "models":
		// The reply (snapshot mode "models") opens the picker.
		m.statusNote = "fetching the model catalogue"
		return m.refresh(), m.send(proto.CmdModels, proto.ModelsBody{})
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
	case proto.SnapshotModels:
		if len(body.Models) == 0 {
			m.statusNote = "the model catalogue is empty"
			break
		}
		m.picker = &modelPicker{models: body.Models}
		// Start the cursor on the active strand's current model when
		// we know it, so enter-without-moving is a no-op switch.
		if current := m.strandModels[m.activeStrand()]; current != "" {
			for i, info := range body.Models {
				if info.Name == current {
					m.picker.cursor = i
				}
			}
		}
	case proto.SnapshotConfig:
		// The ack for a model switch echoes the effective config; pull
		// the catalogue name out and pin it to the strand we switched.
		var config struct {
			ModelName string `json:"model_name"`
		}
		if err := json.Unmarshal(body.Config, &config); err == nil &&
			config.ModelName != "" && m.pendingModelStrand != "" {
			m.strandModels[m.pendingModelStrand] = config.ModelName
			m.statusNote = m.pendingModelStrand + " → " + config.ModelName
		}
		m.pendingModelStrand = ""
	case proto.SnapshotResume:
		// Resume is followed by replayed events.
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
	if m.picker != nil {
		sections = append(sections, m.renderPicker())
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
	segment := ""
	if name := m.strandModels[strand]; name != "" {
		segment = " │ " + name
	}
	left := fmt.Sprintf("loom │ %s │ %s │ %s: %s%s │ %s tok $%.4f",
		m.cfg.Session, m.connState, strand, phase, segment,
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

// onStaleApproval re-opens a prompt the server refused because the
// record moved between the draw and the keystroke. The refusal carries
// the record as it now stands, so the question can be re-asked from the
// answer itself rather than waiting for a pull to bring it back.
func (m Model) onStaleApproval(body proto.ErrorBody) Model {
	m.statusNote = "approval refused — the request changed; re-check it"
	var details struct {
		Escalation *proto.EscalationBody `json:"escalation"`
	}
	if len(body.Details) == 0 || json.Unmarshal(body.Details, &details) != nil {
		return m.refresh()
	}
	if details.Escalation == nil || details.Escalation.Status != proto.EscalationPending {
		return m.refresh()
	}
	// The head of the queue is where the answered one was, and a
	// refused answer has not decided anything.
	m.escalations = append([]proto.EscalationBody{*details.Escalation}, m.escalations...)
	m.dismissed = false
	return m.refresh()
}

// renderOverlay is the escalation approval prompt: what would run, the
// exact policy diff it would run under, and a y/n.
//
// Everything outside the fence is the client's own words. Everything
// inside it came from the model, went through proto.SanitizePreview on
// the way, and is bounded on screen — an unbounded block of
// model-authored text in the chrome could push the wanted lines and the
// y/n line out of the viewport, which forges a prompt just as well as a
// cursor move does.
func (m *Model) renderOverlay() string {
	esc := m.escalations[0]
	var b strings.Builder
	b.WriteString(styleOverlayTitle.Render("sandbox escalation on "+overlayScope(esc)) + "\n")
	if esc.Denial != nil {
		b.WriteString(esc.Denial.Reason + "\n")
		for _, grant := range esc.Denial.Wanted {
			b.WriteString(styleWant.Render("wants: "+grant.Display()) + "\n")
		}
		for _, line := range esc.Denial.Enforcement {
			b.WriteString(styleDim.Render(line) + "\n")
		}
	}
	b.WriteString(m.renderAction(esc))
	b.WriteString(styleHelp.Render("y approve · n deny · esc later"))
	return styleOverlay.MaxWidth(m.contentWidth()).Render(strings.TrimRight(b.String(), "\n"))
}

// overlayScope names the strand the record was raised on. It is the
// record's own call scope; empty means the record names no call, which
// is a different statement from naming the wrong one and is said as
// such rather than left blank.
func overlayScope(esc proto.EscalationBody) string {
	if esc.Strand == "" {
		return "no strand (raised out of band)"
	}
	return esc.Strand
}

// previewLines bounds the fenced block. Six lines is enough to read a
// command line and see that a long one is long, and small enough that
// the decision keys stay on screen whatever the model wrote.
const previewLines = 6

// renderAction draws the tool name and the fenced argument window.
//
// The tool name is printed unconditionally, including when the record
// does not carry one: "no tool named" is information a person deciding
// this needs, and an absent line reads as an ordinary prompt with
// nothing to say. The footer is unconditional for the same reason — the
// approval binds the whole action through its digest, while the screen
// holds at most a two-kilobyte window of it, and a reader who is not
// told that will take the window for the action.
func (m *Model) renderAction(esc proto.EscalationBody) string {
	tool := esc.Tool
	if tool == "" {
		tool = "(no tool named on this record)"
	}
	var b strings.Builder
	b.WriteString(styleWant.Render("runs: "+tool) + "\n")
	b.WriteString(styleDim.Render("┌ arguments · written by the model") + "\n")
	lines, cut := previewBlock(esc.Preview, m.contentWidth()-6)
	for _, line := range lines {
		b.WriteString(styleDim.Render("│ ") + line + "\n")
	}
	b.WriteString(styleDim.Render("└ "+previewFooter(esc.Preview, cut)) + "\n")
	return b.String()
}

// previewBlock sanitises the preview and folds it into at most
// previewLines display lines, reporting whether anything was left over.
func previewBlock(preview string, width int) ([]string, bool) {
	if preview == "" {
		return []string{styleDim.Render("(this record carries no preview)")}, false
	}
	if width < 16 {
		width = 16
	}
	folded := fold(proto.SanitizePreview(preview), width)
	if len(folded) > previewLines {
		return folded[:previewLines], true
	}
	return folded, false
}

// fold breaks text into runs of at most width runes. It is a hard fold,
// not a word wrap: the preview is canonicalised JSON with no reliable
// word boundaries, and a fold that hunts for spaces would let the model
// choose where the breaks land.
func fold(text string, width int) []string {
	var lines []string
	line := make([]rune, 0, width)
	for _, r := range text {
		line = append(line, r)
		if len(line) == width {
			lines = append(lines, string(line))
			line = line[:0]
		}
	}
	if len(line) > 0 {
		lines = append(lines, string(line))
	}
	return lines
}

// previewFooter says what the fence is a window on. The byte count is
// the client's own count of what it holds, never a number read out of
// the preview, so a model that writes a plausible-looking size marker
// into its own arguments cannot restate the footer.
func previewFooter(preview string, cut bool) string {
	if preview == "" {
		return "no preview · the approval still binds the whole action"
	}
	if cut {
		return fmt.Sprintf("%d bytes of preview, first %d lines shown · the approval binds the whole action",
			len(preview), previewLines)
	}
	return fmt.Sprintf("%d bytes of preview · the approval binds the whole action, not this window",
		len(preview))
}

// renderPicker is the :models modal: one row per catalogue entry —
// name, dialect, provider model id, the roles it backs with the active
// ones starred — with the current strand's model marked.
func (m *Model) renderPicker() string {
	var b strings.Builder
	b.WriteString(styleOverlayTitle.Render("model catalogue — "+m.activeStrand()) + "\n")
	current := m.strandModels[m.activeStrand()]
	for i, info := range m.picker.models {
		marker := "  "
		if i == m.picker.cursor {
			marker = "▸ "
		}
		line := marker + info.Name + "  (" + info.Dialect + " · " + info.ModelID + ")"
		if roles := roleTags(info); roles != "" {
			line += "  " + roles
		}
		if info.Name == current {
			line += "  ← current"
		}
		if i == m.picker.cursor {
			b.WriteString(styleWant.Render(line) + "\n")
		} else {
			b.WriteString(line + "\n")
		}
	}
	b.WriteString(styleHelp.Render("enter switch · j/k move · esc close"))
	return styleOverlay.MaxWidth(m.contentWidth()).Render(strings.TrimRight(b.String(), "\n"))
}

// roleTags renders "roles: main*,plan" — every role whose chain lists
// the model, a star on the ones it currently resolves for.
func roleTags(info proto.ModelInfo) string {
	if len(info.Roles) == 0 {
		return ""
	}
	tags := make([]string, 0, len(info.Roles))
	for _, role := range info.Roles {
		tag := role
		for _, active := range info.Active {
			if active == role {
				tag += "*"
			}
		}
		tags = append(tags, tag)
	}
	return "roles: " + strings.Join(tags, ",")
}

func (m *Model) renderHelp() string {
	return styleHelp.Render(
		" enter send · tab strand · ctrl+t thinking · :fork :compact :abort :models :quit · ctrl+c exit")
}
