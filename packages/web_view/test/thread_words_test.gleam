//// What the inbox's time words say (`web_view/thread_words`): a wait's short
//// age, when a wait is marked, how long a turn has run, and the sentence a
//// stuck strand's reason code gets.

import gleam/option.{None, Some}
import web_view/session_brief
import web_view/thread_words.{Clock, Words}

pub fn tokens_are_worded_in_thousands_and_millions_test() {
  assert thread_words.tokens(0) == "0"
  assert thread_words.tokens(999) == "999"
  assert thread_words.tokens(412_000) == "412k"
  assert thread_words.tokens(1_200_000) == "1.2M"
  assert thread_words.tokens(2_000_000) == "2M"
}

pub fn a_goal_status_has_words_only_when_it_is_known_test() {
  assert thread_words.goal_status("limited") == Some("stopped at its budget")
  assert thread_words.goal_status("active") == Some("active")
  assert thread_words.goal_status("surprise") == None
}

pub fn a_strand_is_worded_by_state_and_time_test() {
  assert thread_words.strand_phrase(session_brief.Idle, None) == [Words("idle")]
  assert thread_words.strand_phrase(session_brief.Working, Some(9))
    == [Words("working since "), Clock(9)]
}

pub fn the_delegates_line_counts_each_state_test() {
  let strand = fn(state) { session_brief.Strand("s", state, None) }

  assert thread_words.delegates([]) == ""
  assert thread_words.delegates([
      strand(session_brief.Idle),
      strand(session_brief.Working),
      strand(session_brief.Stopped),
      strand(session_brief.Idle),
    ])
    == "1 working, 1 stopped, 2 idle"
}

pub fn a_wait_is_worded_as_the_row_says_it_test() {
  assert thread_words.short_age(30_000) == "now"
  assert thread_words.short_age(2_400_000) == "40m"
  assert thread_words.short_age(4_920_000) == "1h 22m"
  assert thread_words.short_age(10_800_000) == "3h 00m"
  assert thread_words.short_age(3 * 86_400_000) == "3d"
}

pub fn a_wait_of_an_hour_is_marked_and_a_shorter_one_is_not_test() {
  assert thread_words.overdue(3_600_000)
  assert !thread_words.overdue(3_599_999)
}

pub fn a_turn_is_worded_by_how_long_it_has_run_test() {
  assert thread_words.turn_words(0, 840_000) == "14 min into a turn"
  assert thread_words.turn_words(0, 7_300_000) == "2 h into a turn"
  assert thread_words.turn_words(0, 59_000) == "a turn that has just started"
  assert thread_words.turn_words(900_000, 0) == "a turn that has just started"
}

pub fn the_reason_table_is_closed_test() {
  assert thread_words.kind_of(Some("rate_limited")) == thread_words.RateLimited
  assert thread_words.kind_of(Some("overloaded")) == thread_words.Overloaded
  assert thread_words.kind_of(Some("timeout")) == thread_words.TimedOut
  assert thread_words.kind_of(Some("provider_error")) == thread_words.Other
  assert thread_words.kind_of(Some("rate_limited_x")) == thread_words.Other
  assert thread_words.kind_of(None) == thread_words.Other
}

pub fn a_rate_limit_with_no_reset_says_so_test() {
  assert thread_words.stuck_phrase(thread_words.RateLimited, Some(5000), None)
    == [
      Words("Rate-limited at "),
      Clock(5000),
      Words("; nothing has retried."),
      Words(" The provider gave no reset time."),
    ]
}

pub fn a_rate_limit_with_a_reset_says_when_test() {
  assert thread_words.stuck_phrase(
      thread_words.RateLimited,
      Some(1_000_000),
      Some(900_000),
    )
    == [
      Words("Rate-limited at "),
      Clock(1_000_000),
      Words("; nothing has retried."),
      Words(" The provider asked for a wait of 15 min, until "),
      Clock(1_900_000),
      Words("."),
    ]
}

pub fn a_wait_without_a_failure_time_is_a_duration_test() {
  assert thread_words.stuck_phrase(
      thread_words.Overloaded,
      None,
      Some(7_200_000),
    )
    == [
      Words("The provider was overloaded"),
      Words("; nothing has retried."),
      Words(" The provider asked for a wait of 2 h."),
    ]
}

pub fn a_reason_that_is_not_the_providers_says_nothing_of_a_retry_test() {
  assert thread_words.stuck_phrase(thread_words.Other, Some(1), Some(5000))
    == [
      Words("The last turn failed at "),
      Clock(1),
      Words("; nothing has retried."),
    ]
  assert thread_words.stuck_phrase(thread_words.TimedOut, None, None)
    == [
      Words("The provider did not answer in time"),
      Words("; nothing has retried."),
    ]
}

pub fn every_failure_has_a_title_and_a_head_test() {
  assert thread_words.stuck_title(thread_words.RateLimited)
    == "The last turn failed on a provider rate limit, and nothing has retried."
  assert thread_words.stuck_head(thread_words.RateLimited, None)
    == [Words("Rate-limited, has not retried")]
  assert thread_words.stuck_head(thread_words.Other, Some(5))
    == [Words("Stopped on a failed run")]
}

// The row names the time of the failure, so a reader sees `Rate-limited at
// 13:52, has not retried` where the row's age alone said how long ago.
pub fn a_stuck_head_names_the_time_it_failed_test() {
  assert thread_words.stuck_head(thread_words.RateLimited, Some(1000))
    == [
      Words("Rate-limited at "),
      Clock(1000),
      Words(", has not retried"),
    ]
  assert thread_words.stuck_head(thread_words.TimedOut, Some(2000))
    == [
      Words("Provider timed out at "),
      Clock(2000),
      Words(", has not retried"),
    ]
}
