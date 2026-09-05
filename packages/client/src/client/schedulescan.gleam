//// The scheduled-heartbeat scanner: one session-scoped state machine that
//// wakes on its own injected timer, re-derives from the durable store
//// which configured schedules are due, and fires each once per
//// occurrence.
////
//// `docs/design-notes/scheduled-heartbeats.md` is the design ruling this
//// module implements — read "Durability and the crash story" there
//// before changing anything in here. The shape mirrors
//// `client/rulescan`'s session-scoped restartable service, its
//// `default_options`/`with_logger` builder, and its `start`/`supervised`
//// pair; what differs is what drives it and what it remembers between
//// ticks.
////
//// ## Driven by a re-armed named timeout on the session's own clock
////
//// `client/rulescan` is fed by the StorageWriter's post-commit
//// publication, because a triggered rule can only become relevant when
//// new model output exists to trigger it. A schedule fires on a clock
//// whether anything committed or not, so this one is a
//// **`weft/state_machine`** whose whole liveness is one *named timeout*
//// (`scan_timer`, below), re-armed by every scan for the soonest
//// boundary any still-active schedule needs next. A scan that finds
//// nothing left active cancels the name instead, and the machine goes
//// quiet.
////
//// The timeout is armed on the session's own clock rather than on the
//// wall clock: the builder takes
//// `weft/timer.Injected(after: runtime.effects.timers.after)`, the same
//// injected seam the strand driver re-arms its own poll and retry timers
//// with. That is what keeps a simulated session's heartbeats on logical
//// time and lets `schedulescan_test` drive a fake wheel by hand, and it
//// is the reason this module could not be a weft machine before weft
//// 0.4.2 grew `with_timer_source`. Nothing about the discipline is this
//// module's own any more: the generation tag that used to ride on every
//// `Tick` is `weft/internal/timer`'s generation stamp, and a wake from an
//// arming a later scan superseded dies in the book's own check rather
//// than in a hand-written guard. What the injected source gives up is
//// cancellation — an `after` call yields no handle, so a superseded or
//// cancelled arming still rings — and that check is exactly what makes
//// the loss safe.
////
//// One state, `Watching`, and the machine never leaves it. That is not
//// an actor written as a machine by accident: what moves per event is
//// the *delay*, recomputed from the store on every scan, and neither of
//// the two structural timeouts can carry that — a state timeout is
//// cancelled by a change of state this machine never makes, and a
//// periodic one has a single fixed cadence. The state exists so the
//// timer belongs to the machine rather than to a phase, which is what
//// lets one name be armed, superseded and cancelled from one place.
////
//// ## No progress state: every tick recomputes fully from the store
////
//// `client/rulescan` keeps a `Progress` map between hints — a cursor, a
//// hold flag — because it must not re-scan a whole branch on every
//// commit. A schedule has no branch to scan: whether an occurrence is
//// due and how many times a schedule has fired are both questions a
//// bounded prefix scan of the write-once fire-marks (`read_prefix`,
//// below, under `client/schedule.fired_key_prefix`) answers exactly,
//// every time. The one question those marks cannot answer is when a
//// schedule's `expires_after_s` window opened, because a schedule that
//// has never fired has no earliest mark to read it off — so that
//// instant is recorded durably instead, once per schedule ever, in the
//// cell `client/schedule.seen_key` names (`observed_since`, below).
//// That is a durable fact and not machine data, so the paragraph's claim
//// survives it: this machine holds nothing across ticks beyond the
//// static, parsed
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
//// design note's "The crux" section for the full argument. Holding
//// costs nothing durable, and it does not postpone the end either: the
//// expiry clock starts when this scanner first *observes* a schedule,
//// not when one first fires, so a `wake = false` heartbeat held forever
//// on a strand nobody ever opens a run on stops costing a tick once
//// `expires_after_s` has passed, exactly like a schedule that fired
//// every slot. That is what issue #157 changed. The clock used to start
//// at the earliest fired-mark, which gave a schedule that never landed
//// one no clock at all: it ticked for the life of the session, and
//// `expires_after_s` named a week to the operator that would never
//// begin.
////
//// ## A settled target ends the schedule
////
//// A schedule is checked against the strand it fires onto before any
//// timing arithmetic happens, and for a subagent target the answer can
//// be "this strand has stopped". A subagent exists to run one brief:
//// once that brief has settled, or the Agency has marked the strand
//// reaped, its timeline is over, and a fire onto it would inject text
//// nobody will read — or, for a `WakesIdle` schedule, open a run on a
//// driver whose task ended, which is a child's life extended past its
//// work and outside its parent's spawn budget (issue #163). Such a
//// schedule is `Expired` for the tick: no fire, no re-arm, and no wake
//// whoever configured it, operator or model.
////
//// The two facts read are exactly the two `client/agency.is_live` and
//// `client/agency.reap` decide from — the durable `reaped` mark on the
//// lineage cell and the brief's own terminal result — so the scanner and
//// the Agency cannot disagree about whether a child is finished. It
//// **fails closed**: a `sub:` target with no lineage cell, or one whose
//// cell will not decode, reads as finished. That is the opposite
//// direction from `client/rulescan`'s hold on an unreadable strand, and
//// deliberately so: a held rule costs a tick, while a fired schedule may
//// open a run. A root strand answers `False` without any read at all,
//// which is both the hot path and the honest one — `main` is idle
//// between runs rather than finished, so a terminal result there says
//// the last prompt ended and nothing about whether the next will arrive.
////
//// ## Isolation
////
//// Every read here goes straight to the session store
//// (`storage.get_register`/`list_registers` against
//// `runtime.session.store`), never through the writer's mailbox — the
//// same door `client/rulescan` reads through and for the same reason: a
//// slow tick's up-to-`max_schedules` bounded scans must never queue in
//// front of a settlement. The writer hears exactly two things from this
//// machine, both on its own process: the fire itself — an ordinary marked
//// admission — and, once per schedule ever, the expect-absent claim of
//// that schedule's observation instant (`observed_since`).
//// It is a restartable service (`client/serve`'s service supervisor):
//// killing it mid-tick costs the tick in flight and nothing else, and the
//// replacement's first tick (armed on the way into `Watching`, per the
//// module doc above) re-derives everything from the durable fire-marks.
//// One dependency this buys nothing against: the scanner's whole
//// liveness rests on one re-armed named timeout, and
//// `runtime/effects.Timers`'s own contract — which is the contract
//// `weft/timer.Injected` restates — tolerates a dropped wake precisely
//// because the strand driver can always rediscover a missed one by
//// re-planning. This machine has no such rediscovery path, so a wake
//// genuinely lost (not merely late) would silently end every schedule
//// until the scanner itself restarts. `effects.real_timers()` never
//// drops one in production; the risk is confined to a host supplying its
//// own, lossier `Timers`.

