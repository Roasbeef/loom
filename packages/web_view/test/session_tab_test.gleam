//// The Session tab's rows: the goal, the jobs, the viewers and the cost.
////
//// The first group draws `view/session_tab` from plain rows, its whole
//// contract: what each row says, that names, commands and the goal are only
//// text nodes, that the pane always has its heading and its cost, and that a
//// page passing no roster draws no viewers. The second drives the pages: a
//// tick makes the read-only `live_jobs` read once per interval and no more,
//// the reply fills the row, an operator's page names its viewers, and an
//// observer's page draws the jobs and never the viewers.

import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/connection_event
import session_view/session_summary.{Another, Live, Unread, Viewer, Viewers, You}
import session_view/snapshot
import session_view/snapshot_view
import web_view/component
import web_view/operator_page
import web_view/view/session_tab

fn drawn(jobs, viewers) -> String {
  element.to_string(session_tab.view(
    [],
    "$0.00",
    jobs,
    viewers,
    None,
    element.none(),
    element.none(),
    element.none(),
    element.none(),
  ))
}

// The pane is drawn whether or not it shows, so its heading and its cost row
// are always there and the panel's other panes never move.
pub fn nothing_to_say_still_draws_the_heading_and_the_cost_test() {
  let html = drawn(Unread, None)

  assert string.contains(html, "<section aria-label=\"Session\"")
  assert string.contains(html, "pane pane-session")
  assert string.contains(html, "Session</h2>")
  assert string.contains(html, "Cost</h3>")
  assert string.contains(html, "$0.00")

  // The label says it is an estimate, so the figure does not say it again.
  assert !string.contains(html, "est $")
}

// The groups are in the order a reader scans, each under an eyebrow heading:
// the pane's title is the Session group's, then People, Goal, Jobs and Cost.
// The pane keeps six children so the handlers' paths hold, and the
// stylesheet puts the controls and the invitation among the groups.
pub fn the_groups_read_session_people_goal_jobs_cost_test() {
  let html =
    element.to_string(session_tab.view(
      [],
      "$0.12",
      Unread,
      Some(Viewers([], 1)),
      Some("/src/loom"),
      element.none(),
      element.none(),
      element.none(),
      element.none(),
    ))
  let positions =
    list.map(
      [
        "Session</h2>",
        "session-group-workspace",
        "People</h3>",
        "Goal</h3>",
        "Jobs</h3>",
        "Cost</h3>",
      ],
      fn(part) {
        let assert Ok(#(before, _)) = string.split_once(html, part)
          as "every group is drawn"
        string.length(before)
      },
    )
  assert positions == list.sort(positions, int.compare)
  assert string.contains(html, "/src/loom")
  assert !string.contains(html, "Est. cost")

  // A page that shows no viewers and read no label draws neither group.
  let bare = drawn(Unread, None)
  assert !string.contains(bare, "People")
  assert !string.contains(bare, "session-group-workspace")
}

pub fn a_pinned_goal_is_the_terminals_row_and_no_goal_says_none_test() {
  let with_goal =
    element.to_string(session_tab.view(
      ["goal active · 10/100 tokens · 2 continuations · ship it"],
      "$0.12",
      Unread,
      None,
      None,
      element.none(),
      element.none(),
      element.none(),
      element.none(),
    ))
  assert string.contains(with_goal, "Goal")
  assert string.contains(
    with_goal,
    "goal active · 10/100 tokens · 2 continuations · ship it",
  )
  assert string.contains(with_goal, "$0.12")

  let without = drawn(Unread, None)
  assert string.contains(without, "Goal")
  assert string.contains(without, "none")
}

pub fn the_goal_is_only_ever_a_text_node_test() {
  let html =
    element.to_string(session_tab.view(
      ["goal active · <script>alert(1)</script>"],
      "$0.00",
      Unread,
      None,
      None,
      element.none(),
      element.none(),
      element.none(),
      element.none(),
    ))
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert !string.contains(html, "<script")
}

pub fn unread_jobs_say_so_and_never_zero_test() {
  let html = drawn(Unread, Some(Viewers([], 0)))

  assert string.contains(html, "pane pane-session")
  assert string.contains(html, "Jobs")
  assert string.contains(html, "not read yet")
  assert !string.contains(html, "none live")
}

pub fn a_board_with_no_job_says_none_and_the_refresh_is_a_tooltip_test() {
  let html = drawn(Live(0, [], 0), None)

  assert string.contains(html, "title=\"At the last refresh\">none</p>")
  assert !string.contains(html, "none live")
}

pub fn jobs_are_a_count_their_rows_and_what_was_left_out_test() {
  let html =
    drawn(
      Live(11, ["job-1 · running · started by op-1 · sleep 1 · age 2s"], 10),
      None,
    )

  assert string.contains(html, "11 live")
  assert string.contains(html, " · at last refresh")
  assert string.contains(html, "<li>job-1 · running · started by op-1")
  assert string.contains(html, "+10 more jobs not shown")
}

pub fn a_job_command_is_only_ever_a_text_node_test() {
  let html =
    drawn(Live(1, ["job · running · <script>alert(1)</script>"], 0), None)

  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert !string.contains(html, "<script")
}

pub fn viewers_are_named_with_their_roles_and_your_own_is_marked_test() {
  let html =
    drawn(
      Unread,
      Some(Viewers(
        [
          Viewer("Alice", ["operator"], 1, You),
          Viewer("<b>Bob</b>", ["observer"], 1, Another),
        ],
        5,
      )),
    )

  assert string.contains(html, "5 attached")
  assert string.contains(html, "Alice")
  assert string.contains(html, " · operator · you")
  assert string.contains(html, "&lt;b&gt;Bob&lt;/b&gt;")
  assert string.contains(html, " · observer · viewing<")
  assert string.contains(html, "+3 more not shown")
  assert !string.contains(html, "<b>Bob")
}

// One person's three tabs are one line that says so, with one role in the
// home's words: the engine's `owner, operator` and `3 pages` never appear.
pub fn a_principal_with_pages_is_one_line_that_counts_them_test() {
  let html =
    drawn(
      Unread,
      Some(Viewers([Viewer("Owner", ["owner", "operator"], 3, You)], 3)),
    )

  assert string.contains(html, "Owner")
  assert string.contains(html, " · operator · 3 tabs · you")
  assert !string.contains(html, "owner, operator")
  assert !string.contains(html, "pages")
  assert !string.contains(html, "more not shown")
}

pub fn no_roster_means_no_viewers_row_test() {
  let html = drawn(Live(0, [], 0), None)

  assert !string.contains(html, "Viewers")
  assert !string.contains(html, "attached")
}

pub fn the_view_carries_no_handler_test() {
  let html = drawn(Live(1, ["x"], 0), Some(Viewers([], 0)))
  assert !string.contains(html, "data-lustre-on")
}

// --- on the pages ---------------------------------------------------------------

fn jobs_frame(id: Int, command: String) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"reply_to\":"
    <> int.to_string(id)
    <> ",\"event\":\"snapshot\",\"body\":{\"mode\":\"live_jobs\",\"board\":"
    <> "{\"strand\":\"main\",\"observed_at_ms\":1000,\"jobs\":[{\"id\":\"job-1\","
    <> "\"state\":\"running\",\"started_by\":\"op-1\",\"command_excerpt\":\""
    <> command
    <> "\",\"age_ms\":250,\"deadline_ms\":10750}],\"total\":1,\"omitted\":0}}}",
  )
}

