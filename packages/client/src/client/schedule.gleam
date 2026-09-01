//// Scheduled heartbeats: the operator-authored store, the durable
//// fired-mark key shapes, and the fenced text one fire actually injects.
////
//// `docs/design-notes/scheduled-heartbeats.md` is the design ruling this
//// module implements; read it before changing a bound or a refusal here.
//// The shape is `client/rules` verbatim — an operator-authored,
//// parsed-and-bounded config store plus a fenced, non-authority-framed
//// injection — reused because the argument for keeping a rule out of a
//// model's context until it is relevant applies just as well to a fire
//// that is due on a clock rather than triggered by a literal match.
//// `client/schedulescan` is the actor that watches the clock; this module
//// is the store half.
////
//// ## Two kinds of schedule, one `Schedule`
////
//// A schedule reaches the scanner from one of two places, and the value
//// is the same either way — same type, same bounds, same code path once
//// it is running.
////
//// **The operator's**, a `[[schedule]]` table in `loom.toml`, parsed at
//// boot by `parse`. These live beside rules and the model catalogue, an
//// operator edits them with an editor, and restarting the server *is*
//// the trust decision, exactly as it is for `[[rule]]`.
////
//// **The model's**, created through `tools/schedule` and stored as a
//// reserved `schedule/config/…` cell (see `config_key`, `encode`,
//// `decode`). The first version of this feature had no such thing: a
//// schedule injects text into a model's own context on a timer with
//// nobody necessarily present, so letting a model write one was ruled a
//// way for it to extend its own liveness and spend unsupervised. What
//// changed is not the risk assessment but the *bound* — every recurring
//// schedule now carries a mandatory expiry no model can raise, which
//// turns "unsupervised forever" into "unsupervised for at most
//// `default_max_fires` fires or a week." `Policy` is the operator's say
//// over that door and defaults open; read its doc comment for the whole
//// argument, and `docs/design-notes/scheduled-heartbeats.md`'s addendum
//// for what the reversal cost.
////
//// The bounds are the important part of "the same value either way": a
//// model-created schedule is built by `build`, which enforces exactly
//// what `parse` enforces, through the same predicates and constants. The
//// two paths word their refusals differently — one names a TOML key an
//// operator must go and edit, the other names an argument a model just
//// wrote — and can never disagree about what is allowed.
////
//// ```toml
//// [[schedule]]
//// name = "watch-subagent"
//// every = "300s"
//// target = "sub:main/reviewer-abc123"
//// wake = true
//// body = "Check on the review subagent and steer it if it has stalled."
////
//// [[schedule]]
//// name = "one-shot-reminder"
//// at = "2026-09-01T09:00:00Z"
//// body = "The migration window opens today. Confirm the plan is ready."
//// ```
////
//// ## Interval and one-shot, and nothing else
////
//// A schedule is either a fixed interval (`every = "300s"`, a positive
//// whole number of seconds followed by a literal `s`) or a one-shot
//// (`at`, an RFC3339 UTC timestamp) — never both, and never neither. No
//// five-field cron syntax and no timezone handling beyond UTC epoch
//// seconds: the design note cuts both as a swamp neither prior-art use
//// case (watching a subagent, polling unattended) needs.
////
//// ## Expiry is mandatory for a recurring schedule, always both bounds
////
//// An `every` schedule always carries an `Expiry`, defaulted when the
//// operator does not set it: `max_fires` defaults to and caps at 1000,
//// `expires_after_s` defaults to and caps at 604800 seconds (7 days).
//// Whichever bound is hit first ends the schedule — "both bounds,
//// always, earliest wins," not "either/or" — which is what keeps the
//// worst case at exactly 1000 fire-mark rows per schedule rather than
//// leaving an operator free to write a 60-second-interval, 7-day,
//// no-`max_fires` schedule that would leave 10,080. A one-shot schedule
//// carries no `Expiry` at all: its occurrence count is 1 by
//// construction, so there is nothing left for a bound to protect.
////
//// ## `wake`: opt-in, and why it may default to something rules cannot
////
//// A rule may only steer an already-open run, because content arrives
//// constantly and unpredictably and a rule that could wake an idle
//// strand could keep a session alive forever, one fire at a time. A
//// schedule breaks every leg of that argument — it is operator-authored,
//// time-driven, and (see above) always expires — so `wake = true` is
//// offered as an opt-in per schedule: a schedule with `wake = false`
//// (the default) steers an open run and holds when the strand is idle,
//// exactly like a rule; `wake = true` may start a fresh run on an idle
//// strand. The expiry above is what makes that safe: a `wake = true`
//// schedule cannot keep a session alive past a bound the operator set
//// and can see in the config file.
////
//// ## The bounds, and why each one is here
////
//// Every limit below refuses at parse time with a worded message, the
//// same discipline `client/rules` uses, because the alternative is a
//// config that boots and then behaves strangely. `max_schedules` bounds
//// how many standing clocks one session may run. `min_interval_s` is
//// comfortably above timer/poll granularity and keeps an `every`
//// schedule from being a busy-loop against provider budget.
//// `max_name_length` and the character rules on a name are copied from
//// `client/rules.max_name_length` verbatim, for the identical reason:
//// the name is a durable key segment and appears inside the injected
//// fence, so a `/`, a newline or a quote in it would make one of those
//// ambiguous. `max_target_length` bounds a strand name defensively —
//// `client/rules` has no direct analog, since a rule always steers its
//// own strand, but a schedule names its target explicitly. `max_fires`
//// and `expires_after_s` are bounded as described above.
////
//// ## Parsing an RFC3339 `at`
////
//// `gleam_time` — already resolved into this build as `tom`'s own
//// dependency, since TOML itself has a native (unquoted) datetime
//// literal — ships `gleam/time/timestamp.parse_rfc3339`, a total,
//// non-backtracking parser for exactly this grammar, plus
//// `to_unix_seconds_and_nanoseconds` to read the result back out as
//// epoch time. Rather than write a second RFC3339 parser, or accept
//// TOML's own bare datetime literal (which would let `at` silently mean
//// something other than the UTC instant this module works in), `at` is
//// parsed as an ordinary quoted string and handed straight to that
//// function. `gleam_time` is declared as a direct dependency of this
//// package for that reason — see `gleam.toml`.

