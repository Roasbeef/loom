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
//// fire-marks (`read_prefix`, below, under
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
//// `now_s` the way an interval's slot does. A late annotation names a
//// window that closed before this fire landed; it does not claim the
//// server was down for it — an interval schedule held on a stubbornly
//// idle strand across a slot boundary reads exactly the same way, and
//// both are, correctly, "late" in the sense the text describes.
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
//// design note's "The crux" section for the full argument. The expiry
//// clock only starts on a schedule's first landed fire (`expires_after_s`
//// counts from the earliest fired-mark, per `client/schedule`), so a
//// schedule that never once fires — held forever on a strand nobody ever
//// opens a run on — never expires either: it keeps ticking, and keeps
//// costing nothing durable, for the life of the session. That is a cost
//// question, not a safety one: no fires means no liveness extension and
//// no rows, which is the property `wake = true` actually needs.
////
//// ## Isolation
////
//// Every read here goes straight to the session store
//// (`storage.get_register`/`list_registers` against
//// `runtime.session.store`), never through the writer's mailbox — the
//// same door `client/rulescan` reads through and for the same reason: a
//// slow tick's up-to-`max_schedules` bounded scans must never queue in
//// front of a settlement. The only thing this actor sends the writer is
//// the fire itself — an ordinary marked admission — on its own process.
//// It is a restartable service (`client/serve`'s service supervisor):
//// killing it mid-tick costs the tick in flight and nothing else, and the
//// replacement's first tick (armed at start, per the module doc above)
//// re-derives everything from the durable fire-marks. One dependency this
//// buys nothing against: the scanner's whole liveness rests on one
//// re-armed `Timers.after` deadline, and `runtime/effects.Timers`'s own
//// contract tolerates a dropped wake precisely because the strand driver
//// can always rediscover a missed one by re-planning — this actor has no
//// such rediscovery path, so a wake genuinely lost (not merely late)
//// would silently end every schedule until the scanner itself restarts.
//// `effects.real_timers()` never drops one in production; the risk is
//// confined to a host supplying its own, lossier `Timers`.

import client/schedule.{type Schedule}
import core/clock
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/bool
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import storage/storage
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
/// Constructor invariants: `schedules` is the parsed, validated operator
/// schedule list (`client/schedule.parse`); with `model_door_open` false
/// an empty list makes every tick a no-op and the actor re-arms nothing,
/// so it goes quiet after its first tick.
pub type Options {
  Options(
    /// The operator's `[[schedule]]` tables, fixed for this boot.
    schedules: List(Schedule),
    /// Whether the model may create schedules of its own this session
    /// (`client/schedule.policy_opens_the_door`). It changes exactly one
    /// thing here: a scanner with nothing active keeps a slow rescan
    /// timer instead of going quiet, because a schedule may arrive
    /// without anything in this actor's own state changing.
    model_door_open: Bool,
    logger: Logger,
  )
}

/// The scanner's mailbox.
///
/// Two variants, and the split exists to stop a leak rather than to
/// express two kinds of work — both do the identical scan. Every tick
/// ends by arming the next one, so anything that delivers a `Tick`
/// delivers a *chain*, not an event: two `Tick`s in flight become two
/// self-perpetuating chains, and with the door open's rescan floor
/// neither ever goes quiet. `poke` used to send `Tick` and so leaked one
/// chain per model `schedule_create`, forever.
///
/// `Tick` therefore carries the generation it was armed under, and a tick
/// whose generation is stale is dropped without re-arming — so a chain
/// the actor has moved on from dies at its next delivery. `Rescan` is the
/// out-of-band "look now" that `poke` sends: it scans and adopts a fresh
/// generation, which is what retires whichever chain was already pending.
pub type Message {
  /// A wake armed by this actor, tagged with the generation current when
  /// it was armed. A stale one is a chain being retired.
  Tick(generation: Int)

  /// Look now, out of band. Adopts a new generation, so any pending
  /// `Tick` becomes stale and dies rather than compounding.
  Rescan
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
  Options(schedules:, model_door_open: False, logger: log.discard())
}

