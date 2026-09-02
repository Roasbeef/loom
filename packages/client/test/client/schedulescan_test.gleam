//// The scheduled-heartbeat scanner against a real runtime, driven by a
//// deterministic fake timer wheel rather than the wall clock.
////
//// Mirrors `test/client/rulescan_test.gleam`'s posture — a real runtime,
//// a real writer, a real supervised scanner, only the effect surface
//// scripted — but the seam under test here is
//// `runtime/effects.Timers`, not the writer's post-commit hint. The fake
//// clock below is restated from
//// `conformance/simulation/vclock.Clockwork` rather than imported:
//// `client` cannot depend on `conformance` (the dependency runs the
//// other way), and this test needs a much smaller slice of it — a
//// single timer wheel one process advances by hand, no soft-realtime
//// harness around it.
////
//// The provider never settles (`hanging_provider`): every test cares
//// about durable admission — did a fired-mark land, did a run open — not
//// about a turn completing, so a request that never resolves keeps a
//// strand's run open indefinitely without a scripted answer to maintain.

import client/cron
import client/schedule
import client/schedulescan
import core/clock.{type Clock}
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import runtime/lineage
import session/session

// --- a tiny deterministic timer wheel ---------------------------------------
//
// Restated from `conformance/simulation/vclock.Clockwork` (see the module
// doc). `advance` pops and runs the single earliest-deadline wake; `jump`
// moves logical time forward directly, without requiring a deadline to
// exist there yet — the shape "the process was not running for a while"
// needs, since nothing else in a real timer wheel can jump the clock
// itself.

type Deadline {
  Deadline(at: Int, wake: fn() -> Nil)
}

type ClockMessage {
  ReadNow(reply: Subject(Int))
  ScheduleAt(delay_ms: Int, wake: fn() -> Nil)
  TakeEarliest(reply: Subject(Option(fn() -> Nil)))
  JumpTo(now: Int)
  PendingCount(reply: Subject(Int))
  EarliestAt(reply: Subject(Option(Int)))
}

type ClockState {
  ClockState(now: Int, deadlines: List(Deadline))
}

type FakeClock {
  FakeClock(subject: Subject(ClockMessage))
}

fn start_fake_clock(from now: Int) -> FakeClock {
  let assert Ok(started) =
    actor.new(ClockState(now:, deadlines: []))
    |> actor.on_message(handle_clock_message)
    |> actor.start
    as "the fake clock must start"
  FakeClock(subject: started.data)
}

fn handle_clock_message(
  state: ClockState,
  message: ClockMessage,
) -> actor.Next(ClockState, ClockMessage) {
  case message {
    ReadNow(reply:) -> {
      process.send(reply, state.now)
      actor.continue(state)
    }
    ScheduleAt(delay_ms:, wake:) -> {
      let at = state.now + int.max(delay_ms, 0)
      actor.continue(
        ClockState(..state, deadlines: [Deadline(at:, wake:), ..state.deadlines]),
      )
    }
    TakeEarliest(reply:) ->
      case earliest_deadline(state.deadlines) {
        None -> {
          process.send(reply, None)
          actor.continue(state)
        }
        Some(due) -> {
          process.send(reply, Some(due.wake))
          actor.continue(ClockState(
            now: int.max(state.now, due.at),
            deadlines: drop_deadline(state.deadlines, due.at),
          ))
        }
      }
    JumpTo(now:) ->
      actor.continue(ClockState(..state, now: int.max(state.now, now)))
    PendingCount(reply:) -> {
      process.send(reply, list.length(state.deadlines))
      actor.continue(state)
    }
    EarliestAt(reply:) -> {
      process.send(
        reply,
        option.map(earliest_deadline(state.deadlines), fn(due) { due.at }),
      )
      actor.continue(state)
    }
  }
}

fn earliest_deadline(deadlines: List(Deadline)) -> Option(Deadline) {
  list.fold(deadlines, None, fn(best: Option(Deadline), candidate: Deadline) {
    case best {
      None -> Some(candidate)
      Some(current) ->
        case current.at <= candidate.at {
          True -> best
          False -> Some(candidate)
        }
    }
  })
}

fn drop_deadline(deadlines: List(Deadline), at: Int) -> List(Deadline) {
  case deadlines {
    [] -> []
    [first, ..rest] ->
      case first.at == at {
        True -> rest
        False -> [first, ..drop_deadline(rest, at)]
      }
  }
}

fn fake_now(fc: FakeClock) -> Int {
  process.call(fc.subject, waiting: 1000, sending: ReadNow)
}

fn fake_clock(fc: FakeClock) -> Clock {
  clock.from_function(fn() { fake_now(fc) })
}

fn fake_timers(fc: FakeClock) -> effects.Timers {
  effects.Timers(after: fn(delay_ms, wake) {
    process.send(fc.subject, ScheduleAt(delay_ms:, wake:))
  })
}

// Pops and runs the single earliest-deadline wake, reporting whether
// there was one. Runs in the caller's process: schedulescan's own wake is
// just `process.send(self, Tick)`, so calling it here does not block —
// the real work happens asynchronously on the scanner's own actor.
fn fake_advance(fc: FakeClock) -> Bool {
  case process.call(fc.subject, waiting: 1000, sending: TakeEarliest) {
    None -> False
    Some(wake) -> {
      wake()
      True
    }
  }
}

// Moves logical time forward directly, modelling "the server was not
// running for a while": the one thing a real timer wheel cannot do to
// itself, and exactly what a resumed process's next tick has to cope
// with.
fn fake_jump_to(fc: FakeClock, now: Int) -> Nil {
  process.send(fc.subject, JumpTo(now:))
}

fn fake_pending(fc: FakeClock) -> Int {
  process.call(fc.subject, waiting: 1000, sending: PendingCount)
}

