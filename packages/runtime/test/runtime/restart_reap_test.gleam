//// A strand-actor restart (the tree stays up) must not leak the dying
//// incarnation's live effect processes. The exclusivity gate and the
//// orphan-versus-live decision are incarnation-local, so a leaked effect
//// would run *concurrently* with the replacement's recovery replay —
//// "safe to run again" stretched to "safe to run beside itself", which
//// no replay registration ever promised. The reaper closes this: every
//// effect is linked to a per-incarnation companion that dies with the
//// driver and takes the effects with it.
////
//// The scripted tool blocks forever on its first execution; the test
//// kills the driver mid-execution and lets recovery replay the call.
//// The replay asserts the first execution's process is already dead —
//// before the reaper existed, it was still alive and blocked, and the
//// two executions of one exclusive tool overlapped.

import core/clock
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import machine/operation.{ReplaySafe, RunFailed, RunLastResult}
import provider/stream
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session
import support/fake
import support/harness
import support/recorder

pub fn strand_restart_reaps_the_live_tool_effect_test() {
  let rec = recorder.start()
  let pids = pid_log()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [#("slow", ReplaySafe)],
      fn(spec) {
        case fake.turn(spec) {
          0 -> fake.Reply(fake.tool_use("digging", [#("c1", "slow")], 4))
          _ -> fake.Reply(fake.answer("done", 5))
        }
      },
      fn(_run) {
        // Every execution logs its own process first, so a later
        // execution can ask whether an earlier one is still running.
        record_pid(pids, process.self())
        case recorder.bump(rec, "slow-runs") {
          1 -> fake.ToolHang
          _ -> {
            // The recovery replay: the first execution's process must
            // already be dead, or two executions of one exclusive tool
            // are running at once.
            let overlapping =
              logged_pids(pids)
              |> list.filter(fn(pid) { pid != process.self() })
              |> list.filter(process.is_alive)
            case overlapping {
              [] -> Nil
              _ -> {
                let _seen = recorder.bump(rec, "overlap")
                Nil
              }
            }
            fake.ToolReply(text: "out:slow", is_error: False, terminate: False)
          }
        }
      },
    )
  // The tool is exclusive: the sharpest form of the gate the leak broke.
  let eff =
    effects.Effects(
      ..base_effects,
      tools: effects.ToolSurface(
        ..base_effects.tools,
        execution_mode: fn(_name) { effects.ExclusiveExecution },
      ),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 50,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("dig")])
    as "the prompt must be accepted"
  // Restart the strand actor — not the tree — while the first execution
  // is blocked inside the effect process.
  wait_for(fn() { recorder.read(rec, "slow-runs") >= 1 }, 5000)
  kill_strand(rt, "main")
  // Recovery replays the ReplaySafe call and the run completes.
  let assert Ok(last) = api.await_result(rt, op, within_ms: 15_000)
    as "the run must complete after the strand restart"
  harness.assert_completed(last)
  // The replay ran exactly once beside zero live predecessors.
  assert recorder.read(rec, "slow-runs") == 2
  assert recorder.read(rec, "overlap") == 0
  // And the reaped first execution stays dead: nothing re-adopted it.
  let assert [first, ..] = logged_pids(pids)
  assert !process.is_alive(first)
  process.kill(rt.tree.supervisor)
}

pub fn provider_timeout_cancels_before_settling_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base_effects,
      provider: effects.ProviderSurface(timeout_ms: 10, request: fn(_spec) {
        let events = process.new_subject()
        stream.immediate(events:, cancel: fn() {
          let _cancelled = recorder.bump(rec, "provider-cancelled")
          process.send(events, stream.Failed(error: stream.ProviderCancelled))
        })
      }),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("wait for the provider")])
    as "the prompt must be accepted"
  let assert Ok(RunLastResult(outcome: RunFailed(error:), ..)) =
    api.await_result(rt, op, within_ms: 5000)
    as "the cancelled provider request must settle terminally"
  assert error.code == "provider_error"
  assert error.message == "provider request was cancelled"
  assert recorder.read(rec, "provider-cancelled") == 1
  process.kill(rt.tree.supervisor)
}

