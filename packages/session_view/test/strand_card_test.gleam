//// The words on a strand's card: one status line, the badge's count of
//// strands waiting for a decision, and the context size a strand's own view
//// shows.

import gleam/option.{type Option, None, Some}
import gleam/string
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

// The engine's phase words are not a person's: `assistant` is the model
// generating, and a state word the activity already says is not said twice.
pub fn the_engines_words_are_a_persons_words_test() {
  assert strand_card.status_line(line(agent_view.Working, "assistant", None))
    == "Working · thinking"
  assert strand_card.status_line(line(agent_view.Working, "tool", None))
    == "Working"
  assert strand_card.status_line(line(agent_view.Working, "Working", None))
    == "Working"
  assert strand_card.status_line(line(
      agent_view.Waiting,
      "Waiting for update-readme-power",
      None,
    ))
    == "Waiting for update-readme-power"
}

// A tool's activity is `name · command`: the card names the tool, and the
// whole text is the card's tooltip, cut to the limit.
pub fn a_tool_is_named_and_its_command_is_the_tooltip_test() {
  let busy =
    line(agent_view.Working, "bash · printf 'hi' > /Users/x/notes.txt", None)
  assert strand_card.status_line(busy) == "Working · bash"
  assert strand_card.status_title(busy)
    == "Working · bash · printf 'hi' > /Users/x/notes.txt"

  // A summary in a person's words has no one-word head, so it stays whole.
  let summary = line(agent_view.Working, "Reading the config · 3 files", None)
  assert strand_card.status_line(summary)
    == "Working · Reading the config · 3 files"

  let long =
    line(agent_view.Working, "bash · " <> string.repeat("x", 400), None)
  assert string.length(strand_card.status_title(long))
    == strand_card.title_limit
  assert strand_card.status_title(line(agent_view.Finished, "done", Some(72)))
    == "Finished 1m 12s"
}

pub fn each_state_has_a_glyph_and_a_model_a_short_name_test() {
  assert strand_card.glyph(agent_view.Working) == "●"
  assert strand_card.glyph(agent_view.Finished) == "✓"
  assert strand_card.glyph(agent_view.Waiting) == "◌"
  assert strand_card.model_name("zai-org/GLM-5.3") == "GLM-5.3"
  assert strand_card.model_name("kimi-k3") == "kimi-k3"
  assert strand_card.model_name("odd/") == "odd/"
}

// The roster words a task it cannot read as a placeholder, which a strand's
// view leaves out rather than show as the task.
pub fn a_placeholder_is_not_a_task_test() {
  assert strand_card.task_words("Fix the parser") == Some("Fix the parser")
  assert strand_card.task_words("") == None
  assert strand_card.task_words("Task unavailable") == None
  assert strand_card.task_words("Task brief outside loaded history") == None
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