import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import runtime/api
import tom

/// One scheduled heartbeat as the operator wrote it.
///
/// Constructor invariants (guaranteed by `parse`, owed by any direct
/// construction): `name` is unique in its list, non-empty, at most
/// `max_name_length` characters, and contains no `/`, no `"` and no
/// newline; `target` is non-empty and at most `max_target_length`
/// characters; `body` is non-empty and at most `max_body_length`
/// characters.
pub type Schedule {
  Schedule(
    /// The operator's handle for the schedule: the durable fired-mark's
    /// key segment, and the name the injected text attributes itself to.
    name: String,
    /// The strand this schedule addresses, by name — `"main"` unless the
    /// operator names a specific one (a subagent strand, say).
    target: String,
    /// The fixed interval or the one-shot instant this schedule fires on.
    timing: Timing,
    /// Whether this schedule may start a fresh run on an idle strand.
    /// `False` (the default) steers an open run and holds when idle,
    /// exactly like a triggered project rule.
    wake: Bool,
    /// The text injected, once per due occurrence.
    body: String,
  )
}

/// When a schedule fires.
///
/// `Interval` aligns to a fixed grid — `slot = floor(now_s /
/// interval_s)` — and always carries an `Expiry`; `OneShot` fires once,
/// at or after `at` (epoch seconds, UTC), and carries no expiry because
/// its occurrence count is 1 by construction.
pub type Timing {
  Interval(seconds: Int, expiry: Expiry)
  OneShot(at: Int)
}

/// The mandatory bounds a recurring schedule expires under. Whichever is
/// reached first ends the schedule — "both bounds, always, earliest
/// wins."
pub type Expiry {
  Expiry(max_fires: Int, expires_after_s: Int)
}

/// The most `[[schedule]]` entries one configuration may define. Each is
/// a standing clock; raising this later needs evidence, not a knob.
pub const max_schedules = 16

/// The shortest interval an `every` schedule may name, in seconds.
/// Anything tighter is a busy-loop against provider budget.
pub const min_interval_s = 60

/// The longest a schedule name may be, in characters. Copied from
/// `client/rules.max_name_length`: the name is a durable key segment and
/// is quoted inside the injected fence.
pub const max_name_length = 64

/// The longest a schedule body may be, in characters. Copied from
/// `client/rules.max_body_length`: a schedule is supposed to cost less
/// than the prompt line it replaces.
pub const max_body_length = 8192

/// The longest a schedule's target strand name may be, in characters.
/// Bounded defensively even though `client/rules` has no direct analog.
pub const max_target_length = 64

/// `max_fires`'s default when an `every` schedule does not set one, and
/// also its ceiling when it does.
pub const default_max_fires = 1000

/// `max_fires`'s ceiling. Identical to `default_max_fires`: the default
/// already sits at the cap, so a smaller explicit value narrows it and a
/// larger one is refused.
pub const max_max_fires = 1000

/// `expires_after_s`'s default when an `every` schedule does not set
/// one, and also its ceiling when it does: 604800 seconds, 7 days —
/// matching Claude Code's own auto-expiry.
pub const default_expires_after_s = 604_800

/// `expires_after_s`'s ceiling. Identical to `default_expires_after_s`
/// for the same reason `max_max_fires` is: the default already sits at
/// the cap.
pub const max_expires_after_s = 604_800

// The strand a schedule addresses when the operator names none.
const default_target = "main"

// A defensive bound on the *string* `every` is written as, not on the
// interval it names — comfortably wider than any real interval (even
// `604800s`) while keeping the digit scan below it bounded (lint R5).
const max_every_length = 20

// A defensive bound on the RFC3339 string `at` is written as. Generous
// for the full grammar (date, time, fractional seconds, an offset) while
// keeping a pathological value out of the parser.
const max_at_length = 40

// --- parsing -----------------------------------------------------------

/// Parses the `[[schedule]]` entries of a `loom.toml` document. Total:
/// every failure is a human-worded `Error` naming the offending entry
/// and key, which is what the server prints when it refuses to boot.
///
/// Entries keep **file order**; nothing here depends on it the way
/// `client/rules` depends on trigger order, but it costs nothing to
/// preserve and a re-ordered config is a confusing diff to review
/// otherwise.
///
/// Only `[[schedule]]` is read here. This parser reads the same document
/// `client/rules.parse` and `client/catalog.parse` do and is strict about
/// everything inside a schedule and silent about everything outside one,
/// so the three can share one file without any of them knowing the
/// others' schemas.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.parse("") == Ok([])
/// ```
///
/// ```gleam
/// assert schedule.parse("[[schedule]]\nname = \"\"\nevery = \"300s\"\nbody = \"b\"")
///   == Error("schedule 1.name must be non-empty")
/// ```
///
pub fn parse(text: String) -> Result(List(Schedule), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(describe_parse_error),
  )
  parse_document(document)
}

// The document half of `parse`. Not a public door, for the same reason
// `client/rules.parse_document` is not one: each config parser pays its
// own small `tom.parse` at boot and keeps its own worded failure.
fn parse_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Schedule), String) {
  use tables <- result.try(case dict.get(document, "schedule") {
    Error(Nil) -> Ok([])
    Ok(tom.ArrayOfTables(tables)) -> Ok(tables)
    Ok(_other) ->
      Error(
        "schedule must be an array of [[schedule]] tables, each with "
        <> "name, a timing (every or at), and body",
      )
  })
  use Nil <- result.try(bounded_count(list.length(tables)))
  use parsed <- result.try(
    tables
    |> list.index_map(fn(fields, index) { parse_schedule(index + 1, fields) })
    |> result.all,
  )
  use Nil <- result.try(unique_names(parsed, []))
  Ok(parsed)
}

fn parse_schedule(
  position: Int,
  fields: Dict(String, tom.Toml),
) -> Result(Schedule, String) {
  let place = "schedule " <> string.inspect(position)
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    [
      "name", "target", "every", "at", "max_fires", "expires_after_s", "wake",
      "body",
    ],
    place,
  ))
  use name <- result.try(schedule_name(fields, place))

  // Once the schedule has a name, say the name: an operator reading a
  // refusal about `schedule 7` has to count tables to find it.
  let place = place <> " (" <> name <> ")"
  use target <- result.try(schedule_target(fields, place))
  use timing <- result.try(schedule_timing(fields, place))
  use wake <- result.try(schedule_wake(fields, place))
  use body <- result.try(bounded_string(fields, place, "body", max_body_length))
  Ok(Schedule(name:, target:, timing:, wake:, body:))
}

