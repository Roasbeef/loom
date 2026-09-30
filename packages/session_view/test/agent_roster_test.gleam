//// Which strands a strip lists and in what order is one rule both hosts
//// read. The terminal's own tests drive `lines` through its strip
//// (`agent_strip_test`); these pin `chips`, the web view's layout of the same
//// rule: `main` first, working agents after it, the advisor on its own and
//// settled strands listed in reverse row order.

import gleam/list
import gleam/option.{None, Some}
import session_view/agent_roster
import session_view/agent_view

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
  )
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
    row("sub:main/c-7a8b9c", agent_view.Idle),
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
