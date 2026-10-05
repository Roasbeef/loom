//// The composer's pending line: when a press shows it, the word it carries,
//// and how the server's refusal count ends it.

import web_client/pending_rule.{
  Clear, Heard, Keep, Pending, Queueing, Restore, Sending, Shown, Unheard,
}

pub fn the_queue_button_queues_and_the_others_send_test() {
  assert pending_rule.delivery("queue") == Queueing
  assert pending_rule.delivery("steer") == Sending
  assert pending_rule.delivery("send") == Sending
  assert pending_rule.delivery("") == Sending
}

pub fn the_mark_words_the_delivery_test() {
  assert pending_rule.mark(Sending) == "sending"
  assert pending_rule.mark(Queueing) == "queued"
}

pub fn a_press_shows_the_draft_with_its_delivery_test() {
  assert pending_rule.pressed(Clear, "fix the test", Sending)
    == Shown(Pending("fix the test", Sending))
  assert pending_rule.pressed(Clear, "later", Queueing)
    == Shown(Pending("later", Queueing))
}

pub fn a_press_with_no_word_shows_nothing_test() {
  assert pending_rule.pressed(Clear, "", Sending) == Clear
  assert pending_rule.pressed(Clear, " \n ", Queueing) == Clear
  let shown = Shown(Pending("hi", Sending))
  assert pending_rule.pressed(shown, "  ", Sending) == shown
}

pub fn a_second_press_replaces_the_line_test() {
  let shown = Shown(Pending("first", Sending))
  assert pending_rule.pressed(shown, "second", Queueing)
    == Shown(Pending("second", Queueing))
}

pub fn the_first_count_is_the_baseline_test() {
  let shown = Shown(Pending("hi", Sending))
  assert pending_rule.refused(shown, Unheard, 3) == #(shown, Heard(3), Keep)
  assert pending_rule.refused(Clear, Unheard, 0) == #(Clear, Heard(0), Keep)
}

pub fn a_rising_count_restores_a_shown_draft_test() {
  let shown = Shown(Pending("hi", Sending))
  assert pending_rule.refused(shown, Heard(3), 4)
    == #(Clear, Heard(4), Restore("hi"))
}

pub fn a_rising_count_with_no_line_only_advances_test() {
  assert pending_rule.refused(Clear, Heard(3), 5) == #(Clear, Heard(5), Keep)
}

pub fn a_count_that_does_not_rise_changes_nothing_test() {
  let shown = Shown(Pending("hi", Sending))
  assert pending_rule.refused(shown, Heard(3), 3) == #(shown, Heard(3), Keep)
  assert pending_rule.refused(shown, Heard(3), 1) == #(shown, Heard(3), Keep)
}
