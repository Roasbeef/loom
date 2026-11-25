//// The moves of the page that makes a project (`web_view/project_create`):
//// which presses a step takes, which answers it drops, and what a refusal keeps.

import core/json
import gleam/option.{None, Some}
import web_view/creations
import web_view/project_create.{
  Choosing, Creating, Creation, Done, Reading, Reviewing,
}
import web_view/projects

fn proposal() -> projects.Proposal {
  projects.Proposed(
    json.Object([
      #(
        "check",
        json.Object([
          #("command", json.String("make check")),
          #("because", json.String("the Makefile has a check target")),
        ]),
      ),
      #("setup", json.Null),
      #("notes", json.Array([])),
    ]),
  )
}

fn reviewing() -> project_create.Creation {
  project_create.open()
  |> project_create.chose("/work/loom")
  |> project_create.proposal_heard("/work/loom", proposal())
}

// An empty choice is no choice, and a choice during a read or after the project
// exists changes nothing.
pub fn only_a_choosing_or_reviewing_step_takes_a_choice_test() {
  assert project_create.chose(project_create.open(), "  ")
    == project_create.open()

  let reading = project_create.chose(project_create.open(), " /work/loom ")
  assert reading == Creation(Reading("/work/loom"))
  assert project_create.chose(reading, "/work/other") == reading

  let done = Creation(Done("p1", "/work/loom", None))
  assert project_create.chose(done, "/work/other") == done
}

// The proposal fills both boxes, and an answer for another folder is dropped.
pub fn a_proposal_for_the_folder_being_read_fills_the_boxes_test() {
  let reading = project_create.chose(project_create.open(), "/work/loom")

  assert project_create.proposal_heard(reading, "/work/other", proposal())
    == reading

  let assert Creation(Reviewing(check:, setup:, notice: None, ..)) =
    project_create.proposal_heard(reading, "/work/loom", proposal())
  assert check == "make check"
  assert setup == ""
}

// A refused folder returns to the choice with the fixed words for the reason.
pub fn a_refused_folder_returns_to_the_choice_test() {
  let reading = project_create.chose(project_create.open(), "/etc")

  assert project_create.proposal_heard(
      reading,
      "/etc",
      projects.ProposalRefused(creations.OutsideHome),
    )
    == Creation(Choosing(Some(creations.reason_words(creations.OutsideHome))))
}

// A proposal body that is not the daemon's shape is said in words and not drawn.
pub fn a_body_that_does_not_decode_returns_to_the_choice_test() {
  let reading = project_create.chose(project_create.open(), "/work/loom")
  let assert Creation(Choosing(Some(_))) =
    project_create.proposal_heard(
      reading,
      "/work/loom",
      projects.Proposed(json.Null),
    )
}

// A blank command stores nothing for its key, and a command past the limit is
// refused before the daemon is asked, keeping both boxes as typed.
pub fn confirming_trims_blanks_and_bounds_commands_test() {
  let assert Ok(#(Creation(Creating(check:, ..)), Some("make test"), None)) =
    project_create.confirmed(reviewing(), " make test ", "  ")
  assert check == " make test "

  let long = string_of(project_create.command_limit + 1)
  let assert Error(Creation(Reviewing(notice: Some(_), ..))) =
    project_create.confirmed(reviewing(), long, "")

  assert project_create.confirmed(project_create.open(), "a", "b")
    == Error(project_create.open())
}

fn string_of(count: Int) -> String {
  case count {
    0 -> ""
    _ -> "x" <> string_of(count - 1)
  }
}

// A refusal keeps what was typed; an answer for another folder changes nothing.
pub fn a_refused_creation_keeps_what_was_typed_test() {
  let assert Ok(#(creating, _, _)) =
    project_create.confirmed(reviewing(), "make verify", "make deps")

  assert project_create.settled(
      creating,
      "/work/other",
      projects.MakeFailed("no"),
    )
    == creating

  let assert Creation(Reviewing(check:, setup:, notice: Some("no"), ..)) =
    project_create.settled(creating, "/work/loom", projects.MakeFailed("no"))
  assert check == "make verify"
  assert setup == "make deps"
}
