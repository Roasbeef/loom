//// What `<loom-time>` decides (`web_client/time_rule`): an instant's time of
//// day in a zone, and which attribute values are instants.

import web_client/time_rule

// 22:41:00 UTC on a day in 2026.
const instant = 1_790_030_460_000

pub fn utc_is_the_offset_of_zero_test() {
  assert time_rule.clock(instant, 0) == "22:41"
}

// The browser's offset is minutes to add to local time to reach UTC, so a zone
// ahead of UTC is negative and a zone behind it positive.
pub fn a_zone_east_of_utc_reads_later_test() {
  assert time_rule.clock(instant, -120) == "00:41"
  assert time_rule.clock(instant, -330) == "04:11"
}

pub fn a_zone_west_of_utc_reads_earlier_test() {
  assert time_rule.clock(instant, 300) == "17:41"
  assert time_rule.clock(instant, 480) == "14:41"
}

pub fn the_clock_wraps_a_day_in_both_directions_test() {
  // 00:05 UTC shown five hours west is 19:05 the day before.
  assert time_rule.clock(86_400_000 + 300_000, 300) == "19:05"

  // 23:30 UTC shown three hours east is 02:30 the day after.
  assert time_rule.clock(86_400_000 - 1_800_000, -180) == "02:30"
}

// A time inside a minute rounds up so it is never shown before it comes.
pub fn a_time_inside_a_minute_rounds_up_test() {
  assert time_rule.clock(instant + 1, 0) == "22:42"
  assert time_rule.clock(instant - 1, 0) == "22:41"
}

pub fn midnight_pads_both_fields_and_the_past_is_the_epoch_test() {
  assert time_rule.clock(86_400_000 + 300_000, 0) == "00:05"
  assert time_rule.clock(-5, 0) == "00:00"
}

pub fn only_a_whole_number_is_an_instant_test() {
  assert time_rule.instant("1790030460000") == Ok(instant)
  assert time_rule.instant(" 1790030460000\n") == Ok(instant)
  assert time_rule.instant("") == Error(Nil)
  assert time_rule.instant("soon") == Error(Nil)
  assert time_rule.instant("1.5") == Error(Nil)
}