// The name is a durable key segment (`fired_key`) and it is quoted
// inside the injected fence — the same two reasons, and the same
// characters, `client/rules.rule_name` refuses.
fn schedule_name(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(String, String) {
  use name <- result.try(bounded_string(fields, place, "name", max_name_length))
  case name_breaks_key(name), name_breaks_fence(name) {
    True, _ ->
      Error(
        place
        <> ".name must not contain `/`: the name is a key segment of the "
        <> "durable fired-mark, and the occurrence number that follows it "
        <> "would become unreadable",
      )
    _, True ->
      Error(
        place
        <> ".name must not contain a quote or a newline: the name is "
        <> "quoted inside the injected text, which those would break out "
        <> "of",
      )
    False, False -> Ok(name)
  }
}

// The two character rules a name owes, as predicates rather than as
// spellings inside one refusal: `build` holds a model-created schedule to
// exactly these, and a bound with two definitions is a bound that drifts.
fn name_breaks_key(name: String) -> Bool {
  string.contains(name, "/")
}

fn name_breaks_fence(name: String) -> Bool {
  string.contains(name, "\"") || string.contains(name, "\n")
}

// `target` is a live strand address, and strand names in this system may
// themselves contain `/` (a spawned subagent's name does) — so, unlike
// `name`, no character is refused here, only the length and emptiness a
// strand address always owes.
fn schedule_target(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(String, String) {
  case dict.get(fields, "target") {
    Error(Nil) -> Ok(default_target)
    Ok(tom.String("")) -> Error(place <> ".target must be non-empty")
    Ok(tom.String(text)) ->
      case too_long(text, max_target_length) {
        True ->
          Error(
            place
            <> ".target must be at most "
            <> string.inspect(max_target_length)
            <> " characters",
          )
        False -> Ok(text)
      }
    Ok(_other) -> Error(place <> ".target must be a string")
  }
}

// Exactly one of `every`/`at`, and the keys each licenses.
fn schedule_timing(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Timing, String) {
  case dict.has_key(fields, "every"), dict.has_key(fields, "at") {
    True, True ->
      Error(
        place
        <> ".every and .at are mutually exclusive: a schedule is either a "
        <> "fixed interval or a one-shot, never both",
      )
    False, False ->
      Error(
        place
        <> " must set exactly one of .every or .at: a fixed interval or a "
        <> "one-shot",
      )
    True, False -> {
      use seconds <- result.try(interval_seconds(fields, place))
      use expiry <- result.try(interval_expiry(fields, place))
      Ok(Interval(seconds:, expiry:))
    }
    False, True -> {
      use Nil <- result.try(refuse_interval_only_keys(fields, place))
      use at <- result.try(one_shot_at(fields, place))
      Ok(OneShot(at:))
    }
  }
}

fn interval_seconds(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Int, String) {
  use text <- result.try(bounded_string(
    fields,
    place,
    "every",
    max_every_length,
  ))
  parse_every(text, place)
}

// A positive whole number of seconds followed by a literal `s` — no
// other unit, no negative or zero duration, and never below
// `min_interval_s`. The digit scan is bounded by `max_every_length`
// having already refused anything longer.
fn parse_every(text: String, place: String) -> Result(Int, String) {
  case string.ends_with(text, "s") {
    False ->
      Error(
        place
        <> ".every must be a positive number of seconds followed by `s`, "
        <> "for example `300s` — no other unit is understood",
      )
    True -> {
      let digits = string.drop_end(text, 1)
      case all_digits(digits) {
        False ->
          Error(
            place
            <> ".every must be a positive whole number of seconds followed "
            <> "by `s`, for example `300s`",
          )
        True -> parsed_every_seconds(int.parse(digits), place)
      }
    }
  }
}

fn parsed_every_seconds(
  parsed: Result(Int, Nil),
  place: String,
) -> Result(Int, String) {
  case parsed {
    Error(Nil) ->
      Error(
        place
        <> ".every must be a positive whole number of seconds followed by "
        <> "`s`, for example `300s`",
      )
    Ok(seconds) if seconds <= 0 ->
      Error(place <> ".every must be a positive number of seconds")
    Ok(seconds) if seconds > max_interval_s ->
      Error(
        place
        <> ".every is "
        <> string.inspect(seconds)
        <> "s, above the "
        <> string.inspect(max_interval_s)
        <> "s maximum: a longer interval than the expiry window can never "
        <> "fire twice — use `at` for a one-shot",
      )
    Ok(seconds) if seconds < min_interval_s ->
      Error(
        place
        <> ".every is "
        <> string.inspect(seconds)
        <> "s, below the "
        <> string.inspect(min_interval_s)
        <> "s minimum: anything tighter is a busy-loop against provider "
        <> "budget",
      )
    Ok(seconds) -> Ok(seconds)
  }
}

fn all_digits(text: String) -> Bool {
  text != "" && list.all(string.to_graphemes(text), is_digit)
}

fn is_digit(grapheme: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], grapheme)
}

// The two keys that only mean something beside `every`. A one-shot's
// occurrence count is 1 by construction, so either one here is a
// contradiction worth naming rather than silently ignoring.
fn refuse_interval_only_keys(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Nil, String) {
  case dict.has_key(fields, "max_fires") {
    True ->
      Error(
        place
        <> ".max_fires is only valid alongside .every: a one-shot "
        <> "schedule fires exactly once by construction",
      )
    False ->
      case dict.has_key(fields, "expires_after_s") {
        True ->
          Error(
            place
            <> ".expires_after_s is only valid alongside .every: a "
            <> "one-shot schedule fires exactly once by construction",
          )
        False -> Ok(Nil)
      }
  }
}

