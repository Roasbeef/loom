//// Fixed live-effect fixtures for checkpoint-poll tests and measurements.
//// The provider waits for an explicit release while callers observe the real
//// driver. Storage counters distinguish small control reads from full loads.

import core/clock
import core/register
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import machine/operation.{
  BranchSummaryPreparation, FileOperations, NavigationLastResult,
  StructuralCompleted,
}
import machine/planner
import runtime/api
import runtime/effects
import session/session
import storage/storage
import support/fake
import support/harness
import support/recorder
import weft/poll

/// Which effect the fixture holds until its observation finishes.
pub type Kind {
  /// An ordinary run, which admits quiet steering while the request is live.
  Assistant

  /// A navigation summary with a large frozen preparation.
  Summary
}

/// Runtime handles and counters available only during the held request.
pub type Held {
  Held(
    /// The real runtime whose provider is waiting.
    runtime: api.Runtime,
    /// Read counters owned by the fixture rather than the session tree.
    counters: Subject(recorder.Message),
  )
}

/// Run an observation while a real driver waits for a scripted provider.
/// The request is released and the runtime closed before returning its result.
///
/// ## Examples
///
/// ```gleam
/// // held_operation.run(session, Summary, 25, fn(held) { held.runtime.strand })
/// ```
pub fn run(
  original: session.Session,
  kind: Kind,
  poll_ms: Int,
  inspect: fn(Held) -> a,
) -> a {
  let rec = recorder.start()
  let ready = process.new_subject()
  let sess = counted_session(original, rec)
  let base =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      [],
      fn(spec) {
        let hold = case kind, spec {
          Summary, effects.SummaryRequest(..)
          | Assistant, effects.GenerationRequest(..)
          -> recorder.bump(rec, "request") == 1
          _, _ -> False
        }
        case hold {
          True -> {
            let release = process.new_subject()
            process.send(ready, release)
            process.receive_forever(release)
          }
          False -> Nil
        }
        fake.Reply(fake.answer("summary", 3))
      },
      fn(_) { fake.ToolReply("unused", False, False) },
    )
  let eff =
    effects.Effects(
      ..base,
      hooks: effects.Hooks(..base.hooks, structural_decision: fn(_, _) {
        planner.VerdictGenerate
      }),
    )
  let options = api.default_options(harness.configuration())
  let assert Ok(rt) =
    api.open(sess, eff, api.Options(..options, poll_interval_ms: poll_ms))
    as "the measured runtime opens"
  let operation = case kind {
    Assistant -> api.prompt(rt, [fake.user("held run")])
    Summary -> {
      seed(rt)
      let assert Ok(Some(session.Cell(value: target, ..))) =
        session.strand_leaf(sess, "main")
        as "the first seed leaves a target"
      seed(rt)
      api.navigate(
        rt,
        to: target,
        summarize: True,
        label: None,
        custom_instructions: None,
        preparation: Some(BranchSummaryPreparation(
          messages: [fake.user(string.repeat("synthetic \"line\"\n", 80_000))],
          file_ops: FileOperations(read: [], written: [], edited: []),
          total_tokens: 10,
        )),
      )
    }
  }
  let assert Ok(operation) = operation as "the held operation is admitted"
  let assert Ok(release) = process.receive(ready, within: 5000)
    as "the provider reaches its held request"
  let observed = inspect(Held(rt, rec))
  process.send(release, Nil)
  let outcome = api.await_result(rt, operation, within_ms: 5000)
  let closed = api.close(rt)
  assert closed == Ok(Nil)
  let assert Ok(result) = outcome as "the released operation settles"
  case kind {
    Assistant -> harness.assert_completed(result)
    Summary -> {
      let assert NavigationLastResult(outcome: StructuralCompleted, ..) = result
        as "the released summary completes its navigation"
      Nil
    }
  }
  observed
}

fn counted_session(
  original: session.Session,
  rec: Subject(recorder.Message),
) -> session.Session {
  let get_register = original.store.get_register
  let list_registers = original.store.list_registers
  let store =
    storage.Storage(
      ..original.store,
      get_register: fn(handle, ns, key) {
        case ns {
          register.OpState -> {
            let _ = recorder.bump(rec, "control")
            get_register(handle, ns, key)
          }
          _ -> get_register(handle, ns, key)
        }
      },
      list_registers: fn(handle, ns, prefix) {
        case ns {
          register.OpPreparation -> {
            let _ = recorder.bump(rec, "preparation")
            list_registers(handle, ns, prefix)
          }
          _ -> list_registers(handle, ns, prefix)
        }
      },
    )
  session.Session(..original, store:)
}

fn seed(rt: api.Runtime) -> Nil {
  let assert Ok(op) = api.prompt(rt, [fake.user("seed")])
    as "the seed run is admitted"
  let assert Ok(result) = api.await_result(rt, op, within_ms: 5000)
    as "the seed run settles"
  harness.assert_completed(result)
}

/// Observe additional control reads without counting fixture setup reads or
/// assuming that a fixed sleep spans a tick.
///
/// ## Examples
///
/// ```gleam
/// // held_operation.wait_for_reads(held, 5)
/// ```
pub fn wait_for_reads(held: Held, count: Int) -> poll.Outcome(Nil, Nil) {
  let target = recorder.read(held.counters, "control") + count
  poll.until(within: 5000, every: 10, attempt: fn() {
    case recorder.read(held.counters, "control") >= target {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
}
