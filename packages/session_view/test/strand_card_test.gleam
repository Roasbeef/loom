//// The words on a strand's card, and the badge's count of strands waiting
//// for a decision.

import gleam/list
import gleam/option.{None}
import session_view/agent_roster.{type Line, Line}
import session_view/agent_view
import session_view/strand_card

fn line(status: agent_view.Status) -> Line {
  Line(
    id: "sub:main/tests",
    name: "sub:tests",
    status:,
    text: "",
    title: "",
    elapsed_s: None,
    tokens: None,
  )
}

// A strand that needs a decision says what to do, not only the state.
pub fn a_strand_that_needs_a_decision_says_what_to_do_test() {
  assert strand_card.word(agent_view.NeedsInput) == "Needs approval"
}

// Every other state keeps the label the rest of the roster uses, so the
// terminal and the page do not word one state two ways.
pub fn the_other_states_keep_their_labels_test() {
  list.each(
    [
      agent_view.Working,
      agent_view.Waiting,
      agent_view.Finished,
      agent_view.Failed,
      agent_view.Halted,
      agent_view.Idle,
      agent_view.Unavailable,
    ],
    fn(status) {
      assert strand_card.word(status) == agent_view.label(status)
    },
  )
}

// Only a decision is counted: a failed or halted strand needs attention but
// not a person's answer, and the badge is the count of the second.
pub fn the_badge_counts_only_strands_waiting_for_a_decision_test() {
  let lines = [
    line(agent_view.NeedsInput),
    line(agent_view.Working),
    line(agent_view.Failed),
    line(agent_view.Halted),
    line(agent_view.NeedsInput),
  ]
  assert strand_card.needing(lines) == 2
  assert strand_card.needing([]) == 0
}
