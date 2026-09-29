//// The words on a strand's card: one status line, the badge's count of
//// strands waiting for a decision, and the context size a strand's own view
//// shows.

import gleam/option.{type Option, None, Some}
import session_view/agent_roster.{type Line, Line}
import session_view/agent_view
import session_view/strand_card

fn line(status: agent_view.Status, text: String, elapsed: Option(Int)) -> Line {
  Line(
    id: "sub:main/tests",
    name: "sub:tests",
    status:,
    text:,
    title: "",
    elapsed_s: elapsed,
    tokens: None,
  )
}

// A strand that needs a decision says so in fixed words, whatever its
// activity text holds: the request is the approval card's to show.
pub fn a_strand_that_needs_a_decision_says_only_that_test() {
  assert strand_card.status_line(line(
      agent_view.NeedsInput,
      "Approval required",
      None,
    ))
    == "Needs approval"
  assert strand_card.status_line(line(
      agent_view.NeedsInput,
      "bash: rm -rf /",
      Some(4),
    ))
    == "Needs approval"
}

pub fn a_working_strand_adds_its_activity_after_its_word_test() {
  assert strand_card.status_line(line(agent_view.Working, "code_mode", None))
    == "Working · code_mode"
  assert strand_card.status_line(line(agent_view.Waiting, "retrying", None))
    == "Waiting · retrying"
  assert strand_card.status_line(line(agent_view.Working, "", None))
    == "Working"
}

pub fn a_finished_strand_adds_how_long_it_ran_when_known_test() {
  assert strand_card.status_line(line(agent_view.Finished, "done", Some(72)))
    == "Finished 1m 12s"
  assert strand_card.status_line(line(agent_view.Finished, "done", None))
    == "Finished"
}

pub fn the_other_states_are_their_words_test() {
  assert strand_card.status_line(line(agent_view.Failed, "boom", Some(3)))
    == "Failed"
  assert strand_card.status_line(line(agent_view.Halted, "", None)) == "Halted"
  assert strand_card.status_line(line(agent_view.Idle, "", None)) == "Idle"
  assert strand_card.status_line(line(agent_view.Unavailable, "", None))
    == "Unavailable"
}

// Only a decision is counted: a failed or halted strand needs attention but
// not a person's answer, and the badge is the count of the second.
pub fn the_badge_counts_only_strands_waiting_for_a_decision_test() {
  let lines = [
    line(agent_view.NeedsInput, "", None),
    line(agent_view.Working, "x", None),
    line(agent_view.Failed, "", None),
    line(agent_view.Halted, "", None),
    line(agent_view.NeedsInput, "", None),
  ]
  assert strand_card.needing(lines) == 2
  assert strand_card.needing([]) == 0
}

pub fn the_context_size_is_the_strips_short_count_or_nothing_test() {
  assert strand_card.context_words(Some(950)) == Some("950 tokens")
  assert strand_card.context_words(Some(136_540)) == Some("136.5k tokens")
  assert strand_card.context_words(None) == None
}
