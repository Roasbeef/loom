//// Model-influenced text reaches the screen as characters, never as
//// instructions.
////
//// A provider, a tool result, a strand name and an escalation preview can
//// all carry arbitrary bytes, and a terminal reads some of those bytes as
//// commands: move the cursor, reset the colours, clear the screen, open a
//// hyperlink. The approval overlay is where that stops being a cosmetic
//// problem — it is a full-screen redraw asking a human to authorize a
//// command, so a payload that can repaint it can forge the thing being
//// consented to.
////
//// `tui/text_hygiene` and the escaped literal in `tui/approval` exist to
//// prevent that, and this module is the adversary that holds them to it.
//// Every check drives the shipped loop under the virtual backend and reads
//// the finished buffer back as characters, because an intermediate string
//// that happens to be clean says nothing about the cells a terminal is
//// finally handed: the surfaces differ in which sanitiser they call and in
//// what they do afterwards — wrap, clip, truncate, escape — and only the
//// frame sees all of it.
////
//// "Inert" at the frame has two halves, and both are asserted because
//// neither alone is the property. A cell cannot hold a C0 control or DEL
//// whatever this client does — etui's fill skips those bytes rather than
//// giving them a column — so the *cell* check is really about the C1
//// forms, U+0080 to U+009F, which do become cells and which carry the
//// single-byte CSI and OSC an eight-bit terminal still obeys. What a
//// broken stripper actually leaks is the other half: the parameter bytes
//// behind the introducer, printed where the sequence used to be. A
//// transcript reading `[2J` has not cleared anybody's screen, but it is
//// the visible signature of the sequence that would have, so a surface is
//// only inert when neither half is on it.

import core/json
import etui/backend
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/agents
import tui/approval
import tui/approval_panel
import tui/connection
import tui/frame
import tui/virtual_backend
import tui/workspace
import tui_test/gateway

/// The transcript renders a hostile turn as text a terminal cannot obey.
///
/// Three bodies, because they take three different paths to a cell: a user
/// turn goes through the composer's transcript projection, an assistant
/// turn is parsed as CommonMark, and a stream delta is a transient
/// fragment that never becomes a durable record.
pub fn hostile_transcript_bodies_render_inert_test() {
  let inbox = connection.new_inbox()
  let rows =
    last_rows(quiet_model(inbox), 96, 24, [
      deliver(gateway.full_snapshot("demo")),
      deliver(gateway.user_entry("main", hostile("prompt-sentinel"), 1)),
      deliver(gateway.assistant_entry("main", hostile("reply-sentinel"), 2)),
      deliver(gateway.stream_delta("main", "text", hostile("delta-sentinel"))),
    ])

  // A frame that rendered nothing at all would satisfy every inertness
  // check below, so each surface names itself before its bytes are judged.
  assert_shows(rows, ["prompt-sentinel", "reply-sentinel", "delta-sentinel"])
  assert_inert(rows)
  assert_no_residue(rows)
}

/// A tool call's name, arguments and result render as text in both modes.
///
/// `bash` is the shape the consent chain cares about: the summary carries
/// the command line itself rather than the JSON envelope, so the string a
/// model wrote reaches a cell without a codec escaping it on the way. The
/// run is repeated with detail expanded because the collapsed summary is
/// truncated and the expanded one is not, and a truncation is not a
/// sanitiser.
pub fn hostile_tool_calls_render_inert_test() {
  let collapsed =
    last_rows(quiet_model(connection.new_inbox()), 96, 30, calls())
  assert_shows(collapsed, ["argument-sentinel", "result-sentinel"])
  assert_inert(collapsed)
  assert_no_residue(collapsed)

  let detailed =
    tui.Model(..quiet_model(connection.new_inbox()), details_expanded: True)
  let expanded = last_rows(detailed, 96, 30, calls())
  assert_shows(expanded, ["argument-sentinel", "result-sentinel"])
  assert_inert(expanded)
  assert_no_residue(expanded)
}

