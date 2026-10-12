//// The late-bound handle through which a reap reaches the broker.
////
//// An operation's abort has two halves. The runtime stops the strand's live
//// effect processes and writes the durable marker. The broker cancels the
//// executions and signals the process groups running under the operation,
//// and it is the only thing that can: a default-mode `bash` call runs as a
//// background job under the jobs actor, so its execution and its jailed
//// process belong to no effect process the runtime could stop. `runtime`
//// may not depend on `broker`, so the second half is the host's to join to
//// the first. The operator's abort is joined in `serve` through
//// `gateway.with_effect_abort`; this module is the same join for the other
//// callers that stop a run, which are the Agency's reaps (a deadline, a
//// finished parent, a drained execution).
////
//// ## Flow
////
//// 1. The host mints an `Address(Message)` before building `agency.Config`.
////    The broker does not exist yet and the plane consumes the config, so a
////    closure over the broker would be a value cycle. `abort` closes over
////    the address alone.
//// 2. `supervised` starts the actor under that address once the broker
////    exists, holding the sweep the host built (the operator path's own
////    closure).
//// 3. `send` is a fire-and-forget send, which `abort` wraps. The actor runs
////    the sweep off the caller, which is a reaper that must not wait on the
////    async service's fence.
////
//// A send while the actor restarts is lost. That costs a job running to its
//// wall deadline, which is what happened before this existed, and the reap
//// is re-issued on every later observation of the ledger, so the next one
//// repeats the send.

import core/ids.{type OpId}
import gleam/erlang/process.{type Subject}
import gleam/otp/supervision.{type ChildSpecification}
import weft/actor
import weft/registry as address

/// The actor's mailbox: one operation whose effects are to be cancelled.
pub type Message {
  /// Cancel the broker executions under this operation.
  AbortEffects(operation: OpId)
}

/// Starts the actor under `name` as a supervision child. `sweep` is run once
/// per message, on the actor's process.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, effect_abort.supervised(name, broker.abort(b, _)))
/// ```
pub fn supervised(
  name: address.Address(Message),
  sweep: fn(OpId) -> Nil,
) -> ChildSpecification(Subject(Message)) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) {
    case message {
      AbortEffects(operation:) -> {
        sweep(operation)
        actor.continue(state)
      }
    }
  })
  |> actor.addressed(name)
  |> actor.supervised
}

/// The function an `agency.Config` carries as `abort_effects`: it asks the
/// actor at `name` to sweep and returns at once.
///
/// ## Examples
///
/// ```gleam
/// // agency.Config(..config, abort_effects: effect_abort.abort(name))
/// ```
pub fn abort(name: address.Address(Message)) -> fn(OpId) -> Nil {
  fn(operation) { send(name, operation) }
}

/// Asks the actor at `name` to sweep `operation` and returns at once. A
/// request to an address nobody is bound to is dropped.
///
/// ## Examples
///
/// ```gleam
/// // effect_abort.send(name, operation)
/// ```
pub fn send(name: address.Address(Message), operation: OpId) -> Nil {
  let _sent = address.send(name, AbortEffects(operation:))
  Nil
}