import client/agency
import client/cron
import client/schedule.{type Schedule}
import core/clock
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import core/message
import core/register
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import runtime/lineage
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor
import weft/registry as address
import weft/state_machine as sm
import weft/timer

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
///
/// It is a zero-delay *arming* rather than a `sm.continuing(Rescan)`,
/// and the difference is observable. An injected message is handled
/// inside `start`'s own continuation, so the first scan would be over
/// before any caller could see the machine at all; a wake armed on the
/// session's clock leaves "the first tick is armed and has not run" a
/// state a simulated session can hold still and step through, which is
/// what every fixture in `schedulescan_test` drives.
const first_tick_delay_ms = 0

/// The one name every arming of this machine's timer uses.
///
/// One name is the whole mechanism. `sm.with_named_timeout` replaces
/// whatever is armed under a name, so each scan's re-arm supersedes the
/// arming that woke it and a wake for the superseded one dies in the
/// timer book's generation check — which is how "one live chain, however
/// many pokes" is a property of weft rather than of a tag this module
/// carries. A second name would be a second chain.
const scan_timer = "schedule-scan"

/// Whether the model may create schedules of its own this session
/// (`client/schedule.policy_opens_the_door`), as the scanner needs to
/// know it.
///
/// It changes exactly one thing here, which is what the two names have
/// to carry: whether a scan that finds nothing active may let the machine
/// go quiet. Nothing else in this module branches on it.
pub type ModelDoor {
  /// The model may create a schedule at any moment, so a scan finding
  /// nothing active keeps a slow rescan timer rather than going quiet —
  /// a schedule can arrive without anything in this machine's own data
  /// changing, and a machine that had gone quiet would never find out.
  DoorOpen

  /// The operator's list is the whole story. A scan finding nothing
  /// active re-arms nothing, and the machine goes quiet for good.
  DoorShut
}

/// What the scanner watches and how loudly it works.
///
/// Constructor invariants: `schedules` is the parsed, validated operator
/// schedule list (`client/schedule.parse`); with `model_door` `DoorShut`
/// an empty list makes every tick a no-op and the machine re-arms nothing,
/// so it goes quiet after its first tick.
pub type Options {
  Options(
    /// The operator's `[[schedule]]` tables, fixed for this boot.
    schedules: List(Schedule),
    /// Whether a schedule may appear between two ticks without this
    /// machine being told through its own data.
    model_door: ModelDoor,
    logger: Logger,
  )
}

