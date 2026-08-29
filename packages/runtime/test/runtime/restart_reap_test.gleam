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
        stream.StreamHandle(events:, cancel: fn() {
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
        stream.StreamHandle(events:, cancel: fn() {
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

pub fn strand_restart_reaches_the_provider_consumer_monitor_test() {
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
        let owner =
          process.spawn_unlinked(fn() {
            let down =
              process.new_selector()
              |> process.select_specific_monitor(
                process.monitor(consumer),
                fn(_down) { Nil },
              )
            let _consumer_down = process.selector_receive_forever(down)
            let _cancelled = recorder.bump(rec, "provider-consumer-down")
            Nil
          })
        stream.StreamHandle(events:, cancel: fn() { process.kill(owner) })
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
  wait_for(fn() { recorder.read(rec, "provider-requested") >= 1 }, 5000)
  kill_strand(rt, "main")
  wait_for(fn() { recorder.read(rec, "provider-requested") >= 2 }, 5000)
  wait_for(fn() { recorder.read(rec, "provider-consumer-down") >= 1 }, 5000)
  assert recorder.read(rec, "provider-consumer-down") >= 1
  assert recorder.read(rec, "provider-overlap") == 0
  let assert [first, ..] = logged_pids(pids)
  assert !process.is_alive(first)
  process.kill(rt.tree.supervisor)
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

fn wait_for(condition: fn() -> Bool, remaining: Int) -> Nil {
  case condition() {
    True -> Nil
    False ->
      case remaining <= 0 {
        True -> panic as "timed out waiting for a test condition"
        False -> {
          process.sleep(10)
          wait_for(condition, remaining - 10)
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
