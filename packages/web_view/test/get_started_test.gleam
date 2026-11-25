//// The "Get started" checklist's rules (docs/design-notes/setup-wizard.md): each
//// step's state is derived from what the page holds, an unheard read is never
//// "not done", a skipped step stops holding the entry, and the hint appears only
//// after both reads have answered, after a first session and before a first
//// project.

import gleam/list
import gleam/option.{None, Some}
import web_view/get_started.{type Facts, Facts}

fn fresh() -> Facts {
  Facts(
    sessions: get_started.Absent,
    listing: get_started.Heard,
    folder: None,
    models: [],
    projects: 0,
    boards: get_started.Heard,
    making: get_started.MayMake,
    skipped: [],
  )
}

fn state_of(facts: Facts, key: get_started.Key) -> get_started.State {
  let assert Ok(step) =
    list.find(get_started.checklist(facts), fn(step) { step.key == key })
    as "every key has a row"

  step.state
}

pub fn a_fresh_daemon_has_five_rows_and_two_open_steps_test() {
  assert list.length(get_started.checklist(fresh())) == 5
  assert state_of(fresh(), get_started.Folder) == get_started.Open
  assert state_of(fresh(), get_started.FirstProject) == get_started.Open
  assert !get_started.finished(fresh())
}

pub fn a_read_that_has_not_answered_is_unread_and_never_not_done_test() {
  let facts =
    Facts(..fresh(), listing: get_started.Unheard, boards: get_started.Unheard)

  assert state_of(facts, get_started.Folder) == get_started.Unread
  assert state_of(facts, get_started.FirstProject) == get_started.Unread
}

pub fn a_step_the_page_cannot_read_is_never_drawn_as_done_or_missing_test() {
  let facts =
    Facts(
      ..fresh(),
      sessions: get_started.Present,
      folder: Some("/w"),
      projects: 1,
    )

  assert state_of(facts, get_started.Worktree) == get_started.Unread
  assert state_of(facts, get_started.Publish) == get_started.Unread
  assert state_of(facts, get_started.Extras) == get_started.Unread
}

pub fn the_entry_stays_while_a_step_is_unread_and_hides_when_each_is_done_or_skipped_test() {
  let done =
    Facts(
      ..fresh(),
      sessions: get_started.Present,
      folder: Some("/w"),
      projects: 1,
    )

  // The three steps the page cannot read hold the entry until they are skipped.
  assert !get_started.finished(done)
  assert get_started.finished(
    Facts(..done, skipped: [
      get_started.Worktree,
      get_started.Publish,
      get_started.Extras,
    ]),
  )
}

pub fn a_skip_reads_as_skipped_and_never_covers_a_done_step_test() {
  let facts =
    Facts(..fresh(), folder: Some("/w"), skipped: [
      get_started.Folder,
      get_started.Publish,
    ])

  assert state_of(facts, get_started.Publish) == get_started.Skipped
  assert state_of(facts, get_started.Folder) == get_started.Done
}

pub fn only_a_step_that_is_not_done_offers_skip_and_the_folder_never_does_test() {
  let steps = get_started.checklist(fresh())
  let offered =
    list.filter(steps, get_started.skippable)
    |> list.map(fn(step) { step.key })

  assert offered
    == [
      get_started.Worktree,
      get_started.FirstProject,
      get_started.Publish,
      get_started.Extras,
    ]
}

pub fn a_page_that_may_not_make_a_project_is_not_held_open_by_it_test() {
  let facts =
    Facts(
      ..fresh(),
      sessions: get_started.Present,
      folder: Some("/w"),
      making: get_started.MayNot,
    )

  assert state_of(facts, get_started.FirstProject) == get_started.NotHere
}

pub fn the_hint_needs_both_reads_a_session_no_project_and_the_capability_test() {
  let ready = Facts(..fresh(), sessions: get_started.Present)

  assert get_started.hint(ready)
  assert !get_started.hint(fresh())
  assert !get_started.hint(Facts(..ready, projects: 1))
  assert !get_started.hint(Facts(..ready, making: get_started.MayNot))
  assert !get_started.hint(Facts(..ready, listing: get_started.Unheard))
  assert !get_started.hint(Facts(..ready, boards: get_started.Unheard))
  assert !get_started.hint(Facts(..ready, skipped: [get_started.FirstProject]))
}

pub fn the_status_line_names_the_models_or_says_none_are_listed_test() {
  assert get_started.model_words(["opus", "flash"])
    == "Models the configuration lists: opus, flash"
  assert get_started.model_words([])
    == "No model is listed in a loom.toml; a session uses the LOOM_* environment variables if they are set."
}