// The delay, in ms from `now`, of the earliest pending deadline — a peek,
// consuming nothing. `None` when nothing is pending.
fn fake_earliest_delay_ms(fc: FakeClock) -> Option(Int) {
  case process.call(fc.subject, waiting: 1000, sending: EarliestAt) {
    None -> None
    Some(at) -> Some(at - fake_now(fc))
  }
}

// --- polling ----------------------------------------------------------------

// Tick handling is asynchronous on the scanner's own process, so every
// assertion on its durable effect polls rather than assuming the send in
// `fake_advance`/a direct `Tick` has already been processed.
fn await_true(check: fn() -> Bool, remaining_ms: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case remaining_ms <= 0 {
        True -> False
        False -> {
          process.sleep(5)
          await_true(check, remaining_ms - 5)
        }
      }
  }
}

fn await_named(name: Name(schedulescan.Message), remaining_ms: Int) -> Nil {
  case process.named(name), remaining_ms <= 0 {
    Ok(_pid), _ | _, True -> Nil
    Error(Nil), False -> {
      process.sleep(5)
      await_named(name, remaining_ms - 5)
    }
  }
}

// --- the rig -----------------------------------------------------------

type Rig {
  Rig(
    runtime: api.Runtime,
    session: session.Session,
    fc: FakeClock,
    scanner: Name(schedulescan.Message),
    services: process.Pid,
  )
}

fn harness(
  schedules: List(schedule.Schedule),
  from_ms: Int,
) -> Result(Rig, String) {
  let fc = start_fake_clock(from: from_ms)
  use opened <- result.try(
    session.open_memory(fake_clock(fc))
    |> result.replace_error("the memory session did not open"),
  )
  use entropy <- result.try(start_entropy())
  let effects_record =
    effects.Effects(
      clock: fake_clock(fc),
      entropy:,
      timers: fake_timers(fc),
      provider: hanging_provider(),
      tools: refusing_tools(),
      hooks: effects.default_hooks(),
    )
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  let options = api.default_options(configuration)
  use runtime <- result.try(
    api.open(
      opened,
      effects_record,
      // Far larger than any interval this file uses, so the strand
      // driver's own checkpoint poll never becomes the earliest pending
      // deadline and never interferes with `fake_advance`.
      api.Options(..options, poll_interval_ms: 1_000_000_000),
    )
    |> result.map_error(string.inspect),
  )
  let scanner = process.new_name(prefix: "loom_schedulescan_test")
  use services <- result.try(
    sup.new(sup.OneForOne)
    |> sup.add(schedulescan.supervised(
      schedulescan.default_options(schedules),
      runtime,
      scanner,
    ))
    |> sup.start
    |> result.replace_error("the scanner supervisor did not start"),
  )
  process.unlink(services.pid)
  await_named(scanner, 2000)
  Ok(Rig(runtime:, session: opened, fc:, scanner:, services: services.pid))
}

fn stop(rig: Rig) -> Nil {
  process.kill(rig.services)
  process.kill(rig.runtime.tree.supervisor)
}

// Sends the scanner's mailbox message directly, simulating a spurious
// extra wake with no logical time having passed — exactly the case
// `runtime/effects.Timers`'s own doc says must be harmless. `Rescan` is
// what `poke` sends, and is the shape an out-of-band wake actually takes.
fn replay_tick(rig: Rig) -> Nil {
  process.send(process.named_subject(rig.scanner), schedulescan.Rescan)
}

// A wake tagged with a generation the actor has already moved past — the
// shape a superseded timer chain delivers.
fn stale_tick(rig: Rig, generation: Int) -> Nil {
  process.send(
    process.named_subject(rig.scanner),
    schedulescan.Tick(generation:),
  )
}

// A provider whose every request parks forever: the returned handle
// carries a subject nothing ever sends a terminal on, so a run this
// opens stays open for as long as the test needs one to steer onto.
// `immediate` rather than `owned` because the fixture spawns nothing —
// the hang is the absence of a producer, not a producer that is slow —
// so cancellation has no process, port, or socket to tear down.
fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "no tools in this harness")
    },
    run: fn(_run) { effects.ToolFailed(reason: "no tools in this harness") },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

