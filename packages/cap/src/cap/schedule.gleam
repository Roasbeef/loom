//// `cap/schedule` — heartbeats a program can set for the strand it is
//// running on: text injected back into that strand's own context later,
//// on a timer, whether or not anyone is watching.
////
//// The same door `tools/schedule` opens for a model calling a tool
//// directly, reached from inside a code-mode program instead. Both land
//// on one implementation (`client/scheduleseam.Door`), so a schedule
//// created here is indistinguishable from one created by the tool: same
//// store, same bounds, same listing, and either door can cancel what the
//// other created.
////
//// ## What a schedule can and cannot do
////
//// It fires onto **the strand this program is running on** unless a
//// target is named, and the only other strand it may name is one this
//// strand *spawned* — `every_on`, `at_on` and `cancel_on` are the
//// functions that take one. The host decides that from its own durable
//// record of who spawned whom, so a sibling, a parent, or an unrelated
//// strand is denied with `invalid_schedule`; there is no argument a
//// program can write that reaches another agent's context.
////
//// A schedule belongs to the strand that **created** it, wherever it
//// fires. `list` and `cancel` are keyed on that, so a program sees and
//// retires what this strand made — including schedules onto its
//// subagents, which is what makes them cancellable at all once the
//// subagent has finished — and never another strand's.
////
//// A schedule onto a subagent is always steer-only, whatever `wake` asks
//// for: a subagent has one run, and it also ends the schedule, so
//// everything set onto one stops when its work does. Read `Created.wake`
//// rather than assuming the request.
////
//// A recurring schedule always expires, and a program cannot choose when:
//// both a fire count and a wall-clock window are applied, whichever is
//// reached first ends it. That bound is what makes `wake` offerable at
//// all — a schedule that may start a fresh run on an idle strand can
//// extend a session's life, and this is what stops it doing so
//// indefinitely.
////
//// Whether `wake` is honoured is the operator's, not the program's. A
//// host may run this session under a policy that permits scheduling but
//// forbids waking; a `create` asking to wake then succeeds with
//// `Created.wake` as `SteersOnly`, rather than failing. **Read the field rather
//// than assuming the request**: a program that needs waking to be
//// meaningful should check and say so in its report, not silently rely
//// on it. A host may also disable the capability entirely, in which case
//// every call here is denied.
////
//// ## Four timings, and the two that are not conveniences
////
//// `every` is a fixed interval, `at` a UTC instant, `cron` a five-field
//// calendar expression, and `after` a one-shot a fixed while from now.
//// One of the four per schedule.
////
//// `after` exists because **nothing tells a program the current time**.
//// The strand's prompt carries no clock and no date, so "check back in
//// three quarters of an hour" cannot be turned into the RFC3339 instant
//// `at` wants; `after("check", 2700, …)` is how a program says it, and
//// the host resolves it against the session's own clock.
////
//// `cron` exists because an interval cannot express a *phase*. The
//// interval grid is aligned to the epoch, so `every(…, 86_400, …)` is
//// always 00:00 UTC and no argument moves it. `cron("standup", "0 9 * *
//// 1-5", …)` is 09:00 on weekdays. Everything is **UTC** — there is no
//// timezone or offset handling anywhere in Loom — and the grammar is
//// the standard five fields and nothing more: no seconds field, no
//// month or day names (`JAN`, `MON`), and none of `L`, `W`, `?` or `#`.
//// When *both* day fields are restricted they are ORed rather than
//// ANDed, which is standard cron and catches everybody out: `"0 9 1 *
//// 1"` fires on the first of the month *and* on every Monday.
////
//// `every_within` and `cron_within` are the same two recurring shapes
//// with the expiry bounds stated rather than defaulted. They can only
//// narrow a schedule — the host holds `Bounds` to its own ceilings, and
//// `DefaultBounds` is what the four plain functions pass.
////
//// ## Not a scratch store, and not a way to keep a program alive
////
//// A schedule outlives the execution that created it, which makes it the
//// opposite of `cap/kv`: nothing here is evicted, and a schedule set by
//// a program that then fails still fires. Create one because a *later*
//// turn on this strand should happen, never to hold state for this
//// program — that is what `cap/kv` is for, and what `cap/report` is for
//// when the state should survive.
////
//// A schedule also cannot extend *this* execution. It fires a turn on
//// the strand at some later point; the program that created it has long
//// since returned.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/result

