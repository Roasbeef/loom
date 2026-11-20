//// The terminal strip's duration format, which the elapsed clock shares.

import web_client/duration

pub fn seconds_under_a_minute_test() {
  assert duration.format(0) == "0s"
  assert duration.format(59) == "59s"
}

pub fn minutes_pad_their_seconds_test() {
  assert duration.format(60) == "1m 00s"
  assert duration.format(475) == "7m 55s"
}

pub fn hours_pad_their_minutes_test() {
  assert duration.format(3600) == "1h 00m"
  assert duration.format(3600 + 5 * 60 + 9) == "1h 05m"
}

pub fn a_negative_duration_shows_as_zero_test() {
  assert duration.format(-3) == "0s"
}

pub fn time_left_rounds_minutes_up_test() {
  assert duration.remaining(900) == "15m"
  assert duration.remaining(14 * 60 + 1) == "15m"
  assert duration.remaining(840) == "14m"
  assert duration.remaining(60) == "1m"
}

pub fn time_left_under_a_minute_is_seconds_test() {
  assert duration.remaining(59) == "59s"
  assert duration.remaining(0) == "0s"
  assert duration.remaining(-4) == "0s"
}

// A running call reads `Running · 1m 12s`: seventy-two seconds since the start
// is the terminal's minutes-and-seconds form.
pub fn a_running_call_reads_minutes_and_seconds_test() {
  let offset = duration.since_offset(now: 1_000_072_000, since: 1_000_000_000)
  assert duration.format(offset / 1000) == "1m 12s"
}

// A start the browser's clock has not reached yet is no time, never a
// negative one.
pub fn a_start_in_the_future_is_no_time_test() {
  assert duration.since_offset(now: 100, since: 900) == 0
  assert duration.since_offset(now: 900, since: 900) == 0
}

// The inbox's turn age drops the seconds once a minute has passed, so a turn
// that has run fourteen minutes reads `14m` and not `14m 05s`.
pub fn the_minutes_form_drops_seconds_past_a_minute_test() {
  assert duration.minutes(59) == "59s"
  assert duration.minutes(60) == "1m"
  assert duration.minutes(14 * 60 + 59) == "14m"
  assert duration.minutes(3599) == "59m"
}

// From an hour the two forms agree, and the default form is unchanged.
pub fn the_minutes_form_agrees_with_the_default_from_an_hour_test() {
  assert duration.minutes(3600) == duration.format(3600)
  assert duration.minutes(3600 + 22 * 60 + 9) == "1h 22m"
  assert duration.format(14 * 60 + 5) == "14m 05s"
}