fn start_entropy() -> Result(fn() -> Int, String) {
  actor.new(1)
  |> actor.on_message(fn(next, reply: Subject(Int)) {
    process.send(reply, next)
    actor.continue(next + 1)
  })
  |> actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// --- durable observation -----------------------------------------------

fn fired(runtime: api.Runtime, key: String) -> Bool {
  case api.fact(runtime, key) {
    Ok(Some(_value)) -> True
    Ok(None) | Error(_reason) -> False
  }
}

fn fired_count(runtime: api.Runtime, prefix: String) -> Int {
  case api.reserved_facts(runtime, prefix:) {
    Ok(marks) -> list.length(marks)
    Error(_reason) -> -1
  }
}

// The instant recorded for a schedule on `main`, as the store holds it —
// the cell `client/schedule.seen_key` names, read through the same door
// the fired-marks are read through. `None` covers both "never recorded"
// and an unreadable store, which no assertion here needs to tell apart.
fn seen(runtime: api.Runtime, name: String) -> Option(JsonValue) {
  case api.fact(runtime, schedule.seen_key(strand: "main", name:)) {
    Ok(cell) -> cell
    Error(_reason) -> None
  }
}

fn idle(rig: Rig, strand: String) -> Bool {
  case session.strand_state(rig.session, strand) {
    Ok(Some(session.Cell(value: state, ..))) -> state.current_operation == None
    Ok(None) | Error(_reason) -> False
  }
}

// --- fixtures ------------------------------------------------------------

fn interval_schedule(
  name name: String,
  seconds seconds: Int,
  wake wake: schedule.Wake,
) -> schedule.Schedule {
  schedule.Schedule(
    name:,
    target: "main",
    owner: schedule.OperatorOwned,
    timing: schedule.Interval(
      seconds:,
      expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
    ),
    wake:,
    body: "heartbeat",
  )
}

// An interval schedule whose age bound is short enough for a test to
// step over, and whose fire-count bound is deliberately not the one under
// test. `SteersOnly` on an idle strand is the shape issue #157 was about:
// every fire holds, so no mark ever lands to date the schedule by.
fn aging_schedule(
  name name: String,
  seconds seconds: Int,
  expires_after_s expires_after_s: Int,
) -> schedule.Schedule {
  schedule.Schedule(
    name:,
    target: "main",
    owner: schedule.OperatorOwned,
    timing: schedule.Interval(
      seconds:,
      expiry: schedule.Expiry(max_fires: 1000, expires_after_s:),
    ),
    wake: schedule.SteersOnly,
    body: "heartbeat",
  )
}

// A cron schedule whose expiry's fire-count bound is the one under test
// and whose window is not: seven days is longer than any jump this file
// makes, so nothing here expires by age.
fn cron_schedule(
  name name: String,
  expression expression: String,
  wake wake: schedule.Wake,
  max_fires max_fires: Int,
) -> schedule.Schedule {
  let assert Ok(parsed) = cron.parse(expression)
    as "the fixture's cron expression must parse"
  schedule.Schedule(
    name:,
    target: "main",
    owner: schedule.OperatorOwned,
    timing: schedule.Cron(
      expression: parsed,
      expiry: schedule.Expiry(max_fires:, expires_after_s: 604_800),
    ),
    wake:,
    body: "heartbeat",
  )
}

fn one_shot_schedule(name name: String, at at: Int) -> schedule.Schedule {
  schedule.Schedule(
    name:,
    target: "main",
    owner: schedule.OperatorOwned,
    timing: schedule.OneShot(at:),
    wake: schedule.WakesIdle,
    body: "reminder",
  )
}

// --- 1. wake = false: steers an open run, holds on an idle strand ----------

pub fn a_wake_false_schedule_steers_an_already_open_run_test() {
  let sched =
    interval_schedule(name: "hb", seconds: 60, wake: schedule.SteersOnly)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  let assert Ok(_op) = api.prompt(rig.runtime, [user("hello")])
    as "the prompt must open a run on main"
  let key = schedule.fired_key(strand: "main", name: "hb", occurrence: 0)
  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { fired(rig.runtime, key) }, 2000)
    as "the due occurrence must fire onto the open run"
  assert !idle(rig, "main")
    as "the run must still be open — a steer, not a fresh start"
  assert fired_count(rig.runtime, "schedule/fired/main/hb/") == 1
  // A duplicate wake with no time having passed must not fire twice.
  replay_tick(rig)
  process.sleep(50)
  assert fired_count(rig.runtime, "schedule/fired/main/hb/") == 1
    as "a repeated tick for the same slot must not fire a second time"
  stop(rig)
}

pub fn a_wake_false_schedule_holds_on_an_idle_strand_test() {
  let sched =
    interval_schedule(name: "hb", seconds: 60, wake: schedule.SteersOnly)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  let key = schedule.fired_key(strand: "main", name: "hb", occurrence: 0)
  assert fake_advance(rig.fc) as "the first tick must be pending"
  // Nothing to poll into being: give the (non-)event a moment, then
  // assert its absence directly.
  process.sleep(100)
  assert !fired(rig.runtime, key)
    as "a held fire on an idle strand must leave no mark"
  assert idle(rig, "main") as "the strand must not have been woken"
  stop(rig)
}

// --- 2. wake = true: starts a fresh run on an idle strand, exactly once ----

pub fn a_wake_true_schedule_starts_a_fresh_run_exactly_once_test() {
  let sched =
    interval_schedule(name: "wk", seconds: 60, wake: schedule.WakesIdle)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  assert idle(rig, "main") as "the strand must start idle"
  let key = schedule.fired_key(strand: "main", name: "wk", occurrence: 0)
  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { fired(rig.runtime, key) }, 2000)
    as "the due occurrence must start a fresh run"
  assert !idle(rig, "main") as "the fresh run must now be open"
  assert fired_count(rig.runtime, "schedule/fired/main/wk/") == 1
  // A repeated tick before the next slot boundary must do nothing further.
  replay_tick(rig)
  process.sleep(50)
  assert fired_count(rig.runtime, "schedule/fired/main/wk/") == 1
    as "a repeated tick for the same slot must not start a second run"
  stop(rig)
}

// --- 3. one-shot: fires exactly once at or after `at`, never re-arms ------

pub fn a_one_shot_fires_once_and_never_rearms_test() {
  let sched = one_shot_schedule(name: "once", at: 100)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  let key = schedule.fired_key(strand: "main", name: "once", occurrence: 100)
  // The first tick (t=0) is well before `at` (t=100s): it must not fire.
  assert fake_advance(rig.fc) as "the first tick must be pending"
  process.sleep(100)
  assert !fired(rig.runtime, key) as "a one-shot must not fire before its time"
  // The re-armed tick lands exactly on `at`.
  assert fake_advance(rig.fc) as "the re-armed tick must be pending"
  assert await_true(fn() { fired(rig.runtime, key) }, 2000)
    as "the one-shot must fire once its instant arrives"
  assert fake_now(rig.fc) == 100_000
  // Once fired, the schedule itself leaves nothing behind: the one
  // deadline still in the wheel is the strand driver's own checkpoint
  // poll (parked far in the future by `harness`, never touched), not a
  // re-arm from the schedule.
  assert await_true(fn() { fake_pending(rig.fc) == 1 }, 2000)
    as "a fired one-shot must never re-arm"
  stop(rig)
}

