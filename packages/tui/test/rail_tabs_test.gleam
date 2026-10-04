//// The rail's four tabs, their keys and their commands.
////
//// Strands, Changes, Trace and Session are the web view's tabs in the web
//// view's order. These tests pin what each shows, how the digit keys and
//// `/diff`, `/trace` and `/summary` reach them, that the tab is remembered
//// per workspace (Changes excepted), and what the terminal says when it is
//// too narrow to dock a rail to show them on. With `LOOM_TAB_RENDERS` set to
//// a directory, the last test writes one frame per tab as text.

import core/json
import etui/backend
import etui/buffer
import frame_scene
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as host_bootstrap
import session_view/agent_view
import session_view/model.{Shared} as _
import simplifile
import tui
import tui/agent_strip
import tui/effect
import tui/frame
import tui/layout
import tui/layout_memory
import tui/layout_save
import tui/model.{type Model, Model} as tui_model
import tui/queue_editor
import tui/rail
import tui/submit
import tui_test/stepping

// -------------------------------------------------------------- the scenes

fn program() -> String {
  "import cap/fs\npub fn main() {\n  fs.read(\"a.gleam\")\n}"
}

fn calls() -> json.JsonValue {
  json.Object([
    #("started_unix_ms", json.Int(0)),
    #("elapsed_ms", json.Int(900)),
    #("total", json.Int(2)),
    #("failed", json.Int(1)),
    #("cancelled", json.Int(0)),
    #("unsettled", json.Int(0)),
    #(
      "items",
      json.Array([
        json.Object([
          #("cap", json.String("fs.read")),
          #("args", json.String("a.gleam")),
          #("status", json.String("ok")),
          #("start_ms", json.Int(1)),
          #("duration_ms", json.Int(3)),
        ]),
        json.Object([
          #("cap", json.String("proc.run")),
          #("args", json.String("gleam test")),
          #("status", json.String("failed")),
          #("error", json.String("exit_status")),
          #("start_ms", json.Int(5)),
          #("duration_ms", json.Int(700)),
        ]),
      ]),
    ),
  ])
}

// A conversation whose last program ended with one call failed.
fn ended() -> Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Check the calculator."),
    frame_scene.assistant(2, "", [
      frame_scene.call("c1", "code_mode", [#("program", json.String(program()))]),
    ]),
    frame_scene.result_with(
      3,
      "c1",
      "code_mode",
      "done",
      json.Object([
        #("status", json.String("completed")),
        #("value", json.String("2 files read")),
        #("calls", calls()),
      ]),
      frame_scene.Succeeded,
    ),
    frame_scene.assistant(4, "The check ran.", []),
  ])
}

// The same conversation with the program sent and no result yet.
fn running() -> Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Check the calculator."),
    frame_scene.assistant(2, "", [
      frame_scene.call("c1", "code_mode", [#("program", json.String(program()))]),
    ]),
  ])
}

fn agent(id: String, status: agent_view.Status, activity: String) {
  agent_view.Row(
    id:,
    name: id,
    operation: Some("op-" <> id),
    status:,
    task: "Check the doc comments against behaviour.",
    activity:,
    update: "",
    update_entry: None,
    pending: "",
    approvals: [],
    model: "moonshotai/Kimi-K3",
    recent: [],
    decision: "",
  )
}

// A second agent, so the rail has a list for the cursor to enter.
fn with_agents(model: Model) -> Model {
  Model(
    ..model,
    shared: Shared(..model.shared, agent_rows: [
      agent("main", agent_view.Working, "Waiting for a reviewer"),
      agent(
        "sub:main/tests-0a0b0c0d0e0f1011",
        agent_view.Working,
        "Running tests",
      ),
    ]),
  )
}

fn at(model: Model, width: Int, height: Int) -> Model {
  tui.update(backend.Resize(width, height), model)
}

fn text(model: Model) -> String {
  frame_scene.screen(model, model.view.width, model.view.height)
  |> frame_text
}

fn frame_text(painted: buffer.Buffer) -> String {
  string.join(frame_lines(painted), "\n")
}

fn frame_lines(painted: buffer.Buffer) -> List(String) {
  frame.buffer_to_lines(painted)
}

