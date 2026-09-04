//// Standard five-field cron: the parsed expression, what it refuses in
//// words, and the pure occurrence arithmetic a scanner walks it with.
////
//// `client/schedule` knows two kinds of timing — a fixed interval
//// aligned to the epoch grid, and a one-shot instant — and both are
//// arithmetic a scanner can do with one division. Cron is neither. "at
//// 09:00 on weekdays" is not a multiple of anything, so the slot a tick
//// falls in cannot be computed from `now_s` alone; it has to be searched
//// for over a calendar. That search, and the calendar arithmetic under
//// it, is what this module owns, and it owns it *alone*: an `Expression`
//// is a value, every function here is a pure function of its arguments,
//// and nothing in this file reads a clock. The scanner supplies the
//// instant; this module answers questions about it.
////
//// The parity target is the five-field syntax every standard scheduler
//// speaks, so that an expression an operator has written elsewhere means
//// here what it means there:
////
//// ```
//// minute hour day-of-month month day-of-week
////   0-59   0-23      1-31   1-12         0-7
//// ```
////
//// Each field is `*`, a single value, a range `a-b`, a step `*/n` or
//// `a-b/n`, or a comma-separated list of those. Day-of-week takes `0` or
//// `7` for Sunday through `6` for Saturday, and `7` is normalised to `0`
//// at parse time so the matcher only ever compares against one spelling.
////
//// ## Day-of-month and day-of-week are ORed, not ANDed
////
//// This is the one rule in cron that surprises everybody, and it is the
//// one a reimplementation gets wrong. **When both day fields are
//// restricted — neither is `*` — a date matches if *either* of them
//// matches.** Minute, hour and month are ANDed with each other and with
//// the result. When only one day field is restricted it alone decides;
//// when both are `*` every day matches.
////
//// So `0 9 1 * 1` fires at 09:00 on the first of every month *and* at
//// 09:00 on every Monday — not only on Mondays that fall on the first.
//// The reading is inherited from the original vixie cron and is what the
//// syntax means in the wild, however little the grammar suggests it.
////
//// "Restricted" here means literally *the field is not the single
//// character `*`*, so `*/2` in the day-of-month field counts as
//// restricted and puts the pair into the OR. That is the bright line the
//// refusals and this doc can both state without qualification.
////
//// ## UTC, and no timezone anywhere
////
//// Every instant crossing this boundary is a UTC epoch second, and the
//// civil date derived from one is the UTC date. Loom carries no timezone
//// database and has ruled that it will not, so `0 9 * * 1-5` is 09:00
//// UTC and nothing here will pretend otherwise. A scheduler that speaks
//// local time will disagree with this module by its own offset; that is
//// a deliberate and documented difference, not a bug to patch with a
//// hidden offset.
////
//// ## The search horizon
////
//// `next_occurrence` and `previous_occurrence` walk the calendar a day
//// at a time and give up after `search_horizon_days`. A bound is
//// necessary because a legal expression need not have a next occurrence
//// at all — `0 0 30 2 *` asks for the thirtieth of February — and an
//// unbounded search for one would not return. The bound is set wide
//// enough that no expression which *does* recur can hit it: the longest
//// real gap in the grammar is `29 2`, February 29th, across a century
//// year that is not a leap year, which is the eight years from 2096 to
//// 2104 — 2920 days.
////
//// Within a matching day the walk steps through the hour and minute sets
//// in order rather than trying each of the day's 1440 minutes, so the
//// cost of a search is a day count and not a minute count.
////
//// ## What is deliberately not here
////
//// No seconds field, no `@yearly`-style macros, no month or day *names*
//// (`JAN`, `MON`), and none of the extended syntax — `L`, `W`, `?`, `#`.
//// Each is refused by name in the error text rather than silently
//// mis-parsed, because an operator who writes `0 0 L * *` meaning "the
//// last day of the month" must not be given the first day instead. Every
//// refusal names the field it came from and the item that caused it.

import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// --- the parsed expression -----------------------------------------------

/// A parsed five-field cron expression: the five value sets plus the text
/// it was written as.
///
/// Opaque because the sets carry invariants nothing outside `parse` can
/// be trusted to hold — each is sorted, deduplicated and within its
/// field's range, and the day-of-week set has already had `7` folded to
/// `0`. The matcher and both searches read those properties directly
/// rather than re-checking them, so a hand-built value would be a
/// silently wrong one.
pub opaque type Expression {
  Expression(
    /// Minutes of the hour that match, ascending, each 0-59.
    minutes: List(Int),
    /// Hours of the day that match, ascending, each 0-23.
    hours: List(Int),
    /// The day-of-month restriction, or `Unrestricted` for `*`. Whether
    /// this is restricted is half of the OR rule, so the distinction is
    /// kept rather than expanded to 1-31.
    days_of_month: Restriction,
    /// Months that match, ascending, each 1-12.
    months: List(Int),
    /// The day-of-week restriction, or `Unrestricted` for `*`. Values are
    /// 0-6 with Sunday as 0; a written `7` is already folded to `0`.
    days_of_week: Restriction,
    /// The expression exactly as written, for rendering it back to
    /// whoever configured it.
    text: String,
  )
}

