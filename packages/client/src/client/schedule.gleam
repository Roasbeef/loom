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
//// over that door and defaults to `steer`, which keeps the tools and
//// forbids waking; read its doc comment for the whole argument, and
//// `docs/design-notes/scheduled-heartbeats.md`'s addendum for what the
//// reversal cost and why the default then moved back a step.
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
//// name = "weekday-standup"
//// cron = "0 9 * * 1-5"
//// body = "Summarise what is in flight, as a standup note."
////
//// [[schedule]]
//// name = "one-shot-reminder"
//// at = "2026-09-01T09:00:00Z"
//// body = "The migration window opens today. Confirm the plan is ready."
//// ```
////
//// ## Owner and target: two questions, and the answer to both bounds a
//// schedule's life
////
//// A schedule names the strand it fires onto (`target`) and the party it
//// belongs to (`owner`, see `Owner`). They are the same strand for the
//// ordinary case — a strand asking for its own heartbeat — and they
//// differ in exactly one admitted shape: a strand scheduling onto a
//// strand it spawned, which the seam admits only against the lineage
//// ledger (`client/scheduleseam`, issue #154).
////
//// Keying *cancellation* on the owner is what closes the hole issue #163
//// named. A schedule used to be cancellable only by the strand it fired
//// onto, so a subagent's own heartbeat became uncancellable the moment
//// that subagent settled: it held a ceiling slot for the rest of the
//// session and, with `wake = true`, kept re-opening runs on a driver
//// whose task had ended. With an owner, a parent's schedule onto a child
//// outlives the child's turn and is still the parent's to retire, and a
//// child's own schedules die when the child does — `client/scheduleseam`
//// reaps them on the run end, and `client/schedulescan` treats a settled
//// or reaped target as the end of the schedule.
////
//// What ownership deliberately does *not* touch is a schedule's
//// **identity**, which stays `{target, name}`: the config cell, the
//// observation instant and every fired-mark are keyed on it, and name
//// uniqueness is still per target across both stores. An occurrence is a
//// fact about a strand's timeline, and two schedules sharing that pair
//// would share a mark whoever owned them.
////
//// ## Three shapes, and no fourth
////
//// A schedule is exactly one of a fixed interval (`every = "300s"`, a
//// positive whole number of seconds followed by a literal `s`), a
//// calendar expression (`cron = "0 9 * * 1-5"`, five fields, UTC — see
//// `client/cron`), or a one-shot (`at`, an RFC3339 UTC timestamp). Never
//// two of them, and never none. Cron arrived after the other two: the
//// design note cut it as a swamp, and what changed is that the swamp is
//// the *timezone* half, not the syntax half. `client/cron` speaks the
//// five-field grammar and nothing else — no names, no `L`/`W`/`?`, no
//// seconds field — and every instant it works in is a UTC epoch second,
//// so there is still no timezone handling anywhere in this module.
////
//// What cron buys that `every` cannot say at all is a *phase*: `every =
//// "86400s"` is a grid aligned to the epoch, so a daily heartbeat is
//// always at 00:00 UTC, and `0 9 * * 1-5` is the only way to ask for
//// 09:00 on weekdays.
////
//// ## The due occurrence, and where `Interval` and `Cron` differ
////
//// Both recurring shapes answer "what is due now" from the store alone,
//// and they answer it differently on purpose.
////
//// An `Interval` fires the slot `now_s` falls in, whether or not that
//// slot began before anyone had heard of the schedule. A heartbeat grid
//// has no wall-clock meaning — slot 29,800,000 is not a time anybody
//// asked for — so "the current slot" is the only honest reading of
//// "now", and a schedule created mid-slot fires immediately rather than
//// waiting up to a full period for a boundary nobody chose.
////
//// A `Cron` occurrence *is* a time somebody asked for, so the rule is
//// stricter: the due occurrence is the last match at or before `now_s`
//// (`cron_occurrence`), and it fires **only if that match is at or after
//// `since_s`** — the instant a running scanner first observed the
//// schedule (`seen_key`). An occurrence that passed before the schedule
//// existed was never asked for, so a `0 9 * * *` schedule created at
//// 15:00 does not fire this morning's 09:00 on its first tick; it waits
//// for tomorrow's. Lateness follows the same instant: see `cron_late`.
////
//// ## Expiry is mandatory for a recurring schedule, always both bounds
////
//// An `every` or `cron` schedule always carries an `Expiry`, defaulted
//// when the operator does not set it: `max_fires` defaults to and caps at 1000,
//// `expires_after_s` defaults to and caps at 604800 seconds (7 days).
//// Whichever bound is hit first ends the schedule — "both bounds,
//// always, earliest wins," not "either/or" — which is what keeps the
//// worst case at exactly 1000 fire-mark rows per schedule rather than
//// leaving an operator free to write a 60-second-interval, 7-day,
//// no-`max_fires` schedule that would leave 10,080. A `cron` schedule
//// carries the identical `Expiry` for the identical reason — a
//// five-field expression can name a minute of every hour of every day
//// as easily as `every = "60s"` can. A one-shot schedule
//// carries no `Expiry` at all: its occurrence count is 1 by
//// construction, so there is nothing left for a bound to protect.
////
//// **The age bound counts from when a running scanner first observed
//// the schedule**, not from its first fire. `client/schedulescan`
//// records that instant once, durably, in the cell `seen_key` names,
//// and `recurring_expired` measures `expires_after_s` against it. The
//// alternative — measuring from the earliest fired-mark — left a
//// schedule that had never once landed a fire with no clock at all, so
//// a `wake = false` heartbeat held forever on a strand nobody opens a
//// run on ticked for the life of the session, and `expires_after_s`
//// promised an operator a week that would never begin (issue #157).
//// Counting from first observation is what makes the key mean what it
//// reads as: the schedule ends after its window whether anything ever
//// fired or not.
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
//// schedule from being a busy-loop against provider budget. **A `cron`
//// schedule needs no such bound**, and that is a property of the
//// grammar rather than an omission: cron's finest grain is a minute, so
//// the tightest expression the syntax can write — `* * * * *` — is
//// already exactly `min_interval_s` apart, and there is nothing for a
//// floor to refuse.
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

