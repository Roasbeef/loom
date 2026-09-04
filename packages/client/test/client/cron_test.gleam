//// The cron module: what the five fields accept, what they refuse in
//// words, and the occurrence arithmetic — every expected instant here
//// derived independently of the code under test.
////
//// Mirrors `test/client/schedule_test.gleam`'s style: one test per
//// bound or per vector, named for the thing it proves, so a failing
//// test names what broke rather than leaving that to a diff.
////
//// ## How the expected instants were derived
////
//// Every epoch second in this file was computed from a civil UTC date
//// with `python3 -c "import datetime;print(int(datetime.datetime(Y,M,D,h,m,
//// tzinfo=datetime.timezone.utc).timestamp()))"`, and every weekday
//// claim with `datetime.date(Y,M,D).strftime('%a')`. The comment above
//// each vector states the civil dates and the calendar fact — which
//// weekday, which month length, which leap year — that makes the
//// expected answer the right one. Nothing here was read off a run of
//// the code.

import client/cron
import gleam/option.{type Option, None, Some}
import gleam/string

// --- what parses -----------------------------------------------------------

pub fn an_all_wildcard_expression_parses_test() {
  let assert Ok(expression) = cron.parse("* * * * *")
    as "the every-minute expression must parse"

  // 2026-09-02T12:34:56Z. Every minute matches, so any instant does.
  assert cron.matches(expression, at_s: 1_788_352_496)
}

pub fn the_source_text_survives_parsing_test() {
  let assert Ok(expression) = cron.parse("0 9,17 * * 1-5")
    as "a list-and-range expression must parse"
  assert cron.source(expression) == "0 9,17 * * 1-5"
}

pub fn extra_whitespace_between_fields_is_one_separator_test() {
  let assert Ok(expression) = cron.parse("  0   9 *\t* *  ")
    as "runs of whitespace must separate fields, not create empty ones"

  // 2026-09-02T09:00:00Z.
  assert cron.matches(expression, at_s: 1_788_339_600)
}

pub fn steps_ranges_and_lists_all_parse_test() {
  let assert Ok(_) = cron.parse("*/15 * * * *") as "`*/n` must parse"
  let assert Ok(_) = cron.parse("0-30/10 * * * *") as "`a-b/n` must parse"
  let assert Ok(_) = cron.parse("1,2,3 * * * *") as "a list must parse"
  let assert Ok(_) = cron.parse("30 14 15 3 *") as "single values must parse"
}

// --- each field's bounds ---------------------------------------------------

pub fn the_minute_field_accepts_59_and_refuses_60_test() {
  let assert Ok(_) = cron.parse("59 * * * *") as "minute 59 must be accepted"

  let assert Error(reason) = cron.parse("60 * * * *")
    as "minute 60 must be refused"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "0-59")
}

pub fn the_hour_field_accepts_23_and_refuses_24_test() {
  let assert Ok(_) = cron.parse("0 23 * * *") as "hour 23 must be accepted"

  let assert Error(reason) = cron.parse("0 24 * * *")
    as "hour 24 must be refused"
  assert string.contains(reason, "hour")
  assert string.contains(reason, "0-23")
}

pub fn the_day_of_month_field_runs_from_1_to_31_test() {
  let assert Ok(_) = cron.parse("0 0 1 * *") as "the 1st must be accepted"
  let assert Ok(_) = cron.parse("0 0 31 * *") as "the 31st must be accepted"

  let assert Error(zero) = cron.parse("0 0 0 * *")
    as "day-of-month 0 must be refused: there is no zeroth day"
  assert string.contains(zero, "day-of-month")
  assert string.contains(zero, "1-31")

  let assert Error(over) = cron.parse("0 0 32 * *")
    as "day-of-month 32 must be refused"
  assert string.contains(over, "day-of-month")
}

pub fn the_month_field_runs_from_1_to_12_test() {
  let assert Ok(_) = cron.parse("0 0 1 1 *") as "January must be accepted"
  let assert Ok(_) = cron.parse("0 0 1 12 *") as "December must be accepted"

  let assert Error(zero) = cron.parse("0 0 1 0 *") as "month 0 must be refused"
  assert string.contains(zero, "month")
  assert string.contains(zero, "1-12")

  let assert Error(over) = cron.parse("0 0 1 13 *")
    as "month 13 must be refused"
  assert string.contains(over, "month")
}

