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