/// Why a scheduling call failed.
pub type ScheduleError {
  /// The broker refused the call in band. `code` distinguishes the
  /// reasons worth branching on: `invalid_schedule` (a bound was missed),
  /// `schedule_limit_reached`, `schedule_name_taken`,
  /// `schedule_not_found`, `schedules_unavailable`.
  ScheduleDenied(code: String, message: String)

  /// The capability channel could not carry the call.
  ScheduleUnavailable(reason: String)
}

/// What a schedule is allowed to do to this strand when it is idle at
/// the moment the schedule fires.
///
/// A program asks for one of these and reads back what it was actually
/// granted, which is not always the same — see the module doc on who
/// owns that decision. The capability wire carries a boolean either way;
/// this type is what a program writes and reads on this side of it.
pub type Wake {
  /// The schedule may start a fresh run when the strand is idle.
  WakesIdle

  /// The schedule steers a run already open, and holds when the strand
  /// is idle. What a host that forbids waking grants instead.
  SteersOnly
}

/// One schedule this strand owns.
pub type Schedule {
  Schedule(
    /// The handle it was created under, and the handle `cancel` takes.
    name: String,
    /// The strand it fires onto: this one, or one this strand spawned.
    /// `cancel` takes the name alone and means this strand's own, so a
    /// row naming another target is cancelled with `cancel_on`.
    target: String,
    /// When it fires, rendered — `"every 300s, at most 1000 times"`,
    /// `"cron \"0 9 * * 1-5\" UTC, at most 1000 times"`, or a UTC
    /// instant. A one-shot created with `after` reads as the instant the
    /// host resolved it to, not as the delay that was asked for.
    when: String,
    /// Whether it may start a fresh run on an idle strand.
    wake: Wake,
    /// How many times it has fired so far.
    fired: Int,
    /// The text it injects.
    body: String,
  )
}

/// What a `create` actually produced.
pub type Created {
  Created(
    name: String,
    /// The strand it will fire onto, resolved by the host: this one when
    /// no target was named.
    target: String,
    when: String,
    /// What `wake` ended up being, which is not always what was asked
    /// for — see the module doc.
    wake: Wake,
  )
}

/// Schedules `body` to fire on this strand every `seconds` seconds, until
/// the schedule expires on its own.
///
/// `seconds` has a floor the host enforces; anything tighter is denied
/// with `invalid_schedule` rather than quietly rounded up. `name` must be
/// unique among this strand's schedules and among the host's own — a
/// clash is denied with `schedule_name_taken` rather than replacing
/// anything, so replacing one is always `cancel` then `every` again.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.every(
///     "poll",
///     300,
///     schedule.WakesIdle,
///     "Check whether the build finished.",
///   )
/// ```
///
pub fn every(
  name: String,
  seconds: Int,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create([
    #("name", wire.string(name)),
    #("body", wire.string(body)),
    #("wake", wire.bool(wake_flag(wake))),
    #("every_seconds", wire.int(seconds)),
  ])
}

/// `every`, onto a strand this one spawned rather than onto itself.
///
/// `target` is that strand's name — the one its handle carries. Anything
/// else is denied with `invalid_schedule`: the host checks the target
/// against its own record of who spawned whom, so a sibling's or a
/// parent's name is refused however it was obtained.
///
/// The schedule is **this** strand's: it appears in `list` with `target`
/// set, and `cancel_on` retires it. It is also always steer-only —
/// `Created.wake` says so — and it ends when the target's work does,
/// which is what a heartbeat watching a subagent wants: it steers the
/// child while there is something to steer and stops when there is not.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(spawned) = strand.start(assignment)
/// let assert Ok(made) =
///   schedule.every_on(
///     spawned.strand,
///     "watch",
///     300,
///     schedule.SteersOnly,
///     "Say where the review has got to.",
///   )
/// ```
///
pub fn every_on(
  target: String,
  name: String,
  seconds: Int,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create([
    #("name", wire.string(name)),
    #("body", wire.string(body)),
    #("wake", wire.bool(wake_flag(wake))),
    #("every_seconds", wire.int(seconds)),
    #("target", wire.string(target)),
  ])
}