pub fn the_day_of_week_field_runs_from_0_to_7_test() {
  let assert Ok(_) = cron.parse("0 0 * * 0") as "Sunday as 0 must be accepted"
  let assert Ok(_) = cron.parse("0 0 * * 6") as "Saturday as 6 must be accepted"
  let assert Ok(_) = cron.parse("0 0 * * 7") as "Sunday as 7 must be accepted"

  let assert Error(reason) = cron.parse("0 0 * * 8")
    as "day-of-week 8 must be refused"
  assert string.contains(reason, "day-of-week")
  assert string.contains(reason, "0-7")
}

// 2026-03-01 is a Sunday, and 2026-03-01T00:00:00Z is 1772323200. Both
// spellings of Sunday must select it, and Monday must not.
pub fn day_of_week_7_is_the_same_sunday_as_0_test() {
  let assert Ok(as_zero) = cron.parse("0 0 * * 0") as "`0` must parse"
  let assert Ok(as_seven) = cron.parse("0 0 * * 7") as "`7` must parse"
  let assert Ok(monday) = cron.parse("0 0 * * 1") as "`1` must parse"

  assert cron.matches(as_zero, at_s: 1_772_323_200)
  assert cron.matches(as_seven, at_s: 1_772_323_200)
  assert !cron.matches(monday, at_s: 1_772_323_200)
}

// The weekday arithmetic's two anchors. 1970-01-01 was a Thursday, so
// epoch second 0 is weekday 4; 2026-09-02 was a Wednesday, and
// 2026-09-02T00:00:00Z is 1788307200, so that is weekday 3.
pub fn the_epoch_was_a_thursday_and_2026_09_02_a_wednesday_test() {
  let assert Ok(thursday) = cron.parse("0 0 * * 4") as "`4` must parse"
  let assert Ok(wednesday) = cron.parse("0 0 * * 3") as "`3` must parse"

  assert cron.matches(thursday, at_s: 0)
  assert !cron.matches(wednesday, at_s: 0)

  assert cron.matches(wednesday, at_s: 1_788_307_200)
  assert !cron.matches(thursday, at_s: 1_788_307_200)
}

// --- what is refused -------------------------------------------------------

pub fn month_and_day_names_are_refused_test() {
  let assert Error(weekday) = cron.parse("0 9 * * MON")
    as "a day name must be refused"
  assert string.contains(weekday, "day-of-week")
  assert string.contains(weekday, "MON")

  let assert Error(month) = cron.parse("0 9 * JAN *")
    as "a month name must be refused"
  assert string.contains(month, "month")
  assert string.contains(month, "JAN")
}

pub fn the_last_day_extension_is_refused_test() {
  let assert Error(reason) = cron.parse("0 0 L * *")
    as "`L` must be refused rather than read as something else"
  assert string.contains(reason, "day-of-month")
  assert string.contains(reason, "`L`")
}

pub fn the_nearest_weekday_extension_is_refused_test() {
  let assert Error(reason) = cron.parse("0 0 15W * *") as "`W` must be refused"
  assert string.contains(reason, "day-of-month")
  assert string.contains(reason, "15W")
}

pub fn the_no_specific_value_extension_is_refused_test() {
  let assert Error(reason) = cron.parse("0 0 ? * 1") as "`?` must be refused"
  assert string.contains(reason, "day-of-month")
  assert string.contains(reason, "`?`")
}

pub fn six_fields_are_refused_test() {
  let assert Error(reason) = cron.parse("0 0 0 * * *")
    as "six fields must be refused"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "day-of-week")
  assert string.contains(reason, "seconds field")
}

pub fn four_fields_are_refused_test() {
  let assert Error(reason) = cron.parse("0 9 * *")
    as "four fields must be refused"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "day-of-week")
  assert string.contains(reason, "fewer")
}