/// The scanner's mailbox.
///
/// Two variants, and both do the identical scan: the split says where a
/// wake came from, not what it means. `Tick` is the machine's own named
/// timeout ringing; `Rescan` is the out-of-band "look now" that `poke`
/// sends when a cell has just been written.
///
/// Neither carries a generation, and that is what the port to
/// `weft/state_machine` bought. Every scan ends by re-arming one named
/// timeout, so anything that delivers a wake delivers a *chain* rather
/// than an event — and before the port this module carried its own tag
/// on every `Tick` so that a chain it had moved on from would die at its
/// next delivery, which is `weft/internal/timer`'s generation stamp
/// written a second time by hand. Arming under one name now supersedes
/// the previous arming, so a superseded wake never reaches this type at
/// all: it is dropped in the book. `poke` sending `Rescan` rather than
/// `Tick` is therefore no longer what stops the leak — the supersession
/// is — but the two names are still worth keeping apart, because a
/// reader tracing a wake wants to know whether the clock or a writer
/// produced it.
pub type Message {
  /// The machine's named timeout ringing: the arming the last scan made
  /// has come due.
  Tick

  /// Look now, out of band, because a schedule cell has just been
  /// written. Scans and re-arms exactly as `Tick` does.
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
  Options(schedules:, model_door: DoorShut, logger: log.discard())
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
  Options(..options, model_door: DoorOpen)
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

/// The one state this machine is ever in.
///
/// A single variant, deliberately. What moves between events here is a
/// *delay* — recomputed from the durable store on every scan — and
/// neither of weft's structural timeouts can carry that: a state timeout
/// is cancelled by a change of state this machine never makes, and a
/// periodic timeout has one fixed cadence. So the state exists for the
/// one thing rule 8 of `docs/weft.md` asks for: the timer belongs to the
/// machine rather than to a phase, and `scan_timer` is armed,
/// superseded and cancelled from one place.
///
/// Because the machine never leaves `Watching`, `sm.on_enter` runs
/// exactly once ever — the initial call — which is what makes it the
/// honest home for the first arming rather than a per-entry re-arm in
/// disguise.
type Phase {
  Watching
}

// Everything the machine carries between events. Both fields are fixed
// for the life of the process: the port deleted the generation tag that
// used to sit here, and nothing has taken its place, because a scan
// recomputes every answer it needs from the store.
type State {
  State(options: Options, runtime: Runtime)
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
/// The declared type is `gleam/otp/actor`'s own `StartResult`, which is
/// what `weft/state_machine.start` returns: a weft machine is
/// indistinguishable from an upstream actor to whatever starts it, so
/// this stayed a supervised child of `client/serve` across the port with
/// nothing on either side to change.
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
  name: address.Address(Message),
) -> actor.StartResult(Subject(Message)) {
  builder(options, runtime, name) |> sm.start
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
  name: address.Address(Message),
) -> ChildSpecification(Subject(Message)) {
  sm.supervised(builder(options, runtime, name))
}

// The machine `start` and `supervised` both describe, so the two doors
// cannot drift in what they build.
//
// `with_timer_source` is the load-bearing line. Every one of this
// machine's armings goes through the session's own
// `runtime/effects.Timers.after` — the seam a simulated session steps on
// logical time and `schedulescan_test` drives as a fake wheel — rather
// than through `process.send_after` on the wall clock. Two clocks in a
// session built to have one is a run that is not deterministic, and this
// machine's whole liveness is its timer.
fn builder(
  options: Options,
  runtime: Runtime,
  name: address.Address(Message),
) -> sm.Builder(Phase, State, Message, Subject(Message)) {
  sm.new_with_initialiser(5000, fn(subject) {
    sm.initialised(Watching, State(options:, runtime:))
    |> sm.returning(subject)
    |> Ok
  })
  |> sm.with_timer_source(timer.Injected(after: runtime.effects.timers.after))
  |> sm.addressed(name)
  |> sm.on_enter(entered)
  |> sm.on_event(handle)
}

// The first arming, made once on the way into `Watching`.
//
// This is the only arming site that is not a scan's own re-arm, and it
// exists because nothing has scanned yet: the delay a scan would compute
// is unknown until one has read the store. `first_tick_delay_ms` says
// why it is zero.
fn entered(
  _from: Phase,
  _to: Phase,
  data: State,
) -> sm.Enter(Phase, State, Message) {
  sm.keep(data)
  |> sm.with_named_timeout(
    name: scan_timer,
    after: first_tick_delay_ms,
    sending: Tick,
  )
}

// Both wakes do the identical scan, and the arm the scan ends with is
// what supersedes whichever arming produced this one. A wake for an
// arming already superseded never arrives here: the timer book drops it
// on its generation stamp.
fn handle(
  state: Phase,
  data: State,
  message: Message,
) -> sm.Next(Phase, State, Message) {
  case state, message {
    Watching, Tick | Watching, Rescan -> scan(data)
  }
}

// One pass over every due schedule, ending in exactly one armed wake or
// in the timer cancelled.
fn scan(data: State) -> sm.Next(Phase, State, Message) {
  let #(now_ms, _clock) = clock.read(data.runtime.effects.clock)
  let now_s = now_ms / 1000
  due_schedules(data)
  |> list.map(fn(sched) { process_schedule(data, sched, now_ms, now_s) })
  |> rearm(data, _)
}

// Every schedule this tick must consider: the operator's, fixed at boot,
// plus whatever the model has created since — read fresh from the store
// on every tick rather than held in state.
//
// Re-reading is the point, not an inefficiency to fix later. A
// model-created schedule can appear or be cancelled between any two
// ticks, and this machine is restartable, so a cached list would be a
// second source of truth that a restart, a cancellation, or a create on
// another incarnation could each make stale. The scan is one indexed
// prefix read, against a tick that never runs tighter than
// `schedule.min_interval_s`, over a list whose bound `model_schedules`
// below states and argues.
//
// A failed read yields the operator's schedules alone rather than an
// empty list: a transient store fault must not look like "the model
// cancelled everything", which would silently stop firing the very
// schedules a model may be relying on.
//
// The two lists are appended and nothing else: a schedule carries its
// own `client/schedule.Owner`, so whose text a fire is
// (`schedule.origin_of`) is a property of the value rather than of the
// list it arrived in, and this function used to pair each schedule with
// an origin only because the value could not say. An operator's table
// parses to `OperatorOwned` and a config cell can never decode to it,
// which is what keeps that derivation as trustworthy as the pairing was.
fn due_schedules(state: State) -> List(Schedule) {
  list.append(state.options.schedules, model_schedules(state))
}

// Every model-created schedule this session currently holds, decoded
// from the config cells under one prefix.
//
// The read is bounded by `schedule.max_model_schedules`, and that is
// true only because cancelling a schedule *deletes* its config cell
// rather than overwriting it with a tombstone. The ceiling counts live
// schedules, so a cancelled one leaving a row behind would let this
// prefix grow without bound while the ceiling still read as satisfied,
// and every tick reads the whole of it (issue #164). A cell that does
// not decode is dropped rather than failing the tick: a schedule stored
// by a build with looser bounds is not a schedule that runs today.
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
  sched: Schedule,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  // A target that has stopped ends the schedule before any timing
  // arithmetic is done, because there is no occurrence left worth
  // computing: nothing will read the injection and no later tick will
  // find the strand alive again.
  use <- bool.guard(when: finished(state, sched.target), return: Expired)
  case sched.timing {
    schedule.Interval(seconds:, expiry:) ->
      process_interval(state, sched, seconds, expiry, now_ms, now_s)

    schedule.Cron(expression:, offset_s:, expiry:) ->
      process_cron(
        state,
        sched,
        CronClock(expression:, offset_s:),
        expiry,
        now_ms,
        now_s,
      )

    schedule.OneShot(at:) -> process_one_shot(state, sched, at, now_ms, now_s)
  }
}

