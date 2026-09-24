//// The agent strip must show each live agent on one row, prefer the daemon's
//// glance only while it describes the current operation, keep its clocks on
//// one clock domain each, and never let browsing redirect a draft. The
//// interaction tests drive the real input reducer and paint real frames.

import core/clock
import core/glance.{Glance}
import core/ids
import core/json
import core/message
import core/register
import etui/backend
import etui/geometry
import etui/widgets/textarea
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import tui
import tui/agent_strip.{
  Back, Browsing, Changed, Composing, Down, Halt, Left, Moved, Open, Other, Pass,
  Select, Stop, Unchanged, Up,
}
import tui/agent_view
import tui/agents
import tui/connection
import tui/frame
import tui/inbound
import tui/model as tui_model
import tui/protocol
import tui/render
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import tui/workspace

// --- fixtures --------------------------------------------------------------

fn model() {
  tui.new_model_with_clock(
    connection.new_inbox(),
    workspace.Context("/work", None),
    fn() { 0 },
  )
}

fn raw_op(n) {
  ids.mint_op(ids.generator(clock.fixed(n), n)).0
}

fn op_id(n) {
  ids.op_id_to_string(raw_op(n))
}

fn row(id: String, status: agent_view.Status, operation) -> agent_view.Row {
  agent_view.Row(
    id:,
    name: id,
    operation:,
    status:,
    task: "task of " <> id,
    activity: "activity of " <> id,
    update: "",
    update_entry: None,
    pending: "",
    approvals: [],
    model: "",
    recent: [],
    decision: "",
  )
}

fn roster() {
  [
    protocol.Strand("main", Some("main"), None),
    protocol.Strand("sub:main/audit-panics-1a2b3c", None, Some("assistant")),
    protocol.Strand("sub:main/read-docs-9f8e7d", None, Some("tool")),
  ]
}

fn press(model, key) {
  tui.update(backend.KeyPress(key), model)
}

fn sized(model, width, height) {
  tui.update(backend.Resize(width, height), model)
}

fn painted(model, width, height) {
  let model = sized(model, width, height)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, width, height))
  frame.buffer_to_text(buffer)
}

fn meta_cell(n: Int, started_at: Int) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.OpMeta,
    op_id(n),
    1,
    codec.encode_operation(operation.Operation(
      id: raw_op(n),
      strand: "worker",
      source_leaf: None,
      started_at:,
      intent: operation.RunIntent([]),
    )),
  )
}

fn glance_cell(strand: String, seen: glance.Glance) -> snapshot_view.Cell {
  snapshot_view.Cell(
    register.FactCustom,
    glance.key(strand),
    2,
    glance.encode(seen),
  )
}

fn view(operations, cells) -> snapshot_view.View {
  snapshot_view.View(
    strands: [],
    leaves: dict.new(),
    configurations: dict.new(),
    operations: dict.from_list(operations),
    usage: model().usage,
    settings: snapshot_view.RunSettings("one_at_a_time", "parallel", None),
    peers: [],
    cells:,
    preview: None,
    pending_inputs: Some([]),
    tools: None,
  )
}

// --- names and figures -----------------------------------------------------

pub fn a_minted_child_name_shortens_to_its_slug_test() {
  assert agent_strip.short_name("sub:main/audit-panics-1a2b3c")
    == "audit-panics"
  assert agent_strip.short_name("sub:sub:main/a-1b2c/deeper-work-00ff")
    == "deeper-work"
  assert agent_strip.short_name("main") == "main"
  assert agent_strip.short_name("advisor") == "advisor"

  // A last segment that is not a digest is part of the name.
  assert agent_strip.short_name("sub:main/fix-login") == "fix-login"
}

pub fn durations_read_like_the_reference_strip_test() {
  assert agent_strip.duration(0) == "0s"
  assert agent_strip.duration(59) == "59s"
  assert agent_strip.duration(60) == "1m 00s"
  assert agent_strip.duration(475) == "7m 55s"
  assert agent_strip.duration(3720) == "1h 02m"
}

pub fn token_counts_keep_one_decimal_so_growth_is_visible_test() {
  assert agent_strip.count_label(0) == "0"
  assert agent_strip.count_label(999) == "999"
  assert agent_strip.count_label(1000) == "1.0k"
  assert agent_strip.count_label(136_540) == "136.5k"
  assert agent_strip.count_label(2_345_678) == "2.3m"
}

// --- which agents are listed -----------------------------------------------