// Both bounds, always, whichever the operator states or not — a
// recurring schedule's expiry is never optional (see the module doc).
fn interval_expiry(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Expiry, String) {
  use max_fires <- result.try(bounded_int(
    fields,
    place,
    "max_fires",
    1,
    max_max_fires,
  ))
  use expires_after_s <- result.try(bounded_int(
    fields,
    place,
    "expires_after_s",
    1,
    max_expires_after_s,
  ))
  Ok(Expiry(
    max_fires: option.unwrap(max_fires, default_max_fires),
    expires_after_s: option.unwrap(expires_after_s, default_expires_after_s),
  ))
}

fn one_shot_at(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Int, String) {
  use text <- result.try(bounded_string(fields, place, "at", max_at_length))
  parse_at(text, place)
}

// `at` is a quoted string, not TOML's own bare datetime literal — see
// the module doc's "Parsing an RFC3339 `at`" section for why.
fn parse_at(text: String, place: String) -> Result(Int, String) {
  case timestamp.parse_rfc3339(text) {
    Error(Nil) ->
      Error(
        place
        <> ".at must be a quoted RFC3339 UTC timestamp, for example "
        <> "\"2026-01-01T00:00:00Z\"",
      )
    Ok(instant) -> {
      let #(seconds, _nanoseconds) =
        timestamp.to_unix_seconds_and_nanoseconds(instant)
      Ok(seconds)
    }
  }
}

fn schedule_wake(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Bool, String) {
  case dict.get(fields, "wake") {
    Error(Nil) -> Ok(False)
    Ok(tom.Bool(value)) -> Ok(value)
    Ok(_other) -> Error(place <> ".wake must be a boolean")
  }
}

// Duplicate names are refused rather than resolved, because the name is
// the fired-mark's key segment: two schedules sharing one would let one
// schedule's occurrences collide with the other's.
fn unique_names(
  remaining: List(Schedule),
  seen: List(String),
) -> Result(Nil, String) {
  case remaining {
    [] -> Ok(Nil)
    [schedule, ..rest] ->
      case list.contains(seen, schedule.name) {
        True ->
          Error(
            "two schedules are named "
            <> schedule.name
            <> ": a schedule's name is a key segment of its durable "
            <> "fired-marks, so a shared name would let one schedule's "
            <> "occurrences collide with the other's",
          )
        False -> unique_names(rest, [schedule.name, ..seen])
      }
  }
}

fn bounded_string(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
  limit: Int,
) -> Result(String, String) {
  case dict.get(fields, key) {
    Error(Nil) -> Error(place <> "." <> key <> " is required")
    Ok(tom.String("")) -> Error(place <> "." <> key <> " must be non-empty")
    Ok(tom.String(text)) ->
      case too_long(text, limit) {
        True ->
          Error(
            place
            <> "."
            <> key
            <> " must be at most "
            <> string.inspect(limit)
            <> " characters",
          )
        False -> Ok(text)
      }
    Ok(_other) -> Error(place <> "." <> key <> " must be a string")
  }
}

fn bounded_int(
  fields: Dict(String, tom.Toml),
  place: String,
  key: String,
  min: Int,
  max: Int,
) -> Result(Option(Int), String) {
  case dict.get(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(tom.Int(value)) ->
      case value < min || value > max {
        True ->
          Error(
            place
            <> "."
            <> key
            <> " must be between "
            <> string.inspect(min)
            <> " and "
            <> string.inspect(max),
          )
        False -> Ok(Some(value))
      }
    Ok(_other) -> Error(place <> "." <> key <> " must be an integer")
  }
}

// Asks whether a string is longer than the bound without walking a
// pathological value to its end (lint R5), the way `client/rules` bounds
// a rule's fields.
fn too_long(text: String, limit: Int) -> Bool {
  string.drop_start(text, limit) != ""
}

fn bounded_count(count: Int) -> Result(Nil, String) {
  case count > max_schedules {
    False -> Ok(Nil)
    True ->
      Error(
        "this configuration defines "
        <> string.inspect(count)
        <> " schedules, more than the "
        <> string.inspect(max_schedules)
        <> " standing clocks a session can afford",
      )
  }
}

// The catalogue's and the rule store's strictness helper, restated
// rather than imported: this parser answers about a different set of
// keys and must not depend on either's private surface.
fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

fn describe_parse_error(error: tom.ParseError) -> String {
  case error {
    tom.Unexpected(got:, expected:) ->
      "not valid toml: expected " <> expected <> ", got `" <> got <> "`"
    tom.KeyAlreadyInUse(key:) ->
      "not valid toml: the key " <> string.join(key, ".") <> " appears twice"
  }
}

// --- the durable half --------------------------------------------------

/// The reserved `fact.custom` key of one schedule's write-once fired-mark
/// for one occurrence on one strand. Write-once is the whole
/// at-most-once story: the scanner commits this cell in the same
/// transaction as the injection (or the fresh-run admission, for
/// `wake = true`), expecting it absent — a replay after a crash loses
/// the race to its own earlier self rather than firing twice.
///
/// `occurrence` is the slot's epoch second for an `Interval` schedule
/// (`slot * seconds`, not the slot number itself — `client/schedulescan`
/// computes it) or the `at` epoch second for a `OneShot` schedule, which
/// is what keeps `fired_key_prefix` a clean prefix of every occurrence
/// this schedule could ever produce.
///
/// The strand and name segments are unambiguous even though `target` may
/// itself contain a `/` (a spawned subagent's name can): `occurrence` is
/// always rendered as plain digits and `name` may never contain a `/`
/// (see `Schedule`), so the last `/`-delimited segment is always the
/// occurrence and the one before it is always the name, however many
/// slashes the strand segment carries.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.fired_key(strand: "main", name: "heartbeat", occurrence: 300)
///   == "schedule/fired/main/heartbeat/300"
/// ```
///
pub fn fired_key(
  strand strand: String,
  name name: String,
  occurrence occurrence: Int,
) -> String {
  api.schedule_fact_prefix
  <> "fired/"
  <> strand
  <> "/"
  <> name
  <> "/"
  <> int.to_string(occurrence)
}

/// The prefix every one of one schedule's fired-marks on one strand
/// shares — `fired_key` with the occurrence number left off. This is
/// what `client/schedulescan` scans with `runtime/api.reserved_facts` to
/// count a schedule's total fires and find its earliest occurrence,
/// which is the whole of how expiry is computed: no separate counter,
/// no cached "started at," just a bounded scan of the marks themselves.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.fired_key_prefix(strand: "main", name: "heartbeat")
///   == "schedule/fired/main/heartbeat/"
/// ```
///
pub fn fired_key_prefix(strand strand: String, name name: String) -> String {
  api.schedule_fact_prefix <> "fired/" <> strand <> "/" <> name <> "/"
}

