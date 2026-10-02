//// The agent workspace and the strip, read off whole frames at 120 and 80
//// columns. Both draw an agent as one `agent_row` row, so these tests pin
//// the shape they share (aligned columns, one raised bar for the cursor,
//// names cut in the middle so twins stay apart) and what each adds: the
//// workspace's attention order, filter and labelled detail, and the
//// strip's figures lined up at the right edge.

import etui/buffer
import etui/geometry
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/agent_messages
import session_view/agent_roster
import session_view/agent_view
import tui/agent_row
import tui/agent_strip
import tui/agents
import tui/frame
import tui/theme

const docs = "sub:main/docs-accuracy-review-9e21bb44aa00cc11"

const grep = "sub:main/grep-refs-1c2d3e4f5a6b7c8d"

const lint = "sub:main/lint-pass-0a0b0c0d0e0f1011"

const review = "sub:main/adversarial-code-review-48f3a1b2c3d4e5f6"

const task =
  "Check doc comments against behaviour in docs/architecture and report drifted citations."

fn agent(id: String, status: agent_view.Status, activity: String) {
  agent_view.Row(
    id:,
    name: id,
    operation: Some("op-" <> id),
    status:,
    task:,
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

// Six agents in roster order, which is not attention order: the finished
// and working ones come before the two that need the operator.
fn rows() -> List(agent_view.Row) {
  [
    agent("main", agent_view.Working, "Waiting for 2 reviewers"),
    agent(lint, agent_view.Finished, "Finished"),
    agent(review, agent_view.Working, "Tracing publish_herdr path"),
    agent(grep, agent_view.Failed, "Provider returned 429 after three retries"),
    agent_view.Row(
      ..agent(docs, agent_view.NeedsInput, "Needs approval · fs_write"),
      approvals: ["approval-1"],
      decision: "fs_write docs/next.md",
      pending: "1 received, awaiting delivery",
      recent: ["read", "read", "read", "grep", "fs_write"],
    ),
    agent("advisor", agent_view.Working, "Reviewing main's plan"),
  ]
}

fn roster() -> agent_roster.Roster {
  let now = 1_000_000
  let figures = [
    #("main", 94, 259_000),
    #(lint, 72, 31_000),
    #(review, 165, 65_000),
    #(grep, 63, 144_000),
    #(docs, 158, 74_000),
  ]
  agent_roster.Roster(
    glances: dict.new(),
    clocks: dict.from_list(
      list.map(figures, fn(entry) {
        #(
          entry.0,
          agent_roster.Clock("op-" <> entry.0, None, entry.1 * 1000, now),
        )
      }),
    ),
    pushed: dict.from_list(
      list.map(figures, fn(entry) { #(entry.0, #("op-" <> entry.0, entry.2)) }),
    ),
    now_ms: now,
  )
}

fn sends() -> List(agent_messages.Item) {
  [
    agent_messages.Item(
      "e2",
      "c2",
      docs,
      "main",
      "Two citations drifted in docs/architecture/terminal.md",
      agent_messages.Complete,
      12,
      agent_messages.Accepted,
      ts: 0,
    ),
  ]
}

fn workspace(width: Int, height: Int, inspector: agents.Inspector) {
  let screen = geometry.rect_new(0, 0, width, height)
  agents.render_inspection(
    buffer.buffer_new(screen),
    screen,
    rows(),
    "main",
    inspector,
    agents.Facts(roster(), sends()),
    None,
  )
}

fn selecting(id: String) -> agents.Inspector {
  agents.Inspector(..agents.inspect("main"), selected: id)
}

fn line_with(lines: List(String), needle: String) -> String {
  let assert Ok(line) = list.find(lines, string.contains(_, needle))
    as "the frame draws the expected text"
  line
}

fn column(line: String, needle: String) -> Int {
  let assert Ok(#(before, _)) = string.split_once(line, needle)
    as "the line holds the needle"
  string.length(before)
}

fn index_of(lines: List(String), needle: String) -> Int {
  let assert Ok(#(index, _)) =
    lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, needle) })
    as "the frame draws the expected text"
  index
}

pub fn the_list_is_in_attention_order_after_main_test() {
  let lines = workspace(120, 40, selecting(docs)) |> frame.buffer_to_lines
  let order =
    ["● main", "? docs-accuracy", "× grep-refs", "● adversarial", "✓ lint-pass"]
    |> list.map(index_of(lines, _))
  assert order == list.sort(order, int.compare)
  assert index_of(lines, "◆ advisor") > index_of(lines, "✓ lint-pass")
}

pub fn wide_workspace_aligns_its_columns_and_labels_its_detail_test() {
  let lines = workspace(120, 40, selecting(docs)) |> frame.buffer_to_lines
  let main = line_with(lines, "● main")
  let failed = line_with(lines, "× grep-refs")
  let needs = line_with(lines, "▸ ? docs-accuracy-review")

  // The action, time and context columns line up across rows.
  assert column(main, "Waiting") == column(failed, "Provider")
  assert column(main, "1m34") == column(needs, "2m38")
  assert column(main, "259k") == column(failed, "144k")
  assert string.contains(failed, "Provider returned 429…")

  // The detail is labelled sections beside the list, each said once.
  assert string.contains(line_with(lines, " 1 Activity "), "4 Collab")
  assert string.contains(
    line_with(lines, "needs input ·"),
    "needs input · 2m 38s · 74k ctx · Kimi-K3",
  )
  assert string.contains(line_with(lines, "TASK"), "TASK")
  assert string.contains(line_with(lines, "Needs approval:"), "fs_write")
  assert string.contains(line_with(lines, "a reviews"), "the exact request")
  assert string.contains(line_with(lines, "LATEST MESSAGES"), "LATEST")
  assert string.contains(line_with(lines, "→ main"), "Two citations")
  assert string.contains(line_with(lines, "INBOX"), "1 received")
  assert string.contains(line_with(lines, "TOOLS"), "read ×3 · grep · fs_write")
  assert list.count(lines, string.contains(_, "Needs approval:")) == 1
  assert string.contains(
    line_with(lines, "To: main"),
    "To: main · Enter opens the selected transcript",
  )
  assert string.contains(
    line_with(lines, "AGENT WORKSPACE"),
    "6 agents · 3 working · 2 need you",
  )
  assert list.all(lines, fn(line) { string.length(line) <= 120 })
}

pub fn a_failed_agent_leads_with_its_error_once_test() {
  let lines = workspace(120, 40, selecting(grep)) |> frame.buffer_to_lines
  assert string.contains(line_with(lines, "× Provider returned 429"), "after")
  assert string.contains(line_with(lines, "Enter opens its transcript"), "the")
  assert string.contains(line_with(lines, "repeated here"), "not repeated here")
  assert string.contains(line_with(lines, "failed ·"), "1m 03s · 144k ctx")
}

pub fn narrow_workspace_stacks_the_detail_under_the_list_test() {
  let lines = workspace(80, 24, selecting(grep)) |> frame.buffer_to_lines
  let rule = index_of(lines, "│ ────────────")
  assert index_of(lines, "▸ × grep-refs") < rule
  assert index_of(lines, "1 Activity   2 Messages") == rule + 1
  assert index_of(lines, "failed · 1m 03s") > rule
  assert index_of(lines, "NOW") > rule
  assert !list.any(lines, string.contains(_, "LATEST MESSAGES"))
  assert string.contains(line_with(lines, "Esc"), "↑↓ · Enter open")
  assert list.all(lines, fn(line) { string.length(line) <= 80 })
}

pub fn the_cursor_row_is_one_raised_bar_test() {
  let buf = workspace(120, 40, selecting(docs))
  let lines = frame.buffer_to_lines(buf)
  let y = index_of(lines, "▸ ? docs-accuracy-review")
  let line = line_with(lines, "▸ ? docs-accuracy-review")
  let start = column(line, "▸") - 1
  let cells =
    list.repeat(Nil, agent_row.table_width)
    |> list.index_map(fn(_, offset) { start + offset })
  assert list.all(cells, fn(x) {
    buffer.cell_bg(buffer.get_cell(buf, geometry.Position(x, y)))
    == theme.raised
  })
}

pub fn tab_cycles_the_filter_and_keeps_a_shown_selection_test() {
  let inspector = selecting(docs)
  let attention = agents.cycle_filter(inspector, rows(), agents.Next)
  assert attention.filter == agents.AttentionAgents
  assert attention.selected == docs
  let lines = workspace(120, 40, attention) |> frame.buffer_to_lines
  assert string.contains(line_with(lines, "NEED YOU"), "2 of 6")
  assert !list.any(lines, string.contains(_, "lint-pass"))

  // A filter that hides the selection selects its own first row.
  let working = agents.cycle_filter(attention, rows(), agents.Next)
  assert working.filter == agents.WorkingAgents
  assert working.selected == "main"
  let settled = agents.cycle_filter(working, rows(), agents.Next)
  assert settled.selected == lint
  assert agents.cycle_filter(settled, rows(), agents.Next).filter
    == agents.AllAgents
  assert agents.cycle_filter(inspector, rows(), agents.Previous).filter
    == agents.SettledAgents
}

pub fn navigation_follows_the_drawn_order_test() {
  let next = agents.navigate(agents.inspect("main"), rows(), agents.Next)
  assert next.selected == docs
  let after = agents.navigate(next, rows(), agents.Next)
  assert after.selected == grep
  assert agents.next_attention(after, rows()).selected == docs
}

// --- the strip ---------------------------------------------------------

fn strip_lines() -> List(agent_roster.Line) {
  let line = fn(id, name, status, text, elapsed, tokens) {
    agent_roster.Line(id, name, status, text, "", elapsed, tokens)
  }
  [
    line(
      "main",
      "main",
      agent_view.Working,
      "Waiting for adversarial-code-review, docs-accuracy-review",
      Some(250),
      Some(259_000),
    ),
    line(
      "sub:main/tests-aa11bb22cc33dd44",
      "tests",
      agent_view.NeedsInput,
      "Needs approval · network",
      Some(34),
      Some(9000),
    ),
    line(
      review,
      "adversarial-code-review",
      agent_view.Working,
      "Tracing quit-path publish_herdr reachability",
      Some(165),
      Some(65_000),
    ),
    line(
      "sub:main/adversarial-code-review-ec14a1b2c3d4e5f6",
      "adversarial-code-review",
      agent_view.Working,
      "Grep-searching herdr:loom references",
      Some(63),
      Some(144_000),
    ),
    line(
      docs,
      "docs-accuracy-review",
      agent_view.Working,
      "Writing an early note before reading herdr.gleam",
      Some(158),
      Some(74_000),
    ),
    line(
      "sub:main/bootstrap-resume-77aa10bb20cc30dd",
      "bootstrap-resume",
      agent_view.Working,
      "Grepping bootstrap.gleam for resume references",
      Some(51),
      Some(119_000),
    ),
    line(
      "advisor",
      "advisor",
      agent_view.Working,
      "Reviewing main's plan · 1 nudge pending",
      Some(18),
      Some(22_000),
    ),
  ]
}

fn strip(width: Int, height: Int, rows: Int, focus: agent_strip.Focus) {
  let screen = geometry.rect_new(0, 0, width, height)
  agent_strip.render(
    buffer.buffer_new(screen),
    geometry.rect_new(0, height - rows, width, rows),
    strip_lines(),
    focus,
    "main",
  )
  |> frame.buffer_to_lines
}

pub fn seven_agents_fit_one_row_each_at_120_test() {
  let lines = strip(120, 40, 7, agent_strip.Composing)
  let main = line_with(lines, "● main")
  let tests = line_with(lines, "? tests")
  let advisor = line_with(lines, "◆ advisor")

  // The figures end at the edge, and their `·` lines up down the strip.
  assert column(main, " · 259k ctx") == column(tests, " ·   9k ctx")
  assert column(main, " · 259k") == column(advisor, " ·  22k")
  assert string.ends_with(main, "259k ctx")
  assert column(main, "Waiting") == column(advisor, "Reviewing")

  // Twins share a slug, so each keeps the head of its digest.
  assert string.contains(line_with(lines, "-48f3"), "adversarial-code-review")
  assert string.contains(line_with(lines, "-ec14"), "adversarial-code-review")
  assert list.all(lines, fn(line) { string.length(line) <= 120 })
}

pub fn the_strip_cuts_twins_in_the_middle_at_80_test() {
  let lines = strip(80, 24, 5, agent_strip.Composing)
  assert list.length(list.filter(lines, fn(line) { line != "" })) == 5
  assert string.contains(line_with(lines, "…-48f3"), "adversarial-code-r")
  assert string.contains(line_with(lines, "…-ec14"), "adversarial-code-r")
  assert string.contains(
    line_with(lines, "+3 more"),
    "+3 more · Down enters the strip · F2 opens the list",
  )
  assert list.all(lines, fn(line) { string.length(line) <= 80 })
}

pub fn the_strip_cursor_is_marked_and_raised_test() {
  let lines =
    strip(120, 40, 7, agent_strip.Browsing("sub:main/tests-aa11bb22cc33dd44"))
  assert string.starts_with(line_with(lines, "? tests"), " ❯ ?")
  assert string.starts_with(line_with(lines, "● main"), " › ●")
}

// --- the shared cuts -----------------------------------------------------

pub fn names_are_cut_in_the_middle_and_actions_at_a_word_test() {
  assert agent_row.cut_middle("adversarial-code-review-48f3", 16)
    == "adversaria…-48f3"
  assert agent_row.cut_middle("main", 16) == "main"
  assert agent_row.cut("Tracing publish_herdr reachability", 24)
    == "Tracing publish_herdr…"
  assert agent_row.cut("Needs approval · network", 18) == "Needs approval…"
  assert agent_row.cut(
      "Two citations drifted in docs/architecture/terminal.md",
      40,
    )
    == "Two citations drifted in docs/architect…"
  assert agent_row.compact_duration(51) == "0m51"
  assert agent_row.compact_duration(3720) == "1h02"
  assert agent_row.compact_count(74_400) == "74k"
  assert agent_row.compact_count(950) == "950"
}

// --- the critique round ----------------------------------------------------

// The workspace is anchored under the identity line and is as tall as what
// it shows, so a short roster does not hang in the middle of an empty frame.
pub fn the_workspace_sits_at_the_top_and_fits_its_content_test() {
  let screen = geometry.rect_new(0, 0, 120, 40)
  let body = geometry.rect_new(0, 1, 120, 39)
  let lines =
    agents.render_inspection(
      buffer.buffer_new(screen),
      body,
      rows(),
      "main",
      selecting(docs),
      agents.Facts(roster(), sends()),
      None,
    )
    |> frame.buffer_to_lines
  assert index_of(lines, "AGENT WORKSPACE") == 1
  let bottom = index_of(lines, "╰")
  assert bottom < 39
  assert bottom > index_of(lines, "To: main")
}

// A list cut by its room says how many agents it hides, as the picker does.
pub fn a_cut_list_counts_what_it_hides_test() {
  let many =
    list.repeat(Nil, 20)
    |> list.index_map(fn(_, index) {
      agent(
        "sub:main/worker-" <> int.to_string(index) <> "-0a0b0c0d",
        agent_view.Working,
        "Working",
      )
    })
  let screen = geometry.rect_new(0, 0, 80, 24)
  let lines =
    agents.render_inspection(
      buffer.buffer_new(screen),
      geometry.rect_new(0, 1, 80, 23),
      [agent("main", agent_view.Working, "Waiting"), ..many],
      "main",
      agents.inspect("main"),
      agents.Facts(roster(), []),
      None,
    )
    |> frame.buffer_to_lines
  assert list.any(lines, string.contains(_, "more below"))
}

// An empty roster says so, rather than blaming a filter that hides nothing.
pub fn an_empty_roster_says_there_are_no_agents_yet_test() {
  let screen = geometry.rect_new(0, 0, 120, 40)
  let lines =
    agents.render_inspection(
      buffer.buffer_new(screen),
      screen,
      [],
      "main",
      agents.inspect("main"),
      agents.no_facts(),
      None,
    )
    |> frame.buffer_to_lines
  assert list.any(lines, string.contains(_, "No agents yet."))
}

// The latest messages read in transcript order, the newest last.
pub fn the_latest_messages_put_the_newest_last_test() {
  let older =
    agent_messages.Item(
      "e1",
      "c1",
      "main",
      docs,
      "Review the docs for drift",
      agent_messages.Complete,
      10,
      agent_messages.Started,
      ts: 0,
    )
  let screen = geometry.rect_new(0, 0, 120, 40)
  let lines =
    agents.render_inspection(
      buffer.buffer_new(screen),
      screen,
      rows(),
      "main",
      selecting(docs),
      agents.Facts(roster(), [list.first(sends()) |> result_or(older), older]),
      None,
    )
    |> frame.buffer_to_lines
  assert index_of(lines, "← main  Review") < index_of(lines, "→ main  Two")
}

fn result_or(value: Result(a, Nil), fallback: a) -> a {
  case value {
    Ok(value) -> value
    Error(Nil) -> fallback
  }
}

// The viewed strand's mark is quiet; only the cursor's mark is amber.
pub fn only_the_cursor_mark_is_amber_in_the_table_test() {
  let buf = workspace(120, 40, selecting(docs))
  let lines = frame.buffer_to_lines(buf)
  let y = index_of(lines, "› ● main")
  let x = column(line_with(lines, "› ● main"), "›")
  assert buffer.cell_fg(buffer.get_cell(buf, geometry.Position(x, y)))
    == theme.quiet
}
