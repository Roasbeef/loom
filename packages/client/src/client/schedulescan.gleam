//// The scheduled-heartbeat scanner: one session-scoped actor that wakes
//// on its own injected timer, re-derives from the durable store which
//// configured schedules are due, and fires each once per occurrence.
////
//// `docs/design-notes/scheduled-heartbeats.md` is the design ruling this
//// module implements — read "Durability and the crash story" there
//// before changing anything in here. The shape mirrors
//// `client/rulescan`'s session-scoped restartable actor, its
//// `default_options`/`with_logger` builder, and its `start`/`supervised`
//// pair; what differs is what drives it and what it remembers between
//// ticks.
////
//// ## Driven by a timer, not by a commit hint
////
//// `client/rulescan` is fed by the StorageWriter's post-commit
//// publication, because a triggered rule can only become relevant when
//// new model output exists to trigger it. A schedule fires on a clock
//// whether anything committed or not, so the feed here is
//// `runtime/effects.Timers.after` — the same injected seam the strand
//// driver re-arms its own poll and retry timers with — never a second,
//// untestable clock. `Timers.after` is one-shot, so every tick ends by
//// re-arming a single timer for the soonest boundary any still-active
//// schedule needs next; a tick that finds nothing left active re-arms
//// nothing at all, and the actor goes quiet.
////
//// ## No progress state: every tick recomputes fully from the store
////
//// `client/rulescan` keeps a `Progress` map between hints — a cursor, a
//// hold flag — because it must not re-scan a whole branch on every
//// commit. A schedule has no branch to scan: whether an occurrence is
//// due, how many times a schedule has fired, and how long ago the first
//// fire was are all questions a bounded prefix scan of the write-once
//// fire-marks (`runtime/api.reserved_facts` under
//// `client/schedule.fired_key_prefix`) answers exactly, every time. So
//// this actor holds nothing across ticks beyond the static, parsed
//// `List(client/schedule.Schedule)` it started with — a restart loses
//// nothing, because there was nothing to lose, and the first tick after
//// a restart (armed immediately, at start) re-derives the same due/not
//// due answer the process that crashed would have.
////
//// ## "At most one late fire," and why it falls out of the algorithm
////
//// An `Interval` schedule aligns to a fixed grid: `slot = floor(now_s /
//// interval_s)`, and the occurrence a slot names is that slot's own
//// epoch second (`slot * interval_s`). A tick only ever asks "is the
//// *current* slot's mark absent" — it never walks backward over slots a
//// missed window skipped — so a session closed through a missed window
//// catches up to exactly one fire (the current slot's) at the next boot,
//// never a replay of the whole backlog.
////
//// `late` is a display-only annotation, and for an `Interval` schedule it
//// cannot be computed from `now_s` and `slot` alone — `slot` is derived
//// *from* `now_s`, so "is `now_s` past this slot's own boundary" is
//// always false by construction. What actually distinguishes a missed
//// window from an on-time fire is already sitting in the marks this tick
//// just scanned: on-time, the *immediately preceding* slot's mark exists
//// (the previous tick landed on it); after a skipped window it does not,
//// because nothing ever ticked during it. So `late` for an `Interval`
//// schedule is "this is not the first occurrence ever, and the
//// immediately preceding slot has no fired mark" — derived from the same
//// bounded scan that already answers expiry, no extra state. A `OneShot`
//// schedule has exactly one occurrence — `at` itself — so its lateness is
//// the simpler `now_s >= at + <grace>`, since `at` does not depend on
//// `now_s` the way an interval's slot does.
////
//// ## An idle strand holds unless the schedule opts in
////
//// `wake = false` (the default) steers an open run and holds — the fire
//// is simply not attempted successfully, the mark stays absent, and the
//// next tick tries the same occurrence again — exactly mirroring
//// `client/rulescan`'s idle-strand behaviour. `wake = true` may start a
//// fresh run on an idle strand instead
//// (`runtime/api.send_to_strand_marking`, landing `Started`), which is
//// safe only because every recurring schedule expires (`client/schedule`
//// bounds `max_fires`/`expires_after_s` unconditionally) — see the
//// design note's "The crux" section for the full argument.
////
//// ## Isolation
////
//// Every read here goes straight to the session store
//// (`runtime/api.fact`/`reserved_facts`), never through the writer's
//// mailbox, so a slow tick cannot sit in front of a settlement. The only
//// thing this actor sends the writer is the fire itself — an ordinary
//// marked admission — on its own process. It is a restartable service
//// (`client/serve`'s service supervisor): killing it mid-tick costs the
//// tick in flight and nothing else, and the replacement's first tick
//// (armed at start, per the module doc above) re-derives everything from
//// the durable fire-marks.

