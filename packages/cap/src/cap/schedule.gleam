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
//// It fires onto **the strand this program is running on**, and no
//// other. There is no target argument, here or in the tool, so a program
//// cannot schedule work into another strand's context — not a sibling's,
//// and not a subagent's it spawned.
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

/// One schedule already set on this strand.
pub type Schedule {
  Schedule(
    /// The handle it was created under, and the handle `cancel` takes.
    name: String,
    /// When it fires, rendered — `"every 300s, at most 1000 times"` or a
    /// UTC instant.
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

fn create(
  fields: List(#(String, MsgPackValue)),
) -> Result(Created, ScheduleError) {
  use value <- result.try(
    dispatch.call("schedule.create", wire.args(fields))
    |> result.map_error(map_error),
  )
  use name <- result.try(field(value, "name"))
  use when <- result.try(field(value, "when"))
  use wake <- result.try(wake_field(value, "wake"))
  Ok(Created(name:, when:, wake:))
}

/// Lists the schedules set on this strand.
///
/// Only this strand's own, and only ones a program or the model created:
/// a schedule the operator configured is not listed and cannot be
/// cancelled here.
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
  use when <- result.try(field(row, "when"))
  use body <- result.try(field(row, "body"))
  use wake <- result.try(wake_field(row, "wake"))
  use fired <- result.try(
    wire.int_field(row, "fired") |> result.map_error(bad_result),
  )
  Ok(Schedule(name:, when:, wake:, fired:, body:))
}

/// Cancels one schedule on this strand by name. It will not fire again.
///
/// A name that is not this strand's own is denied with
/// `schedule_not_found` rather than silently succeeding, so a program
/// cannot believe it has tidied up when it has not.
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