// A `wake = false` one-shot naming a permanently idle strand is `Held`
// on every attempt, forever — it has no expiry to end that. Left at its
// naive floor this would poll once a second for the life of the session;
// the retry must never go faster than the same busy-loop floor
// `client/schedule` enforces on every `every` schedule.
pub fn a_held_one_shot_retries_no_faster_than_the_interval_floor_test() {
  let sched =
    schedule.Schedule(
      name: "stuck",
      target: "main",
      owner: schedule.OperatorOwned,
      timing: schedule.OneShot(at: 100),
      wake: schedule.SteersOnly,
      body: "reminder",
    )
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  assert idle(rig, "main") as "the strand must start idle"
  // First tick (t=0): not yet due, re-arms at the real remaining wait.
  assert fake_advance(rig.fc) as "the first tick must be pending"
  // The re-armed tick lands at or after `at`; the strand is still idle and
  // wake=false may not start a run, so this occurrence holds.
  assert fake_advance(rig.fc) as "the re-armed tick must be pending"
  let key = schedule.fired_key(strand: "main", name: "stuck", occurrence: 100)
  process.sleep(100)
  assert !fired(rig.runtime, key) as "a held one-shot must leave no mark"
  assert await_true(
    fn() {
      case fake_earliest_delay_ms(rig.fc) {
        Some(delay) -> delay >= schedule.min_interval_s * 1000
        None -> False
      }
    },
    2000,
  )
    as "a held or failed one-shot must retry no faster than the interval floor"
  stop(rig)
}

// --- 4. a skipped window still produces exactly one, late, fire -----------

pub fn a_skipped_window_produces_exactly_one_late_fire_test() {
  let sched =
    interval_schedule(name: "hb", seconds: 60, wake: schedule.SteersOnly)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  let assert Ok(_op) = api.prompt(rig.runtime, [user("hello")])
    as "the prompt must open a run on main"
  let first_key = schedule.fired_key(strand: "main", name: "hb", occurrence: 0)
  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { fired(rig.runtime, first_key) }, 2000)
    as "the first occurrence must fire"
  // Simulate the process not running across several slot boundaries: jump
  // logical time forward by more than one interval before the re-armed
  // tick is ever allowed to run.
  fake_jump_to(rig.fc, 250_000)
  assert fake_advance(rig.fc) as "the resumed tick must be pending"
  let skipped_key =
    schedule.fired_key(strand: "main", name: "hb", occurrence: 60)
  let current_key =
    schedule.fired_key(strand: "main", name: "hb", occurrence: 240)
  assert await_true(fn() { fired(rig.runtime, current_key) }, 2000)
    as "the resumed tick must fire the *current* slot, not a skipped one"
  assert !fired(rig.runtime, skipped_key)
    as "an intermediate skipped slot must never fire"
  assert fired_count(rig.runtime, "schedule/fired/main/hb/") == 2
    as "at most one late fire, not a replay of the whole backlog"
  stop(rig)
}

// --- 5. an expired schedule stops firing and stops re-arming ---------------

pub fn an_expired_schedule_stops_firing_and_stops_rearming_test() {
  let sched =
    schedule.Schedule(
      name: "capped",
      target: "main",
      owner: schedule.OperatorOwned,
      timing: schedule.Interval(
        seconds: 60,
        expiry: schedule.Expiry(max_fires: 1, expires_after_s: 604_800),
      ),
      wake: schedule.WakesIdle,
      body: "heartbeat",
    )
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  let first_key =
    schedule.fired_key(strand: "main", name: "capped", occurrence: 0)
  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { fired(rig.runtime, first_key) }, 2000)
    as "the first occurrence must fire, spending max_fires"
  // The re-armed tick sees the cap already reached and must not fire the
  // next slot at all.
  assert fake_advance(rig.fc) as "the re-armed tick must be pending"
  process.sleep(100)
  let next_key =
    schedule.fired_key(strand: "main", name: "capped", occurrence: 60)
  assert !fired(rig.runtime, next_key)
    as "an expired schedule must not fire again"
  assert fired_count(rig.runtime, "schedule/fired/main/capped/") == 1
  // The one deadline left in the wheel is the strand driver's own
  // checkpoint poll (see the comment in the one-shot test above), not a
  // re-arm from the now-expired schedule.
  assert await_true(fn() { fake_pending(rig.fc) == 1 }, 2000)
    as "an expired schedule must stop contributing to the re-arm"
  stop(rig)
}

// --- 7. cron: the first fire is the first match after it was observed -----
//
// Every instant below is UTC, from the first week of September 2026:
//
//   2026-09-02T09:00:00Z (Wed) = 1788339600
//   2026-09-02T15:00:00Z (Wed) = 1788361200
//   2026-09-03T09:00:00Z (Thu) = 1788426000
//   2026-09-04T09:00:00Z (Fri) = 1788512400
//   2026-09-05T09:00:00Z (Sat) = 1788598800
//   2026-09-06T09:00:00Z (Sun) = 1788685200
//   2026-09-06T10:00:00Z (Sun) = 1788688800

const wednesday_at_three_pm_ms = 1_788_361_200_000

const wednesday_at_nine_ms = 1_788_339_600_000

const sunday_at_ten_s = 1_788_688_800