/// Schedules `body` to fire on this strand once, at `instant` — an
/// RFC3339 UTC timestamp, for example `"2026-09-01T09:00:00Z"`.
///
/// An instant already past fires promptly, once, annotated as late. It is
/// never replayed for every occurrence that was missed.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.at(
///     "window",
///     "2026-09-01T09:00:00Z",
///     schedule.WakesIdle,
///     "The window opened.",
///   )
/// ```
///
pub fn at(
  name: String,
  instant: String,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create([
    #("name", wire.string(name)),
    #("body", wire.string(body)),
    #("wake", wire.bool(wake_flag(wake))),
    #("at", wire.string(instant)),
  ])
}

/// `at`, onto a strand this one spawned rather than onto itself. The
/// target rule and the ownership rule are `every_on`'s exactly.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.at_on(
///     spawned.strand,
///     "deadline",
///     "2026-09-01T09:00:00Z",
///     schedule.SteersOnly,
///     "Wrap up and report what you have.",
///   )
/// ```
///
pub fn at_on(
  target: String,
  name: String,
  instant: String,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create([
    #("name", wire.string(name)),
    #("body", wire.string(body)),
    #("wake", wire.bool(wake_flag(wake))),
    #("at", wire.string(instant)),
    #("target", wire.string(target)),
  ])
}

/// Whether a recurring schedule takes the host's default expiry or a
/// narrower one this program states.
///
/// Two variants rather than a pair of `Option`s, because "say nothing
/// and get the host's ceiling" and "state both bounds" are the only two
/// things a caller can usefully mean, and a record of two `Option`s
/// would offer four. Both bounds are always active whichever variant is
/// used — the host applies its default in place of anything this does
/// not state — and whichever is reached first ends the schedule.
///
/// `Bounds` can only ever *narrow*. The host holds both numbers to the
/// same ceilings it holds its own configuration to, so a value above one
/// is denied with `invalid_schedule` rather than granted.
pub type Bounds {
  /// The host's defaults: its ceiling on both bounds. What `every`,
  /// `cron`, `at` and `after` pass.
  DefaultBounds

  /// The bounds this program wants, each at or under the host's ceiling.
  Bounds(
    /// End the schedule after this many fires, at least 1.
    max_fires: Int,
    /// End the schedule this many seconds after it is created, at
    /// least 1.
    expires_after_s: Int,
  )
}

/// Schedules `body` to fire on this strand on a five-field cron
/// expression — `"0 9 * * 1-5"` for 09:00 on weekdays.
///
/// **All times are UTC**, and both day fields are ORed when both are
/// restricted; the module doc has the whole of the grammar and what it
/// deliberately does not accept. An expression the host cannot parse is
/// denied with `invalid_schedule`, and the refusal names the field and
/// the item that caused it.
///
/// Reach for this rather than `every` whenever the *time of day* matters:
/// an interval is a grid aligned to the epoch, so `every(…, 86_400, …)`
/// fires at midnight UTC and there is no argument that moves it.
///
/// A cron schedule's first fire is its first match **after the host
/// loaded it**. A match earlier the same day, before this program ran,
/// was never asked for and does not fire.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.cron(
///     "standup",
///     "0 9 * * 1-5",
///     schedule.WakesIdle,
///     "Summarise what is in flight, as a standup note.",
///   )
/// ```
///
pub fn cron(
  name: String,
  expression: String,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create(schedule_fields(
    name,
    body,
    wake,
    DefaultBounds,
    "cron",
    wire.string(expression),
  ))
}

/// `cron`, onto a strand this one spawned rather than onto itself. The
/// target rule and the ownership rule are `every_on`'s exactly.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.cron_on(
///     spawned.strand,
///     "hourly-check",
///     "0 * * * *",
///     schedule.SteersOnly,
///     "Say where the review has got to.",
///   )
/// ```
///
pub fn cron_on(
  target: String,
  name: String,
  expression: String,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create([
    #("target", wire.string(target)),
    ..schedule_fields(
      name,
      body,
      wake,
      DefaultBounds,
      "cron",
      wire.string(expression),
    )
  ])
}