/// Whether a field constrains anything, which for the two day fields is
/// the question the OR rule turns on.
///
/// A `*` field is not the same value as a field listing every legal
/// value, even though the two match the same instants: only the first
/// leaves the *other* day field in sole charge of the date. Keeping the
/// two apart in the type is what makes the OR rule statable without a
/// flag beside the data.
type Restriction {
  /// The field was the single character `*`.
  Unrestricted

  /// The field named values: sorted, deduplicated, in range.
  Restricted(values: List(Int))
}

/// A civil date in the proleptic Gregorian calendar, UTC.
type Civil {
  Civil(
    /// The year, as written on a calendar — 2026, not an offset.
    year: Int,
    /// The month, 1-12.
    month: Int,
    /// The day of the month, 1-31.
    day: Int,
  )
}

/// One field's identity for the parser: what to call it in a refusal and
/// what values it accepts.
type Bounds {
  Bounds(
    /// The field's name as an operator would say it, which every refusal
    /// about the field leads with.
    field: String,
    /// The lowest value the field accepts.
    low: Int,
    /// The highest value the field accepts.
    high: Int,
  )
}

/// The longest expression `parse` will look at, in characters.
///
/// Every legal five-field expression fits easily: the widest thing the
/// grammar can say is a comma list, and a minute field naming all sixty
/// minutes individually would be refused here rather than parsed, which
/// is the right trade — `*` says the same thing in one character. The
/// bound exists so that a pathological input is refused before any field
/// is scanned at all.
pub const max_expression_length = 64

/// How many days a search examines before answering `None`.
///
/// See the module doc: a legal expression need not recur, so the search
/// must be bounded, and the bound must clear the longest gap a recurring
/// expression can have. That gap is February 29th across a non-leap
/// century year — 2096 to 2104, 2920 days — so this is that with room.
pub const search_horizon_days = 3000

const seconds_per_minute = 60

const seconds_per_day = 86_400

const minutes_per_hour = 60

const minutes_per_day = 1440

// One `Bounds` per field, so that a refusal's wording and the range it
// enforces can never disagree: both come from the same value.
const bounds_of_minute = Bounds(field: "minute", low: 0, high: 59)

const bounds_of_hour = Bounds(field: "hour", low: 0, high: 23)

const bounds_of_day_of_month = Bounds(field: "day-of-month", low: 1, high: 31)

const bounds_of_month = Bounds(field: "month", low: 1, high: 12)

const bounds_of_day_of_week = Bounds(field: "day-of-week", low: 0, high: 7)

// --- parsing ---------------------------------------------------------------

/// Parses a five-field cron expression, total: every input either
/// becomes an `Expression` or becomes a sentence an operator can act on.
///
/// The error is prose rather than an ADT because there is exactly one
/// thing a caller does with it — put it in front of whoever wrote the
/// expression — and the useful content is which field and which item,
/// which no variant name would carry better than the words do.
///
/// Order of work: the length bound first, so nothing pathological is
/// scanned; then the field count, so a four-field expression is not
/// reported as a bad day-of-week; then each field left to right, so the
/// first thing an operator reads about is the leftmost thing they got
/// wrong.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * 1-5")
/// assert cron.source(expression) == "0 9 * * 1-5"
/// ```
///
/// ```gleam
/// let assert Error(reason) = cron.parse("0 24 * * *")
/// assert string.contains(reason, "hour")
/// ```
///
pub fn parse(text: String) -> Result(Expression, String) {
  use Nil <- result.try(within_length(text))
  use fields <- result.try(five_fields(text))

  let #(minute, hour, day_of_month, month, day_of_week) = fields

  use minutes <- result.try(parse_values(minute, bounds_of_minute))
  use hours <- result.try(parse_values(hour, bounds_of_hour))
  use days_of_month <- result.try(parse_restriction(
    day_of_month,
    bounds_of_day_of_month,
  ))
  use months <- result.try(parse_values(month, bounds_of_month))
  use days_of_week <- result.try(parse_week_restriction(day_of_week))

  Ok(Expression(minutes:, hours:, days_of_month:, months:, days_of_week:, text:))
}

/// The expression exactly as it was written.
///
/// Kept because a rendered schedule should show an operator the string
/// they typed and not a normalisation of it: `0 9 * * MON-FRI` is not
/// accepted at all, but `0 9 * * 1-5` and `0 9 * * 1,2,3,4,5` are the
/// same `Expression` and are not the same thing to read.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("*/15 * * * *")
/// assert cron.source(expression) == "*/15 * * * *"
/// ```
///
pub fn source(expression: Expression) -> String {
  expression.text
}