// A call whose arguments are hostile, a call whose tool name is hostile,
// and a failing result whose text is hostile: the three places a tool
// round trip puts a model-influenced string on the transcript.
fn calls() -> List(virtual_backend.Step) {
  [
    deliver(gateway.full_snapshot("demo")),
    deliver(gateway.tool_call_entry(
      "main",
      "bash",
      hostile("argument-sentinel"),
      1,
    )),
    deliver(gateway.tool_call_entry("main", hostile("tool-sentinel"), "ls", 2)),
    deliver(gateway.tool_result_entry("main", hostile("result-sentinel"), 3)),
  ]
}

/// The agent rail and the inspector render hostile strand names as text.
///
/// A sub-agent is named by whatever spawned it and its phase comes back
/// from the server as a string, so both are model-influenced. The rail and
/// the overlay are checked separately because they overlap on screen: one
/// frame showing both would leave whichever lost the paint order untested.
pub fn hostile_agent_names_render_inert_test() {
  let names =
    gateway.strands_snapshot([
      #("main", hostile_tail("active-sentinel"), hostile_tail("phase-sentinel")),
      #("sub:one", hostile_tail("child-sentinel"), "idle"),
    ])
  let rail_inbox = connection.new_inbox()
  let railed = tui.Model(..quiet_model(rail_inbox), agent_rail_visible: True)
  let rail = last_rows(railed, 120, 24, [deliver(names)])
  assert_shows(rail, ["active-sentinel", "child-sentinel", "phase-sentinel"])
  assert_inert(rail)
  assert_no_residue(rail)

  let overlay_inbox = connection.new_inbox()
  let opened =
    tui.Model(..quiet_model(overlay_inbox), overlay: tui.AgentInspector(0))
  let inspector = last_rows(opened, 120, 30, [deliver(names)])
  assert_shows(inspector, [
    "active-sentinel",
    "child-sentinel",
    "phase-sentinel",
  ])
  assert_inert(inspector)
  assert_no_residue(inspector)
}

/// The approval overlay shows an escape as its six characters, not its byte.
///
/// This is the surface the whole rule exists for. The panel renders the
/// captured record as an escaped JSON literal rather than as text, so an
/// ESC arrives on screen as the printable `\u001b` a human can see and
/// weigh — deleting it instead would hide the difference between a benign
/// path and one carrying a repaint.
///
/// It is therefore the one surface the residue check must not be pointed
/// at: an escaped literal shows `\u001b[2J` on purpose, parameter bytes
/// and all, because a human being asked to consent is entitled to see that
/// the path carries a screen clear.
pub fn hostile_approval_detail_shows_escapes_not_controls_test() {
  let review = hostile_review()
  let model =
    tui.Model(
      ..quiet_model(connection.new_inbox()),
      approvals: [review],
      overlay: tui.ApprovalInspector(approval_panel.new(review)),
    )
  let rows = last_rows(model, 110, 30, [])

  // The tool field is one bare ESC and sits near the head of the literal,
  // where no wrap can split it, so this pins the escaped form itself
  // rather than the accident of where a long line broke.
  assert_shows(rows, ["\"tool\":\"\\u001b\""])
  assert_inert(rows)
}

// One captured escalation whose every displayed field is hostile: the
// action digest the approval echoes, the preview a human reads, and the
// path inside the requested grant.
fn hostile_review() -> approval.Review {
  approval.Review(
    id: "escalation-1",
    seq: 7,
    status: approval.Pending,
    tool: "\u{1b}",
    preview: hostile("preview-sentinel"),
    origin: None,
    permission: approval.Exact(hostile("action-sentinel"), [
      json.Object([
        #("kind", json.String("writable_root")),
        #("path", json.String(hostile("path-sentinel"))),
      ]),
    ]),
  )
}