pub fn an_empty_list_item_is_refused_test() {
  let assert Error(reason) = cron.parse("1,,2 * * * *")
    as "an empty list item must be refused rather than dropped"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "empty list item")
}

pub fn a_reversed_range_is_refused_test() {
  let assert Error(reason) = cron.parse("5-1 * * * *")
    as "a reversed range must be refused rather than wrapped"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "5-1")
}

pub fn a_zero_step_is_refused_test() {
  let assert Error(reason) = cron.parse("*/0 * * * *")
    as "a zero step must be refused rather than read as 1"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "at least 1")
}

pub fn a_step_over_a_single_value_is_refused_test() {
  let assert Error(reason) = cron.parse("5/10 * * * *")
    as "`a/n` is not in the grammar and must be refused"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "5/10")
}

pub fn a_second_step_in_one_item_is_refused_test() {
  let assert Error(reason) = cron.parse("0-30/5/2 * * * *")
    as "two steps in one item must be refused"
  assert string.contains(reason, "minute")
  assert string.contains(reason, "written once")
}

pub fn an_over_length_expression_is_refused_test() {
  // Forty repetitions of `1,` plus `1 * * * *` is 89 characters, well
  // past the 64-character bound, and every character of it is legal —
  // so only the length can be what refuses it.
  let long_minutes = string.repeat("1,", 40) <> "1 * * * *"

  let assert Error(reason) = cron.parse(long_minutes)
    as "an over-length expression must be refused"
  assert string.contains(reason, "at most 64 characters")
}

pub fn an_empty_expression_is_refused_test() {
  let assert Error(reason) = cron.parse("")
    as "the empty string must be refused"
  assert string.contains(reason, "fewer")
}

// --- next_occurrence -------------------------------------------------------

// 2026-09-02T12:34:56Z is 1788352496. A `*/5` minute field matches every
// minute whose number is a multiple of five, which on a minute-aligned
// grid is every epoch second divisible by 300; the smallest one strictly
// greater than 1788352496 is 1788352500, which is 12:35:00Z.
pub fn a_five_minute_step_lands_on_the_next_multiple_test() {
  let assert Ok(expression) = cron.parse("*/5 * * * *")
    as "`*/5 * * * *` must parse"

  assert cron.next_occurrence(expression, after_s: 1_788_352_496)
    == Some(1_788_352_500)
}

// 2026-09-04 was a Friday and 2026-09-07 the following Monday.
// 2026-09-04T09:00:00Z is 1788512400 and 2026-09-07T09:00:00Z is
// 1788771600. Asked from the Friday fire itself, a weekday schedule must
// skip Saturday and Sunday and answer the Monday — the "strictly
// greater" contract, since the seed is itself a match.
pub fn a_weekday_schedule_skips_the_weekend_test() {
  let assert Ok(expression) = cron.parse("0 9 * * 1-5")
    as "`0 9 * * 1-5` must parse"

  assert cron.next_occurrence(expression, after_s: 1_788_512_400)
    == Some(1_788_771_600)
}

// One second before the same Friday fire: 2026-09-04T08:59:59Z is
// 1788512399, so the answer is that Friday's own 09:00, 1788512400.
pub fn a_weekday_schedule_fires_later_the_same_day_test() {
  let assert Ok(expression) = cron.parse("0 9 * * 1-5")
    as "`0 9 * * 1-5` must parse"

  assert cron.next_occurrence(expression, after_s: 1_788_512_399)
    == Some(1_788_512_400)
}

// `30 14 15 3 *` is once a year. 2026-03-15T14:30:00Z is 1773585000 and
// 2027-03-15T14:30:00Z is 1805121000, so from the 2026 fire the answer
// is a year later — the walk has to cross a year boundary, and March 15
// is not the same weekday in the two years.
pub fn a_yearly_expression_crosses_the_year_boundary_test() {
  let assert Ok(expression) = cron.parse("30 14 15 3 *")
    as "`30 14 15 3 *` must parse"

  assert cron.next_occurrence(expression, after_s: 1_773_585_000)
    == Some(1_805_121_000)
}

