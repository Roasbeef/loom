//// Physical clearance for the compiler and satellite launcher.
////
//// The owner broker remains the only policy, grant and pooled-budget
//// authority. Physical hosts inject this small lifecycle record so local
//// assembly and a later executor adapter can use the same build and launch
//// code without passing an owner Broker into the physical configuration.
//// `local` preserves the existing broker clearance and abort-step ordering;
//// the returned cancellation callback names only that cleared call.
////
//// A remote adapter must forward the exact prepared command for owner
//// clearance, validate it against current registration authority at physical
//// admission, and deliver the complete original CallEvent stream. This is a
//// host-language dependency injection seam, never a wire closure protocol.

import broker/broker
import core/ids.{type OpId}
import gleam/erlang/process.{type Subject}
import gleam/result

/// One cleared physical call. Settlement and helper/native custody remain
/// on the existing CallEvent stream, never inferred from cancellation.
///
/// ## Examples
///
/// ```gleam
/// let call = physical.RunningCall(cancel: cancel_native_call)
/// call.cancel()
/// ```
pub type RunningCall {
  /// The cancellation handle is local to the physical adapter.
  RunningCall(
    /// Idempotent cancellation of this call, including clearance that raced
    /// the launcher's first abort-step sweep.
    cancel: fn() -> Nil,
  )
}

/// The physical host's clearance and step teardown dependencies.
///
/// ## Examples
///
/// ```gleam
/// let runner = physical.local(owner_broker)
/// let running = runner.clear(prepared_call, events)
/// ```
pub type Runner {
  /// No identity or budget is configured here; each CallSpec supplies them.
  Runner(
    /// Clears the exact prepared command and streams output/settlement to
    /// the supplied subject, or returns the owner's original refusal.
    clear: fn(broker.CallSpec, Subject(broker.CallEvent)) ->
      Result(RunningCall, broker.Refusal),
    /// Revokes the step's tokens and cancels its outstanding calls. Sibling
    /// job steps remain governed by their existing operation-wide abort.
    abort_step: fn(OpId, String) -> Nil,
  )
}

/// Adapts the existing broker without adding another authority or ledger.
///
/// ## Examples
///
/// ```gleam
/// let runner = physical.local(owner_broker)
/// runner.abort_step(operation, "run")
/// ```
pub fn local(owner: broker.Broker) -> Runner {
  Runner(
    clear: fn(call, events) {
      broker.clear_call(owner, call, events:, waiting: 5000)
      |> result.map(fn(handle) {
        RunningCall(cancel: fn() { broker.cancel(owner, handle) })
      })
    },
    abort_step: fn(operation, step) {
      broker.abort_step(owner, operation, step_id: step)
    },
  )
}
