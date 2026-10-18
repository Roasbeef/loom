//// Which strands a strip lists and in what order is one rule both hosts
//// read. The terminal's own tests drive `lines` through its strip
//// (`agent_strip_test`); these pin `chips`, the web view's layout of the same
//// rule: `main` first, working agents after it, the advisor on its own and
//// settled strands listed in reverse row order.

import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/agent_roster
import session_view/agent_view
import session_view/remote_agent

fn row(id: String, status: agent_view.Status) -> agent_view.Row {
  agent_view.Row(
    id:,
    name: id,
    operation: None,
    status:,
    task: "",
    activity: agent_view.label(status),
    update: "",
    update_entry: None,
    pending: "",
    approvals: [],
    model: "",
    recent: [],
    decision: "",
    placement: None,
  )
}

// A strand that has run an operation, which is what a settled strand has.
fn ran(id: String, status: agent_view.Status) -> agent_view.Row {
  agent_view.Row(..row(id, status), operation: Some("op-1"))
}

fn ids(lines: List(agent_roster.Line)) -> List(String) {
  case lines {
    [] -> []
    [first, ..rest] -> [first.id, ..ids(rest)]
  }
}

pub fn chips_lead_with_main_and_fold_settled_strands_test() {
  let rows = [
    row("sub:main/tests-1a2b3c", agent_view.Working),
    row("advisor", agent_view.Idle),
    row("main", agent_view.Working),
    row("sub:main/lint-4d5e6f", agent_view.Finished),
    row("sub:main/review-0a0b0c", agent_view.NeedsInput),
  ]
  let chips = agent_roster.chips(agent_roster.new(), rows, "main")
  assert ids(chips.listed)
    == ["main", "sub:main/tests-1a2b3c", "sub:main/review-0a0b0c"]
  let assert Some(advisor) = chips.advisor
  assert advisor.id == "advisor"
  assert ids(chips.settled) == ["sub:main/lint-4d5e6f"]
}

pub fn settled_strands_are_listed_in_reverse_row_order_test() {
  let rows = [
    row("main", agent_view.Idle),
    row("sub:main/a-1a2b3c", agent_view.Finished),
    row("sub:main/b-4d5e6f", agent_view.Failed),
    ran("sub:main/c-7a8b9c", agent_view.Idle),
  ]
  let chips = agent_roster.chips(agent_roster.new(), rows, "main")
  assert ids(chips.settled)
    == ["sub:main/c-7a8b9c", "sub:main/b-4d5e6f", "sub:main/a-1a2b3c"]
}

pub fn the_active_strand_is_listed_and_not_settled_test() {
  let rows = [
    row("main", agent_view.Idle),
    row("sub:main/a-1a2b3c", agent_view.Finished),
  ]
  let chips = agent_roster.chips(agent_roster.new(), rows, "sub:main/a-1a2b3c")
  assert ids(chips.listed) == ["main", "sub:main/a-1a2b3c"]
  assert chips.settled == []
}

pub fn the_listed_chips_are_the_strip_lines_test() {
  let rows = [
    row("main", agent_view.Idle),
    row("sub:main/a-1a2b3c", agent_view.Waiting),
    row("sub:main/b-4d5e6f", agent_view.Failed),
  ]
  let roster = agent_roster.new()
  assert agent_roster.chips(roster, rows, "main").listed
    == agent_roster.lines(roster, rows, "main")
}

pub fn geometry_counts_the_same_members_as_painting_test() {
  let statuses = [
    agent_view.Working, agent_view.Waiting, agent_view.NeedsInput,
    agent_view.Halted, agent_view.Finished, agent_view.Failed, agent_view.Idle,
    agent_view.Unavailable,
  ]
  list.each(statuses, fn(status) {
    let rows = [
      row("main", status),
      row("advisor", status),
      row("sub:main/a", status),
      row("sub:main/b", agent_view.Idle),
    ]
    list.each(["main", "advisor", "sub:main/a", "sub:main/b"], fn(active) {
      let lines = agent_roster.lines(agent_roster.new(), rows, active)
      assert agent_roster.listed_count(rows, active) == list.length(lines)
    })
  })
  assert agent_roster.listed_count([], "main") == 0
}

pub fn a_capture_without_an_advisor_has_no_advisor_chip_test() {
  let chips =
    agent_roster.chips(
      agent_roster.new(),
      [row("main", agent_view.Idle)],
      "main",
    )
  assert chips.advisor == None
  assert chips.settled == []
}