// Every escape shape a hostile provider would reach for, as one string.
//
// Cursor movement and a colour reset repaint what a human has already
// read; a screen clear removes it; an OSC hyperlink turns an innocuous
// word into a destination; and the last three are the same instructions
// written without the two-byte introducer — a lone ESC, a C1 CSI, a C1
// next-line — which a stripper that only knew `ESC [` would let through.
fn escapes() -> String {
  [
    "\u{1b}[5;10H",
    "\u{1b}[0m",
    "\u{1b}]8;;https://evil.example\u{07}approve\u{1b}]8;;\u{07}",
    "\u{1b}[2J",
    "\u{1b}",
    "\u{9b}31m",
    "\u{85}",
    "\u{07}",
  ]
  |> string.join(" ")
}

// The corpus behind a marker, for a surface that cuts a long value from
// the tail.
fn hostile(marker: String) -> String {
  marker <> " " <> escapes()
}

// The corpus in front of a marker, for a surface that keeps the tail: the
// rail and the inspector cut a strand name from the front, because the
// tail is what tells two sub-agents on the same file apart.
fn hostile_tail(marker: String) -> String {
  escapes() <> " " <> marker
}

// A frame that drew nothing passes every inertness check, so each run
// proves it put the surface under test on screen first.
fn assert_shows(rows: List(String), markers: List(String)) -> Nil {
  let text = string.join(rows, "\n")
  list.each(markers, fn(marker) {
    assert string.contains(text, marker)
      as { "the frame never rendered the surface carrying " <> marker }
  })
}

// Half the verdict: no cell of the finished frame holds a codepoint a
// terminal would read as anything but a character. C0 covers ESC and BEL,
// 0x7F is delete, and 0x80–0x9F are the single-byte C1 forms of the same
// instructions, CSI and OSC among them.
fn assert_inert(rows: List(String)) -> Nil {
  assert control_codes(rows) == []
    as "a rendered cell held a control character, so model text reached the terminal as an instruction"
}

// The other half: a stripped sequence leaves no visible signature either.
// These are the parameter bytes of the payload below, each the tail that
// would be printed where its sequence used to be if the stripper stopped
// recognising the introducer in front of it. They are also the half that
// notices a regression, since the introducer itself would be dropped by
// the buffer whether this client sanitised it or not.
fn assert_no_residue(rows: List(String)) -> Nil {
  let text = string.join(rows, "\n")
  list.each(["[5;10H", "[0m", "[2J", "31m", "8;;", "evil.example"], fn(tail) {
    assert !string.contains(text, tail)
      as { "a stripped escape sequence left " <> tail <> " on the frame" }
  })
}

fn control_codes(rows: List(String)) -> List(Int) {
  rows
  |> list.flat_map(string.to_utf_codepoints)
  |> list.map(string.utf_codepoint_to_int)
  |> list.filter(is_control)
}

fn is_control(code: Int) -> Bool {
  code < 0x20 || code == 0x7F || { code >= 0x80 && code <= 0x9F }
}

fn deliver(payload: String) -> virtual_backend.Step {
  virtual_backend.Deliver(message: connection.Incoming(payload))
}

// One scripted run at a fixed screen, read back as the rows of the last
// frame it drew. The settling ticks the virtual backend emits flush any
// frame the client deferred to pace a burst, so the last frame is the one
// an operator would be looking at when the run stopped.
fn last_rows(
  model: tui.Model,
  width: Int,
  height: Int,
  steps: List(virtual_backend.Step),
) -> List(String) {
  let script =
    virtual_backend.script(
      backend.TerminalSize(width:, height:),
      steps,
      model.inbox,
    )
  let assert Ok(run) = tui.run_script(model, script)
    as "the scripted backend cannot refuse to start"
  let assert Ok(last) = list.last(run.frames)
    as "every run draws at least its initial frame"
  frame.buffer_to_lines(last)
}

// The demo scaffolding removed, so a frame shows only what this module put
// there and a stray control character can only have come from the payload.
fn quiet_model(inbox: Subject(connection.Message)) -> tui.Model {
  tui.Model(
    ..tui.new_model(inbox, workspace.Context(path: "/w/demo", branch: None)),
    transcript: [],
    strands: [],
    agent_summary: agents.summary([]),
    notice: "ready",
  )
}