// A daily heartbeat created in the afternoon must not fire this
// morning's occurrence — it was never asked for — and must arm for
// tomorrow's rather than for a slot boundary nobody chose. This is the
// whole difference from `Interval`, which fires the slot it is created
// inside.
pub fn a_daily_cron_does_not_fire_at_creation_and_arms_for_tomorrow_test() {
  let sched =
    cron_schedule(
      name: "standup",
      expression: "0 9 * * *",
      wake: schedule.WakesIdle,
      max_fires: 1000,
    )
  let assert Ok(rig) = harness([sched], wednesday_at_three_pm_ms)
    as "the harness must boot"

  // The first tick: nothing due, because 09:00 this morning passed
  // before the scanner had ever seen this schedule.
  assert fake_advance(rig.fc) as "the first tick must be pending"
  process.sleep(150)
  assert fired_count(rig.runtime, "schedule/fired/main/standup/") == 0
    as "a cron schedule must not fire an occurrence that predates it"
  assert idle(rig, "main") as "the strand must not have been woken"

  // It armed for 09:00 tomorrow: eighteen hours from 15:00.
  assert fake_earliest_delay_ms(rig.fc) == Some(64_800_000)
    as "the re-arm must wait for the next match, not for a grid boundary"

  // Tomorrow's occurrence fires, exactly once.
  assert fake_advance(rig.fc) as "the re-armed tick must be pending"
  let thursday =
    schedule.fired_key(
      strand: "main",
      name: "standup",
      occurrence: 1_788_426_000,
    )
  assert await_true(fn() { fired(rig.runtime, thursday) }, 2000)
    as "the first match after the schedule was observed must fire"
  assert fired_count(rig.runtime, "schedule/fired/main/standup/") == 1

  // And it is not annotated late: the occurrence before it — 09:00 the
  // day the schedule was created — predates the observation instant, so
  // it was never due and nothing was missed.
  assert !string.contains(injected_text(rig, "main"), "(late)")
    as "a cron schedule's first fire must not read as a catch-up"

  // And re-armed a day out, for the match after that.
  assert await_true(
    fn() { fake_earliest_delay_ms(rig.fc) == Some(86_400_000) },
    2000,
  )
    as "a daily cron must re-arm twenty-four hours later"
  stop(rig)
}

// A window the server slept through costs exactly one catch-up fire, the
// same property `interval_schedule` has, reached a different way: the
// due occurrence is the single last match at or before now, so the
// matches in between are never even looked at. The `(late)` marker is on
// the injection's first line, which is all a collapsed client shows.
pub fn a_cron_jump_past_three_occurrences_fires_one_late_test() {
  let sched =
    cron_schedule(
      name: "standup",
      expression: "0 9 * * *",
      wake: schedule.WakesIdle,
      max_fires: 1000,
    )
  let assert Ok(rig) = harness([sched], wednesday_at_three_pm_ms)
    as "the harness must boot"
  assert fake_advance(rig.fc) as "the first tick must be pending"
  process.sleep(150)

  // Sunday morning: Thursday, Friday and Saturday's 09:00 have all gone
  // by unobserved, and Sunday's is the one that is due.
  fake_jump_to(rig.fc, sunday_at_ten_s * 1000)
  assert fake_advance(rig.fc) as "the resumed tick must be pending"

  let sunday =
    schedule.fired_key(
      strand: "main",
      name: "standup",
      occurrence: 1_788_685_200,
    )
  assert await_true(fn() { fired(rig.runtime, sunday) }, 2000)
    as "the resumed tick must fire the last match at or before now"
  assert !fired(
    rig.runtime,
    schedule.fired_key(
      strand: "main",
      name: "standup",
      occurrence: 1_788_426_000,
    ),
  )
    as "a skipped match must never fire"
  assert !fired(
    rig.runtime,
    schedule.fired_key(
      strand: "main",
      name: "standup",
      occurrence: 1_788_598_800,
    ),
  )
    as "nor the one immediately before the due occurrence"
  assert fired_count(rig.runtime, "schedule/fired/main/standup/") == 1
    as "at most one late fire, not a replay of the whole backlog"

  let text = injected_text(rig, "main")
  assert string.contains(text, "(late)")
    as "the catch-up fire must say so on its first line"
  assert string.contains(text, "scheduled window for this occurrence has")
  stop(rig)
}

// `max_fires` ends a cron schedule exactly as it ends an interval one:
// both carry the same `Expiry`, and `schedule.recurring_expired` is the
// one predicate either goes through.
pub fn a_capped_cron_expires_after_its_one_fire_test() {
  let sched =
    cron_schedule(
      name: "capped",
      expression: "0 9 * * *",
      wake: schedule.WakesIdle,
      max_fires: 1,
    )

  // Created exactly on a match, so the very first tick has something
  // due: the observation instant and the occurrence coincide, and the
  // `>= since_s` rule admits the boundary.
  let assert Ok(rig) = harness([sched], wednesday_at_nine_ms)
    as "the harness must boot"
  let first =
    schedule.fired_key(
      strand: "main",
      name: "capped",
      occurrence: 1_788_339_600,
    )
  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { fired(rig.runtime, first) }, 2000)
    as "an occurrence landing on the observation instant must fire"
  assert fired_count(rig.runtime, "schedule/fired/main/capped/") == 1

  // The next tick finds the cap already spent: no fire, and no re-arm.
  assert fake_advance(rig.fc) as "the re-armed tick must be pending"
  process.sleep(150)
  assert !fired(
    rig.runtime,
    schedule.fired_key(
      strand: "main",
      name: "capped",
      occurrence: 1_788_426_000,
    ),
  )
    as "an expired cron schedule must not fire again"
  assert fired_count(rig.runtime, "schedule/fired/main/capped/") == 1

  // The one deadline left in the wheel is the strand driver's own
  // checkpoint poll, parked far out by `harness` — not a re-arm.
  assert await_true(fn() { fake_pending(rig.fc) == 1 }, 2000)
    as "an expired cron schedule must stop contributing to the re-arm"
  stop(rig)
}

// --- 6. the observation instant: one write, and the clock it starts -------