/// A provider owner which dies before publication has not proved drain. The
/// late monitor can observe only `noproc`, so the safe outcome is to poison the
/// reaper and stop the session rather than admit recovery beside unknown work.
pub fn dead_provider_owner_fails_session_closed_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base,
      provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(_spec) {
        let _requested = recorder.bump(rec, "dead-owner-requested")
        let stopped = process.new_subject()
        let owner =
          process.spawn_unlinked(fn() {
            process.send(stopped, Nil)
            process.kill(process.self())
          })
        let assert Ok(Nil) = process.receive(stopped, within: 1000)
        process.sleep(5)
        stream.owned(events: process.new_subject(), owner:, cancel: fn() { Nil })
      }),
    )
  let assert Ok(rt) =
    api.open(sess, eff, api.default_options(harness.configuration()))
  let root_monitor = process.monitor(rt.tree.supervisor)
  let assert Ok(_op) = api.prompt(rt, [fake.user("lose the owner")])

  let assert Ok(True) =
    process.new_selector()
    |> process.select_specific_monitor(root_monitor, fn(_down) { True })
    |> process.selector_receive(5000)
    as "unknown provider ownership must stop the session"
  assert recorder.read(rec, "dead-owner-requested") == 1
}

/// The parked request worker is an ownership boundary, not a new failure
/// domain. If the injected provider crashes that worker unexpectedly, the
/// linked effect must fault as it did before the boundary existed; recovery
/// then runs only after the published custodian drains.
pub fn provider_surface_crash_faults_the_effect_and_recovers_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Reply(fake.answer("recovered", 5)) },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base,
      provider: effects.ProviderSurface(timeout_ms: 100, request: fn(spec) {
        case recorder.bump(rec, "provider-requested") {
          1 -> {
            process.kill(process.self())
            process.receive_forever(process.new_subject())
          }
          _ -> base.provider.request(spec)
        }
      }),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("survive the provider crash")])
    as "the prompt must be accepted"

  let assert Ok(last) = api.await_result(rt, op, within_ms: 5000)
    as "the recovered provider attempt must complete"
  harness.assert_completed(last)
  assert recorder.read(rec, "provider-requested") == 2
    as "recovery must replace the crashed provider request exactly once"
  process.kill(rt.tree.supervisor)
}

pub fn provider_timeout_without_acknowledgement_stays_terminal_test() {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base_effects,
      provider: effects.ProviderSurface(timeout_ms: 10, request: fn(_spec) {
        let events = process.new_subject()
        stream.immediate(events:, cancel: fn() {
          let _cancelled = recorder.bump(rec, "unacknowledged-cancel")
          Nil
        })
      }),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(op) = api.prompt(rt, [fake.user("wait for the provider")])
    as "the prompt must be accepted"
  let assert Ok(RunLastResult(outcome: RunFailed(error:), ..)) =
    api.await_result(rt, op, within_ms: 5000)
    as "an unacknowledged cancellation must still settle terminally"
  assert error.code == "provider_error"
  assert error.message == "provider cancellation could not be confirmed"
  // A retryable fallback would dispatch and cancel the request again.
  assert recorder.read(rec, "unacknowledged-cancel") == 1
  process.kill(rt.tree.supervisor)
}

pub fn strand_restart_waits_for_the_provider_owner_drain_test() {
  let rec = recorder.start()
  let pids = pid_log()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base_effects,
      provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(_spec) {
        let consumer = process.self()
        let events = process.new_subject()
        let _requested = recorder.bump(rec, "provider-requested")
        record_pid(pids, consumer)
        let overlapping =
          logged_pids(pids)
          |> list.filter(fn(pid) { pid != consumer })
          |> list.filter(process.is_alive)
        case overlapping {
          [] -> Nil
          _ -> {
            let _overlap = recorder.bump(rec, "provider-overlap")
            Nil
          }
        }
        let ready = process.new_subject()
        let owner =
          process.spawn_unlinked(fn() {
            // A Subject names the process that creates it. The owner must
            // therefore mint this capability and hand it back before the
            // provider effect can issue cancellation.
            let cancel = process.new_subject()
            process.send(ready, cancel)
            let _cancel = process.receive_forever(cancel)
            let _drained = recorder.bump(rec, "provider-owner-drained")
            Nil
          })
        let cancel = process.receive_forever(ready)
        stream.owned(events:, owner:, cancel: fn() {
          let _cancelled = recorder.bump(rec, "provider-cancel-called")
          process.send(cancel, Nil)
        })
      }),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(_op) = api.prompt(rt, [fake.user("wait for the provider")])
    as "the prompt must be accepted"
  wait_for_named(
    fn() { recorder.read(rec, "provider-requested") >= 1 },
    5000,
    "the first provider request",
  )
  kill_strand(rt, "main")
  wait_for_named(
    fn() { recorder.read(rec, "provider-cancel-called") >= 1 },
    5000,
    "the predecessor provider cancellation",
  )
  wait_for_named(
    fn() { recorder.read(rec, "provider-owner-drained") >= 1 },
    5000,
    "the predecessor provider owner drain",
  )
  // The predecessor owner must acknowledge its drain before recovery can
  // dispatch request two; checking in this order makes overlap impossible to
  // hide behind an eventually delivered owner-drained message.
  wait_for_named(
    fn() { recorder.read(rec, "provider-requested") >= 2 },
    5000,
    "the replacement provider request",
  )
  assert recorder.read(rec, "provider-owner-drained") >= 1
  assert recorder.read(rec, "provider-overlap") == 0
  let assert [first, ..] = logged_pids(pids)
  assert !process.is_alive(first)
  process.kill(rt.tree.supervisor)
}