/// Refuses an over-long input without walking it to the end.
///
/// The `too_long` idiom rather than a length comparison: the question is
/// "is there anything past character 64", which `string.drop_start`
/// answers without counting a pathological value's every grapheme (lint
/// R5, the same shape `client/schedule` bounds its string fields with).
fn within_length(text: String) -> Result(Nil, String) {
  case too_long(text, max_expression_length) {
    False -> Ok(Nil)

    True ->
      Error(
        "a cron expression must be at most "
        <> int.to_string(max_expression_length)
        <> " characters: nothing the five-field grammar can say needs more "
        <> "room than that",
      )
  }
}

fn too_long(text: String, limit: Int) -> Bool {
  string.drop_start(text, limit) != ""
}

/// Splits on whitespace and insists on exactly five fields.
///
/// Any run of spaces, tabs or newlines separates fields, and a leading
/// or trailing run is not a field — which is why the split is followed
/// by dropping the empties rather than by a stricter splitter.
///
/// The count is decided by pattern, not by `list.length`: the patterns
/// answer the bounded question directly (lint R5), and they let too-few
/// and too-many be told apart, which matters because they are different
/// mistakes. A four-field expression is usually a forgotten field; a
/// six-field one is usually a seconds field the writer expected to be
/// understood.
fn five_fields(
  text: String,
) -> Result(#(String, String, String, String, String), String) {
  let fields =
    text
    |> string.replace("\t", " ")
    |> string.replace("\n", " ")
    |> string.replace("\r", " ")
    |> string.split(" ")
    |> list.filter(fn(field) { field != "" })

  case fields {
    [minute, hour, day_of_month, month, day_of_week] ->
      Ok(#(minute, hour, day_of_month, month, day_of_week))

    // Fewer than five. Naming all five in order is the whole of the
    // help, since the writer has to see which one they left out.
    [] | [_] | [_, _] | [_, _, _] | [_, _, _, _] ->
      Error(
        "a cron expression has five whitespace-separated fields — minute "
        <> "hour day-of-month month day-of-week — and this one has fewer",
      )

    // More than five, most often a leading seconds field.
    [_, _, _, _, _, _, ..] ->
      Error(
        "a cron expression has five whitespace-separated fields — minute "
        <> "hour day-of-month month day-of-week — and this one has more: "
        <> "there is no seconds field",
      )
  }
}

/// Parses a field whose `*` may as well be expanded, which is the three
/// that take part in no OR rule: minute, hour and month.
fn parse_values(text: String, bounds: Bounds) -> Result(List(Int), String) {
  use restriction <- result.try(parse_restriction(text, bounds))

  case restriction {
    Unrestricted -> Ok(stepped_values(bounds.low, bounds.high, 1, []))
    Restricted(values:) -> Ok(values)
  }
}

/// Parses the day-of-week field, which is the one field whose values are
/// not simply its own.
///
/// `0` and `7` both mean Sunday, and folding `7` down to `0` here — once,
/// at the boundary — is what lets everything downstream compare a single
/// spelling. A range spanning the seam (`5-7`) folds member by member, so
/// it becomes Friday, Saturday and Sunday rather than a range that runs
/// backwards.
fn parse_week_restriction(text: String) -> Result(Restriction, String) {
  use restriction <- result.try(parse_restriction(text, bounds_of_day_of_week))

  case restriction {
    Unrestricted -> Ok(Unrestricted)

    Restricted(values:) ->
      Ok(Restricted(values: sorted_unique(list.map(values, sunday_as_zero))))
  }
}

fn sunday_as_zero(day: Int) -> Int {
  case day == 7 {
    True -> 0
    False -> day
  }
}

/// Parses one field into either `Unrestricted` or the values it names.
///
/// The `*` test is on the whole field text and not on its first
/// character, which is the bright line the module doc states: `*/2` is
/// restricted, and only a bare `*` is not.
fn parse_restriction(
  text: String,
  bounds: Bounds,
) -> Result(Restriction, String) {
  case text == "*" {
    True -> Ok(Unrestricted)

    False -> {
      use values <- result.try(parse_items(string.split(text, ","), bounds, []))
      Ok(Restricted(values: sorted_unique(values)))
    }
  }
}

/// Folds the comma-separated items of one field into their values,
/// stopping at the first item that will not parse.
fn parse_items(
  items: List(String),
  bounds: Bounds,
  collected: List(Int),
) -> Result(List(Int), String) {
  case items {
    [] -> Ok(collected)

    [item, ..rest] -> {
      use values <- result.try(parse_item(item, bounds))
      parse_items(rest, bounds, list.append(values, collected))
    }
  }
}

/// Parses one list item: a value, a range, or either of those stepped.
///
/// The `/` split comes first because it is the outermost operator in the
/// item grammar — `1-30/5` is a step over a range, never a range over a
/// step — and because a second `/` is a distinct mistake worth naming
/// rather than folding into the general refusal.
fn parse_item(item: String, bounds: Bounds) -> Result(List(Int), String) {
  use Nil <- result.try(non_empty_item(item, bounds))

  case string.split(item, "/") {
    [base] -> {
      use #(from, to) <- result.try(parse_span(base, bounds, item))
      Ok(stepped_values(from, to, 1, []))
    }

    [base, step] -> parse_stepped_item(base, step, bounds, item)

    // No `/` at all is the arm above, so this is two or more of them.
    [] | [_, _, _, ..] ->
      Error(unsupported(
        bounds,
        item,
        "a step is written once, as `*/n` or `a-b/n`",
      ))
  }
}

/// An empty item is almost always a typed-over comma (`1,,2`) or a
/// trailing one (`1,`), and both are worth saying out loud: silently
/// dropping them would accept a list the writer did not mean.
fn non_empty_item(item: String, bounds: Bounds) -> Result(Nil, String) {
  case item == "" {
    False -> Ok(Nil)

    True ->
      Error(
        "the cron "
        <> bounds.field
        <> " field has an empty list item: `1,,2` and `1,` are not lists of "
        <> "two values",
      )
  }
}

/// Parses `a-b/n` or `*/n`.
///
/// The base is checked for steppability before it is parsed, so that
/// `5/10` is refused as "a step needs a range" rather than as whatever a
/// bare `5` would have become — the grammar has no `a/n` form and
/// guessing one would silently invent occurrences.
fn parse_stepped_item(
  base: String,
  step_text: String,
  bounds: Bounds,
  item: String,
) -> Result(List(Int), String) {
  use Nil <- result.try(steppable_base(base, bounds, item))
  use #(from, to) <- result.try(parse_span(base, bounds, item))
  use step <- result.try(parse_step(step_text, bounds, item))

  Ok(stepped_values(from, to, step, []))
}

fn steppable_base(
  base: String,
  bounds: Bounds,
  item: String,
) -> Result(Nil, String) {
  case base == "*" || string.contains(base, "-") {
    True -> Ok(Nil)

    False ->
      Error(unsupported(
        bounds,
        item,
        "a step needs `*` or a range before the `/`, as in `*/15` or `0-30/5`",
      ))
  }
}

/// The step must be a whole number of at least one. Zero is refused
/// rather than treated as one, because a zero step is a writer's
/// arithmetic slip and a silent `1` would fire sixty times an hour.
fn parse_step(
  text: String,
  bounds: Bounds,
  item: String,
) -> Result(Int, String) {
  use step <- result.try(parse_whole(text, bounds, item))

  case step >= 1 {
    True -> Ok(step)

    False ->
      Error(unsupported(
        bounds,
        item,
        "a step must be at least 1: `*/0` names no values at all",
      ))
  }
}

/// Parses the value or range before any `/`, returning its inclusive
/// endpoints so that the stepped and unstepped forms share one walk.
fn parse_span(
  base: String,
  bounds: Bounds,
  item: String,
) -> Result(#(Int, Int), String) {
  case base == "*" {
    True -> Ok(#(bounds.low, bounds.high))

    False -> parse_numeric_span(base, bounds, item)
  }
}

fn parse_numeric_span(
  base: String,
  bounds: Bounds,
  item: String,
) -> Result(#(Int, Int), String) {
  case string.split(base, "-") {
    [single] -> {
      use value <- result.try(parse_bounded(single, bounds, item))
      Ok(#(value, value))
    }

    [low, high] -> {
      use from <- result.try(parse_bounded(low, bounds, item))
      use to <- result.try(parse_bounded(high, bounds, item))
      use Nil <- result.try(ascending(from, to, bounds, item))
      Ok(#(from, to))
    }

    // A range has one hyphen. Two or more is either a typo or an attempt
    // at a negative bound, and neither is in the grammar.
    [] | [_, _, _, ..] ->
      Error(unsupported(
        bounds,
        item,
        "a range is written `a-b`, with one hyphen and no negative bounds",
      ))
  }
}

/// A reversed range is refused rather than wrapped.
///
/// `5-1` on a day-of-week field looks like it should mean "Friday
/// through Monday", and some schedulers read it that way. This one does
/// not, so it says so: a wrapping reading here would disagree with the
/// list the writer could have written instead (`5,6,0,1`) about nothing
/// except which one they get.
fn ascending(
  from: Int,
  to: Int,
  bounds: Bounds,
  item: String,
) -> Result(Nil, String) {
  case from <= to {
    True -> Ok(Nil)

    False ->
      Error(unsupported(
        bounds,
        item,
        "a range runs upwards, so `a-b` needs a no greater than b: a "
          <> "wrapping range is written as a list instead",
      ))
  }
}

fn parse_bounded(
  text: String,
  bounds: Bounds,
  item: String,
) -> Result(Int, String) {
  use value <- result.try(parse_whole(text, bounds, item))

  case value < bounds.low || value > bounds.high {
    False -> Ok(value)

    True ->
      Error(
        "the cron "
        <> bounds.field
        <> " field takes "
        <> int.to_string(bounds.low)
        <> "-"
        <> int.to_string(bounds.high)
        <> ", so the "
        <> int.to_string(value)
        <> " in `"
        <> item
        <> "` is out of range",
      )
  }
}

/// Parses a run of digits, which is the only numeral shape the grammar
/// has. This is where every name and every extension lands, so this is
/// where they are named in the refusal.
fn parse_whole(
  text: String,
  bounds: Bounds,
  item: String,
) -> Result(Int, String) {
  case all_digits(text) {
    False -> Error(unsupported(bounds, item, grammar_reminder()))

    // `all_digits` has already excluded the empty string and every
    // non-digit, so the parse cannot fail — but it is a `Result`, and
    // mapping it keeps this function total without an assertion. The
    // mapper is lazy rather than a `replace_error` value: on this arm
    // the message is never used, and building it would be a sentence
    // formatted for every legal number in every legal expression.
    True ->
      result.map_error(int.parse(text), fn(_unparseable) {
        unsupported(bounds, item, grammar_reminder())
      })
  }
}

fn all_digits(text: String) -> Bool {
  text != "" && list.all(string.to_graphemes(text), is_digit)
}

fn is_digit(grapheme: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], grapheme)
}

/// The one refusal every unparseable item shares: what the grammar
/// actually is, and — named rather than left to be guessed at — the two
/// families of thing that look like cron and are not.
fn grammar_reminder() -> String {
  "a field is `*`, a number, a range `a-b`, a step `*/n` or `a-b/n`, or a "
  <> "comma-separated list of those — month and day names such as `JAN` or "
  <> "`MON` are not understood, and neither are the extensions `L`, `W`, "
  <> "`?` and `#`"
}

fn unsupported(bounds: Bounds, item: String, reason: String) -> String {
  "the cron "
  <> bounds.field
  <> " field does not understand `"
  <> item
  <> "`: "
  <> reason
}

/// Every value from `from` to `to` inclusive, taking every `step`th.
///
/// A step wider than the span yields just the span's first value, which
/// is what `*/90` on a minute field means and is why this is a walk
/// rather than a division.
fn stepped_values(
  from: Int,
  to: Int,
  step: Int,
  collected: List(Int),
) -> List(Int) {
  case from > to {
    True -> list.reverse(collected)
    False -> stepped_values(from + step, to, step, [from, ..collected])
  }
}

fn sorted_unique(values: List(Int)) -> List(Int) {
  values
  |> list.unique
  |> list.sort(int.compare)
}

// --- matching --------------------------------------------------------------

/// Whether the minute containing `at_s` is one the expression names.
///
/// The question is about the *minute*, not the second: cron's finest
/// grain is a minute, so every second of a matching minute matches. A
/// caller holding a tick instant can therefore ask directly without
/// having to align it first.
///
/// Minute, hour and month are ANDed. The two day fields are combined by
/// the OR rule the module doc states, and that combination is then ANDed
/// with the rest.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * *")
/// // 2026-09-02T09:00:37Z is inside the 09:00 minute.
/// assert cron.matches(expression, at_s: 1_788_339_637)
/// ```
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * *")
/// // 2026-09-02T08:59:00Z is not.
/// assert !cron.matches(expression, at_s: 1_788_339_540)
/// ```
///
pub fn matches(expression: Expression, at_s at_s: Int) -> Bool {
  let day = floor_div(at_s, seconds_per_day)
  let minute_of_day =
    floor_div(at_s - day * seconds_per_day, seconds_per_minute)

  day_matches(expression, civil_from_days(day), day)
  && list.contains(expression.hours, minute_of_day / minutes_per_hour)
  && list.contains(expression.minutes, minute_of_day % minutes_per_hour)
}

/// Whether a whole day is one the expression can fire on: the month, and
/// the two day fields under the OR rule.
///
/// Takes both the civil date and the day number because the two day
/// fields need different things from the same day — day-of-month is in
/// the date, and day-of-week is arithmetic on the day number — and
/// recomputing either from the other would be work already done.
fn day_matches(expression: Expression, date: Civil, day: Int) -> Bool {
  list.contains(expression.months, date.month)
  && day_of_week_or_month_matches(expression, date.day, day_of_week(day))
}

/// The OR rule itself, written as the four cases rather than as a flag
/// and a condition, so that a reader sees all four and the compiler
/// checks that all four are here.
fn day_of_week_or_month_matches(
  expression: Expression,
  day_of_month: Int,
  weekday: Int,
) -> Bool {
  case expression.days_of_month, expression.days_of_week {
    // Neither field constrains the date, so every day is a candidate.
    Unrestricted, Unrestricted -> True

    // One field restricted: it alone decides, and there is nothing to
    // OR it with.
    Restricted(values: days), Unrestricted -> list.contains(days, day_of_month)

    Unrestricted, Restricted(values: weekdays) ->
      list.contains(weekdays, weekday)

    // Both restricted: either one matching is enough. This is the arm
    // the module doc is about — `0 9 1 * 1` fires on the first of the
    // month *and* on Mondays, not on Mondays that are the first.
    Restricted(values: days), Restricted(values: weekdays) ->
      list.contains(days, day_of_month) || list.contains(weekdays, weekday)
  }
}

// --- searching -------------------------------------------------------------

/// The smallest minute-aligned epoch second strictly greater than
/// `after_s` that the expression matches, or `None` when there is none
/// within `search_horizon_days`.
///
/// Strictly greater is the contract a scanner needs: asked what comes
/// after the occurrence it has just fired, it must not be handed that
/// same occurrence again. So `0 9 * * 1-5` from a Friday 09:00:00
/// answers the following Monday, and from Friday 08:59:59 answers that
/// same Friday 09:00.
///
/// The search is by day, not by minute. Each day is tested against the
/// month and day fields once, and only a day that passes has its hour
/// and minute sets walked — in ascending order, so the first hit is the
/// answer. A day that matches always yields a minute, because a minute
/// set is never empty, so the minute walk runs at most once per call.
///
/// `None` means "not within the horizon", which for any expression that
/// recurs at all means "never" (see the module doc for the bound's
/// derivation). A caller should treat it as a schedule that will not
/// fire again rather than retrying with a later seed.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("*/5 * * * *")
/// // 2026-09-02T12:34:56Z -> 12:35:00Z.
/// assert cron.next_occurrence(expression, after_s: 1_788_352_496)
///   == Some(1_788_352_500)
/// ```
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 0 30 2 *")
/// // The thirtieth of February never comes.
/// assert cron.next_occurrence(expression, after_s: 0) == None
/// ```
///
pub fn next_occurrence(
  expression: Expression,
  after_s after_s: Int,
) -> Option(Int) {
  // The first minute-aligned second strictly after `after_s`: floor to
  // the minute and add one, which lands on the next minute whether or
  // not `after_s` was itself aligned.
  let candidate =
    floor_div(after_s, seconds_per_minute)
    * seconds_per_minute
    + seconds_per_minute

  let day = floor_div(candidate, seconds_per_day)
  let from_minute =
    floor_div(candidate - day * seconds_per_day, seconds_per_minute)

  next_from(
    expression,
    day,
    civil_from_days(day),
    from_minute,
    search_horizon_days,
  )
}

/// The largest matching minute-aligned epoch second strictly less than
/// `before_s`, or `None` when there is none within
/// `search_horizon_days`.
///
/// The mirror of `next_occurrence`, and it exists for the same reason
/// `client/schedule.interval_late` looks at the preceding slot: to judge
/// whether a fire is landing in the window it was due in, a scanner has
/// to know which window that was, and for cron the preceding window
/// cannot be computed by subtracting an interval. Strictly less matters
/// here for the same reason strictly greater does there — asked about
/// the instant of an occurrence, this must answer the one before it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * 1-5")
/// // From Monday 2026-09-07T09:00:00Z back to Friday 2026-09-04T09:00Z.
/// assert cron.previous_occurrence(expression, before_s: 1_788_771_600)
///   == Some(1_788_512_400)
/// ```
///
pub fn previous_occurrence(
  expression: Expression,
  before_s before_s: Int,
) -> Option(Int) {
  // The last minute-aligned second strictly before `before_s`: floor
  // `before_s - 1` to the minute. When `before_s` is itself aligned that
  // steps a whole minute back; otherwise it lands on the minute
  // `before_s` is inside.
  let candidate =
    floor_div(before_s - 1, seconds_per_minute) * seconds_per_minute

  let day = floor_div(candidate, seconds_per_day)
  let upto_minute =
    floor_div(candidate - day * seconds_per_day, seconds_per_minute)

  previous_from(
    expression,
    day,
    civil_from_days(day),
    upto_minute,
    search_horizon_days,
  )
}

/// Walks days forward from `day`, whose civil date is `date`, looking
/// for the first match at or after `from_minute` on that day.
///
/// `day` and `date` are advanced together rather than one being derived
/// from the other each step: the day number is what an epoch second is
/// built from and the date is what the month and day-of-month fields are
/// tested against, and stepping both is one addition and one calendar
/// increment instead of a full days-to-civil conversion per day.
///
/// `remaining` is the horizon, counted in days examined. It is the only
/// thing that terminates this walk, because an expression may name a
/// date that does not exist.
fn next_from(
  expression: Expression,
  day: Int,
  date: Civil,
  from_minute: Int,
  remaining: Int,
) -> Option(Int) {
  use <- bool.lazy_guard(when: remaining <= 0, return: fn() { None })

  // Moving to the next day drops the minute floor: only the seeded day
  // is bounded below, by the caller's instant. Every later day is a
  // whole day of candidates.
  let advance = fn() {
    next_from(expression, day + 1, next_date(date), 0, remaining - 1)
  }

  use <- bool.lazy_guard(
    when: !day_matches(expression, date, day),
    return: advance,
  )

  expression.hours
  |> first_minute_at_or_after(expression.minutes, from_minute)
  |> option.map(instant_of(day, _))
  |> option.lazy_or(advance)
}

/// The mirror of `next_from`: days backwards, and within a matching day
/// the latest minute at or before `upto_minute`.
fn previous_from(
  expression: Expression,
  day: Int,
  date: Civil,
  upto_minute: Int,
  remaining: Int,
) -> Option(Int) {
  use <- bool.lazy_guard(when: remaining <= 0, return: fn() { None })

  // Retreating lifts the minute ceiling to the last minute of the day,
  // for the same reason advancing drops the floor to zero.
  let retreat = fn() {
    previous_from(
      expression,
      day - 1,
      previous_date(date),
      minutes_per_day - 1,
      remaining - 1,
    )
  }

  use <- bool.lazy_guard(
    when: !day_matches(expression, date, day),
    return: retreat,
  )

  expression.hours
  |> last_minute_at_or_before(expression.minutes, upto_minute)
  |> option.map(instant_of(day, _))
  |> option.lazy_or(retreat)
}

fn instant_of(day: Int, minute_of_day: Int) -> Int {
  day * seconds_per_day + minute_of_day * seconds_per_minute
}

/// The earliest minute-of-day at or after `from` that the hour and
/// minute sets both admit, if there is one on this day.
///
/// Both sets are ascending, so folding over the hours and keeping the
/// first hit is the answer. An hour earlier than `from`'s hour needs a
/// minute of sixty or more and so contributes nothing; an hour later
/// needs a negative one and so admits its whole minute set. That is why
/// no explicit hour comparison appears here — the threshold arithmetic
/// already says it.
fn first_minute_at_or_after(
  hours: List(Int),
  minutes: List(Int),
  from: Int,
) -> Option(Int) {
  use earliest, hour <- list.fold(hours, None)

  let candidate =
    minutes
    |> first_at_or_after(from - hour * minutes_per_hour)
    |> option.map(fn(minute) { hour * minutes_per_hour + minute })

  // Hours ascend, so an answer already found is the earlier one and
  // wins. Both sides are values in hand, so the eager `or` is free.
  option.or(earliest, candidate)
}

/// The mirror: the latest minute-of-day at or before `upto`.
fn last_minute_at_or_before(
  hours: List(Int),
  minutes: List(Int),
  upto: Int,
) -> Option(Int) {
  use latest, hour <- list.fold(hours, None)

  let candidate =
    minutes
    |> last_at_or_before(upto - hour * minutes_per_hour)
    |> option.map(fn(minute) { hour * minutes_per_hour + minute })

  // Hours ascend, so here the *later* candidate is the better one and
  // takes precedence over what was found before it.
  option.or(candidate, latest)
}

fn first_at_or_after(values: List(Int), from: Int) -> Option(Int) {
  case values {
    [] -> None

    [value, ..rest] ->
      case value >= from {
        True -> Some(value)
        False -> first_at_or_after(rest, from)
      }
  }
}

/// The largest value no greater than `upto`. The list ascends, so the
/// last one that qualifies is the answer and a single fold finds it.
fn last_at_or_before(values: List(Int), upto: Int) -> Option(Int) {
  use best, value <- list.fold(values, None)

  case value <= upto {
    True -> Some(value)
    False -> best
  }
}

// --- calendar arithmetic ---------------------------------------------------
//
// All of it integer, all of it pure, none of it a clock. Epoch seconds
// may be negative — nothing here assumes 1970 is the earliest instant —
// so every division that could see a negative numerator floors rather
// than truncating.

/// Integer division that rounds towards negative infinity.
///
/// Erlang's `div` truncates towards zero, so `-1 / 86400` is `0` and the
/// day before the epoch would come out as day zero — the same day as the
/// epoch itself. Flooring is what makes "days since the epoch" a
/// monotone function of the instant, which every derivation below rests
/// on. `denominator` is positive at every call site here.
fn floor_div(numerator: Int, denominator: Int) -> Int {
  let quotient = numerator / denominator

  case numerator % denominator < 0 {
    True -> quotient - 1
    False -> quotient
  }
}

/// The non-negative remainder, for the same reason `floor_div` floors:
/// Erlang's `rem` takes the sign of the dividend, and a negative weekday
/// index would index nothing.
fn floor_mod(numerator: Int, denominator: Int) -> Int {
  numerator - floor_div(numerator, denominator) * denominator
}

/// The day of the week of a day number, 0 for Sunday through 6 for
/// Saturday.
///
/// 1970-01-01 was a Thursday, so day 0 is weekday 4 and the offset is
/// `+ 4`. The modulo is the flooring one because day numbers before the
/// epoch are negative.
fn day_of_week(day: Int) -> Int {
  floor_mod(day + 4, 7)
}

/// The civil UTC date of a day number, by Howard Hinnant's
/// `civil_from_days`.
///
/// The algorithm's trick is to move the start of the year to March, so
/// that the leap day lands at the *end* of the year and every month
/// before it has a fixed length. That turns the whole calendar into
/// arithmetic on a 400-year era with no special cases at all, and it is
/// why the steps below talk about eras and about a year that starts in
/// March. Each step is commented; the shape is not guessable from the
/// constants.
fn civil_from_days(day: Int) -> Civil {
  // Shift the epoch from 1970-01-01 to 0000-03-01, the start of a
  // 400-year era. 719468 is the number of days between the two.
  let shifted = day + 719_468

  // Which 400-year era the day falls in, and how far into it. An era is
  // 146097 days — 400 years of 365 days plus 97 leap days — and that
  // count is exact, which is the whole reason the era is the unit.
  let era = floor_div(shifted, 146_097)
  let day_of_era = shifted - era * 146_097

  // The year within the era, 0-399. The three correction terms remove
  // the leap days already counted: one per four years, less one per
  // century, plus one back for the last day of the era.
  let year_of_era =
    {
      day_of_era
      - day_of_era
      / 1460
      + day_of_era
      / 36_524
      - day_of_era
      / 146_096
    }
    / 365

  let year = year_of_era + era * 400

  // How far into the March-started year the day is, 0-365: the day of
  // the era less every day belonging to the years before this one.
  let day_of_year =
    day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }

  // The month index counting from March, 0-11. The 153/5 pair is the
  // exact average length of a month in the five-month 31-30-31-30-31
  // cycle the shifted calendar repeats, which is what makes this a
  // division rather than a table.
  let month_from_march = { 5 * day_of_year + 2 } / 153
  let day = day_of_year - { 153 * month_from_march + 2 } / 5 + 1

  // Back to a January-started month. March is index 0, so the first ten
  // indices are months 3-12 and the last two wrap to January and
  // February.
  let month = case month_from_march < 10 {
    True -> month_from_march + 3
    False -> month_from_march - 9
  }

  // January and February belong to the *next* calendar year, since the
  // shifted year began in March.
  case month <= 2 {
    True -> Civil(year: year + 1, month:, day:)
    False -> Civil(year:, month:, day:)
  }
}

/// The Gregorian leap year rule: every fourth year, except every
/// hundredth, except every four-hundredth.
///
/// The century exception is the clause a reimplementation forgets, and
/// forgetting it is not a rounding error — it invents a 29th of February
/// in 1900, 2100 and 2200, and every date after one of those shifts by a
/// day. The `% 400` clause is what puts 2000 and 2400 back.
fn is_leap_year(year: Int) -> Bool {
  year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 }
}

