//// The second line of a row under "Watch live": which words a state gets, and
//// that no state is ever said to have ended.

import gleam/option.{None, Some}
import gleam/string
import web_view/sessions
import web_view/watch_rule.{Facts}

fn facts(
  activity: option.Option(sessions.Activity),
  pinned: Int,
  asks: Int,
  review: watch_rule.Review,
  project: option.Option(String),
) -> String {
  watch_rule.words(Facts(activity:, pinned:, asks:, review:, project:))
}

// A working session says it runs, and the rail's count follows while it is above
// none.
pub fn a_working_session_says_running_and_what_is_lifted_test() {
  assert facts(Some(sessions.Working), 2, 0, watch_rule.NothingToRead, None)
    == "running · 2 lifted"
  assert facts(Some(sessions.Working), 0, 0, watch_rule.NothingToRead, None)
    == "running"
}

// A pending approval is the first word whatever else is open, with the count.
pub fn a_pending_approval_says_approval_test() {
  assert facts(Some(sessions.NeedsYou), 1, 0, watch_rule.NothingToRead, None)
    == "approval · 1 lifted"
}

// An open ask puts the project first, or says only `asked` when the catalogue
// found no project.
pub fn an_open_ask_names_the_project_test() {
  assert facts(
      Some(sessions.Idle),
      1,
      1,
      watch_rule.NothingToRead,
      Some("aegis"),
    )
    == "aegis · asked"
  assert facts(Some(sessions.Idle), 1, 1, watch_rule.NothingToRead, None)
    == "asked"
}

// A finished session with changes to read says so, and a quiet one with
// nothing to read is quiet, with its project first.
pub fn a_finished_session_is_to_review_or_quiet_test() {
  assert facts(Some(sessions.Idle), 0, 0, watch_rule.ToRead, Some("loom"))
    == "finished · to review"
  assert facts(
      Some(sessions.Idle),
      0,
      0,
      watch_rule.NothingToRead,
      Some("aegis"),
    )
    == "aegis · quiet"
  assert facts(None, 0, 0, watch_rule.NothingToRead, None) == "quiet"
}

// No state is ever worded as an ending.
pub fn no_state_says_ended_test() {
  let every = [
    facts(Some(sessions.Failed), 0, 0, watch_rule.NothingToRead, None),
    facts(Some(sessions.Idle), 0, 0, watch_rule.ToRead, None),
    facts(Some(sessions.Idle), 0, 0, watch_rule.NothingToRead, None),
    facts(None, 0, 0, watch_rule.NothingToRead, Some("x")),
  ]
  assert !string.contains(string.join(every, " "), "ended")
}