// Issue #157 end to end. A `wake = false` heartbeat on a strand nobody
// ever opens a run on holds on every tick, so no fired-mark ever lands —
// and while `expires_after_s` was measured from the earliest mark, that
// meant a schedule with no clock at all, ticking for the life of the
// session behind a config key that read as a week. The first tick now
// records when it observed the schedule, and that recording is what ends
// it.
pub fn a_held_schedule_expires_from_its_observation_instant_test() {
  let sched = aging_schedule(name: "hb", seconds: 60, expires_after_s: 3600)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  assert idle(rig, "main") as "the strand must start idle"

  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { seen(rig.runtime, "hb") == Some(json.Int(0)) }, 2000)
    as "the first tick must record the instant it observed the schedule"
  assert fired_count(rig.runtime, "schedule/fired/main/hb/") == 0
    as "a held fire leaves no mark, which is why the marks cannot date it"

  // Past the schedule's window, with nothing having fired inside it.
  fake_jump_to(rig.fc, 4_000_000)
  assert fake_advance(rig.fc) as "the re-armed tick must be pending"

  // The one deadline left in the wheel is the strand driver's own
  // checkpoint poll (parked far out by `harness`), not a re-arm from a
  // schedule — the same reading the max_fires expiry test above takes.
  // Settled before it is read, never polled: a count taken in the gap
  // between the pop and the re-arm reads `1` for a schedule that is
  // still very much arming, which would pass against the bug.
  process.sleep(200)
  assert fake_pending(rig.fc) == 1
    as "a schedule expired by age must stop contributing to the re-arm"
  assert fired_count(rig.runtime, "schedule/fired/main/hb/") == 0
    as "an expired schedule must not fire on its way out"
  stop(rig)
}

// The cell is written at most once per schedule, and that is the whole
// invariant: a later tick re-basing the clock to its own `now` would give
// a schedule an age that never grows, which is the bug this fix is for
// wearing a different hat.
pub fn the_observation_instant_is_written_once_test() {
  let sched = aging_schedule(name: "hb", seconds: 60, expires_after_s: 3600)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  assert fake_advance(rig.fc) as "the first tick must be pending"
  assert await_true(fn() { seen(rig.runtime, "hb") == Some(json.Int(0)) }, 2000)
    as "the first tick must record its own instant"

  // A second scan, out of band, at a later logical time: same cell, same
  // instant, because the cell was not absent this time.
  fake_jump_to(rig.fc, 120_000)
  replay_tick(rig)
  process.sleep(150)
  assert seen(rig.runtime, "hb") == Some(json.Int(0))
    as "a later tick must not re-base the clock to its own now"
  stop(rig)
}

// An instant already in the store belongs to the schedule, not to
// whichever incarnation ticks next — which is what makes a restart
// harmless. Planted an hour and more back with nothing ever fired, the
// very first tick of this scanner must find the schedule finished rather
// than starting its clock afresh.
pub fn a_planted_observation_instant_is_honoured_test() {
  let sched = aging_schedule(name: "hb", seconds: 60, expires_after_s: 3600)
  let assert Ok(rig) = harness([sched], 4_000_000) as "the harness must boot"
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.seen_key(strand: "main", name: "hb"),
      schedule.seen_value(since_s: 0),
    )
    as "the seen cell must be writable"

  // The first tick has been armed since `harness` returned and has not
  // run yet, so the plant lands before this scanner has ever looked.
  assert fake_advance(rig.fc) as "the first tick must be pending"
  process.sleep(200)
  assert fake_pending(rig.fc) == 1
    as "a schedule planted as observed long ago must expire on sight"
  assert fired_count(rig.runtime, "schedule/fired/main/hb/") == 0
    as "an expired schedule must not fire"
  assert seen(rig.runtime, "hb") == Some(json.Int(0))
    as "the planted instant must survive the tick that read it"
  stop(rig)
}

// --- a settled target ends the schedule ------------------------------------

// Issue #163's sharp half, in the scanner. A subagent has one run; once
// it has ended, a schedule keyed to that strand must not fire — and a
// `WakesIdle` one must certainly not open a fresh run on a driver whose
// task is over, which is a child extending its own liveness outside the
// spawn budget its parent was held to.
//
// The strand here is real and idle, with a live driver, which is what
// makes the assertion mean something: the fire would land if the check
// were not there, and the control test below proves exactly that.
pub fn a_reaped_target_stops_the_schedule_test() {
  let assert Ok(rig) = harness([], 0) as "the harness must boot"
  let child = start_child(rig)
  plant_lineage(rig, child, an_op(), reaped: True)
  plant_config(rig, child, "watch")

  // The wheel already holds the scanner's first armed tick and each
  // strand driver's own checkpoint poll (parked far out by `harness`), so
  // the assertion is against that baseline rather than a count: an
  // `Active` schedule would add exactly one deadline to it.
  let before = fake_pending(rig.fc)
  replay_tick(rig)
  process.sleep(200)
  assert !fired(
    rig.runtime,
    schedule.fired_key(strand: child, name: "watch", occurrence: 0),
  )
    as "a schedule on a reaped strand must not fire"
  assert idle(rig, child) as "and must certainly not open a run on it"
  assert fake_pending(rig.fc) == before
    as "a schedule whose target has stopped must stop re-arming"
  stop(rig)
}

// The same schedule with a live target fires and opens the run, which is
// what makes the two tests above and below a measurement rather than a
// pair of vacuous truths: what changes between them is one durable fact
// about the target, not whether the strand is reachable.
pub fn a_live_child_target_still_fires_test() {
  let assert Ok(rig) = harness([], 0) as "the harness must boot"
  let child = start_child(rig)
  plant_lineage(rig, child, an_op(), reaped: False)
  plant_config(rig, child, "watch")

  replay_tick(rig)
  assert await_true(
    fn() {
      fired(
        rig.runtime,
        schedule.fired_key(strand: child, name: "watch", occurrence: 0),
      )
    },
    2000,
  )
    as "a schedule on a live child must fire"
  stop(rig)
}