/// Declares that the model may create schedules this session, which keeps
/// the scanner rescanning even with nothing of the operator's left to
/// fire.
///
/// ## Examples
///
/// ```gleam
/// // schedulescan.default_options([]) |> schedulescan.with_model_door_open
/// ```
///
pub fn with_model_door_open(options: Options) -> Options {
  Options(..options, model_door_open: True)
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
  State(
    options: Options,
    runtime: Runtime,
    self: Subject(Message),
    /// The generation a `Tick` must carry to be acted on. Incremented by
    /// every scan, so exactly one armed chain is live at a time however
    /// many pokes arrive.
    generation: Int,
  )
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
      process.send(subject, Tick(generation: 1))
    })
    actor.initialised(State(options:, runtime:, self: subject, generation: 1))
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
    // A wake from a chain this actor has already replaced. Dropping it
    // *without* re-arming is the whole mechanism: that is where the
    // superseded chain ends.
    Tick(generation:) if generation != state.generation -> actor.continue(state)

    Tick(..) | Rescan -> scan(state)
  }
}

// One pass over every due schedule, ending in exactly one armed wake.
//
// The generation moves first and the arm captures the new value, so a
// `Tick` still in flight under the old one is already stale by the time
// it is delivered.
fn scan(state: State) -> actor.Next(State, Message) {
  let scanned = State(..state, generation: state.generation + 1)
  let #(now_ms, _clock) = clock.read(scanned.runtime.effects.clock)
  let now_s = now_ms / 1000
  due_schedules(scanned)
  |> list.map(fn(due) { process_schedule(scanned, due, now_ms, now_s) })
  |> rearm(scanned, _)
  actor.continue(scanned)
}

// Every schedule this tick must consider: the operator's, fixed at boot,
// plus whatever the model has created since — read fresh from the store
// on every tick rather than held in state.
//
// Re-reading is the point, not an inefficiency to fix later. A
// model-created schedule can appear or be cancelled between any two
// ticks, and this actor is restartable, so a cached list would be a
// second source of truth that a restart, a cancellation, or a create on
// another incarnation could each make stale. The scan is one indexed
// prefix read over a list bounded by `schedule.max_model_schedules`,
// against a tick that never runs tighter than `schedule.min_interval_s`.
//
// A failed read yields the operator's schedules alone rather than an
// empty list: a transient store fault must not look like "the model
// cancelled everything", which would silently stop firing the very
// schedules a model may be relying on.
fn due_schedules(state: State) -> List(Due) {
  let operator =
    list.map(state.options.schedules, fn(sched) {
      Due(schedule: sched, origin: schedule.OperatorConfigured)
    })
  let model =
    list.map(model_schedules(state), fn(sched) {
      Due(schedule: sched, origin: schedule.ModelCreated)
    })
  list.append(operator, model)
}

// A schedule paired with where it came from. The origin is not carried on
// `Schedule` itself because it is not a property of the schedule — it is a
// property of the store it was read out of, and this is the one place both
// stores are in scope. It exists so a fire can say whose text it is: a
// model reading "standing operator configuration" above a body it wrote
// itself has been handed an authority nobody granted.
type Due {
  Due(schedule: Schedule, origin: schedule.Origin)
}

fn model_schedules(state: State) -> List(Schedule) {
  case read_prefix(state, schedule.config_key_prefix) {
    Error(Nil) -> []
    Ok(cells) ->
      list.filter_map(cells, fn(pair) {
        let #(_key, value) = pair
        schedule.decode(value)
      })
  }
}

fn process_schedule(
  state: State,
  due: Due,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  case due.schedule.timing {
    schedule.Interval(seconds:, expiry:) ->
      process_interval(state, due, seconds, expiry, now_ms, now_s)
    schedule.OneShot(at:) -> process_one_shot(state, due, at, now_ms, now_s)
  }
}

