//// `loom project`: what the launcher accepts before it starts any daemon, and
//// what each subcommand prints for the reply it gets. Neither needs a daemon,
//// so both are tested on the parser and on the pure function the runner prints
//// through.

import core/json
import gleam/list
import gleam/string
import session_view/project_board as board
import tui

fn reply(fields: List(#(String, String))) -> json.JsonValue {
  json.Object(list.map(fields, fn(each) { #(each.0, json.String(each.1)) }))
}

fn ticket(stage: String, id: String, title: String) -> json.JsonValue {
  reply([#("stage", stage), #("id", id), #("title", title)])
}

pub fn the_three_subcommands_parse_test() {
  assert tui.launch_project(["init"]) == Ok(tui.ProjectInit)
  assert tui.launch_project(["board"]) == Ok(tui.ProjectBoard)
  assert tui.launch_project(["post", "fix the flaky test"])
    == Ok(tui.ProjectPost("fix the flaky test"))
}

pub fn the_flags_every_local_command_takes_are_accepted_test() {
  assert tui.launch_project(["init", "--config", "loom.toml"])
    == Ok(tui.ProjectInit)
  assert tui.launch_project(["post", "fix it", "--config", "loom.toml"])
    == Ok(tui.ProjectPost("fix it"))
}

pub fn a_refusal_carries_the_usage_test() {
  // A post needs its text, a verb must be one of the three, and a flag the
  // launcher does not know is refused with the same usage.
  let assert Error(missing) = tui.launch_project(["post"])
  assert string.contains(missing, "usage: loom project")
  let assert Error(unknown) = tui.launch_project(["frobnicate"])
  assert string.contains(unknown, "usage: loom project")
  let assert Error(bare) = tui.launch_project([])
  assert string.contains(bare, "usage: loom project")
  let assert Error(flag) = tui.launch_project(["init", "--no-such-flag"])
  assert string.contains(flag, "usage: loom project")
}

pub fn init_prints_the_project_and_its_router_test() {
  let created =
    reply([
      #("project", "p-1a2b3c"),
      #("workspace", "/work/repo"),
      #("router_session", "01a1-router"),
    ])
  assert tui.project_reply_text(tui.ProjectInit, created)
    == "project p-1a2b3c ready for /work/repo; router session 01a1-router"
}

pub fn post_prints_the_trigger_it_made_test() {
  assert tui.project_reply_text(
      tui.ProjectPost("fix a"),
      json.Object([
        #("trigger", json.String("cli-1")),
        #("repeated", json.Bool(False)),
      ]),
    )
    == "posted cli-1"
}

pub fn board_prints_one_line_a_ticket_in_the_order_it_came_test() {
  let board =
    json.Object([
      #(
        "tickets",
        json.Array([
          ticket("person/answer", "t-a", "fix a"),
          ticket("working", "t-b", "fix b"),
        ]),
      ),
    ])
  assert tui.project_reply_text(tui.ProjectBoard, board)
    == "person/answer  t-a  fix a\nworking  t-b  fix b"
}

pub fn board_flattens_a_title_the_router_wrote_test() {
  // A title is model text. It must not break the line it is printed on.
  let board =
    json.Object([
      #(
        "tickets",
        json.Array([ticket("queued", "t-c", "fix\nthe\u{1b}[31m thing")]),
      ),
    ])
  let printed = tui.project_reply_text(tui.ProjectBoard, board)
  assert !string.contains(printed, "\n")
  assert !string.contains(printed, "\u{1b}")
}

pub fn mode_parses_the_three_modes_and_refuses_any_other_word_test() {
  assert tui.launch_project(["mode", "ci", "off"])
    == Ok(tui.ProjectMode("ci", board.ModeOff))
  assert tui.launch_project(["mode", "ci", "observe", "--config", "loom.toml"])
    == Ok(tui.ProjectMode("ci", board.ModeObserve))
  assert tui.launch_project(["mode", "ci", "auto"])
    == Ok(tui.ProjectMode("ci", board.ModeAuto))

  let assert Error(unknown) = tui.launch_project(["mode", "ci", "on"])
  assert string.contains(unknown, "off, observe or auto")
  let assert Error(missing) = tui.launch_project(["mode", "ci"])
  assert string.contains(missing, "usage: loom project")
}

// A verdict is a replay unless `--live` is on the command line, because a live
// run spends model calls.
pub fn verdict_is_a_replay_unless_live_is_asked_for_test() {
  assert tui.launch_project(["verdict", "ci"])
    == Ok(tui.ProjectVerdict("ci", board.Replay))
  assert tui.launch_project(["verdict", "ci", "--live"])
    == Ok(tui.ProjectVerdict("ci", board.Live))
  assert tui.launch_project(["verdict", "ci", "--config", "x.toml", "--live"])
    == Ok(tui.ProjectVerdict("ci", board.Live))

  let assert Error(missing) = tui.launch_project(["verdict"])
  assert string.contains(missing, "usage: loom project")
}

pub fn mode_and_verdict_print_what_happened_test() {
  assert tui.project_reply_text(
      tui.ProjectMode("ci", board.ModeObserve),
      json.Object([]),
    )
    == "rule ci is now observe"

  let finding = json.Object([#("words", json.String("Replay read 30 labels."))])
  assert tui.project_reply_text(tui.ProjectVerdict("ci", board.Replay), finding)
    == "Replay verdict on ci recorded. Replay read 30 labels."

  // A live run says it started and how to watch it, and is not worded as a
  // finding.
  let started =
    json.Object([
      #("state", json.String("running")),
      #("words", json.String("90 trials started.")),
    ])
  let printed =
    tui.project_reply_text(tui.ProjectVerdict("ci", board.Live), started)
  assert string.contains(printed, "Live verdict on ci running.")
  assert string.contains(printed, "90 trials started.")
  assert string.contains(printed, "loom project board --watch")
}

pub fn an_empty_board_says_so_test() {
  assert tui.project_reply_text(tui.ProjectBoard, json.Object([]))
    == "no tickets"
  assert tui.project_reply_text(
      tui.ProjectBoard,
      json.Object([#("tickets", json.Array([]))]),
    )
    == "no tickets"
}
