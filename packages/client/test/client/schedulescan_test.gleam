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

import client/schedule
import client/schedulescan
import core/clock.{type Clock}
import core/message
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as sup
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
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
// `runtime/effects.Timers`'s own doc says must be harmless.
fn replay_tick(rig: Rig) -> Nil {
  process.send(process.named_subject(rig.scanner), schedulescan.Tick)
}

fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.StreamHandle(events: process.new_subject())
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
  wake wake: Bool,
) -> schedule.Schedule {
  schedule.Schedule(
    name:,
    target: "main",
    timing: schedule.Interval(
      seconds:,
      expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
    ),
    wake:,
    body: "heartbeat",
  )
}

fn one_shot_schedule(name name: String, at at: Int) -> schedule.Schedule {
  schedule.Schedule(
    name:,
    target: "main",
    timing: schedule.OneShot(at:),
    wake: True,
    body: "reminder",
  )
}

// --- 1. wake = false: steers an open run, holds on an idle strand ----------

pub fn a_wake_false_schedule_steers_an_already_open_run_test() {
  let sched = interval_schedule(name: "hb", seconds: 60, wake: False)
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
  let sched = interval_schedule(name: "hb", seconds: 60, wake: False)
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
  let sched = interval_schedule(name: "wk", seconds: 60, wake: True)
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

// --- 4. a skipped window still produces exactly one, late, fire -----------

pub fn a_skipped_window_produces_exactly_one_late_fire_test() {
  let sched = interval_schedule(name: "hb", seconds: 60, wake: False)
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
      timing: schedule.Interval(
        seconds: 60,
        expiry: schedule.Expiry(max_fires: 1, expires_after_s: 604_800),
      ),
      wake: True,
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