// The second of the two facts a settled target is read from, and the one
// an ordinary subagent actually ends by: its brief has a terminal
// result. The Agency reads exactly this pair (`is_live`, `reap`), so the
// scanner agreeing with it is the point rather than a coincidence.
pub fn a_settled_brief_stops_the_schedule_test() {
  let assert Ok(rig) = harness([], 0) as "the harness must boot"
  let child = start_child(rig)
  let brief = an_op()
  plant_lineage(rig, child, brief, reaped: False)
  plant_settled(rig, brief)
  plant_config(rig, child, "watch")

  replay_tick(rig)
  process.sleep(200)
  assert !fired(
    rig.runtime,
    schedule.fired_key(strand: child, name: "watch", occurrence: 0),
  )
    as "a schedule on a strand whose brief has settled must not fire"
  assert idle(rig, child) as "and must not open a run on it"
  stop(rig)
}

// Fails closed: a `sub:` target with no lineage cell is not a strand
// this session started, and a schedule naming one is over rather than
// waiting. The direction is deliberately the opposite of
// `client/rulescan`'s hold, because a held rule costs a tick and a fired
// schedule may open a run.
pub fn a_target_with_no_lineage_cell_stops_the_schedule_test() {
  let assert Ok(rig) = harness([], 0) as "the harness must boot"
  let child = start_child(rig)
  plant_config(rig, child, "watch")

  replay_tick(rig)
  process.sleep(200)
  assert !fired(
    rig.runtime,
    schedule.fired_key(strand: child, name: "watch", occurrence: 0),
  )
    as "a subagent-shaped target with no ledger cell must not fire"
  assert idle(rig, child) as "and must not open a run on it"
  stop(rig)
}

// A root strand is idle between runs rather than finished, so none of
// the above may leak onto `main`: a terminal result there says the last
// prompt ended, not that the next one will never arrive.
pub fn a_settled_root_target_still_fires_test() {
  let assert Ok(rig) = harness([], 0) as "the harness must boot"
  let assert Ok(op) = api.prompt(rig.runtime, [user("hello")])
    as "the prompt must open a run on main"
  plant_settled(rig, op)

  let planted =
    schedule.Schedule(
      name: "mine",
      target: "main",
      owner: schedule.StrandOwned(strand: "main"),
      timing: schedule.OneShot(at: 0),
      wake: schedule.WakesIdle,
      body: "look at the build",
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.config_key(strand: "main", name: "mine"),
      schedule.encode(planted),
    )
    as "the config cell must be writable"

  replay_tick(rig)
  assert await_true(
    fn() {
      fired(
        rig.runtime,
        schedule.fired_key(strand: "main", name: "mine", occurrence: 0),
      )
    },
    2000,
  )
    as "a root strand's own schedule must fire whatever its last result was"
  stop(rig)
}

// A parent-owned schedule firing on a child must not tell the child it
// scheduled the thing itself. The attribution names the owner and says
// what the instruction is worth — as much as a steer from that strand,
// and no more — because a strand's instruction reaching a child
// disguised as the child's own earlier intent is an authority nobody
// granted.
pub fn a_parent_owned_fire_is_attributed_to_the_parent_test() {
  let assert Ok(rig) = harness([], 0) as "the harness must boot"
  let child = start_child(rig)
  plant_lineage(rig, child, an_op(), reaped: False)
  plant_config(rig, child, "watch")

  replay_tick(rig)
  assert await_true(
    fn() {
      fired(
        rig.runtime,
        schedule.fired_key(strand: child, name: "watch", occurrence: 0),
      )
    },
    2000,
  )
    as "the schedule must fire onto the live child"

  let text = injected_text(rig, child)
  assert string.contains(text, "scheduled by main")
  assert string.contains(text, "no authority beyond a steer")
  assert !string.contains(text, "you* scheduled")
  assert !string.contains(text, "standing operator configuration")
  stop(rig)
}

// --- fixtures for a child target -------------------------------------------

// A real, idle subagent strand with a live driver — `api.create_idle_strand`
// is the same door the `fork` and `create_strand` protocol commands use.
// Real rather than planted because every test above turns on whether a
// fire *lands*, and a strand nothing is listening on would refuse one for
// reasons that have nothing to do with the check under test.
fn start_child(rig: Rig) -> String {
  let child = "sub:main/worker-abc123"
  let assert Ok(Nil) =
    api.create_idle_strand(
      rig.runtime,
      named: child,
      configuration: machine_strand.StrandConfiguration(
        model: machine_strand.ModelIdentity(
          provider: "acme",
          model_id: "loom-1",
        ),
        thinking_level: machine_strand.ThinkingOff,
        active_tool_names: [],
      ),
      at: None,
    )
    as "the child strand must be creatable"
  child
}

// The child's lineage cell, as the Agency would have written it. The two
// facts the scanner reads from it are `reaped` and `brief`; everything
// else is filled in to make a well-formed cell.
fn plant_lineage(
  rig: Rig,
  child: String,
  brief: ids.OpId,
  reaped reaped: Bool,
) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      lineage.register_key(child),
      lineage.encode(lineage.Lineage(
        strand: child,
        parent: "main",
        depth: 1,
        minted_by: lineage.CallSite(
          operation: brief,
          step_id: "turn-1:tools",
          source_index: 0,
        ),
        brief:,
        tools: [],
        deadline: None,
        detached: False,
        reaped:,
      )),
    )
    as "the ledger must accept a cell written by the harness"
  Nil
}