pub fn strand_exit_during_provider_start_waits_for_parked_custodian_test() {
  let rec = recorder.start()
  let entered = process.new_subject()
  let cancelled = process.new_subject()
  let drained = process.new_subject()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base,
      provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(_spec) {
        let events = process.new_subject()
        case recorder.bump(rec, "provider-started") {
          1 -> {
            let gate = process.new_subject()
            process.send(entered, gate)
            let _release_start = process.receive_forever(gate)
            let ready = process.new_subject()
            let owner =
              process.spawn_unlinked(fn() {
                let stop = process.new_subject()
                process.send(ready, stop)
                let _stop = process.receive_forever(stop)
                process.sleep(100)
                process.send(drained, Nil)
              })
            let stop = process.receive_forever(ready)
            stream.owned(events:, owner:, cancel: fn() {
              process.send(cancelled, Nil)
              process.send(stop, Nil)
            })
          }
          _ -> {
            process.send(events, stream.Failed(error: stream.ProviderCancelled))
            stream.immediate(events:, cancel: fn() { Nil })
          }
        }
      }),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
  let assert Ok(_operation) = api.prompt(rt, [fake.user("wait")])
  let assert Ok(release_start) = process.receive(entered, within: 5000)

  kill_strand(rt, "main")

  process.sleep(25)
  assert recorder.read(rec, "provider-started") == 1
    as "recovery must remain behind the already-published parked custodian"
  process.send(release_start, Nil)
  let assert Ok(Nil) = process.receive(cancelled, within: 5000)
  assert process.receive(drained, within: 20) == Error(Nil)
  let assert Ok(Nil) = process.receive(drained, within: 5000)
  wait_for_named(
    fn() { recorder.read(rec, "provider-started") >= 2 },
    5000,
    "the replacement provider request",
  )
  process.kill(rt.tree.supervisor)
}

pub fn strand_exit_waits_for_its_published_provider_owner_test() {
  let rec = recorder.start()
  let consumers = pid_log()
  let owners = pid_log()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base_effects,
      provider: delayed_drain_provider(rec, consumers, owners),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(_op) = api.prompt(rt, [fake.user("wait for the provider")])
    as "the prompt must be accepted"
  wait_for_named(
    fn() { recorder.read(rec, "provider-handle-returned") >= 1 },
    5000,
    "the first provider handle",
  )
  // Kill the driver while its effect is consuming the published runtime
  // custodian. The reaper must cancel that witness and keep recovery behind
  // the inner owner's independent drain.
  kill_strand(rt, "main")
  wait_for_named(
    fn() { recorder.read(rec, "provider-cancel-called") >= 1 },
    5000,
    "the orphaned provider cancellation",
  )
  process.sleep(25)
  assert recorder.read(rec, "provider-requested") == 1
  let assert [first_owner, ..] = logged_pids(owners)
  assert process.is_alive(first_owner)
  wait_for_named(
    fn() { recorder.read(rec, "provider-owner-drained") >= 1 },
    5000,
    "the orphaned provider owner drain",
  )
  wait_for_named(
    fn() { recorder.read(rec, "provider-requested") >= 2 },
    5000,
    "the replacement provider request",
  )
  assert recorder.read(rec, "provider-overlap") == 0
  let assert [first_consumer, ..] = logged_pids(consumers)
  assert !process.is_alive(first_consumer)
  process.kill(rt.tree.supervisor)
}