// Re-arms one timer for the soonest boundary any still-`Active` schedule
// needs.
//
// With nothing active there is normally nothing to wake for, and the
// actor goes quiet rather than ticking forever over nothing. That is only
// true while the operator's list is the whole story: once the
// model-facing door is open, a schedule can appear between any two ticks,
// and an actor that has gone quiet would never find out. `poke` is what
// makes that prompt — the seam rings this actor the moment it writes a
// cell — and the floor below is what makes it *certain*, because a poke
// is an ordinary message and the one thing this actor must never do is
// stop scanning because a wake went missing. The floor costs one timer
// per `schedule.min_interval_s` and bounds the worst case to noticing a
// new schedule one interval late instead of never.
fn rearm(state: State, statuses: List(ScheduleStatus)) -> Nil {
  let delays =
    list.filter_map(statuses, fn(status) {
      case status {
        Expired -> Error(Nil)
        Active(next_delay_ms:) -> Ok(next_delay_ms)
      }
    })
  case delays, state.options.model_door_open {
    [], False -> Nil
    [], True -> arm(state, idle_rescan_ms())
    [first, ..rest], _ -> arm(state, list.fold(rest, first, int.min))
  }
}

// Arms one wake, tagged with this scan's generation and clamped to what
// a BEAM timer can actually hold.
//
// The clamp is not a nicety. `runtime/effects.real_timers` is
// `spawn_unlinked(sleep(delay); wake())`, `process.sleep` is a `receive
// after`, and a timeout above 2^32-1 ms raises `timeout_value` — on an
// *unlinked* process, so the chain dies silently and the scanner never
// ticks again. Nothing else bounds this: neither creation path caps an
// interval from above, and a one-shot `at` far enough out overflows on
// its own. Waking early costs one wasted scan, which re-derives the same
// answer and re-arms; waking never costs every schedule in the session.
fn arm(state: State, delay_ms: Int) -> Nil {
  let self = state.self
  let generation = state.generation
  state.runtime.effects.timers.after(
    int.min(delay_ms, max_timer_delay_ms),
    fn() { process.send(self, Tick(generation:)) },
  )
}

/// The longest delay a BEAM `receive after` accepts (2^32-1 ms, about
/// 49.7 days). A larger one raises `timeout_value` rather than sleeping,
/// so every armed delay is clamped to it and a longer wait is served by
/// re-arming after the clamp expires.
pub const max_timer_delay_ms = 4_294_967_295

// The floor an otherwise-quiet scanner rescans on when the model may
// create schedules. A function rather than a `const`: Gleam constants
// must be literals, and this is an imported constant times another.
fn idle_rescan_ms() -> Int {
  schedule.min_interval_s * 1000
}

/// Rings the scanner so it rescans now rather than at its next armed
/// deadline — what `client/scheduleseam` calls the moment it writes a
/// schedule's config cell.
///
/// It sends `Rescan`, not `Tick`, and that distinction is load-bearing.
/// Every scan ends by arming the next wake, so a bare `Tick` would start
/// a second self-perpetuating chain beside the one already pending —
/// which is what this did before, leaking one permanent chain per model
/// `schedule_create` or `schedule_cancel`. `Rescan` takes a fresh
/// generation, which retires the pending chain at its next delivery.
///
/// A poke that arrives while the actor is restarting is simply lost,
/// which is why `rearm` keeps a floor.
///
/// ## Examples
///
/// ```gleam
/// // schedulescan.poke(scanner_name)
/// ```
///
pub fn poke(name: Name(Message)) -> Nil {
  // Checked alive before sending, for the same reason `client/agency`
  // checks its holder: a send to a name nothing is registered under
  // raises, and the caller is a tool body whose crash would become a
  // fault rather than an in-band result. An unregistered scanner is not
  // even unusual here — it is exactly what a restart looks like from
  // outside — and it costs nothing to miss, because a restarting scanner
  // ticks immediately on the way back up and re-reads every cell.
  let subject = process.named_subject(name)
  case process.subject_owner(subject) {
    Error(Nil) -> Nil
    Ok(pid) ->
      case process.is_alive(pid) {
        False -> Nil
        True -> process.send(subject, Rescan)
      }
  }
}