/// The mark's stored value: the schedule name, so an operator reading
/// the reserved namespace sees what fired rather than inferring it from
/// a key.
///
/// ## Examples
///
/// ```gleam
/// // schedule.fired_value(sched) == json.String("heartbeat")
/// ```
///
pub fn fired_value(schedule: Schedule) -> JsonValue {
  json.String(schedule.name)
}

// --- interval occurrence arithmetic --------------------------------------
//
// Pure and exported so `client/schedulescan`'s tick handler stays a thin
// wrapper and this arithmetic — the one place a fencepost error would be
// easy to make and easy to miss in an actor test — gets a direct,
// deterministic unit test instead of only an actor-and-timer-driven one.

/// The `Interval` slot `now_s` falls in, named by its own epoch second
/// (`slot * seconds`, not the slot number) — what `fired_key` stores as
/// `occurrence` and what every other function here takes as one.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.interval_occurrence(seconds: 60, now_s: 125) == 120
/// ```
///
pub fn interval_occurrence(seconds seconds: Int, now_s now_s: Int) -> Int {
  { now_s / seconds } * seconds
}

/// Whether an about-to-fire occurrence should be annotated `late`: not
/// this schedule's very first occurrence ever, and the immediately
/// preceding slot's occurrence is missing from what has already fired.
///
/// The first fire is never late — there is no prior window it could have
/// missed. Otherwise, on-time firing means the previous tick landed on
/// the immediately preceding slot, so that occurrence's mark exists; a
/// skipped window means nothing ever ticked during it, so the mark does
/// not. This is derived entirely from `occurrences` (an
/// `client/schedulescan`-scanned prefix of fired-marks), never from
/// comparing `now_s` against the occurrence's own boundary — that
/// boundary is computed *from* `now_s` in the first place
/// (`interval_occurrence`), so a time-based check there is always
/// trivially on-time by construction.
///
/// ## Examples
///
/// ```gleam
/// // the very first occurrence is never late
/// assert !schedule.interval_late(occurrences: [], seconds: 60, occurrence: 0)
/// ```
///
/// ```gleam
/// // on-time: the previous slot's mark exists
/// assert !schedule.interval_late(
///   occurrences: [0],
///   seconds: 60,
///   occurrence: 60,
/// )
/// ```
///
/// ```gleam
/// // late: several windows were skipped, so the previous slot has no mark
/// assert schedule.interval_late(
///   occurrences: [0],
///   seconds: 60,
///   occurrence: 240,
/// )
/// ```
///
pub fn interval_late(
  occurrences occurrences: List(Int),
  seconds seconds: Int,
  occurrence occurrence: Int,
) -> Bool {
  case occurrences {
    [] -> False
    _ -> !list.contains(occurrences, occurrence - seconds)
  }
}

/// Whether a recurring schedule's expiry has been reached against what
/// has actually fired: both bounds, always, earliest wins — the same
/// rule `parse` enforces on the *configured* values, checked here against
/// the durable fired-marks themselves.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.interval_expired(
///   occurrences: [0, 60],
///   expiry: schedule.Expiry(max_fires: 2, expires_after_s: 604_800),
///   now_s: 120,
/// )
/// ```
///
/// ```gleam
/// assert !schedule.interval_expired(
///   occurrences: [0],
///   expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
///   now_s: 120,
/// )
/// ```
///
pub fn interval_expired(
  occurrences occurrences: List(Int),
  expiry expiry: Expiry,
  now_s now_s: Int,
) -> Bool {
  // "Has this many-or-more fired" only needs the elements up to the
  // bound, not a full walk to count them (lint R5) — the same
  // `too_long`-shaped idiom `client/rules` uses for a string length.
  case list.drop(occurrences, int.max(expiry.max_fires - 1, 0)) != [] {
    True -> True
    False ->
      case earliest(occurrences) {
        None -> False
        Some(first) -> now_s - first >= expiry.expires_after_s
      }
  }
}

fn earliest(occurrences: List(Int)) -> Option(Int) {
  case occurrences {
    [] -> None
    [first, ..rest] -> Some(list.fold(rest, first, int.min))
  }
}

// --- the injected text ---------------------------------------------------

/// The text one fire injects: an attribution line naming the schedule, a
/// sentence saying whose text this is and that it is time-driven rather
/// than triggered by anything the model said, an optional late
/// annotation, and the body inside a named fence.
///
/// The framing mirrors `client/rules.injection` in spirit, adapted for a
/// different kind of "whose text is this": a triggered rule explains
/// that it was not a turn from the user, and a schedule additionally
/// explains that it is not a turn from *anyone* — a standing instruction
/// firing on a timer, with nobody necessarily present to have prompted
/// it. `late` is set when `client/schedulescan` is firing a schedule
/// noticeably after its window closed (most often because the server was
/// not running), and says so plainly rather than leaving the model to
/// infer a gap in the conversation's own timeline.
///
/// ## Examples
///
/// ```gleam
/// // schedule.injection(sched, False, schedule.OperatorConfigured)
/// ```
///
/// ```gleam
/// // schedule.injection(sched, True, schedule.ModelCreated)
/// ```
///
pub type Origin {
  /// An operator's `[[schedule]]` table. Standing configuration the model
  /// had no hand in.
  OperatorConfigured

  /// A schedule the model created for itself through `tools/schedule` or
  /// the `schedule.*` capabilities.
  ModelCreated
}

