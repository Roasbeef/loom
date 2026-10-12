//// The replay is a script with one branch, and these tests hold the branch
//// to what the page promises: playback stops at the approval dialog, the
//// visitor's answer changes the steps after it, and every link into a figure
//// names a step that exists.

import gleam/list
import gleam/option.{None, Some}
import site/figure
import site/figures
import site/msg.{AllowOnce, AllowSession, Deny}
import site/replay.{Underneath}

pub fn the_script_has_eight_steps_test() {
  assert list.length(replay.steps()) == 8
  assert replay.last() == 7
}

pub fn every_step_has_a_unique_chip_and_some_text_test() {
  let chips = list.map(replay.steps(), fn(step) { step.chip })
  assert list.unique(chips) == chips
  list.each(replay.steps(), fn(step) {
    assert step.title != ""
    assert step.body(None) != ""
    assert step.dwell_ms > 0
  })
}

pub fn playback_stops_at_the_dialog_until_there_is_an_answer_test() {
  assert replay.waiting(replay.gate, None)
  assert !replay.waiting(replay.gate, Some(Deny))
  assert !replay.waiting(replay.gate - 1, None)
  assert replay.next_index(replay.gate, None) == replay.gate
  assert replay.next_index(replay.gate - 1, None) == replay.gate
  assert replay.next_index(replay.gate, Some(AllowOnce)) == replay.gate + 1
}

pub fn playback_stops_at_the_last_step_test() {
  assert replay.next_index(replay.last(), Some(Deny)) == replay.last()
}

pub fn the_reader_cannot_step_past_the_dialog_before_answering_test() {
  assert replay.furthest(None) == replay.gate
  assert replay.furthest(Some(AllowSession)) == replay.last()
}

pub fn every_answer_changes_the_steps_after_the_dialog_test() {
  // The transcript up to the end differs for all three answers.
  let once = replay.lines(replay.last(), Some(AllowOnce))
  let session = replay.lines(replay.last(), Some(AllowSession))
  let denied = replay.lines(replay.last(), Some(Deny))
  assert once != session
  assert once != denied
  assert session != denied
}

pub fn every_answer_changes_the_explanation_of_the_run_step_test() {
  let run = replay.gate + 1
  let once = replay.body(run, Some(AllowOnce))
  let session = replay.body(run, Some(AllowSession))
  let denied = replay.body(run, Some(Deny))
  assert once != session
  assert once != denied
  assert session != denied
}

pub fn the_dialog_step_names_the_refusal_before_the_answer_test() {
  let before = replay.lines(replay.gate, None)
  let after = replay.lines(replay.gate, Some(Deny))
  assert list.length(after) == list.length(before) + 1
}

pub fn steps_before_the_dialog_do_not_depend_on_the_answer_test() {
  list.each(list.take([0, 1, 2, 3, 4, 5, 6, 7], replay.gate), fn(index) {
    assert replay.lines(index, None) == replay.lines(index, Some(Deny))
    assert replay.body(index, None) == replay.body(index, Some(Deny))
  })
}

pub fn links_into_the_figures_name_real_steps_test() {
  list.each(replay.steps(), fn(step) {
    case step.underneath {
      None -> Nil
      Some(Underneath(figure_id, index, label)) -> {
        assert label != ""
        assert index >= 0
        assert index < figure.count(figures.spec(figure_id))
      }
    }
  })
}

pub fn the_dialog_and_the_move_link_into_figures_test() {
  // The approval step and the move step are the two the page leans on.
  let assert Some(approval) = replay.step_at(replay.gate)
  assert approval.underneath != None
  let assert Some(move) = replay.step_at(replay.last())
  assert move.underneath != None
}

pub fn a_step_out_of_range_is_none_test() {
  assert replay.step_at(-1) == None
  assert replay.step_at(99) == None
}
