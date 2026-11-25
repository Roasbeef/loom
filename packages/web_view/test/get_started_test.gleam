//// The "Get started" checklist's rules (docs/design-notes/setup-wizard.md): each
//// step's state is derived from what the page holds, the entry hides when
//// everything the page can read is done, and the hint appears only after a
//// first session and before a first project.

import gleam/list
import gleam/option.{None, Some}
import web_view/get_started.{Facts}

fn state_of(
  facts: get_started.Facts,
  key: get_started.Key,
) -> get_started.State {
  let assert Ok(step) =
    list.find(get_started.checklist(facts), fn(step) { step.key == key })
    as "every key has a row"

  step.state
}

pub fn a_fresh_daemon_has_five_rows_and_two_open_steps_test() {
  let facts = Facts(0, None, [], 0, get_started.MayMake)

  assert list.length(get_started.checklist(facts)) == 5
  assert state_of(facts, get_started.Folder) == get_started.Open
  assert state_of(facts, get_started.FirstProject) == get_started.Open
  assert !get_started.finished(facts)
}

pub fn a_step_the_page_cannot_read_is_never_drawn_as_done_or_missing_test() {
  let facts = Facts(3, Some("/w"), ["opus"], 1, get_started.MayMake)

  assert state_of(facts, get_started.Worktree) == get_started.Unread
  assert state_of(facts, get_started.Publish) == get_started.Unread
  assert state_of(facts, get_started.Extras) == get_started.Unread
}

pub fn the_entry_hides_once_the_readable_steps_are_done_test() {
  assert get_started.finished(Facts(1, Some("/w"), [], 1, get_started.MayMake))
  assert !get_started.finished(Facts(1, Some("/w"), [], 0, get_started.MayMake))
}

pub fn a_page_that_may_not_make_a_project_is_not_held_open_by_it_test() {
  let facts = Facts(1, Some("/w"), [], 0, get_started.MayNot)

  assert state_of(facts, get_started.FirstProject) == get_started.NotHere
  assert get_started.finished(facts)
}

pub fn the_hint_needs_a_session_and_no_project_and_the_capability_test() {
  assert get_started.hint(Facts(1, None, [], 0, get_started.MayMake))
  assert !get_started.hint(Facts(0, None, [], 0, get_started.MayMake))
  assert !get_started.hint(Facts(1, None, [], 1, get_started.MayMake))
  assert !get_started.hint(Facts(1, None, [], 0, get_started.MayNot))
}

pub fn the_status_line_names_the_models_or_says_none_are_listed_test() {
  assert get_started.model_words(["opus", "flash"])
    == "Models the configuration lists: opus, flash"
  assert get_started.model_words([])
    == "No model is listed in a loom.toml; a session uses the LOOM_* environment variables if they are set."
}