// A terminal result for one operation, under the reserved
// `operation-result/` key `api.await_strand_result` reads — the same fact
// a real run's terminal transaction writes, which is what makes "this
// strand's brief has settled" a durable question.
fn plant_settled(rig: Rig, op: ids.OpId) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      operation.result_fact_key(op),
      codec.encode_last_result(operation.RunLastResult(
        operation: op,
        leaf: None,
        outcome: operation.RunCompleted(
          completion: operation.CompletedByAssistant,
        ),
        final_assistant: None,
      )),
    )
    as "a terminal result must be plantable"
  Nil
}

// A parent-owned, waking schedule onto a child, planted straight into
// the store: the seam refuses to grant `WakesIdle` on a subagent target,
// and what these tests exercise is the scanner's own refusal to act on
// one however it got there — an operator's `[[schedule]]`, or a cell an
// older build wrote.
fn plant_config(rig: Rig, child: String, name: String) -> Nil {
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.config_key(strand: child, name:),
      schedule.encode(schedule.Schedule(
        name:,
        target: child,
        owner: schedule.StrandOwned(strand: "main"),
        timing: schedule.OneShot(at: 0),
        wake: schedule.WakesIdle,
        body: "check on the review",
      )),
    )
    as "the config cell must be writable"
  Nil
}

fn an_op() -> ids.OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 11))
  op
}

// --- one chain, however many wakes ----------------------------------------

// Every scan ends by arming the next wake, so anything delivering a wake
// delivers a *chain*, not an event. Before the generation tag, `poke`
// sent a bare tick and the extra chain re-armed itself forever: one
// permanent chain per model `schedule_create` or `schedule_cancel`, each
// costing a full store scan per period for the life of the session.
// Measured 2 -> 5 pending after three pokes, and it never came back down.
//
// The property is convergence, not an instantaneous count: a superseded
// chain is still sitting in the timer wheel until its deadline arrives,
// and what the fix guarantees is that when it *does* arrive it dies there
// instead of re-arming. So this drains the wheel and asserts the actor is
// back to exactly one live chain.
pub fn pokes_leave_exactly_one_live_timer_chain_test() {
  let sched =
    interval_schedule(name: "hb", seconds: 60, wake: schedule.SteersOnly)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  process.sleep(300)
  let before = fake_pending(rig.fc)

  replay_tick(rig)
  replay_tick(rig)
  replay_tick(rig)
  process.sleep(300)

  // Drain: each pop runs one wake. The live chain re-arms, the superseded
  // ones do not, so the wheel settles back to its one-chain baseline.
  drain(rig, 12)

  assert fake_pending(rig.fc) == before
  stop(rig)
}

// The other half of the same mechanism, isolated: a wake from a chain the
// actor has replaced must die where it lands rather than re-arming.
pub fn a_stale_tick_does_not_rearm_test() {
  let sched =
    interval_schedule(name: "hb", seconds: 60, wake: schedule.SteersOnly)
  let assert Ok(rig) = harness([sched], 0) as "the harness must boot"
  process.sleep(300)
  let before = fake_pending(rig.fc)

  // Generation 0 is behind whatever the actor has reached.
  stale_tick(rig, 0)
  stale_tick(rig, 0)
  process.sleep(300)

  // No new deadline was armed by either: a stale tick is inert.
  assert fake_pending(rig.fc) == before
  stop(rig)
}

// Pops one wake at a time, letting the scanner settle between pops.
//
// The schedule under test is deliberately `wake: False`, which is what
// makes a plain settle sound here: a `wake: True` scan opens a run
// through the writer and can outrun any fixed wait on a loaded box, and
// the next pop would then take the strand driver's checkpoint poll
// instead — jumping logical time eleven days, expiring the schedule, and
// ending on a count that looks exactly like the leak this test exists to
// catch. Holding on an idle strand costs one store read and returns, so
// the scan is fast for a reason rather than by luck. Chain arithmetic is
// the same either way; `wake` changes what a fire does, not how many
// wakes are armed.
fn drain(rig: Rig, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False ->
      case fake_advance(rig.fc) {
        False -> Nil
        True -> {
          process.sleep(120)
          drain(rig, remaining - 1)
        }
      }
  }
}

// --- origin travels with the store the schedule came from ------------------

// The unit tests pin `injection`'s two attributions; this pins the
// *wiring*, which is the half that can silently regress. A model-created
// cell must reach the model framed as the model's own — telling a model
// that text it wrote is "standing operator configuration" hands it an
// authority nobody granted, on a schedule it set itself.
pub fn a_model_created_schedule_fires_attributed_to_the_model_test() {
  // No operator schedules at all: everything here comes from the store.
  let assert Ok(rig) = harness([], 0) as "the harness must boot"

  let planted =
    schedule.Schedule(
      name: "mine",
      target: "main",
      owner: schedule.StrandOwned(strand: "main"),
      timing: schedule.OneShot(at: 0),
      wake: schedule.WakesIdle,
      body: "look at the build",
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      rig.runtime,
      schedule.config_key(strand: "main", name: "mine"),
      schedule.encode(planted),
    )
    as "the config cell must be writable"

  replay_tick(rig)
  assert await_true(
    fn() {
      fired(
        rig.runtime,
        schedule.fired_key(strand: "main", name: "mine", occurrence: 0),
      )
    },
    2000,
  )

  let text = injected_text(rig, "main")
  assert string.contains(text, "you* scheduled")
  assert !string.contains(text, "standing operator configuration")
  stop(rig)
}

// The strand's projected context — what the model would actually read.
// The same door `rulescan_test` looks through.
fn injected_text(rig: Rig, strand: String) -> String {
  let leaf = case session.strand_leaf(rig.session, strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    Ok(None) | Error(_reason) -> None
  }
  case session.project_context(rig.session, leaf) {
    Ok(messages) -> messages |> list.map(text_of) |> string.join("\n")
    Error(_reason) -> ""
  }
}

fn text_of(item: message.AgentMessage) -> String {
  case item {
    message.UserMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    _other -> ""
  }
}