/// How a fire attributes itself, which is the whole point of the fence.
///
/// Both origins say the same two things — this is not a turn from the
/// user, and it arrived on a timer — and then diverge on the one question
/// the fence exists to answer: *whose text is this*. Getting that wrong
/// in the model-created direction is the sharper error, because a model
/// reading "this is standing operator configuration" above text it wrote
/// itself has been handed an authority nobody granted, on a schedule it
/// set. So the model-created line says plainly that the reader wrote it.
fn attribution(origin: Origin) -> String {
  case origin {
    OperatorConfigured ->
      "This is standing operator configuration, firing automatically on a "
      <> "timer. It is not a turn from the user — nobody necessarily "
      <> "prompted it — and no reply is expected; treat it as scheduled "
      <> "instruction and carry on with the work in hand."

    ModelCreated ->
      "This is a heartbeat *you* scheduled earlier, firing automatically "
      <> "on a timer. It is not a turn from the user, and it is not "
      <> "operator configuration — it carries no authority beyond what you "
      <> "already had when you set it. No reply is expected; treat it as a "
      <> "note to self and carry on with the work in hand."
  }
}

pub fn injection(schedule: Schedule, late: Bool, origin: Origin) -> String {
  let late_line = case late {
    True ->
      "This fire is late: the scheduled window for this occurrence has "
      <> "already closed, whether because the server was not running or "
      <> "because nothing was there to act on it in time. It is exactly "
      <> "one catch-up fire, not a replay of every occurrence that was "
      <> "missed.\n\n"
    False -> ""
  }

  // The attribution line carries the late marker as well as the name,
  // because that line is the whole of what a reader sees when a client
  // collapses this injection: `tui_gleam` renders any `[loom] ` message
  // as its first line until the reader expands it, on the standing
  // agreement that a harness injection's first line names it completely.
  // Lateness is the one fact about a fire that changes what a reader
  // should do about it, so it belongs above that fold rather than four
  // paragraphs into a body nobody has opened.
  let late_marker = case late {
    True -> " (late)"
    False -> ""
  }
  "[loom] scheduled heartbeat \""
  <> schedule.name
  <> "\""
  <> late_marker
  <> "\n\n"
  <> attribution(origin)
  <> "\n\n"
  <> late_line
  <> "--- begin scheduled heartbeat \""
  <> schedule.name
  <> "\" ---\n"
  <> schedule.body
  <> "\n--- end scheduled heartbeat \""
  <> schedule.name
  <> "\" ---"
}

// --- model-created schedules ---------------------------------------------
//
// Everything below serves the second way a schedule can come to exist: a
// model asked for one through `tools/schedule`, rather than an operator
// writing it in `loom.toml`. The two kinds are the same `Schedule` value
// held to the same bounds, and `client/schedulescan` runs them through
// one code path — the difference is entirely in where the value is read
// from and who is allowed to have put it there.

/// Whether a model may create schedules at all, and if so whether it may
/// create ones that wake an idle strand.
///
/// This is the whole of the operator's say over the model-facing door,
/// and it is deliberately one knob with three positions rather than two
/// booleans that can disagree.
///
/// **The default is `ModelSchedulesWake`: the door is open.** That is a
/// deliberate reversal of where this feature started, and the reason is
/// that the half-open position is not a feature. A heartbeat exists to
/// fire when nobody is prompting — to check on unattended work, to poll
/// something that changes on its own — and a schedule that may only
/// steer a run already open cannot do any of that. Shipping `steer` as
/// the default would have meant shipping a cron that never fires when it
/// matters, which reads as a bug rather than as a policy.
///
/// What makes the open default defensible is that the bound is
/// structural rather than postural. Every recurring schedule expires,
/// always, on both `max_fires` and `expires_after_s` with the earlier
/// winning, and no model-created schedule can raise either. So a model
/// can wake itself, and cannot wake itself indefinitely: the worst case
/// is `max_model_schedules` schedules each firing `default_max_fires`
/// times or for a week, whichever comes first, in a session an operator
/// is running and can stop.
///
/// The other two positions remain for operators who want them.
/// `ModelSchedulesSteer` keeps the tools but forbids waking, which is
/// the right setting for a host that pays per token and wants a model's
/// reminders to cost nothing while nobody is working. `ModelSchedulesOff`
/// registers no schedule tool at all, which is the right setting for a
/// host that wants scheduling to be its own decision entirely — and it is
/// still the only position under which a model cannot see the door.
pub type Policy {
  /// No schedule tool is registered. The model cannot see the door.
  ModelSchedulesOff

  /// The model may create schedules, but `wake` is forced false: they
  /// steer an open run and hold when the strand is idle.
  ModelSchedulesSteer

  /// The model may additionally create schedules that start a fresh run
  /// on an idle strand.
  ModelSchedulesWake
}

/// What a document with no `[schedules]` table means, and what a server
/// started with no config file at all gets. See `Policy` for why the door
/// defaults open.
pub const default_policy = ModelSchedulesWake

/// The longest recurring interval, in seconds — the same 7 days
/// `max_expires_after_s` caps the expiry window at.
///
/// Two things rest on this bound, and the second is why it is an error
/// rather than a nit. An interval longer than the schedule's own expiry
/// window can never fire twice, so it is a one-shot written the hard way
/// and `describe_timing` would tell the model "at most 1000 times" about
/// something that fires once. And an unbounded interval becomes an
/// unbounded *timer delay*: `client/schedulescan.arm` must clamp anyway
/// (a one-shot `at` can be arbitrarily far out), but a delay above
/// 2^32-1 ms raises `timeout_value` inside an unlinked timer process, so
/// the scanner would go silently deaf. Refusing here keeps the clamp a
/// backstop rather than the only guard.
pub const max_interval_s = 604_800

/// The most schedules one session will hold on a model's behalf, across
/// every strand.
///
/// A ceiling rather than a rate, for the reason `tools/remember`'s note
/// ceiling is one: each live schedule is a standing claim on the
/// scanner's every tick and on provider budget, and a model that creates
/// them in a loop should meet a wall it can read rather than a session
/// that slows down. Operator `[[schedule]]` tables are counted
/// separately, under `max_schedules`, so turning the door on can never
/// shrink what the operator configured.
pub const max_model_schedules = 16

/// The reserved key one model-created schedule's config lives under.
///
/// `schedule/config/…`, disjoint from the `schedule/fired/…` marks: a
/// fired-mark says an occurrence is spent and is written once, a config
/// cell says a schedule exists and is overwritten when it is cancelled.
/// Sharing a prefix would let a malformed key of one shape be read as the
/// other. Both sit under `runtime/api.schedule_fact_prefix`, so neither
/// is reachable by `put_fact` — a model reaches this cell through the
/// tool seam, which is harness code, and never by writing a fact itself.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.config_key(strand: "main", name: "poll")
///   == "schedule/config/main/poll"
/// ```
///
pub fn config_key(strand strand: String, name name: String) -> String {
  config_key_prefix <> strand <> "/" <> name
}