/// Schedules `body` to fire on this strand once, `seconds` from now.
///
/// This is the relative one-shot, and it exists because **nothing tells
/// this program the current time**: the strand's prompt carries no clock
/// and no date, so an absolute instant for `at` cannot be computed here
/// and a guessed one is either refused or fired at the wrong moment. The
/// host resolves this against the session's own clock.
///
/// `seconds` is between 1 and 604800 (seven days); outside that it is
/// denied with `invalid_schedule`, and the refusal says why the upper
/// bound is where it is — a schedule only fires while this session's
/// server is running.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.after(
///     "recheck",
///     2700,
///     schedule.WakesIdle,
///     "Check whether the migration finished.",
///   )
/// ```
///
pub fn after(
  name: String,
  seconds: Int,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create(schedule_fields(
    name,
    body,
    wake,
    DefaultBounds,
    "in_seconds",
    wire.int(seconds),
  ))
}

/// `after`, onto a strand this one spawned rather than onto itself. The
/// target rule and the ownership rule are `every_on`'s exactly.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.after_on(
///     spawned.strand,
///     "nudge",
///     600,
///     schedule.SteersOnly,
///     "Wrap up and report what you have.",
///   )
/// ```
///
pub fn after_on(
  target: String,
  name: String,
  seconds: Int,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create([
    #("target", wire.string(target)),
    ..schedule_fields(
      name,
      body,
      wake,
      DefaultBounds,
      "in_seconds",
      wire.int(seconds),
    )
  ])
}

/// `every`, with the expiry bounds stated rather than defaulted.
///
/// The only way to ask for a *shorter* life than the host's ceiling —
/// four fires, or an hour — which is what a program wants when the thing
/// it is watching will plainly be over long before a week is. `Bounds`
/// cannot widen anything: a value above the host's ceiling is denied
/// with `invalid_schedule`.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.every_within(
///     "poll",
///     300,
///     schedule.Bounds(max_fires: 12, expires_after_s: 3600),
///     schedule.WakesIdle,
///     "Check whether the build finished.",
///   )
/// ```
///
pub fn every_within(
  name: String,
  seconds: Int,
  bounds: Bounds,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create(schedule_fields(
    name,
    body,
    wake,
    bounds,
    "every_seconds",
    wire.int(seconds),
  ))
}

/// `cron`, with the expiry bounds stated rather than defaulted. The
/// bounds rule is `every_within`'s exactly.
///
/// Capability: `schedule.create`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(made) =
///   schedule.cron_within(
///     "standup",
///     "0 9 * * 1-5",
///     schedule.Bounds(max_fires: 5, expires_after_s: 604_800),
///     schedule.SteersOnly,
///     "Summarise what is in flight, as a standup note.",
///   )
/// ```
///
pub fn cron_within(
  name: String,
  expression: String,
  bounds: Bounds,
  wake: Wake,
  body: String,
) -> Result(Created, ScheduleError) {
  create(schedule_fields(
    name,
    body,
    wake,
    bounds,
    "cron",
    wire.string(expression),
  ))
}

// The fields every creation shares, plus the one that names its timing.
//
// Written once because the timing is the only thing that differs between
// six of these functions, and a seventh spelling of `name`/`body`/`wake`
// is a seventh place for one of them to be misspelled — the host denies
// an unknown argument, so a typo here is a capability that never works
// rather than one that works oddly.
fn schedule_fields(
  name: String,
  body: String,
  wake: Wake,
  bounds: Bounds,
  timing_key: String,
  timing: MsgPackValue,
) -> List(#(String, MsgPackValue)) {
  [
    #("name", wire.string(name)),
    #("body", wire.string(body)),
    #("wake", wire.bool(wake_flag(wake))),
    #(timing_key, timing),
    ..bounds_fields(bounds)
  ]
}

// `DefaultBounds` sends no field at all rather than sending the host's
// ceiling back to it: the default is the host's to state, and a program
// that echoed today's number would pin a bound the host may later
// narrow.
fn bounds_fields(bounds: Bounds) -> List(#(String, MsgPackValue)) {
  case bounds {
    DefaultBounds -> []

    Bounds(max_fires:, expires_after_s:) -> [
      #("max_fires", wire.int(max_fires)),
      #("expires_after_s", wire.int(expires_after_s)),
    ]
  }
}