// --- interval schedules ------------------------------------------------

fn process_interval(
  state: State,
  due: Due,
  seconds: Int,
  expiry: schedule.Expiry,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  let prefix =
    schedule.fired_key_prefix(
      strand: due.schedule.target,
      name: due.schedule.name,
    )
  case read_prefix(state, prefix) {
    // A store read that fails is not worth stopping for: retry on the
    // schedule's own cadence, which is already bounded well above a
    // busy loop (`schedule.min_interval_s`).
    Error(Nil) -> Active(next_delay_ms: seconds * 1000)
    Ok(marks) ->
      interval_with_marks(state, due, seconds, expiry, now_ms, now_s, marks)
  }
}

fn interval_with_marks(
  state: State,
  due: Due,
  seconds: Int,
  expiry: schedule.Expiry,
  now_ms: Int,
  now_s: Int,
  marks: List(#(String, JsonValue)),
) -> ScheduleStatus {
  let prefix =
    schedule.fired_key_prefix(
      strand: due.schedule.target,
      name: due.schedule.name,
    )
  let occurrences =
    list.filter_map(marks, fn(pair) {
      let #(key, _value) = pair
      key |> string.drop_start(string.length(prefix)) |> int.parse
    })
  case schedule.interval_expired(occurrences:, expiry:, now_s:) {
    True -> Expired
    False -> {
      let occurrence = schedule.interval_occurrence(seconds:, now_s:)
      maybe_fire_interval(state, due, occurrence, seconds, occurrences)
      Active(next_delay_ms: next_interval_delay_ms(occurrence, seconds, now_ms))
    }
  }
}

// The current slot's occurrence, fired if its mark is still absent. The
// absence check reads `occurrences` — the same prefix scan
// `interval_with_marks` already paid for this tick — rather than a
// second point read: nothing can have changed it since, this actor being
// the only writer of its own tick. A held or failed attempt is not
// specially retried mid-slot: the next tick this schedule gets is the
// next slot boundary, at which point a *new* occurrence is due — which is
// the same "never iterate backward over skipped slots" property that
// makes a missed window cost at most one late fire rather than one
// attempt is a debt carried forward.
fn maybe_fire_interval(
  state: State,
  due: Due,
  occurrence: Int,
  seconds: Int,
  occurrences: List(Int),
) -> Nil {
  use <- bool.guard(when: list.contains(occurrences, occurrence), return: Nil)
  let key =
    schedule.fired_key(
      strand: due.schedule.target,
      name: due.schedule.name,
      occurrence:,
    )
  let late = schedule.interval_late(occurrences:, seconds:, occurrence:)
  let _verdict = fire(state, due, key, late:)
  Nil
}

// The epoch second the *next* slot begins at — the boundary a fire
// occurring now is judged `late` against, and the instant re-arming
// waits for.
fn next_interval_delay_ms(occurrence: Int, seconds: Int, now_ms: Int) -> Int {
  let boundary_ms = { occurrence + seconds } * 1000
  int.max(boundary_ms - now_ms, 1000)
}

// --- one-shot schedules --------------------------------------------------

fn process_one_shot(
  state: State,
  due: Due,
  at: Int,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  let key =
    schedule.fired_key(
      strand: due.schedule.target,
      name: due.schedule.name,
      occurrence: at,
    )
  case read_fact(state, key) {
    // Fired forever: a one-shot's occurrence count is 1 by construction,
    // and its mark existing is the whole of that fact.
    Some(_already_fired) -> Expired
    None -> due_one_shot(state, due, key, at, now_ms, now_s)
  }
}

// The floor a held or failed retry never goes below: a one-shot with
// nothing to steer is otherwise a candidate for tight, indefinite
// re-arming — a `wake = false` one-shot naming a strand that never opens
// a run polls forever, and one naming a strand that doesn't exist fails
// every attempt forever — so the same busy-loop floor `client/schedule`
// already enforces on a configured `every` applies here too. A function
// rather than a `const`: Gleam constants must be literals, and this is
// one imported constant times another.
fn held_or_failed_retry_ms() -> Int {
  schedule.min_interval_s * 1000
}

// Not yet due: re-arm at the real remaining wait, clamped. Due: fire, and
// stop re-arming for good the moment the mark actually lands (`Fired` or
// `AlreadyFired`) — a one-shot never re-arms once its single occurrence
// is spent. A held or failed attempt (no open run yet, say) retries no
// sooner than `held_or_failed_retry_ms`, never at the tight cadence a
// genuinely not-yet-due wait uses.
fn due_one_shot(
  state: State,
  due: Due,
  key: String,
  at: Int,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  case now_s >= at {
    False -> Active(next_delay_ms: int.max(at * 1000 - now_ms, 1000))
    True ->
      case fire(state, due, key, late: now_s >= at + late_grace_s) {
        Fired | AlreadyFired -> Expired
        Held | Failed(..) -> Active(next_delay_ms: held_or_failed_retry_ms())
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

fn fire(state: State, due: Due, key: String, late late: Bool) -> Fire {
  let mark = api.Mark(key:, value: schedule.fired_value(due.schedule))
  let text = injected_message(state, due, late)
  let verdict = case due.schedule.wake {
    False -> {
      let target = api.on_strand(state.runtime, due.schedule.target)
      classify_steer(api.steer_marking(target, text, mark:))
    }
    True ->
      classify_send(api.send_to_strand_marking(
        state.runtime,
        to: due.schedule.target,
        message: text,
        mark:,
      ))
  }
  report(state, due.schedule, verdict)
  verdict
}

// The injected turn. A user-role message because that is the only shape
// a provider API has for context the harness supplies; the text itself
// says whose it is and why, which is `client/schedule.injection`'s whole
// job.
fn injected_message(
  state: State,
  due: Due,
  late: Bool,
) -> message.AgentMessage {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)
  message.UserMessage(
    content: [
      message.UserText(
        text: schedule.injection(due.schedule, late, due.origin),
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

// --- durable reads -------------------------------------------------------
//
// Straight to the session store, never through the writer's mailbox — see
// the module doc's "Isolation" section. `client/rulescan.read_fact` is the
// same door for the same reason.

// A store fault reads as "no mark" here, unlike `read_prefix`'s explicit
// `Error`: this point read only ever gates whether a *fire is attempted*
// (`maybe_fire_interval`, `process_one_shot`), never whether one is
// recorded. A fault-as-absent misread proceeds to `fire`, whose commit
// carries the mark's own absent-expectation — if the mark truly exists,
// that commit fails on it (`FactConflict`, handled), and if the store is
// genuinely faulting the commit fails too (`Failed`, retried on the
// held/failed floor). Either way the CAS is what stays safe, not this
// read; nothing here needs the two helpers' error handling to match.
fn read_fact(state: State, key: String) -> Option(JsonValue) {
  storage.get_register(state.runtime.session.store, register.FactCustom, key)
  |> result.unwrap(None)
  |> option.map(fn(cell: storage.Register) { cell.value.payload })
}

// A prefix scan of `fact.custom`, read directly off the store the same way
// `read_fact` is. `Error(Nil)` on a store fault — the caller retries next
// tick, on its own bounded cadence, rather than treating a transient read
// failure as "nothing has ever fired here."
fn read_prefix(
  state: State,
  prefix: String,
) -> Result(List(#(String, JsonValue)), Nil) {
  storage.list_registers(
    state.runtime.session.store,
    register.FactCustom,
    Some(prefix),
  )
  |> result.map(fn(cells) {
    list.map(cells, fn(pair) {
      let #(key, storage.Register(value:, ..)) = pair
      #(key, value.payload)
    })
  })
  |> result.replace_error(Nil)
}