import client/schedule.{type Schedule}
import core/clock
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import runtime/api.{type Runtime}
import telemetry/field
import telemetry/log.{type Logger}

/// A small grace period, in seconds, added to a one-shot's `at` before a
/// fire is annotated `late`. Without it, a fire landing a few
/// milliseconds after `at` — an entirely ordinary scheduling jitter, not
/// a missed instant — would read to the model as a catch-up fire it is
/// not. An `Interval` schedule's lateness is derived structurally instead
/// (see the module doc's "At most one late fire" section) and does not
/// use this constant.
const late_grace_s = 5

/// How soon after `start` the scanner evaluates every schedule for the
/// first time. Zero rather than the first real interval, so a schedule
/// due at boot fires promptly instead of waiting a full period —
/// "at most one late fire per schedule at the next boot" only holds if
/// the next boot actually looks right away.
const first_tick_delay_ms = 0

/// What the scanner watches and how loudly it works.
///
/// Constructor invariants: `schedules` is the parsed, validated schedule
/// list (`client/schedule.parse`) — an empty list makes every tick a
/// no-op and the actor re-arms nothing, so it goes quiet after its first
/// tick.
pub type Options {
  Options(schedules: List(Schedule), logger: Logger)
}

/// The scanner's mailbox. One variant: every tick is self-armed through
/// the injected `runtime/effects.Timers` seam, so nothing external ever
/// sends this actor anything else.
pub type Message {
  Tick
}

/// The shipped options for a schedule list: a silent logger.
///
/// ## Examples
///
/// ```gleam
/// // schedulescan.default_options(parsed_schedules)
/// ```
///
pub fn default_options(schedules: List(Schedule)) -> Options {
  Options(schedules:, logger: log.discard())
}

/// Sets the logger the scanner reports fires and refusals on.
///
/// ## Examples
///
/// ```gleam
/// // schedulescan.default_options(schedules) |> schedulescan.with_logger(logger)
/// ```
///
pub fn with_logger(options: Options, logger: Logger) -> Options {
  Options(..options, logger:)
}

type State {
  State(options: Options, runtime: Runtime, self: Subject(Message))
}

// Whether a schedule is still worth waking up for, and if so, in how
// many milliseconds. `Expired` schedules are dropped from the next
// re-arm computation entirely — an expired `Interval` needs no further
// ticks, and neither does a `OneShot` once its one mark has landed.
type ScheduleStatus {
  Expired
  Active(next_delay_ms: Int)
}

/// Starts the scanner under `name`, watching `runtime`'s session, and
/// arms its first tick immediately.
///
/// Register it in the restartable service tier, beside the commit
/// forwarder and the triggered-rule scanner: a restart re-derives every
/// schedule's due/expired state fresh from the durable fire-marks, so
/// there is no subscription to re-register the way `client/rulescan`'s
/// writer-hint subscription needs one.
///
/// ## Examples
///
/// ```gleam
/// // schedulescan.start(schedulescan.default_options(schedules), runtime, name)
/// ```
///
pub fn start(
  options: Options,
  runtime: Runtime,
  name: Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(5000, fn(subject) {
    runtime.effects.timers.after(first_tick_delay_ms, fn() {
      process.send(subject, Tick)
    })
    actor.initialised(State(options:, runtime:, self: subject))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// The scanner as a supervision child, which is how a host should wire
/// it — in the restartable tier, beside `client/rulescan`'s.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, schedulescan.supervised(options, runtime, name))
/// ```
///
pub fn supervised(
  options: Options,
  runtime: Runtime,
  name: Name(Message),
) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(options, runtime, name) })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      let #(now_ms, _clock) = clock.read(state.runtime.effects.clock)
      let now_s = now_ms / 1000
      state.options.schedules
      |> list.map(fn(sched) { process_schedule(state, sched, now_ms, now_s) })
      |> rearm(state, _)
      actor.continue(state)
    }
  }
}

fn process_schedule(
  state: State,
  sched: Schedule,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  case sched.timing {
    schedule.Interval(seconds:, expiry:) ->
      process_interval(state, sched, seconds, expiry, now_ms, now_s)
    schedule.OneShot(at:) -> process_one_shot(state, sched, at, now_ms, now_s)
  }
}

