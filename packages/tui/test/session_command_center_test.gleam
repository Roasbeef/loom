//// The session picker as a cross-session view: presence joins lifecycle
//// with the daemon's activity reply, filters narrow the drawn rows, and the
//// highlight follows an identity rather than a position when either moves.

import etui/buffer
import etui/geometry
import etui/keys
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/connection
import tui/daemon/protocol
import tui/frame
import tui/model as tui_model
import tui/session_control
import tui/session_selector
import tui/workspace
import weft

fn session(id: String, workspace: String, status) -> protocol.Session {
  protocol.Session(id, workspace, id, 1, status)
}

fn activity(id: String, state) -> protocol.Activity {
  protocol.Activity(id, state, 1, 0, 0, None, None, None, [])
}

// Two workspaces, interleaved on the page, so grouping has to move a row.
fn page() -> protocol.Page {
  protocol.Page(
    3,
    [
      session("waiting", "/work/loom", protocol.Resident("a")),
      session("saved", "/work/lnd", protocol.Saved),
      session("busy", "/work/loom/", protocol.Resident("b")),
      session("quiet", "/work/lnd", protocol.Resident("c")),
    ],
    None,
  )
}

fn observed() -> session_selector.State {
  session_selector.new(page(), "busy")
  |> session_selector.observe(["waiting", "busy", "quiet"], [
    activity("waiting", protocol.NeedsYou),
    activity("busy", protocol.Working),
    activity("quiet", protocol.Idle),
  ])
}

fn ids(rows: List(protocol.Session)) -> List(String) {
  list.map(rows, fn(row) { row.session_id })
}

fn press(state, key) -> session_selector.State {
  let assert session_selector.Continue(next) =
    session_selector.update(key, state)
    as "navigation keys keep the picker open"
  next
}

pub fn rows_group_by_workspace_in_page_order_test() {
  let state = observed()
  assert list.map(session_selector.groups(state), fn(group) { group.0 })
    == ["/work/loom", "/work/lnd"]
  assert ids(session_selector.visible(state))
    == ["waiting", "busy", "saved", "quiet"]

  // The current session is highlighted by identity, after grouping moved it.
  assert session_selector.selected_row(state)
    |> option.map(fn(row) { row.session_id })
    == Some("busy")
}

pub fn presence_joins_lifecycle_with_activity_test() {
  let state = observed()
  let presences =
    list.map(state.page.sessions, fn(row) {
      session_selector.presence(state, row)
    })
  assert presences
    == [
      session_selector.NeedsYou,
      session_selector.Inactive,
      session_selector.Working,
      session_selector.Idle,
    ]

  // A saved row is inactive whatever an old reply said about it, and a
  // resident row nobody has asked about is unobserved rather than idle.
  let stale =
    session_selector.State(
      ..state,
      activity: dict.insert(
        state.activity,
        "saved",
        activity("saved", protocol.Working),
      ),
    )
  let assert Ok(saved) =
    list.find(page().sessions, fn(row) { row.session_id == "saved" })
    as "the fixture has a saved row"
  assert session_selector.presence(stale, saved) == session_selector.Inactive
  let fresh = session_selector.new(page(), "busy")
  let assert [waiting, ..] = page().sessions as "the fixture has rows"
  assert session_selector.presence(fresh, waiting)
    == session_selector.Unobserved
}

pub fn tab_cycles_filters_and_counts_match_the_rows_test() {
  let state = observed()
  assert session_selector.counts(state)
    == [
      #(session_selector.AllSessions, 4),
      #(session_selector.NeedsYouSessions, 1),
      #(session_selector.WorkingSessions, 1),
      #(session_selector.IdleSessions, 1),
      #(session_selector.InactiveSessions, 1),
    ]
  let needs = press(state, keys.Tab)
  assert needs.filter == session_selector.NeedsYouSessions
  assert ids(session_selector.visible(needs)) == ["waiting"]

  // Every tab's count is the number of rows it draws.
  list.fold(list.repeat(Nil, 5), state, fn(current, _) {
    let assert Ok(count) =
      list.key_find(session_selector.counts(current), current.filter)
      as "every filter has a count"
    assert list.length(session_selector.visible(current)) == count
    press(current, keys.Tab)
  })
  assert press(state, keys.BackTab).filter == session_selector.InactiveSessions
}

pub fn enter_opens_the_highlighted_row_under_a_filter_test() {
  let idle = state_with_filter(session_selector.IdleSessions)
  let assert Some(row) = session_selector.selected_row(idle)
    as "the idle tab has a row"
  assert row.session_id == "quiet"
  assert session_selector.update(keys.Enter, idle)
    == session_selector.Choose(row)
}

