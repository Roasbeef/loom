//// The terminal strip's duration format, which the elapsed clock shares.

import web_client/elapsed

pub fn seconds_under_a_minute_test() {
  assert elapsed.duration(0) == "0s"
  assert elapsed.duration(59) == "59s"
}

pub fn minutes_pad_their_seconds_test() {
  assert elapsed.duration(60) == "1m 00s"
  assert elapsed.duration(475) == "7m 55s"
}

pub fn hours_pad_their_minutes_test() {
  assert elapsed.duration(3600) == "1h 00m"
  assert elapsed.duration(3600 + 5 * 60 + 9) == "1h 05m"
}

pub fn a_negative_duration_shows_as_zero_test() {
  assert elapsed.duration(-3) == "0s"
}