// Whether the strand a schedule fires onto has stopped for good.
//
// **Only a subagent can answer yes**, and the check costs nothing for
// anyone else: a root strand is idle between runs rather than finished,
// so a terminal result on `main` says the last prompt ended and nothing
// about whether the next one will arrive. A subagent is the opposite. It
// exists to run one brief; when that brief has settled, or the Agency
// has marked the strand reaped, its timeline is over. Firing onto it
// then would inject text nobody will read, and — for a `WakesIdle`
// schedule planted before this build capped it, or one an operator
// configured — would re-open a run on a driver whose task had ended,
// which is the security-shaped half of issue #163.
//
// The two facts are exactly the two `client/agency.reap` and
// `client/agency.is_live` decide from, read the same way: the durable
// `reaped` mark on the lineage cell, and the brief's own terminal
// result. Both are store reads on this process — `is_live`'s
// `api.await_strand_result` with a zero budget is one immediate read of
// the operation-keyed result fact — so this stays off the writer's
// mailbox like every other read here.
//
// It fails **closed**: a `sub:` strand with no lineage cell, or one
// whose cell will not decode, reads as finished. That is the opposite
// direction from `client/rulescan`'s hold, and deliberately so — a rule
// held on an unreadable strand is retried and costs a tick, while a
// schedule fired onto one may open a run. The Agency writes a lineage
// cell before the brief is accepted, so a `sub:` name with no cell is
// not a strand this session started.
fn finished(state: State, target: String) -> Bool {
  use <- bool.guard(when: !agency.is_subagent(target), return: False)
  case read_fact(state, lineage.register_key(target)) {
    None -> True
    Some(payload) ->
      case lineage.decode(payload) {
        Error(_corrupt) -> True
        Ok(cell) -> cell.reaped || settled(state, cell)
      }
  }
}

// Whether the brief a subagent was spawned to run has already settled.
// Read second, and only when the reap mark says nothing, because it is
// the more expensive of the two facts and the cheaper one is decisive
// when it answers.
fn settled(state: State, cell: lineage.Lineage) -> Bool {
  api.await_strand_result(
    state.runtime,
    strand: cell.strand,
    operation: cell.brief,
    within_ms: 0,
  )
  |> result.is_ok
}