// A fork that has not run is idle and has no operation: it waits for its
// first prompt, so the strip lists it as a card. One that ran and is idle
// again has an operation and is settled.
pub fn a_strand_that_never_ran_is_listed_and_one_that_ran_is_not_test() {
  let rows = [
    row("main", agent_view.Idle),
    row("sub:main/docs", agent_view.Idle),
    ran("sub:main/old-1a2b3c", agent_view.Idle),
  ]
  let chips = agent_roster.chips(agent_roster.new(), rows, "main")

  assert ids(chips.listed) == ["main", "sub:main/docs"]
  assert ids(chips.settled) == ["sub:main/old-1a2b3c"]
  assert agent_roster.listed_count(rows, "main") == 2
}

// --- children on other orchestrators (protocol-change/090) -------------------

fn remote(
  standing: remote_agent.Standing,
  summary: String,
  age_ms: Option(Int),
) -> remote_agent.RemoteAgent {
  remote_agent.RemoteAgent(
    id: "sub:^main/build-turn-1-0",
    parent: "main",
    orchestrator: "box",
    standing:,
    title: "build the release",
    summary:,
    tokens: 12_400,
    model: "fast",
    age_ms:,
  )
}

// A child on another orchestrator has no strand here, so its row comes from the
// daemon's list and carries the orchestrator as its placement. It is listed
// beside the capture's rows while it runs, with the glance's words and tokens.
pub fn a_running_remote_child_is_listed_with_its_placement_test() {
  let roster =
    agent_roster.new()
    |> agent_roster.observe_remote(
      [remote(remote_agent.Running, "compiling the tests", Some(2000))],
      10_000,
    )
  let rows =
    list.append(
      [row("main", agent_view.Working)],
      agent_roster.remote_rows(roster),
    )
  let assert [main, child] = agent_roster.lines(roster, rows, "main")
  assert main.placement == None
  assert child.id == "sub:^main/build-turn-1-0"
  assert child.placement == Some("box")
  assert child.status == agent_view.Working
  assert child.text == "compiling the tests"
  assert child.title == "build the release"
  assert child.tokens == Some(12_400)
  assert child.age_s == Some(2)
}

// The age keeps growing on the host's own clock while no new list arrives, as
// it does while the parent's daemon cannot reach the orchestrator: the strip
// shows the last glance and how old it is, and nothing is asked of anyone.
pub fn a_remote_childs_glance_ages_on_the_hosts_clock_test() {
  let roster =
    agent_roster.new()
    |> agent_roster.observe_remote(
      [remote(remote_agent.Running, "compiling", Some(1000))],
      10_000,
    )
  let #(later, _) = agent_roster.tick(roster, 70_000)
  let assert [line] =
    agent_roster.lines(later, agent_roster.remote_rows(later), "main")
  assert line.age_s == Some(61)
}

// A remote child with no summary yet says where it stands, and a settled one
// leaves the listed chips for the settled ones, as a local strand does.
pub fn a_remote_childs_standing_is_worded_when_it_has_no_summary_test() {
  let starting = remote(remote_agent.Starting, "", None)
  assert agent_roster.remote_row(starting).activity == "Starting on box"
  assert agent_roster.remote_row(starting).status == agent_view.Waiting

  let roster =
    agent_roster.new()
    |> agent_roster.observe_remote(
      [remote(remote_agent.Completed, "", None)],
      0,
    )
  let chips =
    agent_roster.chips(
      roster,
      [row("main", agent_view.Idle), ..agent_roster.remote_rows(roster)],
      "main",
    )
  assert ids(chips.listed) == ["main"]
  assert ids(chips.settled) == ["sub:^main/build-turn-1-0"]
}

// The list's wire form is total and bounded: what the daemon encodes decodes to
// the same entries, and an unknown standing is refused rather than drawn.
pub fn a_remote_children_list_round_trips_and_refuses_damage_test() {
  let agents = [remote(remote_agent.Running, "x", Some(5))]
  let fields = [
    #("remote_children", json.Array(list.map(agents, remote_agent.encode))),
  ]
  assert remote_agent.decode_all(fields) == Ok(agents)
  let assert json.Object(damaged) =
    remote_agent.encode(remote(remote_agent.Running, "x", None))
  let damaged =
    json.Object(list.key_set(damaged, "standing", json.String("dancing")))
  let assert Error(_) =
    remote_agent.decode_all([#("remote_children", json.Array([damaged]))])
}