// Re-arms one timer for the soonest boundary any still-`Active` schedule
// needs, or none at all when every schedule is `Expired` — the actor
// goes quiet rather than ticking forever over nothing.
fn rearm(state: State, statuses: List(ScheduleStatus)) -> Nil {
  let delays =
    list.filter_map(statuses, fn(status) {
      case status {
        Expired -> Error(Nil)
        Active(next_delay_ms:) -> Ok(next_delay_ms)
      }
    })
  case delays {
    [] -> Nil
    [first, ..rest] -> {
      let delay = list.fold(rest, first, int.min)
      let self = state.self
      state.runtime.effects.timers.after(delay, fn() {
        process.send(self, Tick)
      })
    }
  }
}

// --- interval schedules ------------------------------------------------

fn process_interval(
  state: State,
  sched: Schedule,
  seconds: Int,
  expiry: schedule.Expiry,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  let prefix = schedule.fired_key_prefix(strand: sched.target, name: sched.name)
  case api.reserved_facts(state.runtime, prefix:) {
    // A store read that fails is not worth stopping for: retry on the
    // schedule's own cadence, which is already bounded well above a
    // busy loop (`schedule.min_interval_s`).
    Error(_reason) -> Active(next_delay_ms: seconds * 1000)
    Ok(marks) ->
      interval_with_marks(state, sched, seconds, expiry, now_ms, now_s, marks)
  }
}

fn interval_with_marks(
  state: State,
  sched: Schedule,
  seconds: Int,
  expiry: schedule.Expiry,
  now_ms: Int,
  now_s: Int,
  marks: List(#(String, JsonValue)),
) -> ScheduleStatus {
  let prefix = schedule.fired_key_prefix(strand: sched.target, name: sched.name)
  let occurrences =
    list.filter_map(marks, fn(pair) {
      let #(key, _value) = pair
      key |> string.drop_start(string.length(prefix)) |> int.parse
    })
  case schedule.interval_expired(occurrences:, expiry:, now_s:) {
    True -> Expired
    False -> {
      let slot = now_s / seconds
      maybe_fire_interval(state, sched, slot, seconds, occurrences)
      Active(next_delay_ms: next_interval_delay_ms(slot, seconds, now_ms))
    }
  }
}

// The current slot's occurrence, fired if its mark is still absent. A
// held or failed attempt is not specially retried mid-slot: the next
// tick this schedule gets is the next slot boundary, at which point a
// *new* occurrence is due — which is the same "never iterate backward
// over skipped slots" property that makes a missed window cost at most
// one late fire rather than one attempt is a debt carried forward.
fn maybe_fire_interval(
  state: State,
  sched: Schedule,
  slot: Int,
  seconds: Int,
  occurrences: List(Int),
) -> Nil {
  let occurrence = slot * seconds
  let key =
    schedule.fired_key(strand: sched.target, name: sched.name, occurrence:)
  case api.fact(state.runtime, key) {
    Ok(Some(_already_fired)) -> Nil
    Ok(None) -> {
      let late = schedule.interval_late(occurrences:, seconds:, occurrence:)
      let _verdict = fire(state, sched, key, late:)
      Nil
    }
    Error(_reason) -> Nil
  }
}

// The epoch second the *next* slot begins at — the boundary a fire
// occurring now is judged `late` against, and the instant re-arming
// waits for.
fn interval_boundary_s(slot: Int, seconds: Int) -> Int {
  { slot + 1 } * seconds
}

fn next_interval_delay_ms(slot: Int, seconds: Int, now_ms: Int) -> Int {
  let boundary_ms = interval_boundary_s(slot, seconds) * 1000
  int.max(boundary_ms - now_ms, 1000)
}

// --- one-shot schedules --------------------------------------------------

fn process_one_shot(
  state: State,
  sched: Schedule,
  at: Int,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  let key =
    schedule.fired_key(strand: sched.target, name: sched.name, occurrence: at)
  case api.fact(state.runtime, key) {
    // Fired forever: a one-shot's occurrence count is 1 by construction,
    // and its mark existing is the whole of that fact.
    Ok(Some(_already_fired)) -> Expired
    Ok(None) -> due_one_shot(state, sched, key, at, now_ms, now_s)
    // A read failure retries on the same clamped cadence a not-yet-due
    // schedule would use — see `due_one_shot`.
    Error(_reason) -> Active(next_delay_ms: int.max(at * 1000 - now_ms, 1000))
  }
}

// Not yet due: re-arm at the real remaining wait, clamped. Due: fire, and
// stop re-arming for good the moment the mark actually lands (`Fired` or
// `AlreadyFired`) — a one-shot never re-arms once its single occurrence
// is spent. A held or failed attempt (no open run yet, say) is retried
// promptly rather than waiting for a boundary that has already passed:
// `at` is already in the past by construction here, so the same clamped
// formula that governs the not-yet-due case collapses to its floor.
fn due_one_shot(
  state: State,
  sched: Schedule,
  key: String,
  at: Int,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  case now_s >= at {
    False -> Active(next_delay_ms: int.max(at * 1000 - now_ms, 1000))
    True ->
      case fire(state, sched, key, late: now_s >= at + late_grace_s) {
        Fired | AlreadyFired -> Expired
        Held | Failed(..) -> Active(next_delay_ms: 1000)
      }
  }
}

// --- firing --------------------------------------------------------------

type Fire {
  // The injection (or the fresh-run admission) and the mark landed
  // together.
  Fired
  // The mark was already there: another incarnation, or a concurrent
  // tick, already did this. The occurrence is spent either way.
  AlreadyFired
  // No open run to steer, and this schedule may not start one. The mark
  // stays absent and the next tick that finds this occurrence still
  // current tries again.
  Held
  // Anything else — a stolen lease, an unreadable register. Treated
  // like a hold: the next tick tries again rather than losing the fire.
  Failed(reason: String)
}

fn fire(state: State, sched: Schedule, key: String, late late: Bool) -> Fire {
  let mark = api.Mark(key:, value: schedule.fired_value(sched))
  let text = injected_message(state, sched, late)
  let verdict = case sched.wake {
    False -> {
      let target = api.on_strand(state.runtime, sched.target)
      classify_steer(api.steer_marking(target, text, mark:))
    }
    True ->
      classify_send(api.send_to_strand_marking(
        state.runtime,
        to: sched.target,
        message: text,
        mark:,
      ))
  }
  report(state, sched, verdict)
  verdict
}

// The injected turn. A user-role message because that is the only shape
// a provider API has for context the harness supplies; the text itself
// says whose it is and why, which is `client/schedule.injection`'s whole
// job.
fn injected_message(
  state: State,
  sched: Schedule,
  late: Bool,
) -> message.AgentMessage {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)
  message.UserMessage(
    content: [
      message.UserText(
        text: schedule.injection(sched, late),
        text_signature: None,
      ),
    ],
    timestamp: now,
  )
}