fn live_jobs_reads(frames: List(String)) -> List(String) {
  list.filter(frames, string.contains(_, "\"cmd\":\"live_jobs\""))
}

fn operator(model) -> String {
  element.to_string(operator_page.view(model))
}

fn observer(model) -> String {
  element.to_string(component.view(model))
}

// A page whose lane finished its first transfer and whose first reads were
// refused, on a clock the test sets.
fn ready(clock, wire, role: String) {
  page_fixture.run(
    component.new(page_fixture.start_with(clock)),
    component.update,
    [
      component.Opened(wire),
      component.Arrived(page_fixture.transfer(role, [])),
    ],
  )
  |> page_fixture.refuse_reads(component.update, wire, component.Arrived)
}

// The page's first tick-driven ask comes one interval after it opened, so a
// test that wants the ask moves its clock there before the tick.
fn first_tick(clock, model) {
  page_fixture.set(clock, component.jobs_refresh_ms)
  page_fixture.run(model, component.update, [component.Ticked])
}

// The daemon's answer to every request in `frames`, so the lane's one command
// slot is free for the next ask: a catch-up is answered with a catch-up, and
// any other read is refused.
fn refused(model, frames: List(String)) {
  let answers =
    frames
    |> list.filter(fn(frame) {
      !string.contains(frame, "\"cmd\":\"snapshot")
      && !string.contains(frame, "\"cmd\":\"subscribe\"")
    })
    |> list.flat_map(fn(frame) {
      let id = page_fixture.request_id(frame)
      case string.contains(frame, "\"cmd\":\"catch_up\"") {
        True -> page_fixture.catch_up(id, "operator")
        False -> [page_fixture.refusal(id)]
      }
    })

  page_fixture.run(model, component.update, [component.Arrived(answers)])
}