fn create(
  fields: List(#(String, MsgPackValue)),
) -> Result(Created, ScheduleError) {
  use value <- result.try(
    dispatch.call("schedule.create", wire.args(fields))
    |> result.map_error(map_error),
  )
  use name <- result.try(field(value, "name"))
  use target <- result.try(field(value, "target"))
  use when <- result.try(field(value, "when"))
  use wake <- result.try(wake_field(value, "wake"))
  Ok(Created(name:, target:, when:, wake:))
}

/// Lists the schedules this strand owns, wherever each fires.
///
/// Only ones this strand created — its own heartbeats and any it set onto
/// a strand it spawned, each row naming its `target` — and only ones a
/// program or the model created: a schedule the operator configured is
/// not listed and cannot be cancelled here.
///
/// Capability: `schedule.list`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(existing) = schedule.list()
/// ```
///
pub fn list() -> Result(List(Schedule), ScheduleError) {
  use value <- result.try(
    dispatch.call("schedule.list", wire.args([]))
    |> result.map_error(map_error),
  )
  use rows <- result.try(
    wire.array_field(value, "schedules") |> result.map_error(bad_result),
  )
  list.try_map(rows, decode_row)
}

fn decode_row(row: MsgPackValue) -> Result(Schedule, ScheduleError) {
  use name <- result.try(field(row, "name"))
  use target <- result.try(field(row, "target"))
  use when <- result.try(field(row, "when"))
  use body <- result.try(field(row, "body"))
  use wake <- result.try(wake_field(row, "wake"))
  use fired <- result.try(
    wire.int_field(row, "fired") |> result.map_error(bad_result),
  )
  Ok(Schedule(name:, target:, when:, wake:, fired:, body:))
}

/// Cancels one schedule this strand set on itself, by name. It will not
/// fire again, and its record of past fires goes with it, so the name is
/// free to use again.
///
/// A name this strand does not own is denied with `schedule_not_found`
/// rather than silently succeeding, so a program cannot believe it has
/// tidied up when it has not — and a schedule that fires onto another
/// strand is not found by this call at all: it wants `cancel_on`.
///
/// Capability: `schedule.cancel`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = schedule.cancel("poll")
/// ```
///
pub fn cancel(name: String) -> Result(Nil, ScheduleError) {
  dispatch.call("schedule.cancel", wire.args([#("name", wire.string(name))]))
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

/// Cancels one schedule this strand set onto another strand — the
/// counterpart to `every_on` and `at_on`, addressed by the same target.
///
/// A schedule is named by the pair `{target, name}`, so this is not a
/// convenience over `cancel`: the same name may be in use on this strand
/// and on a subagent's, and `cancel` means this strand's own. `list`
/// shows which target each schedule fires onto.
///
/// Capability: `schedule.cancel`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = schedule.cancel_on(spawned.strand, "watch")
/// ```
///
pub fn cancel_on(target: String, name: String) -> Result(Nil, ScheduleError) {
  dispatch.call(
    "schedule.cancel",
    wire.args([
      #("name", wire.string(name)),
      #("target", wire.string(target)),
    ]),
  )
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

fn field(value: MsgPackValue, key: String) -> Result(String, ScheduleError) {
  wire.string_field(value, key) |> result.map_error(bad_result)
}

// The capability wire carries `wake` as a boolean in both directions,
// which is the shape the host's own tool result already uses. These two
// functions are the whole of the translation, so the polarity is written
// down once per direction and nowhere else.
fn wake_flag(wake: Wake) -> Bool {
  case wake {
    WakesIdle -> True
    SteersOnly -> False
  }
}

fn wake_field(value: MsgPackValue, key: String) -> Result(Wake, ScheduleError) {
  case wire.bool_field(value, key) {
    Error(reason) -> Error(bad_result(reason))
    Ok(True) -> Ok(WakesIdle)
    Ok(False) -> Ok(SteersOnly)
  }
}

fn bad_result(reason: String) -> ScheduleError {
  ScheduleUnavailable("bad schedule result: " <> reason)
}

fn map_error(error: CallError) -> ScheduleError {
  case error {
    Unreachable(reason:) -> ScheduleUnavailable(reason:)
    Denied(code:, message:) -> ScheduleDenied(code:, message:)
  }
}