import client/cron.{type Expression}
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
/// characters; a `StrandOwned` `owner` is bounded exactly as `target` is.
pub type Schedule {
  Schedule(
    /// The operator's handle for the schedule: the durable fired-mark's
    /// key segment, and the name the injected text attributes itself to.
    name: String,
    /// The strand this schedule addresses, by name — `"main"` unless the
    /// operator names a specific one (a subagent strand, say).
    target: String,
    /// Who the schedule belongs to: the operator, or the strand that
    /// asked for it. `target` and `owner` are the same strand for the
    /// ordinary model-created schedule and differ when a parent
    /// schedules onto a child it spawned.
    owner: Owner,
    /// The fixed interval or the one-shot instant this schedule fires on.
    timing: Timing,
    /// Whether this schedule may start a fresh run on an idle strand,
    /// or may only steer one already open.
    wake: Wake,
    /// The text injected, once per due occurrence.
    body: String,
  )
}

/// Who a schedule belongs to — which is a different question from which
/// strand it fires onto, and the two answers together are what bound a
/// schedule's life.
///
/// Ownership decides who may `list` and `cancel` a schedule; `target`
/// decides whose context a fire lands in. Keying cancellation on the
/// *creator* rather than on the target is what fixes the hole issue #163
/// names: a schedule created by a subagent onto itself was cancellable
/// only through a strand that had already settled, so nobody could
/// retire it and it held a session-wide ceiling slot for good. With an
/// owner, a parent can schedule onto a child and still cancel it, and
/// the child's own schedules are reaped when the child's run ends.
///
/// The identity of a schedule stays `{target, name}` — the config, seen
/// and fired keys are unchanged by this type, and name uniqueness is
/// still per target — because those keys are what the scanner derives an
/// occurrence from, and two schedules sharing them would share a mark
/// whoever owned them.
pub type Owner {
  /// A `[[schedule]]` table in `loom.toml`. Not the model's to list or
  /// cancel through any door, and attributed as standing configuration
  /// when it fires. A stored config cell can never decode to this — see
  /// `decode` — so nothing a model creates can claim the operator's
  /// voice.
  OperatorOwned

  /// The strand that asked for the schedule. It is the only strand that
  /// may list or cancel it, and — when it is not also the target — the
  /// strand a fire attributes itself to.
  StrandOwned(strand: String)
}

/// When a schedule fires.
///
/// Two recurring shapes and one single occurrence. Both recurring ones
/// always carry an `Expiry` — the module doc's "Expiry is mandatory"
/// section is the argument, and it applies to a calendar expression
/// exactly as it does to a fixed interval — and `OneShot` carries none
/// because its occurrence count is 1 by construction.
pub type Timing {
  /// A fixed grid aligned to the epoch: `slot = floor(now_s /
  /// interval_s)`, and the occurrence a slot names is its own epoch
  /// second. Fires the slot `now_s` falls in, including the slot that
  /// was already under way when the schedule was created.
  Interval(seconds: Int, expiry: Expiry)

  /// A five-field cron expression, UTC (`client/cron`). Unlike
  /// `Interval` this can express a phase and a calendar shape —
  /// "09:00 on weekdays", "the first of the month" — and unlike
  /// `Interval` it never fires an occurrence that passed before the
  /// schedule was first observed, because a cron occurrence is an
  /// instant somebody named rather than a slot on a grid. See
  /// `cron_occurrence`.
  Cron(expression: Expression, expiry: Expiry)

  /// One occurrence, at or after `at` (epoch seconds, UTC).
  OneShot(at: Int)
}

/// The mandatory bounds a recurring schedule expires under. Whichever is
/// reached first ends the schedule — "both bounds, always, earliest
/// wins."
pub type Expiry {
  Expiry(max_fires: Int, expires_after_s: Int)
}