fn days_in_month(year: Int, month: Int) -> Int {
  case month == 2 {
    True ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }

    // April, June, September and November are the short ones; the rest
    // are 31. Written as a membership test rather than as twelve arms so
    // that no catch-all is needed for an out-of-range month.
    False ->
      case list.contains([4, 6, 9, 11], month) {
        True -> 30
        False -> 31
      }
  }
}

/// The calendar day after `date`.
fn next_date(date: Civil) -> Civil {
  case date.day < days_in_month(date.year, date.month) {
    True -> Civil(..date, day: date.day + 1)
    False -> first_of_next_month(date)
  }
}

fn first_of_next_month(date: Civil) -> Civil {
  case date.month == 12 {
    True -> Civil(year: date.year + 1, month: 1, day: 1)
    False -> Civil(..date, month: date.month + 1, day: 1)
  }
}

/// The calendar day before `date`.
fn previous_date(date: Civil) -> Civil {
  case date.day > 1 {
    True -> Civil(..date, day: date.day - 1)
    False -> last_of_previous_month(date)
  }
}

fn last_of_previous_month(date: Civil) -> Civil {
  case date.month == 1 {
    True -> Civil(year: date.year - 1, month: 12, day: 31)

    False -> {
      let month = date.month - 1
      Civil(..date, month:, day: days_in_month(date.year, month))
    }
  }
}