fn key(model: Model, name: String) -> Model {
  let #(next, _) = stepping.step(backend.KeyPress(name), model)
  next
}

fn command(model: Model, words: String) -> Model {
  let typed =
    string.to_graphemes(words)
    |> list.fold(model, fn(model, character) { key(model, character) })
  key(typed, "enter")
}

// ------------------------------------------------------------ the tab bar

pub fn the_tab_bar_names_the_four_tabs_in_the_web_views_order_test() {
  let model = at(ended(), 200, 50)
  let bar =
    list.find(frame_lines(frame_scene.screen(model, 200, 50)), string.contains(
      _,
      "Strands",
    ))
  let assert Ok(row) = bar as "the tab bar is on screen"
  let assert Ok(#(before, _)) = string.split_once(row, "Session")
  assert string.contains(before, "Strands")
  assert string.contains(before, "Changes")
  assert string.contains(before, "Trace")
  assert string.length(before) < string.length(row)
  let assert Ok(#(strands, rest)) = string.split_once(row, "Changes")
  assert string.contains(strands, "Strands")
  let assert Ok(#(_, last)) = string.split_once(rest, "Trace")
  assert string.contains(last, "Session")
}

pub fn the_tab_numbers_are_the_keys_and_the_order_test() {
  assert list.map(
      [rail.Strands, rail.Changes, rail.Trace, rail.Session],
      rail.number,
    )
    == [1, 2, 3, 4]
  assert rail.of_number(0) == Error(Nil)
  assert rail.of_number(5) == Error(Nil)
  assert rail.of_number(3) == Ok(rail.Trace)
}

// ------------------------------------------------------------------ Trace

pub fn trace_shows_a_program_its_result_and_its_calls_test() {
  let model = submit.select_rail_tab(at(ended(), 200, 50), rail.Trace)
  let shown = text(model)
  assert string.contains(shown, "TRACE · latest program")
  assert string.contains(shown, "✓ completed")
  assert string.contains(shown, "1 │ import cap/fs")
  assert string.contains(shown, "3 │   fs.read")
  assert string.contains(shown, "RESULT")
  assert string.contains(shown, "2 files read")
  assert string.contains(shown, "CALLS · 2 calls · 1 failed")
  assert string.contains(shown, "✓ fs.read")
  assert string.contains(shown, "× proc.run")
  assert !string.contains(shown, "+1ms") as "no per-call timing is drawn"
}

pub fn trace_says_a_program_is_still_running_test() {
  let model = submit.select_rail_tab(at(running(), 200, 50), rail.Trace)
  let shown = text(model)
  assert string.contains(shown, "◐ running · awaiting its result")
  assert string.contains(shown, "none yet")
  assert !string.contains(shown, "CALLS") as "the record comes with the result"
}

pub fn trace_says_when_the_strand_has_run_no_program_test() {
  let model =
    submit.select_rail_tab(at(scene_without_a_program(), 200, 50), rail.Trace)
  assert string.contains(text(model), "No program yet")
}

fn scene_without_a_program() -> Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Hello."),
    frame_scene.assistant(2, "Hi.", []),
  ])
}

// ---------------------------------------------------------------- Session

pub fn session_shows_goal_jobs_viewers_and_cost_test() {
  let model = submit.select_rail_tab(at(ended(), 200, 50), rail.Session)
  let shown = text(model)
  assert string.contains(shown, "SESSION")
  assert string.contains(shown, "Goal    none pinned")
  assert string.contains(shown, "Jobs    not read")
  assert string.contains(shown, "Viewers ")
  assert string.contains(shown, "Cost    est $")
  assert model.shared.jobs_refresh == worktree_requested()
    as "choosing Session asks for a fresh read of the live jobs"
}

fn worktree_requested() {
  submit.select_rail_tab(at(ended(), 200, 50), rail.Session).shared.jobs_refresh
}

// ------------------------------------------------------------- the keys