/// The prefix every model-created schedule's config cell shares, which is
/// what `client/schedulescan` scans once per tick to find them.
pub const config_key_prefix = api.schedule_fact_prefix <> "config/"

/// A cancelled schedule's cell value.
///
/// Cancellation overwrites rather than deletes, because the register is a
/// cell and "there is no such key" and "there was one and it is finished"
/// are worth telling apart when reading the reserved namespace by hand.
/// `decode` refuses it, so a tombstone is simply not a schedule to every
/// caller that matters.
pub const cancelled_value = json.Null

/// Renders one schedule as the JSON its config cell holds.
///
/// ## Examples
///
/// ```gleam
/// // schedule.encode(sched) |> json.to_string
/// ```
///
pub fn encode(schedule: Schedule) -> JsonValue {
  json.Object(list.append(
    [
      #("name", json.String(schedule.name)),
      #("target", json.String(schedule.target)),
      #("wake", json.Bool(schedule.wake)),
      #("body", json.String(schedule.body)),
    ],
    timing_fields(schedule.timing),
  ))
}

fn timing_fields(timing: Timing) -> List(#(String, JsonValue)) {
  case timing {
    Interval(seconds:, expiry:) -> [
      #("every_s", json.Int(seconds)),
      #("max_fires", json.Int(expiry.max_fires)),
      #("expires_after_s", json.Int(expiry.expires_after_s)),
    ]
    OneShot(at:) -> [#("at_s", json.Int(at))]
  }
}

/// Reads one config cell back, total: any value that is not a schedule
/// this build would have accepted in the first place is `Error(Nil)`.
///
/// The bounds are re-checked on the way out rather than trusted from the
/// way in. The cell is reserved, so the model cannot have written it —
/// but it outlives the build that wrote it, and a bound that tightens in
/// a later version would otherwise leave a stored schedule running
/// outside limits nothing would accept today. Re-validating makes the
/// current bounds the only ones that ever apply, and costs a dropped row
/// rather than a migration.
///
/// ## Examples
///
/// ```gleam
/// // schedule.decode(schedule.encode(sched)) == Ok(sched)
/// ```
///
/// ```gleam
/// assert schedule.decode(schedule.cancelled_value) == Error(Nil)
/// ```
///
pub fn decode(value: JsonValue) -> Result(Schedule, Nil) {
  use fields <- result.try(object_fields(value))
  use name <- result.try(string_field(fields, "name"))
  use target <- result.try(string_field(fields, "target"))
  use wake <- result.try(bool_field(fields, "wake"))
  use body <- result.try(string_field(fields, "body"))
  use timing <- result.try(decode_timing(fields))
  build(name:, target:, timing:, wake:, body:)
  |> result.replace_error(Nil)
}

fn decode_timing(fields: List(#(String, JsonValue))) -> Result(Timing, Nil) {
  case int_field(fields, "every_s"), int_field(fields, "at_s") {
    // Exactly one, mirroring the `every`/`at` exclusivity `parse`
    // enforces on the TOML side.
    Ok(_seconds), Ok(_at) -> Error(Nil)
    Error(Nil), Error(Nil) -> Error(Nil)
    Ok(seconds), Error(Nil) -> {
      use max_fires <- result.try(int_field(fields, "max_fires"))
      use expires_after_s <- result.try(int_field(fields, "expires_after_s"))
      Ok(Interval(seconds:, expiry: Expiry(max_fires:, expires_after_s:)))
    }
    Error(Nil), Ok(at) -> Ok(OneShot(at:))
  }
}

fn object_fields(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  case value {
    json.Object(fields:) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(Nil)
  }
}

fn field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(JsonValue, Nil) {
  list.key_find(fields, key)
}

fn string_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(String, Nil) {
  case field(fields, key) {
    Ok(json.String(value:)) -> Ok(value)
    Ok(_other) | Error(Nil) -> Error(Nil)
  }
}

fn int_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, Nil) {
  case field(fields, key) {
    Ok(json.Int(value:)) -> Ok(value)
    Ok(_other) | Error(Nil) -> Error(Nil)
  }
}

fn bool_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Bool, Nil) {
  case field(fields, key) {
    Ok(json.Bool(value:)) -> Ok(value)
    Ok(_other) | Error(Nil) -> Error(Nil)
  }
}

/// Builds a schedule from already-typed parts, holding it to every bound
/// `parse` holds a `[[schedule]]` table to.
///
/// This is the constructor the model-facing door and `decode` share.
/// `parse` does not use it: that path refuses with messages naming the
/// TOML key and table position an operator has to go and edit, which a
/// model calling a tool has no use for. The *bounds* are shared as
/// predicates and constants either way, so the two paths can word a
/// refusal differently but can never disagree about what is allowed.
///
/// ## Examples
///
/// ```gleam
/// // schedule.build(name: "poll", target: "main",
/// //   timing: schedule.OneShot(at: 0), wake: False, body: "look")
/// ```
///
pub fn build(
  name name: String,
  target target: String,
  timing timing: Timing,
  wake wake: Bool,
  body body: String,
) -> Result(Schedule, String) {
  use Nil <- result.try(checked_name(name))
  use Nil <- result.try(checked_target(target))
  use Nil <- result.try(checked_body(body))
  use Nil <- result.try(checked_timing(timing))
  Ok(Schedule(name:, target:, timing:, wake:, body:))
}

fn checked_name(name: String) -> Result(Nil, String) {
  case name == "", too_long(name, max_name_length) {
    True, _ -> Error("name must not be empty")
    _, True ->
      Error(
        "name must be at most "
        <> int.to_string(max_name_length)
        <> " characters",
      )
    False, False -> checked_name_characters(name)
  }
}

fn checked_name_characters(name: String) -> Result(Nil, String) {
  case name_breaks_key(name), name_breaks_fence(name) {
    True, _ ->
      Error(
        "name must not contain `/`: it is a key segment of the durable "
        <> "fire-mark",
      )
    _, True ->
      Error(
        "name must not contain a quote or a newline: it is quoted inside "
        <> "the injected text",
      )
    False, False -> Ok(Nil)
  }
}

