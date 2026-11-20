//// The saved-session summary row Home is handed (protocol-change/122): the
//// constructor accepts what the catalogue's table accepts and refuses what its
//// CHECK constraints refuse, so a damaged row is never drawn as a count.

import gleam/option.{None, Some}
import web_view/saved_attention.{Saved}

pub fn a_row_of_counts_and_times_is_accepted_test() {
  assert saved_attention.from_row("a", 1, 2, 3, Some(40), 50)
    == Ok(Saved("a", 1, 2, 3, Some(40), 50))
}

pub fn a_row_of_zeros_with_no_oldest_time_is_accepted_test() {
  assert saved_attention.from_row("a", 0, 0, 0, None, 0)
    == Ok(Saved("a", 0, 0, 0, None, 0))
}

pub fn a_negative_count_or_time_is_refused_test() {
  assert saved_attention.from_row("a", -1, 0, 0, None, 5) == Error(Nil)
  assert saved_attention.from_row("a", 0, -1, 0, None, 5) == Error(Nil)
  assert saved_attention.from_row("a", 0, 0, -1, None, 5) == Error(Nil)
  assert saved_attention.from_row("a", 0, 0, 0, Some(-1), 5) == Error(Nil)
  assert saved_attention.from_row("a", 0, 0, 0, None, -1) == Error(Nil)
}