pub fn main_leads_and_only_live_or_viewed_agents_follow_test() {
  let rows = [
    row("sub:main/a-0001", agent_view.Working, None),
    row("main", agent_view.Idle, None),
    row("sub:main/b-0002", agent_view.Finished, None),
    row("sub:main/c-0003", agent_view.NeedsInput, None),
    row("advisor", agent_view.Working, None),
    row("sub:main/d-0004", agent_view.Failed, None),
  ]
  let ids =
    agent_strip.lines(agent_strip.new(), rows, "main")
    |> list.map(fn(line) { line.id })
  assert ids == ["main", "sub:main/a-0001", "sub:main/c-0003"]

  // The strand on screen stays listed after it settles, so the operator can
  // always see where they are and step back to main.
  let viewing =
    agent_strip.lines(agent_strip.new(), rows, "sub:main/b-0002")
    |> list.map(fn(line) { line.id })
  assert viewing
    == ["main", "sub:main/a-0001", "sub:main/b-0002", "sub:main/c-0003"]
}

pub fn a_lone_primary_draws_no_strip_test() {
  let lines =
    agent_strip.lines(
      agent_strip.new(),
      [row("main", agent_view.Working, None)],
      "main",
    )
  assert agent_strip.visible(lines) == False
  assert agent_strip.height(lines, 40) == 0
}

pub fn the_strip_grows_a_row_per_agent_up_to_its_cap_test() {
  let many =
    list.map(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"], fn(name) {
      row("sub:main/" <> name <> "-0001", agent_view.Working, None)
    })
  let lines =
    agent_strip.lines(
      agent_strip.new(),
      [row("main", agent_view.Idle, None), ..many],
      "main",
    )
  assert list.length(lines) == 11
  assert agent_strip.height(list.take(lines, 3), 40) == 3
  assert agent_strip.height(lines, 40) == agent_strip.max_rows

  // A quarter of a short screen, never below two rows, and nothing at all
  // below the minimum height.
  assert agent_strip.height(lines, 20) == 5
  assert agent_strip.height(lines, 16) == 4
  assert agent_strip.height(lines, 15) == 0
}

// --- glances ---------------------------------------------------------------

pub fn a_glance_for_the_current_operation_replaces_the_fallback_test() {
  let current = op_id(1)
  let seen = Glance(current, "Audit funding panics", "Reading x.go", 5000, 42)
  let state =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", current)], [glance_cell("worker", seen)]),
      0,
    )
  let assert [line] =
    agent_strip.lines(
      state,
      [row("worker", agent_view.Working, Some(current))],
      "worker",
    )
    as "one listed row"
  assert line.text == "Reading x.go"
  assert line.title == "Audit funding panics"
  assert line.tokens == Some(42)
}

// A successor operation must not wear the summary its predecessor earned.
pub fn a_glance_for_another_operation_is_ignored_test() {
  let old = op_id(1)
  let current = op_id(2)
  let seen = Glance(old, "Old task", "Old line", 5000, 42)
  let state =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", current)], [glance_cell("worker", seen)]),
      0,
    )
  let assert [line] =
    agent_strip.lines(
      state,
      [row("worker", agent_view.Working, Some(current))],
      "worker",
    )
    as "one listed row"
  assert line.text == "activity of worker"
  assert line.title == "task of worker"
  assert line.tokens == None
}

// A glance with a title but no summary yet must not blank the row.
pub fn an_empty_summary_falls_back_to_the_deterministic_line_test() {
  let current = op_id(1)
  let seen = Glance(current, "Audit", "", 5000, 0)
  let state =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", current)], [glance_cell("worker", seen)]),
      0,
    )
  let assert [line] =
    agent_strip.lines(
      state,
      [row("worker", agent_view.Working, Some(current))],
      "worker",
    )
    as "one listed row"
  assert line.text == "activity of worker"
  assert line.title == "Audit"
  assert line.tokens == None
}

pub fn an_undecodable_glance_is_skipped_not_fatal_test() {
  let current = op_id(1)
  let broken =
    snapshot_view.Cell(
      register.FactCustom,
      glance.key("worker"),
      2,
      json.String("garbage"),
    )
  let state =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", current)], [broken]),
      0,
    )
  assert dict.size(state.glances) == 0
}

// --- clocks ----------------------------------------------------------------

pub fn a_new_operation_starts_on_the_terminal_clock_test() {
  let fresh = agent_strip.next_clock(None, "op", None, None, 500)
  assert agent_strip.elapsed_ms(fresh, 2500) == 2000
  assert agent_strip.elapsed_ms(fresh, 0) == 0
}