pub fn down_from_the_composer_gives_a_cursorless_tab_the_keyboard_test() {
  let on_trace = submit.select_rail_tab(at(ended(), 200, 50), rail.Trace)
  assert on_trace.view.rail_focus == tui_model.FocusComposer
  let focused = key(on_trace, "down")
  assert focused.view.rail_focus == tui_model.FocusTab
  assert string.contains(text(focused), "1-4 tab · ↑↓ scroll · Esc to composer")

  // The digits choose a tab, and the keyboard stays on a tab with no cursor.
  let session = key(focused, "4")
  assert layout.rail_tab(session) == rail.Session
  assert session.view.rail_focus == tui_model.FocusTab
  let strands = key(session, "1")
  assert layout.rail_tab(strands) == rail.Strands
  assert strands.view.rail_focus == tui_model.FocusComposer
    as "Strands has the list's cursor, entered with Down"

  // Escape hands the keyboard back.
  assert key(focused, "esc").view.rail_focus == tui_model.FocusComposer
}

pub fn with_two_agents_the_digits_still_reach_a_cursorless_tab_test() {
  // The strip is visible off Strands, so Down enters it; a digit from there
  // chooses a tab, and a cursorless tab takes the keyboard.
  let model = with_agents(at(ended(), 200, 50))
  let in_strip = key(model, "down")
  assert in_strip.view.strip_focus != agent_strip.Composing
  let trace = key(in_strip, "3")
  assert layout.rail_tab(trace) == rail.Trace
  assert trace.view.rail_focus == tui_model.FocusTab
  assert trace.view.strip_focus == agent_strip.Composing
  let scrolled = key(trace, "down")
  assert scrolled.view.rail_focus == tui_model.FocusTab
    as "the arrows now scroll the tab"
  let back = key(scrolled, "1")
  assert layout.rail_tab(back) == rail.Strands
    as "1 from Trace returns to Strands"
  assert key(trace, "esc").view.rail_focus == tui_model.FocusComposer
}

// The tab shows what the shared state says: a result whose status the fold
// does not know is `Failed` when the tool reported an error, and
// `Completed` when it did not, so the tab says "failed" and "completed".
pub fn the_tab_words_an_unknown_status_by_the_tools_error_flag_test() {
  let errored =
    submit.select_rail_tab(
      at(failed_with("anything_else"), 200, 50),
      rail.Trace,
    )
  assert string.contains(text(errored), "× failed")
  assert !string.contains(text(errored), "anything_else")
  let plain =
    submit.select_rail_tab(at(ended_with("anything_else"), 200, 50), rail.Trace)
  assert string.contains(text(plain), "✓ completed")
}

// Narrowing below 120 columns takes the docked rail away from a tab that held
// the keyboard. Escape pressed then is the reset and not an interrupt.
pub fn escape_after_the_tab_left_the_screen_does_not_interrupt_test() {
  let focused =
    submit.select_rail_tab(at(ended(), 200, 50), rail.Trace) |> key("down")
  assert focused.view.rail_focus == tui_model.FocusTab
  let narrow = at(focused, 100, 30)
  assert layout.rail_columns(narrow) == 0
  let #(after, effects) = stepping.step(backend.KeyPress("esc"), narrow)
  assert after.view.rail_focus == tui_model.FocusComposer
  assert effects == [] as "no interrupt was sent"
  assert after.shared.notice == narrow.shared.notice
}

pub fn a_key_the_tab_does_not_want_goes_to_the_composer_test() {
  let focused =
    submit.select_rail_tab(at(ended(), 200, 50), rail.Trace) |> key("down")
  let typed = key(focused, "x")
  assert typed.view.rail_focus == tui_model.FocusComposer
  assert string.contains(
    string.join(frame_lines(frame_scene.screen(typed, 200, 50)), "\n"),
    "x",
  )
}

pub fn the_arrows_scroll_a_tab_and_stop_at_its_ends_test() {
  // Four rows of room at 200x20 is too few for the whole program and its
  // calls, so the tab can scroll.
  let model =
    submit.select_rail_tab(at(ended(), 200, 16), rail.Trace) |> key("down")
  assert model.view.rail_scroll == 0
  let top = key(model, "up")
  assert top.view.rail_scroll == 0 as "it does not scroll above its first row"
  let moved = key(model, "down")
  assert moved.view.rail_scroll == 1
  let far =
    list.fold(list.repeat(Nil, 60), model, fn(current, _) {
      key(current, "pagedown")
    })
  assert far.view.rail_scroll > 1
  let again = key(far, "pagedown")
  assert again.view.rail_scroll == far.view.rail_scroll as "nor below its last"
}