// February 29th exists only in a leap year. 2026-03-01T00:00:00Z is
// 1772323200; 2026 and 2027 have no 29th of February, so the answer is
// 2028-02-29T00:00:00Z = 1835395200.
pub fn a_leap_day_expression_waits_for_the_leap_year_test() {
  let assert Ok(expression) = cron.parse("0 0 29 2 *")
    as "`0 0 29 2 *` must parse"

  assert cron.next_occurrence(expression, after_s: 1_772_323_200)
    == Some(1_835_395_200)
}

// The century exception. 2100 is divisible by 4 but is not a leap year,
// because it is divisible by 100 and not by 400 — so from
// 2100-03-01T00:00:00Z = 4107542400 the next 29th of February is
// 2104-02-29T00:00:00Z = 4233686400, four years later and not one.
pub fn a_leap_day_expression_skips_a_non_leap_century_test() {
  let assert Ok(expression) = cron.parse("0 0 29 2 *")
    as "`0 0 29 2 *` must parse"

  assert cron.next_occurrence(expression, after_s: 4_107_542_400)
    == Some(4_233_686_400)
}

// The same century exception approached from *before* it, which is what
// catches a walk that invents a 2100-02-29. 2099-12-31T00:00:00Z is
// 4102358400 and the next real 29th of February is still
// 2104-02-29T00:00:00Z = 4233686400 — 1520 days on. A calendar without
// the century exception would answer 2100 instead.
pub fn a_leap_day_expression_does_not_invent_a_century_leap_day_test() {
  let assert Ok(expression) = cron.parse("0 0 29 2 *")
    as "`0 0 29 2 *` must parse"

  let answer = cron.next_occurrence(expression, after_s: 4_102_358_400)
  assert answer == Some(4_233_686_400)

  // And whatever came back is itself a match, which a date the walk
  // invented could not be.
  let assert Some(instant) = answer as "a leap day must be found"
  assert cron.matches(expression, at_s: instant)
}

// The widest gap the horizon has to clear, and therefore the reason
// `search_horizon_days` is what it is: 2096-03-01T00:00:00Z is
// 3981398400 and the next 29th of February is 2104-02-29T00:00:00Z =
// 4233686400 — eight years, 2920 days.
pub fn the_longest_real_gap_is_inside_the_search_horizon_test() {
  let assert Ok(expression) = cron.parse("0 0 29 2 *")
    as "`0 0 29 2 *` must parse"

  assert cron.search_horizon_days > 2920

  assert cron.next_occurrence(expression, after_s: 3_981_398_400)
    == Some(4_233_686_400)
}

// A date that does not exist has no occurrence, which is the case the
// horizon exists for: `0 0 30 2 *` asks for the thirtieth of February.
pub fn an_impossible_date_has_no_occurrence_test() {
  let assert Ok(expression) = cron.parse("0 0 30 2 *")
    as "`0 0 30 2 *` must parse: it is legal syntax about an unreal date"

  assert cron.next_occurrence(expression, after_s: 0) == None
  assert cron.previous_occurrence(expression, before_s: 4_000_000_000) == None
}

// The OR rule, first order: the weekday arrives before the first of the
// month. 2026-09-02 was a Wednesday; 2026-09-02T10:00:00Z is 1788343200.
// The next Monday is 2026-09-07 (09:00Z = 1788771600) and the next first
// of a month is 2026-10-01, so the Monday wins.
pub fn the_day_rule_or_takes_the_weekday_when_it_comes_first_test() {
  let assert Ok(expression) = cron.parse("0 9 1 * 1")
    as "`0 9 1 * 1` must parse"

  assert cron.next_occurrence(expression, after_s: 1_788_343_200)
    == Some(1_788_771_600)
}

// The OR rule, other order: the first of the month arrives before the
// next Monday. 2026-10-29 was a Thursday; 2026-10-29T10:00:00Z is
// 1793268000. 2026-11-01 was a Sunday (09:00Z = 1793523600) and the next
// Monday is 2026-11-02, so the first of the month wins. Under an AND
// reading neither of these two answers is reachable.
pub fn the_day_rule_or_takes_the_first_when_it_comes_first_test() {
  let assert Ok(expression) = cron.parse("0 9 1 * 1")
    as "`0 9 1 * 1` must parse"

  assert cron.next_occurrence(expression, after_s: 1_793_268_000)
    == Some(1_793_523_600)
}