fn state_with_filter(filter) -> session_selector.State {
  let state = observed()
  list.fold(list.repeat(Nil, 5), state, fn(current, _) {
    case current.filter == filter {
      True -> current
      False -> press(current, keys.Tab)
    }
  })
}

pub fn an_answer_keeps_the_highlighted_identity_test() {
  let state = observed()
  let on_quiet = press(press(press(state, keys.Down), keys.Down), keys.Up)
  let assert Some(before) = session_selector.selected_row(on_quiet)
    as "a row is highlighted"

  // `waiting` settles: under the Needs-you tab its row would vanish, and on
  // the All tab nothing moves, so the cursor stays on the same identity.
  let after =
    session_selector.observe(on_quiet, ["waiting"], [
      activity("waiting", protocol.Idle),
    ])
  assert session_selector.selected_row(after) == Some(before)
}

pub fn an_absent_answer_drops_the_old_one_test() {
  let state = observed()

  // `busy` was asked about and left out of the reply: it is no longer
  // resident, so its old Working answer must not survive. Answers about
  // identities that were not asked, or are not on this page, are ignored.
  let after =
    session_selector.observe(state, ["busy"], [
      activity("quiet", protocol.NeedsYou),
      activity("elsewhere", protocol.NeedsYou),
    ])
  assert dict.get(after.activity, "busy") == Error(Nil)
  assert dict.get(after.activity, "quiet") == dict.get(state.activity, "quiet")
  assert dict.get(after.activity, "elsewhere") == Error(Nil)
}

pub fn resident_ids_are_bounded_by_the_request_limit_test() {
  let rows =
    list.repeat(Nil, 30)
    |> list.index_map(fn(_, index) {
      session("r" <> int.to_string(index + 1), "/work", protocol.Resident("i"))
    })
  let state =
    session_selector.new(
      protocol.Page(
        1,
        [session("saved", "/work", protocol.Saved), ..rows],
        None,
      ),
      "",
    )
  let asked = session_selector.resident_ids(state)
  assert list.length(asked) == protocol.activity_limit
  assert list.first(asked) == Ok("r1")
  assert !list.contains(asked, "saved")
}

// The poll's answer reaches an open picker through the tick's drain, and the
// poll rests once the worker has delivered everything.
pub fn a_drained_answer_marks_the_open_picker_test() {
  let replies = process.new_subject()
  let model =
    tui_model.Model(
      ..tui.new_model_with_clock(
        connection.new_inbox(),
        workspace.Context("/work", None),
        fn() { -5000 },
      ),
      overlay: tui_model.DaemonSelector(session_selector.new(page(), "busy")),
      activity_poll: tui_model.ActivityAsking(replies, ["busy"]),
    )
  process.send(
    replies,
    weft.PulledOutcome(weft.Completed(0, [activity("busy", protocol.Working)])),
  )
  process.send(replies, weft.AllDelivered)
  let answered = session_control.drain_activity(model)
  let assert tui_model.DaemonSelector(selector) = answered.overlay
    as "the picker stays open"
  let assert Ok(busy) =
    list.find(page().sessions, fn(row) { row.session_id == "busy" })
    as "the fixture has a busy row"
  assert session_selector.presence(selector, busy) == session_selector.Working
  let settled = session_control.drain_activity(answered)
  assert settled.activity_poll == tui_model.ActivityResting(-2000)
}

// An answer that outlived its picker changes nothing, and with no daemon the
// service never starts a poll.
pub fn a_closed_picker_ignores_a_late_answer_test() {
  let replies = process.new_subject()
  let model =
    tui_model.Model(
      ..tui.new_model(connection.new_inbox(), workspace.Context("/work", None)),
      activity_poll: tui_model.ActivityAsking(replies, ["busy"]),
    )
  process.send(
    replies,
    weft.PulledOutcome(weft.Completed(0, [activity("busy", protocol.Working)])),
  )
  let after = session_control.drain_activity(model)
  assert after.overlay == tui_model.NoOverlay
  let idle =
    tui_model.Model(
      ..model,
      overlay: tui_model.DaemonSelector(session_selector.new(page(), "busy")),
      activity_poll: tui_model.ActivityDue,
    )
  assert session_control.service_activity(idle).activity_poll
    == tui_model.ActivityDue
}

// A wide picker with nothing to show draws its advice alone, with no
// details divider beside it.
pub fn an_empty_wide_picker_draws_no_divider_test() {
  let screen = geometry.rect_new(0, 0, 150, 30)
  let state = session_selector.new(protocol.Page(1, [], None), "")
  let lines =
    session_selector.render(buffer.buffer_new(screen), screen, state)
    |> frame.buffer_to_lines
  let assert Ok(advice) =
    list.find(lines, fn(line) { string.contains(line, "No saved sessions") })
    as "the empty picker explains itself"
  assert string.split(advice, "│") |> list.length == 3
}