fn classify_steer(admitted: Result(EntryId, api.ApiError)) -> Fire {
  case admitted {
    Ok(_entry) -> Fired
    Error(error) -> classify_error(error)
  }
}

fn classify_send(admitted: Result(api.Delivery, api.ApiError)) -> Fire {
  case admitted {
    Ok(api.Steered(..)) | Ok(api.Started(..)) -> Fired
    Error(error) -> classify_error(error)
  }
}

fn classify_error(error: api.ApiError) -> Fire {
  case error {
    // The mark moved between the read and the commit: somebody already
    // fired this occurrence, which is exactly what the write-once
    // expectation was asked to find out.
    api.FactConflict(..) -> AlreadyFired
    api.QueueRejected(..) -> Held
    api.AcceptRejected(..)
    | api.ReadFailed(..)
    | api.CommitFailed(..)
    | api.SessionStolen(..)
    | api.RaceLost
    | api.ReservedFactKey(..)
    | api.UnreservedFactKey(..)
    | api.EscalationExists(..)
    | api.EscalationNotFound(..)
    | api.EscalationWrongStatus(..) -> Failed(reason: string.inspect(error))
  }
}

fn report(state: State, sched: Schedule, verdict: Fire) -> Nil {
  let where = [
    field.text(key: "schedule", value: sched.name),
    field.text(key: "strand", value: sched.target),
  ]
  case verdict {
    Fired -> log.info(state.options.logger, "schedule.fired", where)
    // Neither of these is a fault: one is another incarnation (or tick)
    // having won, the other is a schedule waiting on a run to exist.
    AlreadyFired | Held -> Nil
    Failed(reason:) ->
      log.warn(state.options.logger, "schedule.injection_refused", [
        field.text(key: "reason", value: reason),
        ..where
      ])
  }
}