/// What a schedule is allowed to do to a strand that is idle when it
/// fires.
///
/// This is the whole of what an operator decides by writing
/// `wake = true`, and the whole of what `Policy` caps a model-created
/// schedule to, so it travels as a value both ends can read. The TOML
/// key and the stored cell stay booleans; the type is what the Gleam on
/// either side of those boundaries works in.
pub type Wake {
  /// The fire may start a fresh run on an idle strand. The mandatory
  /// expiry above is what makes that safe: a waking schedule cannot
  /// keep a session alive past a bound the operator set and can see.
  WakesIdle

  /// The fire steers a run that is already open and holds when the
  /// strand is idle, exactly as a triggered project rule does. This is
  /// the default, and what a `steer` policy caps every schedule to.
  SteersOnly
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
        <> "name, a timing (every, cron or at), and body",
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
      "name", "target", "every", "cron", "at", "max_fires", "expires_after_s",
      "wake", "body",
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

  // An operator's table is the operator's, whatever it targets: a
  // `[[schedule]]` naming a subagent is standing configuration about
  // that subagent, not something the subagent may cancel.
  Ok(Schedule(name:, target:, owner: OperatorOwned, timing:, wake:, body:))
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

// Exactly one of `every`/`cron`/`at`, and the keys each licenses.
//
// The count is taken first and separately from the parse, because "you
// named two timings" and "your cron expression has a bad hour field" are
// different mistakes and an operator reading the second before the first
// would fix the wrong thing.
fn schedule_timing(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Timing, String) {
  use named <- result.try(one_timing_key(fields, place))

  case named {
    EveryKey -> {
      use seconds <- result.try(interval_seconds(fields, place))
      use expiry <- result.try(recurring_expiry(fields, place))
      Ok(Interval(seconds:, expiry:))
    }

    CronKey -> {
      use expression <- result.try(cron_expression(fields, place))
      use expiry <- result.try(recurring_expiry(fields, place))
      Ok(Cron(expression:, expiry:))
    }

    AtKey -> {
      use Nil <- result.try(refuse_recurring_only_keys(fields, place))
      use at <- result.try(one_shot_at(fields, place))
      Ok(OneShot(at:))
    }
  }
}

/// Which of the three `[[schedule]]` timing keys a table set.
///
/// A type rather than the key's own string, so `schedule_timing` reads a
/// value the compiler has already narrowed to three cases and needs no
/// unreachable arm for a fourth spelling that cannot arrive. `parse`'s
/// allowed-key list and `timing_keys` are the two places a new timing
/// would be added, and forgetting either fails a test rather than
/// silently ignoring a key.
type TimingKey {
  EveryKey
  CronKey
  AtKey
}

// The three spellings, paired with what each names. One list, so a
// refusal's wording and the keys the parser actually looks for cannot
// drift apart.
const timing_keys = [
  #("every", EveryKey),
  #("cron", CronKey),
  #("at", AtKey),
]

// Which of the three timing keys this table set, refusing none and more
// than one in words.
//
// The count is a question about the length of a list rather than a case
// over three `dict.has_key` results crossed with each other: three
// booleans crossed are eight arms saying three things, and the message a
// reader gets is better for naming exactly the keys they wrote.
fn one_timing_key(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(TimingKey, String) {
  let named =
    list.filter(timing_keys, fn(pair) {
      let #(key, _timing) = pair
      dict.has_key(fields, key)
    })

  case named {
    [#(_key, only)] -> Ok(only)

    [] ->
      Error(
        place
        <> " must set exactly one of ."
        <> string.join(spelled(timing_keys), ", .")
        <> ": a fixed interval, a cron expression, or a one-shot",
      )

    [_first, _second, ..] ->
      Error(
        place
        <> " sets ."
        <> string.join(spelled(named), " and .")
        <> ", which are mutually exclusive: a schedule fires on one "
        <> "timing, never two",
      )
  }
}

fn spelled(keys: List(#(String, TimingKey))) -> List(String) {
  list.map(keys, fn(pair) {
    let #(key, _timing) = pair
    key
  })
}

// A `cron` key is an ordinary quoted string handed to `client/cron`,
// which is total and words its own refusals by field and item. The
// message is prefixed with the place so an operator reading it knows
// which table to edit, and otherwise passed through untouched — this
// module has nothing to add about an hour field.
fn cron_expression(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Expression, String) {
  use text <- result.try(bounded_string(
    fields,
    place,
    "cron",
    cron.max_expression_length,
  ))
  cron.parse(text)
  |> result.map_error(fn(reason) { place <> ".cron: " <> reason })
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

// The two keys that only mean something beside a *recurring* timing —
// `every` or `cron`. A one-shot's occurrence count is 1 by construction,
// so either one here is a contradiction worth naming rather than
// silently ignoring.
fn refuse_recurring_only_keys(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Nil, String) {
  case dict.has_key(fields, "max_fires") {
    True ->
      Error(
        place
        <> ".max_fires is only valid alongside .every or .cron: a "
        <> "one-shot schedule fires exactly once by construction",
      )
    False ->
      case dict.has_key(fields, "expires_after_s") {
        True ->
          Error(
            place
            <> ".expires_after_s is only valid alongside .every or "
            <> ".cron: a one-shot schedule fires exactly once by "
            <> "construction",
          )
        False -> Ok(Nil)
      }
  }
}

// Both bounds, always, whichever the operator states or not — a
// recurring schedule's expiry is never optional (see the module doc),
// and `every` and `cron` are held to the identical pair.
fn recurring_expiry(
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

// The TOML surface stays a boolean, because that is what an operator
// has already been shown in the worked example and in every comment
// above. The key is optional and its absence is the milder of the two
// states, so a config that never mentions waking never gets it.
fn schedule_wake(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Wake, String) {
  case dict.get(fields, "wake") {
    Error(Nil) -> Ok(SteersOnly)
    Ok(tom.Bool(True)) -> Ok(WakesIdle)
    Ok(tom.Bool(False)) -> Ok(SteersOnly)
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
/// what `client/schedulescan` scans to count a schedule's fires and to
/// see whether the immediately preceding slot landed one — `max_fires`
/// and `Lateness` out of a single bounded scan, with no separate
/// counter. Expiry's other half, the age bound, is not derivable from
/// these marks at all: a schedule that has never fired has none. That
/// instant lives in its own cell instead (`seen_key`).
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

/// The reserved key holding the epoch second a schedule was first
/// observed by a running scanner — where its `expires_after_s` clock
/// starts.
///
/// `schedule/seen/…`, its own corner of the namespace, disjoint from the
/// `schedule/fired/…` marks and the `schedule/config/…` cells by its
/// second segment. That is the argument `config_key` makes, arriving a
/// third time: each of the three shapes means a different thing, is
/// written under a different rule — a mark once per occurrence, a config
/// cell once per creation, this one once per schedule, ever — and
/// sharing a prefix would let a malformed key of one shape be read as
/// another. It sits under `runtime/api.schedule_fact_prefix` like the
/// other two, so it is unreachable by `put_fact`: a model can neither
/// forge an observation instant nor delete one to restart its own
/// schedule's clock.
///
/// One writer, `client/schedulescan`, claims this cell with an
/// expect-absent compare-and-set on the first tick that sees the
/// schedule and never writes it again — so every reader of it, on any
/// later tick or any later incarnation, agrees on one instant. It is
/// keyed on `{strand, name}` exactly as the marks are, which is what
/// makes it the same clock for the operator's schedules and the model's
/// alike.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.seen_key(strand: "main", name: "heartbeat")
///   == "schedule/seen/main/heartbeat"
/// ```
///
pub fn seen_key(strand strand: String, name name: String) -> String {
  api.schedule_fact_prefix <> "seen/" <> strand <> "/" <> name
}

/// The seen cell's stored value: the epoch second of the observation,
/// and nothing else. The key already carries the strand and the name, so
/// the instant is the whole of what this cell has to say.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.seen_value(1_700_000_000) == json.Int(1_700_000_000)
/// ```
///
pub fn seen_value(since_s since_s: Int) -> JsonValue {
  json.Int(since_s)
}

/// Reads a seen cell back, total: anything that is not a plain epoch
/// second is `Error(Nil)`, which the scanner treats as an observation it
/// has not recorded rather than as an instant to measure a life against.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.decode_seen(schedule.seen_value(since_s: 42)) == Ok(42)
/// ```
///
/// ```gleam
/// assert schedule.decode_seen(json.String("42")) == Error(Nil)
/// ```
///
pub fn decode_seen(value: JsonValue) -> Result(Int, Nil) {
  case value {
    json.Int(value: since_s) -> Ok(since_s)

    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(Nil)
  }
}

/// Every reserved prefix one strand's schedules occupy: the config
/// cells, the observation instants, and the fired-marks, in that order.
///
/// The one place the *durable footprint of a strand's schedules* is
/// written down, so retiring them is one list rather than three call
/// sites that can each forget a corner. `client/scheduleseam` reads it
/// twice: when a strand's own run ends and its schedules are reaped, and
/// as the shape a single cancellation deletes a narrower slice of.
///
/// Each prefix ends in `/`, which is what keeps a strand from reaping a
/// differently-named neighbour: `sub:main/worker` and
/// `sub:main/worker-2` share a string prefix and not a path one. A
/// spawned strand's own children are safe for the same reason from the
/// other side — a child's name is `sub:{parent}/…`, so its keys sit
/// under `schedule/config/sub:sub:main/…` and no ancestor's prefix
/// reaches them.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.strand_prefixes(strand: "main")
///   == [
///     "schedule/config/main/", "schedule/seen/main/",
///     "schedule/fired/main/",
///   ]
/// ```
///
pub fn strand_prefixes(strand strand: String) -> List(String) {
  [
    config_key_prefix <> strand <> "/",
    api.schedule_fact_prefix <> "seen/" <> strand <> "/",
    api.schedule_fact_prefix <> "fired/" <> strand <> "/",
  ]
}

// --- occurrence arithmetic ------------------------------------------------
//
// Pure and exported so `client/schedulescan`'s tick handler stays a thin
// wrapper and this arithmetic — the one place a fencepost error would be
// easy to make and easy to miss in an actor test — gets a direct,
// deterministic unit test instead of only an actor-and-timer-driven one.
//
// Two families, one per recurring shape, and they answer the same three
// questions: what is due, whether it is late, and how long until the
// next one. `Interval`'s answers are division; `Cron`'s are a calendar
// search delegated to `client/cron`. `recurring_expired` is shared,
// because expiry is about fired-marks and an observation instant and
// knows nothing about how an occurrence was chosen.

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

/// Whether a fire is landing inside the window it was due in, or after
/// that window has already closed.
///
/// A late fire injects the same body through the same path, so the
/// annotation changes only what the text says about itself. It travels
/// as a value rather than as a `Bool` because both states are ones a
/// reader has to name — a bare `True` three arguments into a call names
/// neither of them.
pub type Lateness {
  /// The fire is landing in the window it was due in.
  OnTime

  /// The window closed before anything fired, most often because the
  /// server was not running. It is exactly one catch-up fire, never a
  /// replay of every occurrence that was missed.
  Late
}

/// Whether an about-to-fire occurrence should be annotated `Late`: not
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
/// assert schedule.interval_late(occurrences: [], seconds: 60, occurrence: 0)
///   == schedule.OnTime
/// ```
///
/// ```gleam
/// // on-time: the previous slot's mark exists
/// assert schedule.interval_late(
///     occurrences: [0],
///     seconds: 60,
///     occurrence: 60,
///   )
///   == schedule.OnTime
/// ```
///
/// ```gleam
/// // late: several windows were skipped, so the previous slot has no mark
/// assert schedule.interval_late(
///     occurrences: [0],
///     seconds: 60,
///     occurrence: 240,
///   )
///   == schedule.Late
/// ```
///
pub fn interval_late(
  occurrences occurrences: List(Int),
  seconds seconds: Int,
  occurrence occurrence: Int,
) -> Lateness {
  case occurrences, list.contains(occurrences, occurrence - seconds) {
    // Nothing has fired at all, so this is the schedule's first
    // occurrence ever and there is no earlier window it could have
    // missed. The mark check is meaningless here and is ignored.
    [], _preceding -> OnTime

    [_fired, ..], True -> OnTime
    [_fired, ..], False -> Late
  }
}

/// Whether a recurring schedule's expiry has been reached: both bounds,
/// always, earliest wins — the same rule `parse` enforces on the
/// *configured* values, checked here against what the store actually
/// holds.
///
/// Shared by `Interval` and `Cron`, which is why it takes neither an
/// interval nor an expression: both bounds are questions about the
/// durable record — how many marks are under this schedule's prefix, and
/// how long ago it was first observed — and neither depends on how the
/// occurrences were spaced.
///
/// The two bounds read two different durable facts. `max_fires` counts
/// the schedule's fired-marks, which is exactly what has been spent.
/// `expires_after_s` is measured from `since_s`, the instant a running
/// scanner first observed this schedule (`seen_key`) — *not* from its
/// earliest fired-mark, which is how this was first written and which
/// gave a schedule that had never landed a fire no age clock at all
/// (issue #157). A held `wake = false` heartbeat on a strand nobody
/// opens a run on is exactly that schedule, and it ticked forever.
/// Reading the start instant off a cell written once, when the schedule
/// was first seen, makes the bound mean the window an operator reads it
/// as and ends a schedule that never fires.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.recurring_expired(
///   occurrences: [0, 60],
///   expiry: schedule.Expiry(max_fires: 2, expires_after_s: 604_800),
///   now_s: 120,
///   since_s: 0,
/// )
/// ```
///
/// ```gleam
/// // never fired, and its window has closed: expired all the same
/// assert schedule.recurring_expired(
///   occurrences: [],
///   expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 100),
///   now_s: 101,
///   since_s: 0,
/// )
/// ```
///
/// ```gleam
/// assert !schedule.recurring_expired(
///   occurrences: [0],
///   expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
///   now_s: 120,
///   since_s: 0,
/// )
/// ```
///
pub fn recurring_expired(
  occurrences occurrences: List(Int),
  expiry expiry: Expiry,
  now_s now_s: Int,
  since_s since_s: Int,
) -> Bool {
  // "Has this many-or-more fired" only needs the elements up to the
  // bound, not a full walk to count them (lint R5) — the same
  // `too_long`-shaped idiom `client/rules` uses for a string length.
  case list.drop(occurrences, int.max(expiry.max_fires - 1, 0)) != [] {
    True -> True

    // The age bound needs no scan at all now that the start instant is
    // recorded rather than inferred: one subtraction against the cell
    // the scanner claimed the first time it saw this schedule.
    False -> now_s - since_s >= expiry.expires_after_s
  }
}

// --- cron occurrence arithmetic ------------------------------------------
//
// `Interval`'s three answers are division on `now_s`. Cron's are a
// calendar search, so all three delegate to `client/cron` and add
// exactly one thing of their own: the `since_s` rule the module doc
// states, which is what keeps a schedule from firing an occurrence that
// passed before anybody had asked for it.

/// The occurrence a `Cron` schedule owes at `now_s`, or `None` when it
/// owes none.
///
/// The candidate is the last match at or before `now_s` —
/// `cron.previous_occurrence` is strictly-before, so the seed is
/// `now_s + 1` and a tick landing exactly on a match sees that match.
/// A tick between two matches sees the earlier one, which is what makes
/// a fire that the server was down for land as one catch-up rather than
/// being skipped.
///
/// It is then **refused if it predates `since_s`**, the instant a running
/// scanner first observed this schedule (`seen_key`). This is the whole
/// difference from `interval_occurrence`, and the reason for it is that a
/// cron occurrence is an instant somebody named. `every = "86400s"`
/// names slot boundaries on an epoch grid, so "the current slot" is the
/// only reading of *now* that means anything and a schedule created
/// mid-slot fires at once. `0 9 * * *` names 09:00, and a schedule
/// created at 15:00 was never asking about this morning: firing it would
/// deliver a heartbeat for a window that closed before the schedule
/// existed, immediately and annotated late, which reads as a bug however
/// carefully it is documented.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * *")
/// // 2026-09-02T09:30:00Z, a schedule observed at 2026-09-02T00:00:00Z:
/// // this morning's 09:00 is due.
/// assert schedule.cron_occurrence(
///     expression: expression,
///     now_s: 1_788_341_400,
///     since_s: 1_788_307_200,
///   )
///   == Some(1_788_339_600)
/// ```
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * *")
/// // The same instant, but the schedule was only observed at 09:15:
/// // 09:00 predates it and is not owed.
/// assert schedule.cron_occurrence(
///     expression: expression,
///     now_s: 1_788_341_400,
///     since_s: 1_788_340_500,
///   )
///   == None
/// ```
///
pub fn cron_occurrence(
  expression expression: Expression,
  now_s now_s: Int,
  since_s since_s: Int,
) -> Option(Int) {
  case cron.previous_occurrence(expression, before_s: now_s + 1) {
    // No match within the search horizon looking backwards, which for
    // any expression that recurs means the schedule is younger than its
    // first occurrence.
    None -> None

    // The match is real but predates the observation instant: it was
    // never asked for, so nothing is owed and nothing is recorded.
    Some(occurrence) if occurrence < since_s -> None

    Some(occurrence) -> Some(occurrence)
  }
}

/// Whether a `Cron` occurrence about to fire should be annotated `Late`:
/// the occurrence *before* it was itself due — at or after `since_s` —
/// and has no fired-mark.
///
/// The same reasoning as `interval_late`, with the preceding window
/// found by a calendar search instead of by subtracting an interval.
/// Lateness is never decided by comparing `now_s` against the
/// occurrence: the occurrence is chosen *from* `now_s`
/// (`cron_occurrence`), so such a check would read as on-time whenever
/// the tick is prompt and as late whenever it is a second slow, which is
/// jitter rather than a missed window. What actually distinguishes the
/// two is already in the marks — a prompt series has a mark on every
/// preceding occurrence, and a window nothing ticked through has none.
///
/// The `since_s` guard is the same one `cron_occurrence` applies, and it
/// matters most on the very first fire: the occurrence before a
/// schedule's first is not a window it missed, so its absent mark says
/// nothing and the fire is `OnTime`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * *")
/// // The first fire of a schedule observed at 2026-09-02T00:00:00Z:
/// // yesterday's 09:00 predates it, so nothing was missed.
/// assert schedule.cron_late(
///     expression: expression,
///     occurrences: [],
///     occurrence: 1_788_339_600,
///     since_s: 1_788_307_200,
///   )
///   == schedule.OnTime
/// ```
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * *")
/// // The same fire from a schedule observed a week earlier, with no
/// // mark on the preceding day: a window closed unfired.
/// assert schedule.cron_late(
///     expression: expression,
///     occurrences: [],
///     occurrence: 1_788_339_600,
///     since_s: 1_787_702_400,
///   )
///   == schedule.Late
/// ```
///
pub fn cron_late(
  expression expression: Expression,
  occurrences occurrences: List(Int),
  occurrence occurrence: Int,
  since_s since_s: Int,
) -> Lateness {
  case cron.previous_occurrence(expression, before_s: occurrence) {
    // Nothing precedes this occurrence within the horizon, so there is
    // no earlier window its absence could stand for.
    None -> OnTime

    Some(preceding) -> preceding_lateness(occurrences, preceding, since_s)
  }
}

// The verdict once the preceding occurrence is known: it has to have
// been *owed* before its absence means anything.
fn preceding_lateness(
  occurrences: List(Int),
  preceding: Int,
  since_s: Int,
) -> Lateness {
  case preceding >= since_s, list.contains(occurrences, preceding) {
    // Before the schedule was observed. Never due, so never missed —
    // this is what makes a first fire on time.
    False, _fired -> OnTime

    // Due and fired: the series is prompt.
    _observed, True -> OnTime

    // Due and unfired: a window closed with nothing in it.
    True, False -> Late
  }
}

/// How long to wait, in milliseconds, for a `Cron` schedule's next
/// occurrence — or `None` when the expression has none within
/// `cron.search_horizon_days`.
///
/// Floored at one second for the reason `client/schedulescan`'s interval
/// re-arm is: a boundary the clock has already reached would otherwise
/// arm a zero delay and spin the scanner against the same occurrence.
///
/// `None` is a schedule that will not fire again — an expression naming
/// a date that does not exist, most of the year — and the scanner treats
/// it as expired for that tick rather than re-arming on a guess.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(expression) = cron.parse("0 9 * * 1-5")
/// // 2026-09-04T09:00:00Z is a Friday fire; the next is the Monday,
/// // 2026-09-07T09:00:00Z, three days later.
/// assert schedule.cron_next_delay_ms(
///     expression: expression,
///     now_s: 1_788_512_400,
///     now_ms: 1_788_512_400_000,
///   )
///   == Some(259_200_000)
/// ```
///
pub fn cron_next_delay_ms(
  expression expression: Expression,
  now_s now_s: Int,
  now_ms now_ms: Int,
) -> Option(Int) {
  cron.next_occurrence(expression, after_s: now_s)
  |> option.map(fn(next) { int.max(next * 1000 - now_ms, 1000) })
}

// --- the injected text ---------------------------------------------------

/// Whose text a fire is injecting, which is the one question the fence
/// around it exists to answer.
///
/// Three answers rather than two, because "the model wrote this" stopped
/// being one fact the moment a strand could schedule onto a strand it
/// spawned. A heartbeat firing on a child says the parent set it; a
/// heartbeat that told the child *it* had scheduled the thing would be
/// inviting the child to treat a sibling authority's instruction as its
/// own earlier intent.
pub type Origin {
  /// An operator's `[[schedule]]` table. Standing configuration the model
  /// had no hand in.
  OperatorConfigured

  /// A schedule the strand being fired on created for itself, through
  /// `tools/schedule` or the `schedule.*` capabilities.
  SelfScheduled

  /// A schedule another strand — the one that spawned this target —
  /// created onto it. Carries the owner's name, because a reader that
  /// cannot see who set a heartbeat cannot weigh it.
  OwnerScheduled(owner: String)
}

/// Whose text one schedule's fire is, derived from the schedule itself.
///
/// The origin used to be a property of the *store* a schedule was read
/// out of, which is why `client/schedulescan` used to pair the two by
/// hand. `Owner` makes it a property of the value: an operator's table
/// parses to `OperatorOwned`, a config cell always decodes to
/// `StrandOwned` (`decode` has no path to the other), and the remaining
/// question — self or owner — is one comparison.
///
/// ## Examples
///
/// ```gleam
/// // schedule.origin_of(operator_table) == schedule.OperatorConfigured
/// ```
///
/// ```gleam
/// // a strand's own heartbeat
/// // schedule.origin_of(sched) == schedule.SelfScheduled
/// ```
///
pub fn origin_of(schedule: Schedule) -> Origin {
  case schedule.owner {
    OperatorOwned -> OperatorConfigured
    StrandOwned(strand:) ->
      case strand == schedule.target {
        True -> SelfScheduled
        False -> OwnerScheduled(owner: strand)
      }
  }
}

/// How a fire attributes itself, which is the whole point of the fence.
///
/// Every origin says the same two things — this is not a turn from the
/// user, and it arrived on a timer — and then diverges on the one
/// question the fence exists to answer: *whose text is this*. Getting
/// that wrong in the model's direction is the sharper error, because a
/// model reading "this is standing operator configuration" above text it
/// wrote itself has been handed an authority nobody granted, on a
/// schedule it set. So the self-scheduled line says plainly that the
/// reader wrote it.
///
/// The owner-scheduled line is the same error one step along. Text a
/// *parent* scheduled onto a child is neither the operator's nor the
/// child's own earlier intent, and telling the child "you scheduled
/// this" would let a strand's instruction reach it disguised as its own
/// memory. So that line names the owner and says exactly what the
/// instruction is worth: as much as a steer from that strand, and no
/// more.
fn attribution(origin: Origin) -> String {
  case origin {
    OperatorConfigured ->
      "This is standing operator configuration, firing automatically on a "
      <> "timer. It is not a turn from the user — nobody necessarily "
      <> "prompted it — and no reply is expected; treat it as scheduled "
      <> "instruction and carry on with the work in hand."

    SelfScheduled ->
      "This is a heartbeat *you* scheduled earlier, firing automatically "
      <> "on a timer. It is not a turn from the user, and it is not "
      <> "operator configuration — it carries no authority beyond what you "
      <> "already had when you set it. No reply is expected; treat it as a "
      <> "note to self and carry on with the work in hand."

    OwnerScheduled(owner:) ->
      "This heartbeat was scheduled by "
      <> owner
      <> ", the strand that spawned you, and is firing automatically on a "
      <> "timer. It is not a turn from the user, it is not operator "
      <> "configuration, and it is not something you scheduled: it carries "
      <> "no authority beyond a steer from that strand would. No reply is "
      <> "expected; weigh it as you would any instruction from "
      <> owner
      <> " and carry on with the work in hand."
  }
}

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
/// it. `Late` is passed when `client/schedulescan` is firing a schedule
/// noticeably after its window closed (most often because the server was
/// not running), and says so plainly rather than leaving the model to
/// infer a gap in the conversation's own timeline.
///
/// ## Examples
///
/// ```gleam
/// // schedule.injection(sched, schedule.OnTime, schedule.OperatorConfigured)
/// ```
///
/// ```gleam
/// // schedule.injection(sched, schedule.Late, schedule.SelfScheduled)
/// ```
///
pub fn injection(schedule: Schedule, late: Lateness, origin: Origin) -> String {
  let late_line = case late {
    Late ->
      "This fire is late: the scheduled window for this occurrence has "
      <> "already closed, whether because the server was not running or "
      <> "because nothing was there to act on it in time. It is exactly "
      <> "one catch-up fire, not a replay of every occurrence that was "
      <> "missed.\n\n"
    OnTime -> ""
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
    Late -> " (late)"
    OnTime -> ""
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
/// **The default is `ModelSchedulesSteer`: the tools are registered and
/// `wake` is capped.** A model can create schedules for itself, and every
/// one of them steers a run already open and holds when the strand is
/// idle, exactly as a triggered project rule does. What a model cannot
/// do under the default is arrange to be woken: nothing it creates can
/// start a run on an idle strand, so the session still ends when the
/// work in flight ends, and the model's own reminders cost nothing while
/// nobody is working.
///
/// The door once shipped open (`ModelSchedulesWake`), on the argument
/// that a heartbeat which can only steer an open run never fires when a
/// heartbeat is for, and that the per-schedule expiry bounded the worst
/// case. The second half did not hold up: expiry is per schedule, a
/// fresh name is a fresh clock, and a model that is running because its
/// heartbeat woke it can create the next one before this one expires
/// (issue #161). So under an open default a model could keep a session
/// alive for as long as the operator left the server up, and Loom's
/// priorities put isolation before capability: the posture that extends a
/// session's life unsupervised is the operator's to opt into, not the
/// build's to assume. Waking is one line of `loom.toml` away
/// (`[schedules] model_created = "wake"`), and a model that asks to wake
/// under the default gets a schedule that steers and a result that says
/// so, rather than a refusal it would retry against.
///
/// The other two positions remain. `ModelSchedulesWake` is for an
/// operator who wants unattended work checked on with nobody prompting
/// and accepts that a model may chain such schedules for the life of the
/// server. `ModelSchedulesOff` registers no schedule tool at all, which
/// is the right setting for a host that wants scheduling to be its own
/// decision entirely — and it is the only position under which a model
/// cannot see the door.
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
/// started with no config file at all gets. See `Policy` for why the
/// default steers rather than wakes.
pub const default_policy = ModelSchedulesSteer

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
///
/// The bound is inclusive, which admits one interval that still fires
/// only once: `604_800` exactly, against the default `expires_after_s` of
/// the same value, since expiry compares `>=` and the second slot lands
/// precisely on the boundary. That is left rather than tightened because
/// an operator who writes a weekly heartbeat and a fortnight of expiry
/// gets the two fires they asked for, and only the coincident pair
/// degenerates — the bound is here to keep timer delays sane, not to
/// prove every admitted interval recurs.
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
/// `schedule/config/…`, disjoint from both the `schedule/fired/…` marks
/// and the `schedule/seen/…` instants: a fired-mark says an occurrence
/// is spent, a seen cell says when a schedule's age clock started, and a
/// config cell says a schedule exists. Sharing a prefix would let a
/// malformed key of one shape be read as another. All three sit under
/// `runtime/api.schedule_fact_prefix`, so none is reachable by
/// `put_fact` — a model reaches this cell through the tool seam, which
/// is harness code, and never by writing a fact itself.
///
/// The cell exists for exactly as long as the schedule does: it is
/// written once, with an expect-absent compare-and-set so two concurrent
/// creations cannot both believe they won, and **deleted** when the
/// schedule is cancelled rather than overwritten with a tombstone. That
/// is what keeps this prefix a list of the live schedules and nothing
/// else, so the `max_model_schedules` ceiling bounds what one tick and
/// one seam call read (issue #164).
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

/// Renders one schedule as the JSON its config cell holds.
///
/// ## Examples
///
/// ```gleam
/// // schedule.encode(sched) |> json.to_string
/// ```
///
pub fn encode(schedule: Schedule) -> JsonValue {
  json.Object(
    [
      #("name", json.String(schedule.name)),
      #("target", json.String(schedule.target)),
      #("wake", json.Bool(stored_wake(schedule.wake))),
      #("body", json.String(schedule.body)),
    ]
    |> list.append(owner_fields(schedule.owner))
    |> list.append(timing_fields(schedule.timing)),
  )
}

// The owner as the cell carries it: one string naming the owning strand.
//
// `OperatorOwned` writes no field, and that is not an omission. An
// operator's schedule has no cell in this store at all — it is read from
// `loom.toml` every boot, exactly as a `[[rule]]` is — so the only way
// this arm is reached is a caller encoding a parsed table for a test.
// Writing a spelling for it would create the one thing the reserved
// namespace is meant to make impossible: a stored value that decodes as
// the operator's voice.
fn owner_fields(owner: Owner) -> List(#(String, JsonValue)) {
  case owner {
    OperatorOwned -> []
    StrandOwned(strand:) -> [#("owner", json.String(strand))]
  }
}

// The stored cell keeps `wake` a JSON boolean rather than following the
// type across. Cells written by earlier builds of this feature are
// already out there, and a config cell that no longer decodes is a
// schedule that silently stops firing — so the type stops at this line,
// and `wake_field` is the only other place the wire's polarity is
// written down.
fn stored_wake(wake: Wake) -> Bool {
  case wake {
    WakesIdle -> True
    SteersOnly -> False
  }
}

// The timing as the cell carries it: one field naming the shape, plus
// the two expiry fields a recurring shape always has.
//
// A `Cron` stores its **source text**, not the parsed sets, and `decode`
// re-parses it. The sets carry invariants only `cron.parse` establishes,
// so a stored expansion of them would be a second, unvalidated way for
// an `Expression` to come into being; and the text is what an operator
// or a model wrote, which is what a listing has to echo back.
fn timing_fields(timing: Timing) -> List(#(String, JsonValue)) {
  case timing {
    Interval(seconds:, expiry:) -> [
      #("every_s", json.Int(seconds)),
      ..expiry_fields(expiry)
    ]

    Cron(expression:, expiry:) -> [
      #("cron", json.String(cron.source(expression))),
      ..expiry_fields(expiry)
    ]

    OneShot(at:) -> [#("at_s", json.Int(at))]
  }
}

fn expiry_fields(expiry: Expiry) -> List(#(String, JsonValue)) {
  [
    #("max_fires", json.Int(expiry.max_fires)),
    #("expires_after_s", json.Int(expiry.expires_after_s)),
  ]
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
/// assert schedule.decode(json.Null) == Error(Nil)
/// ```
///
pub fn decode(value: JsonValue) -> Result(Schedule, Nil) {
  use fields <- result.try(object_fields(value))
  use name <- result.try(string_field(fields, "name"))
  use target <- result.try(string_field(fields, "target"))
  use owner <- result.try(owner_field(fields, "owner", target))
  use wake <- result.try(wake_field(fields, "wake"))
  use body <- result.try(string_field(fields, "body"))
  use timing <- result.try(decode_timing(fields))
  build(name:, target:, owner:, timing:, wake:, body:)
  |> result.replace_error(Nil)
}

// The owner a cell names, defaulting to the target.
//
// A cell written before ownership existed carries no `owner` field, and
// the schedule it describes was created by the strand it targets — that
// was the only shape the door could produce — so the absent field means
// `StrandOwned(target)` and every such cell keeps working, cancellable
// by the strand that made it. The default is also the safe one: it can
// only ever name the strand the schedule already fires onto, so no
// missing field can widen who owns a schedule.
//
// There is deliberately no spelling of `OperatorOwned` here. A model's
// cell that could decode as the operator's would fire with the
// operator's attribution and be uncancellable through the door that
// created it.
fn owner_field(
  fields: List(#(String, JsonValue)),
  key: String,
  target: String,
) -> Result(Owner, Nil) {
  case field(fields, key) {
    Ok(json.String(value: strand)) -> Ok(StrandOwned(strand:))
    Error(Nil) -> Ok(StrandOwned(strand: target))
    Ok(_other) -> Error(Nil)
  }
}

// Which shape a stored cell names, before anything about it is read.
//
// One variant per stored field, so "exactly one timing" is a question
// about the length of a list rather than a case over three `Result`s
// crossed with each other — the same shape `one_timing_key` gives the
// TOML side, and for the same reason: a fourth timing would add one
// entry here instead of doubling an arm count.
type StoredTiming {
  StoredEvery(seconds: Int)
  StoredCron(text: String)
  StoredAt(at: Int)
}

fn decode_timing(fields: List(#(String, JsonValue))) -> Result(Timing, Nil) {
  let named =
    [
      int_field(fields, "every_s") |> result.map(StoredEvery),
      string_field(fields, "cron") |> result.map(StoredCron),
      int_field(fields, "at_s") |> result.map(StoredAt),
    ]
    |> result.values

  // Exactly one, mirroring the exclusivity `parse` enforces on the TOML
  // side. A cell naming two is not a schedule this build would have
  // written, and there is no honest way to pick between them.
  case named {
    [only] -> stored_timing(fields, only)
    [] | [_first, _second, ..] -> Error(Nil)
  }
}

// One stored shape read back. A `cron` cell is re-parsed through
// `cron.parse` rather than trusted: the decoder is total at a durability
// boundary, so an expression this build's grammar no longer accepts
// drops the cell exactly as an out-of-bounds interval does, and the
// schedule stops firing rather than running on a value nothing would
// admit today.
fn stored_timing(
  fields: List(#(String, JsonValue)),
  stored: StoredTiming,
) -> Result(Timing, Nil) {
  case stored {
    StoredAt(at:) -> Ok(OneShot(at:))

    StoredEvery(seconds:) -> {
      use expiry <- result.try(stored_expiry(fields))
      Ok(Interval(seconds:, expiry:))
    }

    StoredCron(text:) -> {
      use expression <- result.try(
        cron.parse(text) |> result.replace_error(Nil),
      )
      use expiry <- result.try(stored_expiry(fields))
      Ok(Cron(expression:, expiry:))
    }
  }
}

fn stored_expiry(fields: List(#(String, JsonValue))) -> Result(Expiry, Nil) {
  use max_fires <- result.try(int_field(fields, "max_fires"))
  use expires_after_s <- result.try(int_field(fields, "expires_after_s"))
  Ok(Expiry(max_fires:, expires_after_s:))
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

fn wake_field(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Wake, Nil) {
  case field(fields, key) {
    Ok(json.Bool(value: True)) -> Ok(WakesIdle)
    Ok(json.Bool(value: False)) -> Ok(SteersOnly)
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
/// //   owner: schedule.StrandOwned("main"),
/// //   timing: schedule.OneShot(at: 0), wake: schedule.SteersOnly,
/// //   body: "look")
/// ```
///
pub fn build(
  name name: String,
  target target: String,
  owner owner: Owner,
  timing timing: Timing,
  wake wake: Wake,
  body body: String,
) -> Result(Schedule, String) {
  use Nil <- result.try(checked_name(name))
  use Nil <- result.try(checked_target(target))
  use Nil <- result.try(checked_owner(owner))
  use Nil <- result.try(checked_body(body))
  use Nil <- result.try(checked_timing(timing))
  Ok(Schedule(name:, target:, owner:, timing:, wake:, body:))
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

// An owning strand is a strand address like the target, so it owes the
// same two bounds. Held here rather than trusted from the seam because
// `decode` reaches this constructor too, and a cell claiming a
// pathological owner is exactly the value a re-validating decoder is
// for.
fn checked_owner(owner: Owner) -> Result(Nil, String) {
  case owner {
    OperatorOwned -> Ok(Nil)
    StrandOwned(strand:) ->
      case strand == "", too_long(strand, max_target_length) {
        True, _ -> Error("owner must not be empty")
        _, True ->
          Error(
            "owner must be at most "
            <> int.to_string(max_target_length)
            <> " characters",
          )
        False, False -> Ok(Nil)
      }
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

    // Nothing to check about the expression itself: an `Expression`
    // exists only because `cron.parse` accepted it, and cron's own
    // minute granularity means the tightest thing the grammar can say is
    // already at `min_interval_s`. So the expiry is the whole of the
    // bound, and it is the same one an interval owes.
    Cron(expiry:, ..) -> checked_expiry(expiry)
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

/// What a model-created schedule's `wake` actually becomes: what was
/// asked for, capped by what this policy allows.
///
/// The policy caps rather than vetoes, and the seam applies it rather
/// than trusting the tool argument. A model asking to wake under
/// `ModelSchedulesSteer` gets a schedule that steers and a result that
/// says so, because refusing instead would teach it to retry against a
/// wall that will not move for anything it can do.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.wake_under(
///     schedule.ModelSchedulesSteer,
///     requested: schedule.WakesIdle,
///   )
///   == schedule.SteersOnly
/// ```
///
pub fn wake_under(policy: Policy, requested requested: Wake) -> Wake {
  case policy, requested {
    ModelSchedulesWake, WakesIdle -> WakesIdle

    ModelSchedulesWake, SteersOnly
    | ModelSchedulesSteer, WakesIdle
    | ModelSchedulesSteer, SteersOnly
    | ModelSchedulesOff, WakesIdle
    | ModelSchedulesOff, SteersOnly
    -> SteersOnly
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

/// The shortest relative one-shot a model may ask for, in seconds.
///
/// One second, because there is nothing to protect: a relative one-shot
/// fires once, so the busy-loop argument `min_interval_s` rests on does
/// not apply, and a model that wants a reminder in a moment is asking
/// for one turn later rather than for a standing clock.
pub const min_in_seconds = 1

/// The furthest ahead a relative one-shot may be asked for, in seconds:
/// 604800, seven days, the same window `max_expires_after_s` caps a
/// recurring schedule's life at.
///
/// The number is shared rather than coincidental. A schedule only fires
/// while this session's server is running, so a wake-up a fortnight out
/// is a promise this process cannot keep; capping the relative form at
/// the same week every other bound uses makes the whole feature answer
/// to one horizon.
pub const max_in_seconds = 604_800

/// Turns a model's "in N seconds" into the absolute epoch second a
/// `OneShot` needs, refusing an N outside `min_in_seconds`..`max_in_seconds`
/// in words.
///
/// This exists because **the model has no clock**. Loom's system prompt
/// carries neither the date nor the time, deliberately, so a model asked
/// to check back "in 45 minutes" cannot compute the RFC3339 instant `at`
/// wants — it can only guess, and a guessed absolute instant is either
/// refused as unparseable or, worse, accepted and fired at the wrong
/// time. The relative form moves the one piece of arithmetic that needs
/// a clock to the side of the seam that has one.
///
/// The caller supplies `now_s` rather than this module reading a clock:
/// `client/schedule` performs no I/O, and the seam already holds the
/// injected `runtime/effects.clock` every other instant in the session
/// comes from.
///
/// ## Examples
///
/// ```gleam
/// assert schedule.relative_instant(now_s: 1000, in_seconds: 45) == Ok(1045)
/// ```
///
/// ```gleam
/// let assert Error(reason) =
///   schedule.relative_instant(now_s: 1000, in_seconds: 0)
/// assert string.contains(reason, "at least")
/// ```
///
pub fn relative_instant(
  now_s now_s: Int,
  in_seconds in_seconds: Int,
) -> Result(Int, String) {
  case in_seconds < min_in_seconds, in_seconds > max_in_seconds {
    True, _ ->
      Error(
        "in_seconds must be at least "
        <> int.to_string(min_in_seconds)
        <> ": a heartbeat cannot fire before it is created",
      )

    _, True ->
      Error(
        "in_seconds must be at most "
        <> int.to_string(max_in_seconds)
        <> " (seven days): a schedule only fires while this session's "
        <> "server is running, so anything further out is a promise this "
        <> "process cannot keep — use a recurring schedule instead",
      )

    False, False -> Ok(now_s + in_seconds)
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