// One day field restricted and the other `*`: the restricted one alone
// decides, with nothing to OR against. 2026-09-02 was a Wednesday, so a
// Monday-only expression must not match it, and a 2nd-of-the-month
// expression must.
pub fn one_restricted_day_field_decides_alone_test() {
  let assert Ok(monday) = cron.parse("0 0 * * 1") as "`0 0 * * 1` must parse"
  let assert Ok(second) = cron.parse("0 0 2 * *") as "`0 0 2 * *` must parse"

  assert !cron.matches(monday, at_s: 1_788_307_200)
  assert cron.matches(second, at_s: 1_788_307_200)
}

// A 31st-of-the-month expression must skip the 30-day months.
// 2026-04-01T12:00:00Z is 1775044800; April has 30 days, so the answer
// is 2026-05-31T00:00:00Z = 1780185600. From one second past that fire
// (1780185601) the answer is 2026-07-31T00:00:00Z = 1785456000, because
// June has 30 days too.
pub fn a_thirty_first_expression_skips_the_short_months_test() {
  let assert Ok(expression) = cron.parse("0 0 31 * *")
    as "`0 0 31 * *` must parse"

  assert cron.next_occurrence(expression, after_s: 1_775_044_800)
    == Some(1_780_185_600)

  assert cron.next_occurrence(expression, after_s: 1_780_185_601)
    == Some(1_785_456_000)
}

// Strictly greater, at the finest grain the module has. `7 * * * *`
// fires at seven minutes past every hour; 2026-09-02T12:07:00Z is
// 1788350820 and the answer is the next hour's, 13:07:00Z = 1788354420.
// A search that admitted the seed would answer the seed.
pub fn an_hourly_expression_advances_a_whole_hour_test() {
  let assert Ok(expression) = cron.parse("7 * * * *")
    as "`7 * * * *` must parse"

  assert cron.next_occurrence(expression, after_s: 1_788_350_820)
    == Some(1_788_354_420)
}

// The day wrap. `0,30 * * * *` has no minute left after 23:30, so a seed
// at 2026-09-01T23:59:00Z = 1788307140 forces the walk onto the next
// day: 2026-09-02T00:00:00Z = 1788307200.
pub fn a_search_wraps_from_the_last_minute_to_the_next_day_test() {
  let assert Ok(expression) = cron.parse("0,30 * * * *")
    as "`0,30 * * * *` must parse"

  assert cron.next_occurrence(expression, after_s: 1_788_307_140)
    == Some(1_788_307_200)
}

// `matches` and `next_occurrence` must agree: the instant handed back is
// a match, and — chosen so the point is not vacuous — the minute before
// it is not. 2026-09-04T09:00:00Z = 1788512400 matches `0 9 * * 1-5`;
// 08:59:00Z = 1788512340 does not.
pub fn the_next_occurrence_matches_and_the_minute_before_it_does_not_test() {
  let assert Ok(expression) = cron.parse("0 9 * * 1-5")
    as "`0 9 * * 1-5` must parse"

  let assert Some(instant) =
    cron.next_occurrence(expression, after_s: 1_788_512_399)
    as "a weekday 09:00 must be found"

  assert instant == 1_788_512_400
  assert cron.matches(expression, at_s: instant)
  assert !cron.matches(expression, at_s: instant - 60)
  assert 1_788_512_340 == instant - 60
}

// --- previous_occurrence ---------------------------------------------------

// The mirror of the weekend skip. From the Monday fire
// 2026-09-07T09:00:00Z = 1788771600, the preceding weekday 09:00 is the
// Friday, 2026-09-04T09:00:00Z = 1788512400 — strictly less, so the
// Monday itself is not the answer.
pub fn the_previous_weekday_occurrence_skips_back_over_the_weekend_test() {
  let assert Ok(expression) = cron.parse("0 9 * * 1-5")
    as "`0 9 * * 1-5` must parse"

  assert cron.previous_occurrence(expression, before_s: 1_788_771_600)
    == Some(1_788_512_400)
}

