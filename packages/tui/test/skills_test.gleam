//// Loaded skills use the same palette, authority and attachment lifecycle.

import core/json
import etui/backend
import etui/widgets/textarea
import gleam/list
import gleam/option.{None}
import session_view/command
import session_view/model as session_model
import session_view/shared_set
import session_view/skills
import tui
import tui/connection
import tui/model as tui_model
import tui/workspace

pub fn skill_completion_preserves_builtin_precedence_and_arguments_test() {
  let rows = [
    command.Suggestion("/review-code", "Inspect code", True),
    command.Suggestion("/help", "Shadow", True),
  ]
  assert command.suggestions_with_skills("/review", rows)
    == [command.Suggestion("/review-code", "Inspect code", True)]
  assert list.length(command.suggestions_with_skills("/help", rows)) == 1
  assert command.parse_with_skills("/help", rows)
    == command.Surface(command.Help)
  assert command.parse_with_skills("/review-code a file", rows)
    == command.Session(command.Prompt("/review-code a file"))
  assert command.suggestions_with_skills("/review-code a", rows) == []
  assert command.parse_with_skills("/review-code\n", rows)
    == command.Session(command.Prompt("/review-code\n"))
}

pub fn disconnected_skill_submission_retains_its_draft_test() {
  let base =
    tui.new_model(connection.new_inbox(), workspace.Context("test", None))
  let model =
    tui_model.Model(
      ..base,
      shared: base.shared
        |> shared_set.peer(session_model.Disconnected)
        |> shared_set.skills([
          command.Suggestion("/review-code", "Inspect code", True),
        ]),
    )
  let updated =
    model
    |> tui.update(backend.Paste("/review-code the queue"), _)
    |> tui.update(backend.KeyPress("enter"), _)
  assert textarea.value(updated.view.input) == "/review-code the queue"
  assert updated.shared.notice == "no conversation is attached; draft retained"
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