pub fn the_digits_choose_a_tab_from_the_strands_list_test() {
  let model = at(with_agents(ended()), 200, 50)
  let browsing = key(model, "down")
  let assert agent_strip.Browsing(_) = browsing.view.strip_focus
  let trace = key(browsing, "3")
  assert layout.rail_tab(trace) == rail.Trace
  assert trace.view.rail_tab == Some(layout_memory.TabTrace)
  assert trace.view.strip_focus == agent_strip.Composing

  // Digit 2 opens the changes, which is the changes setting's.
  let changes = key(key(model, "down"), "2")
  assert layout.rail_tab(changes) == rail.Changes
  assert changes.view.diff_view == tui_model.DiffVisible
  let back = submit.select_rail_tab(changes, rail.Trace)
  assert layout.rail_tab(back) == rail.Trace
  assert back.view.diff_view == tui_model.DiffHidden
    as "choosing another tab closes the changes"
}

pub fn digits_are_ordinary_characters_at_the_composer_test() {
  let model = at(ended(), 200, 50)
  let typed = key(key(model, "3"), "4")
  assert layout.rail_tab(typed) == rail.Strands
  assert typed.view.rail_tab == None
}

// -------------------------------------------------------------- commands

pub fn trace_and_diff_open_their_tabs_on_a_terminal_that_can_dock_test() {
  let model = at(ended(), 120, 40)
  assert layout.rail_columns(model) == 0
  let trace = command(model, "/trace")
  assert layout.rail_tab(trace) == rail.Trace
  assert layout.rail_columns(trace) == 45 as "the command docks the rail"
  assert trace.view.rail == Some(layout_memory.RailShown)
  let summary = command(trace, "/summary")
  assert summary.view.summary_surface != queue_editor.Closed
    as "/summary is the full-screen summary at every width"
  assert layout.rail_tab(summary) == rail.Trace
    as "and it does not move the rail's tab"
  let diff = command(trace, "/diff")
  assert layout.rail_tab(diff) == rail.Changes
  let closed = command(diff, "/diff")
  assert layout.rail_tab(closed) == rail.Trace
    as "closing the changes shows the tab that was chosen"
}

pub fn a_narrow_terminal_says_there_is_no_rail_for_trace_test() {
  let model = at(ended(), 80, 24)
  let trace = command(model, "/trace")
  assert layout.rail_columns(trace) == 0
  assert string.contains(trace.shared.notice, "Trace tab needs the rail")
  assert string.contains(trace.shared.notice, "120 columns")
  let summary = command(model, "/summary")
  assert summary.view.summary_surface != queue_editor.Closed
    as "below 120 columns /summary is still the full-screen summary"
}

// ----------------------------------------------------------- persistence

pub fn the_tab_is_remembered_with_the_rail_test() {
  let path = "/x/layout.json"
  let key_text = layout_memory.workspace_key("/work/loom")
  let base =
    layout_save.apply(
      at(with_agents(ended()), 200, 50),
      layout_memory.Target(path:, key: key_text, saved: layout_memory.default()),
    )
  let #(chosen, effects) = stepping.step(backend.KeyPress("down"), base)
  let #(trace, effects_after) = stepping.step(backend.KeyPress("3"), chosen)
  assert list.filter(effects, is_save) == []
  assert list.filter(effects_after, is_save)
    == [
      effect.SaveLayout(
        path,
        key_text,
        layout_memory.Layout(rail: None, tab: Some(layout_memory.TabTrace)),
      ),
    ]
    as "choosing a tab saves it, and no rail choice where it docked by default"
  assert trace.view.rail_tab == Some(layout_memory.TabTrace)
  let medium = at(ended(), 120, 40)
  let shown = command(medium, "/trace")
  assert shown.view.rail == Some(layout_memory.RailShown)
    as "where the choice is what docked it, it is recorded"
}