pub fn no_jobs_are_read_before_an_interval_has_passed_test() {
  let clock = page_fixture.clock()
  let wire = process.new_subject()
  let model = ready(clock, wire, "operator")
  let _ = page_fixture.sent(wire)

  // The first tick, at the moment the page opened, asks for nothing, so the
  // startup reads are the terminal's reads and the page's lane matches it.
  let model = page_fixture.run(model, component.update, [component.Ticked])
  assert live_jobs_reads(page_fixture.sent(wire)) == []

  // Once the interval has passed since it opened, a tick asks once.
  let _ = first_tick(clock, model)
  assert list.length(live_jobs_reads(page_fixture.sent(wire))) == 1
}

pub fn a_tick_reads_the_jobs_once_per_interval_test() {
  let clock = page_fixture.clock()
  let wire = process.new_subject()
  let model = ready(clock, wire, "operator")
  let _ = page_fixture.sent(wire)

  // The first tick asks, and names the strand the page shows.
  let model = first_tick(clock, model)
  let asked = live_jobs_reads(page_fixture.sent(wire))
  assert list.length(asked) == 1
  let assert [read] = asked as "one read"
  assert string.contains(read, "\"strand\":\"main\"")

  // The answer fills the row, whatever the browser sees of the command.
  let model =
    page_fixture.run(model, component.update, [
      component.Arrived([jobs_frame(page_fixture.request_id(read), "sleep 10")]),
    ])
  assert string.contains(operator(model), "1 live")
  assert string.contains(operator(model), "job-1 · running · started by op-1")

  // A tick inside the interval asks for nothing; one after it asks again.
  let model = page_fixture.run(model, component.update, [component.Ticked])
  let frames = page_fixture.sent(wire)
  assert live_jobs_reads(frames) == []
  let model = refused(model, frames)
  page_fixture.set(clock, 2 * component.jobs_refresh_ms)
  let _ = page_fixture.run(model, component.update, [component.Ticked])
  assert list.length(live_jobs_reads(page_fixture.sent(wire))) == 1
}

pub fn a_refused_read_is_not_repeated_on_every_tick_test() {
  let clock = page_fixture.clock()
  let wire = process.new_subject()
  let model = ready(clock, wire, "operator")
  let _ = page_fixture.sent(wire)

  let model = first_tick(clock, model)
  let asked = page_fixture.sent(wire)
  assert list.length(live_jobs_reads(asked)) == 1
  let model = refused(model, asked)

  let model = page_fixture.run(model, component.update, [component.Ticked])
  let frames = page_fixture.sent(wire)
  assert live_jobs_reads(frames) == []
  assert string.contains(operator(model), "not read yet")
  let model = refused(model, frames)

  // The refusal cleared the outstanding ask, so once the interval has passed
  // the next tick asks exactly once more.
  page_fixture.set(clock, 2 * component.jobs_refresh_ms)
  let _ = page_fixture.run(model, component.update, [component.Ticked])
  assert list.length(live_jobs_reads(page_fixture.sent(wire))) == 1
}

pub fn a_job_command_on_a_page_is_escaped_test() {
  let clock = page_fixture.clock()
  let wire = process.new_subject()
  let model = ready(clock, wire, "operator")
  let _ = page_fixture.sent(wire)
  let model = first_tick(clock, model)
  let assert [read] = live_jobs_reads(page_fixture.sent(wire)) as "one read"
  let model =
    page_fixture.run(model, component.update, [
      component.Arrived([
        jobs_frame(page_fixture.request_id(read), "<script>alert(1)</script>"),
      ]),
    ])

  list.each([operator(model), observer(model)], fn(html) {
    assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
    assert !string.contains(html, "<script")
  })
}

fn peers() -> List(snapshot_view.Peer) {
  [
    snapshot_view.Peer(
      "connection",
      message.Origin("alice", "Alice"),
      snapshot.Operator,
    ),
    snapshot_view.Peer(
      "watcher",
      message.Origin("bob", "Bob <i>the watcher</i>"),
      snapshot.Observer,
    ),
  ]
}

pub fn an_operators_page_names_its_viewers_and_an_observers_does_not_test() {
  let model =
    component.new(page_fixture.start())
    |> component.apply([
      lane_fixture.attended(lane_fixture.captured(10, None), peers()),
    ])

  let operating = operator(model)
  assert string.contains(operating, "2 attached")
  assert string.contains(operating, "Alice")
  assert string.contains(operating, " · operator · you")
  assert string.contains(operating, "Bob &lt;i&gt;the watcher&lt;/i&gt;")
  assert !string.contains(operating, "<i>the watcher")

  // The observer's page holds the same roster and shows none of it.
  let observing = observer(model)
  assert !string.contains(observing, "Viewers")
  assert !string.contains(observing, "attached")
  assert !string.contains(observing, "the watcher")
}