// The daemon measured the run on its own clock; the terminal adds only the
// time since it saw that measurement on its own. Neither clock is ever
// subtracted from the other.
pub fn a_glance_re_anchors_to_the_daemons_own_measurement_test() {
  let current = op_id(1)
  let started = 1_000_000
  let seen = Glance(current, "t", "s", started + 90_000, 0)
  let state =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", current)], [
        meta_cell(1, started),
        glance_cell("worker", seen),
      ]),
      -5000,
    )
  let assert Ok(clock) = dict.get(state.clocks, "worker")
    as "a current operation has a clock"
  assert agent_strip.elapsed_ms(clock, -5000) == 90_000
  assert agent_strip.elapsed_ms(clock, 5000) == 100_000

  // The same glance observed again does not reset the anchor.
  let again =
    agent_strip.observe(
      state,
      view([#("worker", current)], [
        meta_cell(1, started),
        glance_cell("worker", seen),
      ]),
      7000,
    )
  assert dict.get(again.clocks, "worker") == Ok(clock)
}

pub fn a_successor_operation_starts_a_new_clock_test() {
  let first =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", op_id(1))], []),
      1000,
    )
  let second =
    agent_strip.observe(first, view([#("worker", op_id(2))], []), 4000)
  let assert Ok(clock) = dict.get(second.clocks, "worker")
    as "the successor has a clock"
  assert clock.operation == op_id(2)
  assert agent_strip.elapsed_ms(clock, 4000) == 0

  // A strand that settles drops its clock and its pushed usage.
  let pushed = agent_strip.observe_usage(second, "worker", Some(op_id(2)), 9)
  let settled = agent_strip.observe(pushed, view([], []), 5000)
  assert dict.size(settled.clocks) == 0
  assert dict.size(settled.pushed) == 0
}

pub fn a_live_push_wins_over_the_glance_for_the_same_operation_test() {
  let current = op_id(1)
  let seen = Glance(current, "t", "s", 0, 100)
  let state =
    agent_strip.observe(
      agent_strip.new(),
      view([#("worker", current)], [glance_cell("worker", seen)]),
      0,
    )
    |> agent_strip.observe_usage("worker", Some(current), 250)
    |> agent_strip.observe_usage("worker", None, 999_999)
  let assert [line] =
    agent_strip.lines(
      state,
      [row("worker", agent_view.Working, Some(current))],
      "worker",
    )
    as "one listed row"
  assert line.tokens == Some(250)
}

pub fn the_tick_repaints_only_when_a_drawn_second_moves_test() {
  let state =
    agent_strip.observe(agent_strip.new(), view([#("w", op_id(1))], []), 0)
  let #(state, first) = agent_strip.tick(state, 400)
  assert first == Unchanged
  let #(state, second) = agent_strip.tick(state, 1000)
  assert second == Changed
  let #(_, third) = agent_strip.tick(state, 1999)
  assert third == Unchanged
}

// --- keyboard --------------------------------------------------------------

fn three() {
  agent_strip.lines(
    agent_strip.new(),
    [
      row("main", agent_view.Idle, None),
      row("a", agent_view.Working, None),
      row("b", agent_view.Working, None),
    ],
    "main",
  )
}

pub fn entering_puts_the_cursor_on_the_row_after_the_viewed_one_test() {
  assert agent_strip.enter(agent_strip.new(), three(), "main").focus
    == Browsing("a")
  assert agent_strip.enter(agent_strip.new(), three(), "a").focus
    == Browsing("b")

  // From the last row there is nothing below, so the cursor starts at the top.
  assert agent_strip.enter(agent_strip.new(), three(), "b").focus
    == Browsing("main")
  assert agent_strip.enter(agent_strip.new(), [], "main").focus == Composing
}

pub fn keys_move_open_stop_and_return_the_keyboard_test() {
  let at = fn(id) {
    agent_strip.State(..agent_strip.new(), focus: Browsing(id))
  }
  let lines = three()
  assert agent_strip.key(at("a"), Down, lines) == Moved(at("b"))
  assert agent_strip.key(at("b"), Down, lines) == Moved(at("b"))
  assert agent_strip.key(at("b"), Up, lines) == Moved(at("a"))
  assert agent_strip.key(at("main"), Up, lines) == Left(agent_strip.new())
  assert agent_strip.key(at("a"), Back, lines) == Left(agent_strip.new())
  assert agent_strip.key(at("a"), Select, lines) == Open(agent_strip.new(), "a")
  assert agent_strip.key(at("a"), Halt, lines) == Stop(at("a"), "a")
  assert agent_strip.key(at("a"), Other, lines) == Pass(agent_strip.new())
  assert agent_strip.key(agent_strip.new(), Down, lines)
    == Pass(agent_strip.new())
}

// An agent that settles while the cursor rests on it leaves the strip; the
// next key acts on a visible row, never on the vanished one.
pub fn a_cursor_on_a_departed_agent_is_re_seated_test() {
  let at = agent_strip.State(..agent_strip.new(), focus: Browsing("gone"))
  assert agent_strip.key(at, Select, three()) == Open(agent_strip.new(), "main")
  assert agent_strip.key(at, Halt, []) == Left(agent_strip.new())
}

pub fn the_badge_names_a_viewed_agents_task_but_never_mains_test() {
  let lines = three()
  assert agent_strip.badge(lines, "main") == None
  assert agent_strip.badge(lines, "a") == Some("task of a")
  assert agent_strip.badge(lines, "missing") == None
}

// --- the shipped loop ------------------------------------------------------

pub fn the_strip_draws_one_row_per_live_agent_under_the_footer_test() {
  let text =
    tui_model.Model(..model(), strands: roster())
    |> painted(120, 30)
  let lines = string.split(text, "\n")
  let tail = list.drop(lines, list.length(lines) - 3)
  let assert [first, second, third] = tail as "three strip rows end the frame"
  assert string.contains(first, "main")
  assert string.contains(second, "audit-panics")
  assert string.contains(third, "read-docs")
}

pub fn a_short_terminal_keeps_its_rows_for_the_conversation_test() {
  let text =
    tui_model.Model(..model(), strands: roster())
    |> painted(120, 15)
  assert !string.contains(text, "audit-panics ")
}

pub fn down_enters_the_strip_and_enter_opens_the_agent_test() {
  let initial =
    tui_model.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("main draft"),
    )
    |> sized(120, 30)
  let browsing = initial |> press("down")
  assert browsing.strip.focus == Browsing("sub:main/audit-panics-1a2b3c")
  assert browsing.active_strand == "main"
  assert browsing.input == initial.input
  assert string.contains(painted(browsing, 120, 30), "enter opens · x stops")

  // Moving the cursor never retargets the composer.
  let moved = browsing |> press("down")
  assert moved.strip.focus == Browsing("sub:main/read-docs-9f8e7d")
  assert moved.active_strand == "main"

  let opened = moved |> press("enter")
  assert opened.active_strand == "sub:main/read-docs-9f8e7d"
  assert opened.strip.focus == Composing
  assert textarea.value(opened.input) == ""

  // From the last row the cursor wraps to main, and the parked draft comes
  // back with its strand.
  let back = opened |> press("down")
  assert back.strip.focus == Browsing("main")
  let returned = back |> press("enter")
  assert returned.active_strand == "main"
  assert textarea.value(returned.input) == "main draft"
}

pub fn typing_while_browsing_returns_the_key_to_the_composer_test() {
  let browsing =
    tui_model.Model(..model(), strands: roster())
    |> sized(120, 30)
    |> press("down")
  let typed = browsing |> press("q")
  assert typed.strip.focus == Composing
  assert textarea.value(typed.input) == "q"
  assert typed.active_strand == "main"
}

pub fn escape_and_up_from_the_top_hand_the_keyboard_back_test() {
  let browsing =
    tui_model.Model(..model(), strands: roster())
    |> sized(120, 30)
    |> press("down")
  assert { browsing |> press("esc") }.strip.focus == Composing
  let top = browsing |> press("up")
  assert top.strip.focus == Browsing("main")
  assert { top |> press("up") }.strip.focus == Composing
}

// Down belongs to prompt history while the operator is walking it.
pub fn down_walks_history_before_it_enters_the_strip_test() {
  let initial =
    tui_model.Model(..model(), strands: roster(), history: ["older"])
    |> sized(120, 30)
  let recalled = initial |> press("up")
  assert textarea.value(recalled.input) == "older"
  let back = recalled |> press("down")
  assert back.strip.focus == Composing
  assert { back |> press("down") }.strip.focus
    == Browsing("sub:main/audit-panics-1a2b3c")
}

pub fn opening_a_sub_agent_badges_the_composer_with_its_task_test() {
  let opened =
    tui_model.Model(..model(), strands: roster())
    |> sized(120, 30)
    |> press("down")
    |> press("enter")
  assert opened.active_strand == "sub:main/audit-panics-1a2b3c"
  assert string.contains(painted(opened, 120, 30), " Task unavailable ")
}

pub fn x_stops_the_selected_agent_without_retargeting_test() {
  let stopped =
    tui_model.Model(..model(), strands: roster())
    |> sized(120, 30)
    |> press("down")
    |> press("x")
  assert stopped.active_strand == "main"
  assert stopped.notice == "stopping sub:main/audit-panics-1a2b3c"
  assert stopped.strip.focus == Browsing("sub:main/audit-panics-1a2b3c")
}

// The re-anchor to a glance lands a capture after the daemon measured it,
// so the measurement trails the running figure; the drawn time must not
// step backwards at that moment.
pub fn a_re_anchor_never_steps_the_elapsed_time_backwards_test() {
  let running = agent_strip.Clock("op", None, 0, 0)
  let seen = Glance("op", "t", "s", 1_099_700, 0)
  let anchored =
    agent_strip.next_clock(
      Some(running),
      "op",
      Some(seen),
      Some(1_000_000),
      100_000,
    )
  assert agent_strip.elapsed_ms(anchored, 100_000) == 100_000
}

// An overlay the daemon opens on its own, such as an approval, takes the
// cursor out of the strip; closing it must leave the composer holding the
// keyboard, not a cursor that turns the next Enter into a strand switch.
pub fn an_overlay_takes_the_keyboard_out_of_the_strip_test() {
  let browsing =
    tui_model.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("send me"),
    )
    |> sized(120, 30)
    |> press("down")
  assert browsing.strip.focus == Browsing("sub:main/audit-panics-1a2b3c")
  let covered =
    tui_model.Model(
      ..browsing,
      overlay: tui_model.AgentInspector(agents.inspect("main")),
    )
  let closed = covered |> press("esc")
  assert closed.overlay == tui_model.NoOverlay
  assert closed.strip.focus == Composing
  let sent = closed |> press("enter")
  assert sent.active_strand == "main"
  assert textarea.value(sent.input) == ""
}

// Every agent settles while the cursor rests in the strip, so the strip is
// no longer drawn; the next Enter is the composer's.
pub fn a_strip_that_disappears_returns_the_keyboard_test() {
  let browsing =
    tui_model.Model(
      ..model(),
      strands: roster(),
      input: textarea.state_from_string("send me"),
    )
    |> sized(120, 30)
    |> press("down")
  let settled =
    tui_model.Model(..browsing, strands: [
      protocol.Strand("main", Some("main"), None),
    ])
  let sent = settled |> press("enter")
  assert sent.strip.focus == Composing
  assert sent.active_strand == "main"
  assert textarea.value(sent.input) == ""
}

pub fn x_on_an_idle_primary_stops_nothing_test() {
  let stopped =
    tui_model.Model(..model(), strands: roster())
    |> sized(120, 30)
    |> press("down")
    |> press("up")
    |> press("x")
  assert stopped.strip.focus == Browsing("main")
  assert stopped.notice == "nothing is running"
}

// The whole path the daemon's glance takes to the screen: a capture whose
// metadata carries a live sub-agent operation and its glance cell reaches
// `render_cut`, and the strip row and the opened agent's badge show the
// model-written words rather than the deterministic fallback.
pub fn a_captured_glance_reaches_the_strip_and_the_badge_test() {
  let current = op_id(1)
  let child = "sub:main/audit-panics-1a2b3c"
  let seen =
    Glance(current, "Audit funding panics", "Reading manager.go", 5000, 58_200)
  let live =
    snapshot_view.View(
      ..view([#(child, current)], [
        snapshot_view.Cell(
          register.OpState,
          current,
          1,
          codec.encode_state(running_state()),
        ),
        meta_cell(1, 1000),
        glance_cell(child, seen),
      ]),
      strands: [
        protocol.Strand("main", Some("main"), None),
        protocol.Strand(child, None, Some("assistant")),
      ],
    )
  let initial = model() |> sized(120, 30)
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected(initial.session, "epoch", "instance"),
        "peer",
        message.Origin("operator", "Operator"),
        snapshot.Owner,
      ),
      1,
      json.Object([]),
      snapshot.empty(),
      None,
    )
  let captured =
    inbound.apply_channel_update(
      initial,
      session_channel.Captured(cut, live, session_channel.Notified),
    )
  let text = painted(captured, 120, 30)
  assert string.contains(text, "audit-panics")
  assert string.contains(text, "Reading manager.go")
  assert string.contains(text, "58.2k ctx")

  let opened = captured |> press("down") |> press("enter")
  assert opened.active_strand == child
  assert string.contains(painted(opened, 120, 30), " Audit funding panics ")
}

fn running_state() -> operation.OperationState {
  operation.RunState(
    operation.Running,
    operation.RunSettings(
      operation.CompactionSettings(False, 0, 0),
      operation.ConsumeAll,
      operation.ConsumeAll,
      operation.Parallel,
    ),
    operation.Starting,
    operation.Inbox([], [], []),
    None,
  )
}