// The mirror of the leap day. From 2028-02-29T00:00:00Z = 1835395200 the
// preceding 29th of February is 2024-02-29T00:00:00Z = 1709164800.
pub fn the_previous_leap_day_is_four_years_back_test() {
  let assert Ok(expression) = cron.parse("0 0 29 2 *")
    as "`0 0 29 2 *` must parse"

  assert cron.previous_occurrence(expression, before_s: 1_835_395_200)
    == Some(1_709_164_800)
}

// The mirror of the short-month skip. From 2026-05-31T00:00:00Z =
// 1780185600 the preceding 31st is 2026-03-31T00:00:00Z = 1774915200,
// because April has 30 days.
pub fn the_previous_thirty_first_skips_back_over_april_test() {
  let assert Ok(expression) = cron.parse("0 0 31 * *")
    as "`0 0 31 * *` must parse"

  assert cron.previous_occurrence(expression, before_s: 1_780_185_600)
    == Some(1_774_915_200)
}

// Sub-hour mirror: from 2026-09-02T12:34:56Z = 1788352496, the last
// multiple of five minutes before it is 12:30:00Z = 1788352200.
pub fn the_previous_five_minute_slot_is_the_last_multiple_test() {
  let assert Ok(expression) = cron.parse("*/5 * * * *")
    as "`*/5 * * * *` must parse"

  assert cron.previous_occurrence(expression, before_s: 1_788_352_496)
    == Some(1_788_352_200)
}

// The adjacency property, over six seeds and four expressions: stepping
// back and then forward lands on the first match at or *after* the
// seed. When the seed is itself a match that is the seed; when it is
// not, it is the seed's own next occurrence. Both cases are here, and
// each pair was derived above rather than from a run.
pub fn stepping_back_then_forward_returns_to_the_seed_test() {
  // 2026-09-02T12:35:00Z is a `*/5` fire; 12:34:56Z is not, and its
  // next fire is that same 12:35:00Z.
  round_trip("*/5 * * * *", 1_788_352_500, 1_788_352_500)
  round_trip("*/5 * * * *", 1_788_352_496, 1_788_352_500)

  // Friday 2026-09-04T09:00:00Z is a weekday fire; one second earlier
  // is not, and leads to the same instant.
  round_trip("0 9 * * 1-5", 1_788_512_400, 1_788_512_400)
  round_trip("0 9 * * 1-5", 1_788_512_399, 1_788_512_400)

  // 2026-05-31T00:00:00Z is a 31st-of-the-month fire.
  round_trip("0 0 31 * *", 1_780_185_600, 1_780_185_600)

  // 2028-02-29T00:00:00Z is a leap-day fire, and its own predecessor is
  // four years back, so the forward leg crosses 1461 days.
  round_trip("0 0 29 2 *", 1_835_395_200, 1_835_395_200)
}

/// Asserts that `previous_occurrence` then `next_occurrence` lands on
/// `expected`, the first match at or after `seed`, and that the
/// intermediate step really did move backwards.
fn round_trip(text: String, seed: Int, expected: Int) -> Nil {
  let assert Ok(expression) = cron.parse(text)
    as "every expression in the round-trip table must parse"

  let assert Some(previous) =
    cron.previous_occurrence(expression, before_s: seed)
    as "every seed in the round-trip table has an earlier occurrence"

  assert previous < seed
  assert cron.matches(expression, at_s: previous)
  assert cron.next_occurrence(expression, after_s: previous) == Some(expected)

  assert_matching(expression, cron.next_occurrence(expression, after_s: seed))
}

/// Asserts that whatever a search answered, it answered with a matching
/// instant — the invariant tying the two halves of the module together.
fn assert_matching(expression: cron.Expression, answer: Option(Int)) -> Nil {
  case answer {
    None -> Nil
    Some(instant) -> {
      assert cron.matches(expression, at_s: instant)
      Nil
    }
  }
}
