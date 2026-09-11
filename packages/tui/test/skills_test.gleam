//// Loaded skills use the same palette, authority and attachment lifecycle.

import core/json
import etui/backend
import etui/widgets/textarea
import gleam/list
import gleam/option.{None}
import tui
import tui/command
import tui/connection
import tui/skills
import tui/workspace

pub fn skill_completion_preserves_builtin_precedence_and_arguments_test() {
  let rows = [
    command.Suggestion("/review-code", "Inspect code", True),
    command.Suggestion("/help", "Shadow", True),
  ]
  assert command.suggestions_with_skills("/review", rows)
    == [command.Suggestion("/review-code", "Inspect code", True)]
  assert list.length(command.suggestions_with_skills("/help", rows)) == 1
  assert command.parse_with_skills("/help", rows) == command.Help
  assert command.parse_with_skills("/review-code a file", rows)
    == command.Prompt("/review-code a file")
  assert command.suggestions_with_skills("/review-code a", rows) == []
  assert command.parse_with_skills("/review-code\n", rows)
    == command.Prompt("/review-code\n")
}

pub fn disconnected_skill_submission_retains_its_draft_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("test", None))
  let model =
    tui.Model(..base, peer: tui.Disconnected, skills: [
      command.Suggestion("/review-code", "Inspect code", True),
    ])
  let updated =
    model
    |> tui.update(backend.Paste("/review-code the queue"), _)
    |> tui.update(backend.KeyPress("enter"), _)
  assert textarea.value(updated.input) == "/review-code the queue"
  assert updated.notice == "no conversation is attached; draft retained"
}

pub fn skill_page_cannot_loop_or_exceed_its_catalogue_bound_test() {
  let base = [#("offset", json.Int(0)), #("skills", json.Array([]))]
  let assert Error(_) =
    skills.decode(json.Object([#("next", json.Int(0)), ..base]))
    as "an empty page cannot point back to itself"
  let assert Error(_) =
    skills.decode(json.Object([#("next", json.Int(1)), ..base]))
    as "a cursor cannot skip unreturned commands"
  assert skills.decode(json.Object([#("next", json.Null), ..base]))
    == Ok(skills.Page(0, [], None))
}