fn checked_target(target: String) -> Result(Nil, String) {
  case target == "", too_long(target, max_target_length) {
    True, _ -> Error("target must not be empty")
    _, True ->
      Error(
        "target must be at most "
        <> int.to_string(max_target_length)
        <> " characters",
      )
    False, False -> Ok(Nil)
  }
}

fn checked_body(body: String) -> Result(Nil, String) {
  case body == "", too_long(body, max_body_length) {
    True, _ -> Error("body must not be empty")
    _, True ->
      Error(
        "body must be at most "
        <> int.to_string(max_body_length)
        <> " characters",
      )
    False, False -> Ok(Nil)
  }
}

fn checked_timing(timing: Timing) -> Result(Nil, String) {
  case timing {
    OneShot(..) -> Ok(Nil)
    Interval(seconds:, expiry:) -> {
      use Nil <- result.try(checked_interval(seconds))
      checked_expiry(expiry)
    }
  }
}

fn checked_interval(seconds: Int) -> Result(Nil, String) {
  case seconds < min_interval_s, seconds > max_interval_s {
    True, _ ->
      Error(
        "every_s must be at least "
        <> int.to_string(min_interval_s)
        <> " seconds: anything tighter is a busy-loop against provider "
        <> "budget",
      )
    _, True ->
      Error(
        "every_s must be at most "
        <> int.to_string(max_interval_s)
        <> " seconds: a longer interval than the schedule's own expiry "
        <> "window can never fire twice, so it is a one-shot written the "
        <> "hard way — use `at`",
      )
    False, False -> Ok(Nil)
  }
}

fn checked_expiry(expiry: Expiry) -> Result(Nil, String) {
  case
    expiry.max_fires < 1 || expiry.max_fires > max_max_fires,
    expiry.expires_after_s < 1 || expiry.expires_after_s > max_expires_after_s
  {
    True, _ ->
      Error("max_fires must be between 1 and " <> int.to_string(max_max_fires))
    _, True ->
      Error(
        "expires_after_s must be between 1 and "
        <> int.to_string(max_expires_after_s),
      )
    False, False -> Ok(Nil)
  }
}

/// The `[schedules]` policy table, or the default when the document has
/// none.
///
/// Separate from `parse` because they answer different questions about
/// the same file — `parse` reads the schedules an operator wrote, this
/// reads whether the model may write any of its own — and because a
/// document with no `[[schedule]]` at all may still want to open the
/// model-facing door.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.parse_policy("") == Ok(schedule.default_policy)
/// ```
///
pub fn parse_policy(text: String) -> Result(Policy, String) {
  use document <- result.try(
    tom.parse(text) |> result.map_error(describe_parse_error),
  )
  case dict.get(document, "schedules") {
    Error(Nil) -> Ok(default_policy)
    Ok(tom.Table(fields)) -> policy_table(fields)
    Ok(_other) -> Error("[schedules] must be a table")
  }
}

fn policy_table(fields: Dict(String, tom.Toml)) -> Result(Policy, String) {
  use Nil <- result.try(known_keys(
    dict.keys(fields),
    ["model_created"],
    "the [schedules] table",
  ))
  case dict.get(fields, "model_created") {
    Error(Nil) -> Ok(default_policy)
    Ok(tom.String("off")) -> Ok(ModelSchedulesOff)
    Ok(tom.String("steer")) -> Ok(ModelSchedulesSteer)
    Ok(tom.String("wake")) -> Ok(ModelSchedulesWake)
    Ok(_other) ->
      Error(
        "schedules.model_created must be one of \"off\", \"steer\" or "
        <> "\"wake\": \"off\" registers no schedule tool at all, \"steer\" "
        <> "lets the model create schedules that only steer a run already "
        <> "open, and \"wake\" additionally lets one start a fresh run on "
        <> "an idle strand",
      )
  }
}

/// Whether this policy registers the model-facing tools at all.
///
/// ## Examples
///
/// ```gleam
/// assert !schedule.policy_opens_the_door(schedule.ModelSchedulesOff)
/// ```
///
pub fn policy_opens_the_door(policy: Policy) -> Bool {
  case policy {
    ModelSchedulesOff -> False
    ModelSchedulesSteer | ModelSchedulesWake -> True
  }
}

/// Whether this policy permits a model-created schedule to wake an idle
/// strand. The seam applies this rather than trusting the tool argument,
/// so a model asking for `wake` under `ModelSchedulesSteer` gets a
/// schedule that steers rather than a refusal — the request is honoured
/// as far as the operator allowed, and the result says which it was.
///
/// ## Examples
///
/// ```gleam
/// assert !schedule.policy_permits_wake(schedule.ModelSchedulesSteer)
/// ```
///
pub fn policy_permits_wake(policy: Policy) -> Bool {
  case policy {
    ModelSchedulesOff | ModelSchedulesSteer -> False
    ModelSchedulesWake -> True
  }
}

/// Parses a model-supplied RFC3339 UTC instant into epoch seconds.
///
/// The same parser `at` uses on the TOML side, worded for a reader who
/// wrote a tool argument rather than a config file. One parser, because
/// two would be two grammars.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.parse_instant("1970-01-01T00:00:00Z") == Ok(0)
/// ```
///
pub fn parse_instant(text: String) -> Result(Int, String) {
  case timestamp.parse_rfc3339(text) {
    Error(Nil) ->
      Error(
        "at must be an RFC3339 UTC instant, for example "
        <> "\"2026-09-01T09:00:00Z\"",
      )
    Ok(instant) -> {
      let #(seconds, _nanoseconds) =
        timestamp.to_unix_seconds_and_nanoseconds(instant)
      Ok(seconds)
    }
  }
}

/// Renders epoch seconds back as the RFC3339 UTC instant a model wrote,
/// so a confirmation echoes the vocabulary of the request rather than a
/// number nobody asked about.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.render_instant(0) == "1970-01-01T00:00:00Z"
/// ```
///
pub fn render_instant(seconds: Int) -> String {
  timestamp.from_unix_seconds(seconds)
  |> timestamp.to_rfc3339(duration.seconds(0))
}