pub fn registry_restart_preserves_the_provider_drain_barrier_test() {
  let rec = recorder.start()
  let consumers = pid_log()
  let owners = pid_log()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let base_effects =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(_spec) { fake.Hang },
      fn(_run) { fake.ToolHang },
    )
  let eff =
    effects.Effects(
      ..base_effects,
      provider: delayed_drain_provider(rec, consumers, owners),
    )
  let options =
    api.Options(
      ..api.default_options(harness.configuration()),
      poll_interval_ms: 25,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"
  let assert Ok(_op) = api.prompt(rt, [fake.user("wait for the provider")])
    as "the prompt must be accepted"
  wait_for_named(
    fn() { recorder.read(rec, "provider-handle-returned") >= 1 },
    5000,
    "the first provider handle",
  )
  process.sleep(25)
  kill_registry(rt)
  wait_for_named(
    fn() { recorder.read(rec, "provider-cancel-called") >= 1 },
    5000,
    "the predecessor provider cancellation",
  )
  process.sleep(25)
  assert recorder.read(rec, "provider-requested") == 1
  let assert [first_owner, ..] = logged_pids(owners)
  assert process.is_alive(first_owner)
  wait_for_named(
    fn() { recorder.read(rec, "provider-owner-drained") >= 1 },
    5000,
    "the predecessor provider owner drain",
  )
  wait_for_named(
    fn() { recorder.read(rec, "provider-requested") >= 2 },
    5000,
    "the replacement provider request",
  )
  assert recorder.read(rec, "provider-overlap") == 0
  process.kill(rt.tree.supervisor)
}

// This provider keeps cancellation and drain observably separate. The owner
// remains alive for 100 ms after cancellation, creating a deterministic window
// in which an eager retry would overlap it. Each new request checks the owner
// pid log before starting its own subtree.
fn delayed_drain_provider(
  rec: Subject(recorder.Message),
  consumers: PidLog,
  owners: PidLog,
) -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 60_000, request: fn(_spec) {
    let consumer = process.self()
    let events = process.new_subject()
    let _requested = recorder.bump(rec, "provider-requested")
    record_pid(consumers, consumer)
    let overlap =
      logged_pids(owners)
      |> list.any(process.is_alive)
    case overlap {
      True -> {
        let _overlap = recorder.bump(rec, "provider-overlap")
        Nil
      }
      False -> Nil
    }
    let ready = process.new_subject()
    let owner =
      process.spawn_unlinked(fn() {
        let cancel = process.new_subject()
        process.send(ready, cancel)
        let _cancel = process.receive_forever(cancel)
        process.sleep(100)
        let _drained = recorder.bump(rec, "provider-owner-drained")
        Nil
      })
    record_pid(owners, owner)
    let cancel = process.receive_forever(ready)
    let _returned = recorder.bump(rec, "provider-handle-returned")
    stream.owned(events:, owner:, cancel: fn() {
      let _cancelled = recorder.bump(rec, "provider-cancel-called")
      process.send(cancel, Nil)
    })
  })
}

// Kills the named strand's driver process only: the factory restarts it
// under the same registered name while the writer — and the rest of the
// tree — keeps running.
fn kill_strand(rt: api.Runtime, strand: String) -> Nil {
  let assert Ok(subject) = supervisor.strand_subject(rt.tree, strand)
    as "the strand driver must be registered"
  let assert Ok(pid) = process.subject_owner(subject)
    as "the strand driver must be alive"
  process.kill(pid)
}

// The name registry is deliberately restartable. Killing it exercises the
// rest-for-one path while the earlier drain ledger and old reapers stay live.
fn kill_registry(rt: api.Runtime) -> Nil {
  let subject = process.named_subject(rt.tree.registry)
  let assert Ok(pid) = process.subject_owner(subject)
    as "the strand registry must be alive"
  process.kill(pid)
}

fn wait_for(condition: fn() -> Bool, remaining: Int) -> Nil {
  wait_for_named(condition, remaining, "a test condition")
}

fn wait_for_named(
  condition: fn() -> Bool,
  remaining: Int,
  milestone: String,
) -> Nil {
  case condition() {
    True -> Nil
    False ->
      case remaining <= 0 {
        True -> {
          let reason = "timed out waiting for " <> milestone
          panic as reason
        }
        False -> {
          process.sleep(10)
          wait_for_named(condition, remaining - 10, milestone)
        }
      }
  }
}

// --- a pid log -------------------------------------------------------------
//
// The recorder counts; this logs identities. Effect processes register
// themselves so a later execution can check whether an earlier one still
// runs — the overlap the reaper exists to make impossible.

type PidLogMessage {
  Record(pid: Pid)
  All(reply_with: Subject(List(Pid)))
}

type PidLog =
  Subject(PidLogMessage)

fn pid_log() -> PidLog {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(state, message) {
      case message {
        Record(pid:) -> actor.continue(list.append(state, [pid]))
        All(reply_with:) -> {
          process.send(reply_with, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
    as "the pid log must start"
  started.data
}

fn record_pid(log: PidLog, pid: Pid) -> Nil {
  process.send(log, Record(pid:))
}

fn logged_pids(log: PidLog) -> List(Pid) {
  process.call_forever(log, All)
}