// Re-arms this machine's one named timeout for the soonest boundary any
// still-`Active` schedule needs.
//
// With nothing active there is normally nothing to wake for, so the name
// is *cancelled* and the machine goes quiet rather than ticking forever
// over nothing. Cancelling rather than simply arming nothing is what
// keeps rule 8 of `docs/weft.md` honest — the timer belongs to the
// machine and every path through a scan says what should now be armed
// under its one name — and it is also the only way to be rid of an
// arming already in flight: a superseded arming is dropped by the book's
// generation check, and `sm.cancel_timeout` puts a scan that wants no
// wake at all on that same footing.
//
// Going quiet is only right while the operator's list is the whole
// story. Once the model-facing door is open, a schedule can appear
// between any two scans, and a machine that had gone quiet would never
// find out. `poke` is what makes that prompt — the seam rings this
// machine the moment it writes a cell — and the floor below is what
// makes it *certain*, because a poke is an ordinary message and the one
// thing this machine must never do is stop scanning because a wake went
// missing. The floor costs one timer per `schedule.min_interval_s` and
// bounds the worst case to noticing a new schedule one interval late
// instead of never.
fn rearm(
  data: State,
  statuses: List(ScheduleStatus),
) -> sm.Next(Phase, State, Message) {
  let delays =
    list.filter_map(statuses, fn(status) {
      case status {
        Expired -> Error(Nil)
        Active(next_delay_ms:) -> Ok(next_delay_ms)
      }
    })
  case delays, data.options.model_door {
    [], DoorShut -> sm.keep(data) |> sm.cancel_timeout(name: scan_timer)
    [], DoorOpen -> arm(data, idle_rescan_ms())
    [first, ..rest], _door -> arm(data, list.fold(rest, first, int.min))
  }
}