// A program that never ran, ended by `status`.
fn failed_with(status: String) -> Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Check the calculator."),
    frame_scene.assistant(2, "", [
      frame_scene.call("c1", "code_mode", [#("program", json.String(program()))]),
    ]),
    frame_scene.result_with(
      3,
      "c1",
      "code_mode",
      "no",
      json.Object([#("status", json.String(status))]),
      frame_scene.Errored,
    ),
  ])
}

// The same program with a result that is not an error and has `status`.
fn ended_with(status: String) -> Model {
  frame_scene.attach(frame_scene.model(), "fix readme badge", [
    frame_scene.user(1, "Check the calculator."),
    frame_scene.assistant(2, "", [
      frame_scene.call("c1", "code_mode", [#("program", json.String(program()))]),
    ]),
    frame_scene.result_with(
      3,
      "c1",
      "code_mode",
      "fine",
      json.Object([#("status", json.String(status))]),
      frame_scene.Succeeded,
    ),
  ])
}

pub fn a_program_that_did_not_run_is_worded_as_the_transcript_words_it_test() {
  let compile =
    submit.select_rail_tab(
      at(failed_with("compile_failed"), 200, 50),
      rail.Trace,
    )
  assert string.contains(text(compile), "× compile error")
  assert !string.contains(text(compile), "compile_failed")
  let vetting =
    submit.select_rail_tab(
      at(failed_with("vetting_rejected"), 200, 50),
      rail.Trace,
    )
  assert string.contains(text(vetting), "× refused by vetting")
}

fn is_save(requested: effect.Effect) -> Bool {
  case requested {
    effect.SaveLayout(..) -> True
    _ -> False
  }
}

pub fn a_remembered_tab_is_applied_at_launch_but_changes_is_not_test() {
  let target = fn(tab) {
    layout_memory.Target(
      path: "/x/layout.json",
      key: layout_memory.workspace_key("/work/loom"),
      saved: layout_memory.Layout(rail: None, tab: tab),
    )
  }
  let trace =
    layout_save.apply(
      at(ended(), 200, 50),
      target(Some(layout_memory.TabTrace)),
    )
  assert layout.rail_tab(trace) == rail.Trace
  let none = layout_save.apply(at(ended(), 200, 50), target(None))
  assert layout.rail_tab(none) == rail.Strands
}

// -------------------------------------------------------------- the renders

pub fn one_frame_per_tab_can_be_written_for_review_test() {
  let wide = at(ended(), 200, 50)
  let medium = at(ended(), 120, 40)
  let frames = [
    #("tab-strands-200x50", wide),
    #("tab-changes-200x50", submit.select_rail_tab(wide, rail.Changes)),
    #("tab-trace-200x50", submit.select_rail_tab(wide, rail.Trace)),
    #("tab-session-200x50", submit.select_rail_tab(wide, rail.Session)),
    #(
      "tab-trace-running-200x50",
      submit.select_rail_tab(at(running(), 200, 50), rail.Trace),
    ),
    #(
      "tab-strands-120x40",
      submit.select_rail_tab(medium, rail.Strands) |> key("backtab"),
    ),
    #("tab-changes-120x40", submit.select_rail_tab(medium, rail.Changes)),
    #("tab-trace-120x40", submit.select_rail_tab(medium, rail.Trace)),
    #("tab-session-120x40", submit.select_rail_tab(medium, rail.Session)),
    #("tab-80x24-trace-command", command(at(ended(), 80, 24), "/trace")),
    #("tab-80x24-summary-surface", command(at(ended(), 80, 24), "/summary")),
    #(
      "tab-trace-two-agents-200x50",
      submit.select_rail_tab(at(with_agents(ended()), 200, 50), rail.Trace),
    ),
    #(
      "tab-trace-two-agents-120x40",
      submit.select_rail_tab(at(with_agents(ended()), 120, 40), rail.Trace),
    ),
  ]
  list.each(frames, fn(entry) {
    assert string.length(text(entry.1)) > 0
  })
  case host_bootstrap.getenv("LOOM_TAB_RENDERS") {
    Ok(directory) -> {
      let assert Ok(Nil) = simplifile.create_directory_all(directory)
      list.each(frames, fn(entry) {
        let assert Ok(Nil) =
          simplifile.write(
            directory <> "/" <> entry.0 <> ".txt",
            text(entry.1) <> "\n",
          )
      })
    }
    Error(Nil) -> Nil
  }
  assert int.to_string(list.length(frames)) == "13"
}