// Arms one wake under `scan_timer`, clamped to what a BEAM timer can
// actually hold.
//
// The clamp survived the port because the injected source did not move
// where the delay ends up. `runtime/effects.real_timers` is
// `spawn_unlinked(sleep(delay); wake())`, `process.sleep` is a `receive
// after`, and a timeout above 2^32-1 ms raises `timeout_value` — on an
// *unlinked* process, so the chain dies silently and the scanner never
// ticks again. Nothing else bounds this: neither creation path caps an
// interval from above, and a one-shot `at` far enough out overflows on
// its own. Waking early costs one wasted scan, which re-derives the same
// answer and re-arms; waking never costs every schedule in the session.
fn arm(data: State, delay_ms: Int) -> sm.Next(Phase, State, Message) {
  sm.keep(data)
  |> sm.with_named_timeout(
    name: scan_timer,
    after: int.min(delay_ms, max_timer_delay_ms),
    sending: Tick,
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
/// A poke costs no extra chain, however many arrive. Every scan ends by
/// arming one named timeout, and arming a name replaces what was under
/// it — so a poke's own scan supersedes whichever arming was already
/// pending, and the wake for that arming dies in the timer book when it
/// rings. Before the machine owned the timer this had to be arranged by
/// hand, and a bare `Tick` from here leaked one permanent
/// self-perpetuating chain per model `schedule_create` or
/// `schedule_cancel`.
///
/// A poke that arrives while the machine is restarting is simply lost,
/// which is why `rearm` keeps a floor.
///
/// ## Examples
///
/// ```gleam
/// // schedulescan.poke(scanner_name)
/// ```
///
pub fn poke(name: address.Address(Message)) -> Nil {
  // Restart can lose this hint: the replacement immediately scans durable
  // cells. Resolving once prevents a second lookup from changing the receiver.
  let _sent = address.send(name, Rescan)
  Nil
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
  case read_prefix(state, prefix) {
    // A store read that fails is not worth stopping for: retry on the
    // schedule's own cadence, which is already bounded well above a
    // busy loop (`schedule.min_interval_s`).
    Error(Nil) -> Active(next_delay_ms: seconds * 1000)
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
  let occurrences = marked_occurrences(sched, marks)

  // The age half of expiry needs an instant these marks cannot supply,
  // so it comes from the schedule's own seen cell — claimed here if this
  // is the first tick that ever saw this schedule. It is read before the
  // expiry test because the test needs it, so a schedule that expires on
  // `max_fires` at the very first tick that sees it does leave one seen
  // cell behind: one row, and no further ticks to write another.
  let since_s = observed_since(state, sched, now_s)

  case schedule.recurring_expired(occurrences:, expiry:, now_s:, since_s:) {
    True -> Expired
    False -> {
      let occurrence = schedule.interval_occurrence(seconds:, now_s:)
      maybe_fire_interval(state, sched, occurrence, seconds, occurrences)
      Active(next_delay_ms: next_interval_delay_ms(occurrence, seconds, now_ms))
    }
  }
}

// The instant this schedule's `expires_after_s` window opened: the epoch
// second at which a running scanner first observed it, read off the
// store or — on that first observation — claimed here.
//
// One invariant carries the whole mechanism: **the cell is written at
// most once per `{strand, name}`, so every reader of it agrees on one
// instant** — this tick, every later tick, and every later incarnation
// alike. Two things enforce it. The write is an expect-absent
// compare-and-set, so a writer racing through the gap between this
// tick's read and its write loses instead of overwriting; and the loser
// then re-reads the winner's value rather than keeping the one it
// proposed, so the tick that lost the race agrees too. Nothing here ever
// writes the cell a second time, which is why an operator's schedule and
// a model's need no separate treatment: whichever store the schedule
// came from, its clock started when this scanner first saw it.
fn observed_since(state: State, sched: Schedule, now_s: Int) -> Int {
  let key = schedule.seen_key(strand: sched.target, name: sched.name)
  case read_fact(state, key) {
    Some(recorded) -> recorded_since(state, key, recorded, now_s)
    None -> claim_since(state, key, now_s)
  }
}

// A cell that is present but does not decode cannot have come from this
// scanner — the key is reserved, so nothing else may write it — and
// carries no honest instant to recover. It is read as an observation
// this tick failed to establish rather than overwritten with `now_s`: a
// schedule's life must not be re-based because one tick met a corrupt
// cell.
fn recorded_since(
  state: State,
  key: String,
  recorded: JsonValue,
  now_s: Int,
) -> Int {
  case schedule.decode_seen(recorded) {
    Ok(since_s) -> since_s
    Error(Nil) ->
      unrecorded(state, key, "the stored instant did not decode", now_s)
  }
}

// The first observation, claimed with an expect-absent compare-and-set
// rather than a blind write, so two incarnations ticking across the same
// gap cannot each record their own idea of when this schedule began.
fn claim_since(state: State, key: String, now_s: Int) -> Int {
  case
    api.put_reserved_fact_expecting(
      state.runtime,
      key,
      schedule.seen_value(since_s: now_s),
      expected: None,
    )
  {
    Ok(_seq) -> now_s
    Error(error) -> unclaimed_since(state, key, error, now_s)
  }
}

// Why a claim did not land, and what each answer means for this tick.
fn unclaimed_since(
  state: State,
  key: String,
  error: api.ApiError,
  now_s: Int,
) -> Int {
  case error {
    // Another incarnation claimed the cell in the gap between this
    // tick's read and its write. Its instant is the one every reader has
    // to agree on, so it is read back rather than assumed to equal the
    // `now_s` this tick proposed.
    api.FactConflict(..) -> reclaimed_since(state, key, now_s)

    api.RuntimeUnavailable
    | api.AcceptRejected(..)
    | api.QueueRejected(..)
    | api.ReadFailed(..)
    | api.CommitFailed(..)
    | api.SessionStolen(..)
    | api.RaceLost
    | api.ReservedFactKey(..)
    | api.UnreservedFactKey(..)
    | api.EscalationExists(..)
    | api.EscalationNotFound(..)
    | api.EscalationWrongStatus(..) ->
      unrecorded(state, key, string.inspect(error), now_s)
  }
}

// The instant the winner of a lost claim recorded. Read back, never
// inferred: the two ticks proposed different values and only the one that
// landed is this schedule's age.
fn reclaimed_since(state: State, key: String, now_s: Int) -> Int {
  case read_fact(state, key) {
    Some(recorded) -> recorded_since(state, key, recorded, now_s)
    None -> unrecorded(state, key, "the winning claim was not readable", now_s)
  }
}

// An observation this tick could neither read nor record. `now_s` stands
// in for this tick alone: nothing durable is written, nothing expires by
// age (`now_s - now_s` is zero and `expires_after_s` is at least one),
// and the next tick tries the claim again. A store fault must not
// shorten a schedule's life, and it must not silently lengthen one
// either — hence a warning rather than silence, because a cell that
// never lands is an age bound that never arrives.
fn unrecorded(state: State, key: String, reason: String, now_s: Int) -> Int {
  log.warn(state.options.logger, "schedule.seen_unrecorded", [
    field.text(key: "key", value: key),
    field.text(key: "reason", value: reason),
  ])
  now_s
}

// The current slot's occurrence, fired if its mark is still absent. The
// absence check reads `occurrences` — the same prefix scan
// `interval_with_marks` already paid for this tick — rather than a
// second point read: nothing can have changed it since, this machine being
// the only writer of its own tick. A held or failed attempt is not
// specially retried mid-slot: the next tick this schedule gets is the
// next slot boundary, at which point a *new* occurrence is due — which is
// the same "never iterate backward over skipped slots" property that
// makes a missed window cost at most one late fire rather than one
// attempt is a debt carried forward.
fn maybe_fire_interval(
  state: State,
  sched: Schedule,
  occurrence: Int,
  seconds: Int,
  occurrences: List(Int),
) -> Nil {
  use <- bool.guard(when: list.contains(occurrences, occurrence), return: Nil)
  let key =
    schedule.fired_key(strand: sched.target, name: sched.name, occurrence:)
  let late = schedule.interval_late(occurrences:, seconds:, occurrence:)
  let _verdict = fire(state, sched, key, late:)
  Nil
}

// The epoch second the *next* slot begins at — the boundary a fire
// occurring now is judged `late` against, and the instant re-arming
// waits for.
fn next_interval_delay_ms(occurrence: Int, seconds: Int, now_ms: Int) -> Int {
  let boundary_ms = { occurrence + seconds } * 1000
  int.max(boundary_ms - now_ms, 1000)
}

// --- cron schedules ------------------------------------------------------
//
// The same three steps `process_interval` takes — read the marks, settle
// the observation instant, test expiry — over arithmetic that searches a
// calendar instead of dividing. Everything cron-specific about that
// arithmetic is in `client/schedule`, so this half stays a scanner: it
// reads the store, asks, and arms.

// The clock a cron schedule's fields are read against: the expression
// itself, and the fixed offset from UTC that shifts every instant the
// search works in.
//
// A pair rather than two arguments threaded side by side through five
// functions, because they are never apart — every one of
// `client/schedule`'s cron answers takes both — and a signature carrying
// one without the other is a signature that can be called wrong by
// forgetting the offset, which reads as a schedule firing at the wrong
// hour rather than as a type error.
type CronClock {
  CronClock(expression: cron.Expression, offset_s: Int)
}

fn process_cron(
  state: State,
  sched: Schedule,
  cron_clock: CronClock,
  expiry: schedule.Expiry,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  let prefix = schedule.fired_key_prefix(strand: sched.target, name: sched.name)
  case read_prefix(state, prefix) {
    // A store read that fails is retried on the rescan floor rather than
    // on the schedule's own cadence: unlike an interval there is no
    // configured period to fall back on, and the floor is the same
    // bound-well-above-a-busy-loop this machine already uses when it has
    // nothing else to go on.
    Error(Nil) -> Active(next_delay_ms: idle_rescan_ms())

    Ok(marks) ->
      cron_with_marks(state, sched, cron_clock, expiry, now_ms, now_s, marks)
  }
}

fn cron_with_marks(
  state: State,
  sched: Schedule,
  cron_clock: CronClock,
  expiry: schedule.Expiry,
  now_ms: Int,
  now_s: Int,
  marks: List(#(String, JsonValue)),
) -> ScheduleStatus {
  let occurrences = marked_occurrences(sched, marks)

  // Read before the expiry test for the same reason the interval path
  // reads it there: the age bound needs the instant, and the `since_s`
  // rule below needs it too — a cron schedule's very first tick is
  // exactly the tick that claims this cell, and the occurrence it owes
  // is decided against the value that claim settled on.
  let since_s = observed_since(state, sched, now_s)

  case schedule.recurring_expired(occurrences:, expiry:, now_s:, since_s:) {
    True -> Expired

    False -> {
      maybe_fire_cron(state, sched, cron_clock, occurrences, since_s, now_s)
      cron_rearm(state, sched, cron_clock, now_ms, now_s)
    }
  }
}

// The due occurrence, fired if it is owed and its mark is still absent.
//
// "At most one late fire" holds here by construction and not by a
// separate check: `schedule.cron_occurrence` answers with the single
// last match at or before now, so a scanner resuming after a week of
// downtime fires that one occurrence and never walks the matches it
// slept through. `None` — nothing owed, because the last match predates
// the schedule's own observation instant — is the ordinary state of a
// freshly created schedule and not an error.
fn maybe_fire_cron(
  state: State,
  sched: Schedule,
  cron_clock: CronClock,
  occurrences: List(Int),
  since_s: Int,
  now_s: Int,
) -> Nil {
  let CronClock(expression:, offset_s:) = cron_clock
  case schedule.cron_occurrence(expression:, offset_s:, now_s:, since_s:) {
    None -> Nil

    Some(occurrence) ->
      fire_cron_occurrence(
        state,
        sched,
        cron_clock,
        occurrences,
        since_s,
        occurrence,
      )
  }
}

fn fire_cron_occurrence(
  state: State,
  sched: Schedule,
  cron_clock: CronClock,
  occurrences: List(Int),
  since_s: Int,
  occurrence: Int,
) -> Nil {
  use <- bool.guard(when: list.contains(occurrences, occurrence), return: Nil)
  let CronClock(expression:, offset_s:) = cron_clock

  // `occurrence` is a UTC epoch second — `cron_occurrence` shifted it
  // back — so the mark key is the same shape a schedule with no offset
  // writes, and an offset changed later renames no existing mark.
  let key =
    schedule.fired_key(strand: sched.target, name: sched.name, occurrence:)
  let late =
    schedule.cron_late(
      expression:,
      offset_s:,
      occurrences:,
      occurrence:,
      since_s:,
    )
  let _verdict = fire(state, sched, key, late:)
  Nil
}

// The wait until the next match, or the end of the schedule.
//
// An expression can legally name a date that never comes — `0 0 30 2 *`
// is the standing example — and a search that finds nothing within
// `cron.search_horizon_days` means exactly that. Such a schedule is
// `Expired`: it re-arms nothing and stops costing a tick, which is the
// honest answer and the only one that does not leave the machine waking up
// forever over an expression that will never match. It is logged because
// an operator who wrote that expression meant something else.
fn cron_rearm(
  state: State,
  sched: Schedule,
  cron_clock: CronClock,
  now_ms: Int,
  now_s: Int,
) -> ScheduleStatus {
  let CronClock(expression:, offset_s:) = cron_clock
  case schedule.cron_next_delay_ms(expression:, offset_s:, now_s:, now_ms:) {
    Some(next_delay_ms) -> Active(next_delay_ms:)

    None -> {
      log.warn(state.options.logger, "schedule.cron_never_matches", [
        field.text(key: "schedule", value: sched.name),
        field.text(key: "strand", value: sched.target),
        field.text(key: "expression", value: cron.source(expression)),
        field.text(key: "offset", value: schedule.render_utc_offset(offset_s)),
      ])
      Expired
    }
  }
}

// The occurrence numbers under one schedule's fired-mark prefix.
//
// Shared by both recurring paths because both ask the same two questions
// of it — how many fires have been spent, and whether one particular
// occurrence is among them — and a second copy of the key-suffix parse
// would be a second place for the prefix length to be got wrong.
fn marked_occurrences(
  sched: Schedule,
  marks: List(#(String, JsonValue)),
) -> List(Int) {
  let prefix = schedule.fired_key_prefix(strand: sched.target, name: sched.name)
  list.filter_map(marks, fn(pair) {
    let #(key, _value) = pair
    key |> string.drop_start(string.length(prefix)) |> int.parse
  })
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
  case read_fact(state, key) {
    // Fired forever: a one-shot's occurrence count is 1 by construction,
    // and its mark existing is the whole of that fact.
    Some(_already_fired) -> Expired
    None -> due_one_shot(state, sched, key, at, now_ms, now_s)
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

// A one-shot is the only schedule whose lateness a wall clock decides.
// Its single occurrence is `at` itself, so there is no preceding slot
// whose missing mark could stand in for the window having closed the way
// `schedule.interval_late` reads one. The grace period is what keeps
// ordinary scheduling jitter from reading to the model as a catch-up
// fire it is not.
fn one_shot_lateness(at at: Int, now_s now_s: Int) -> schedule.Lateness {
  case now_s >= at + late_grace_s {
    True -> schedule.Late
    False -> schedule.OnTime
  }
}

// Not yet due: re-arm at the real remaining wait, clamped. Due: fire, and
// stop re-arming for good the moment the mark actually lands (`Fired` or
// `AlreadyFired`) — a one-shot never re-arms once its single occurrence
// is spent. A held or failed attempt (no open run yet, say) retries no
// sooner than `held_or_failed_retry_ms`, never at the tight cadence a
// genuinely not-yet-due wait uses.
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
      case fire(state, sched, key, late: one_shot_lateness(at:, now_s:)) {
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

fn fire(
  state: State,
  sched: Schedule,
  key: String,
  late late: schedule.Lateness,
) -> Fire {
  let mark = api.Mark(key:, value: schedule.fired_value(sched))
  let text = injected_message(state, sched, late)
  let verdict = case sched.wake {
    schedule.SteersOnly -> {
      let target = api.on_strand(state.runtime, sched.target)
      classify_steer(api.steer_marking(target, text, mark:))
    }

    schedule.WakesIdle ->
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
  late: schedule.Lateness,
) -> message.AgentMessage {
  let #(now, _clock) = clock.read(state.runtime.effects.clock)
  message.UserMessage(
    content: [
      message.UserText(
        text: schedule.injection(sched, late, schedule.origin_of(sched)),
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
    api.QueueRejected(..) | api.RuntimeUnavailable -> Held
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
//
// `observed_since` reads through this same door and the argument holds
// there for the same reason: a fault read as absence proposes a claim,
// the claim's own expect-absent CAS refuses it if the cell really
// exists (`FactConflict`, whose handler re-reads), and a store faulting
// on both leaves the tick measuring age from `now_s` — which expires
// nothing and writes nothing.
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
