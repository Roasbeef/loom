//// Surviving custody for the resources acquired while assembling a session.
////
//// The builder publishes each cleanup capability before beginning the next
//// acquisition. A Weft scope watches the builder and its consumer independently;
//// builder death starts cleanup even when its task cannot return a result. The
//// cleanup holder sits beneath the builder in that scope, so cleanup never
//// races a builder which can still publish resources.
////
//// This module owns application ordering, not a second process ledger. Weft
//// retains the builder and holder; a state machine retains the finite set of
//// cleanup capabilities. Blocking cleanup runs on a disposable Weft worker.
//// A failed or crashed cleanup leaves the holder alive and reports a blocked
//// reservation. Neither worker death nor a failed close permits the remaining
//// capabilities to run, especially the capability which releases the lease.
////
//// A normal exit of `owner` proves that every published cleanup succeeded.
//// This says nothing about an acquisition which was never published: assembly
//// must use prepare/publish/begin for work which can escape its builder. Each
//// cleanup must itself await the resource's complete retirement before success.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/result
import gleam/string
import weft
import weft/state_machine as sm

/// A fixed assembly boundary, in shutdown order rather than acquisition order.
pub type Part {
  /// The runtime's transitive drain barrier, before any supporting service.
  Runtime

  /// Restartable composition services which can still read session storage.
  Services

  /// The capability broker, after all runtime effects have drained.
  Broker

  /// Jailed helpers, after the broker no longer lends them out.
  Helpers

  /// External MCP clients, after runtime calls have drained.
  Mcp

  /// The session connection and writer lease, or its already-closed actor.
  Storage

  /// Reclaimable service routing, after all its consumers have retired.
  Namespace
}

/// A cleanup which did not establish retirement. Its reservation must remain.
pub type Failure {
  Failed(
    /// The boundary at which ordered cleanup stopped.
    part: Part,
    /// The error or worker exit which prevented proof.
    reason: String,
  )

  /// The cleanup worker died without returning a boundary's outcome.
  Interrupted(reason: String)
}

/// The bounded close report, distinct from the scope's eventual drain proof.
pub type CloseOutcome {
  /// The caller observed the witness retire normally after all cleanup.
  Closed

  /// The report deadline expired; custody and the reservation remain alive.
  StillClosing

  /// Cleanup failed or its witness was lost; replacement is forbidden.
  RecoveryBlocked(failure: Failure)
}

/// The scope's cancellation capability and its acknowledged publication door.
pub opaque type Owner {
  Owner(run: weft.Witnessed, publication: Subject(Message))
}

type Message {
  Publish(Part, fn() -> Result(Nil, String), Subject(Result(Nil, String)))
  Cancel
  AwaitFailure(Subject(Failure))
  Reported(weft.Pulled(Nil, Failure))
}

type Phase {
  Filling
  Closing
  Blocked(Failure)
}

type Book {
  Book(
    cleanups: Dict(Part, fn() -> Result(Nil, String)),
    reports: Subject(weft.Pulled(Nil, Failure)),
    failures: Subject(Failure),
  )
}

/// Starts custody before the parked builder begins acquiring resources.
///
/// `stop_builder` must stop and join no descendants: the scope waits for the
/// builder's exit before asking the independent holder to clean them up. The
/// caller must trap exits because a lost transitive proof is an abnormal scope
/// exit. Watch `owner` before starting the builder; do not kill that witness.
///
/// ## Examples
///
/// ```gleam
/// // instance_owner.start(builder, fn() { process.kill(builder) },
/// //   consumer: manager, failures: events)
/// ```
@internal
pub fn start(
  builder: Pid,
  stop_builder: fn() -> Nil,
  consumer consumer: Pid,
  failures failures: Subject(Failure),
) -> Result(Owner, String) {
  let handoff = process.new_subject()
  let run =
    weft.new_prepared([
      weft.managed(fn(ledger) {
        let outcome = prepare(ledger, builder, stop_builder, failures)
        process.send(handoff, outcome)
        result.replace(outcome, Nil)
      }),
    ])
    |> weft.on_failure(weft.CancelSiblings)
    |> weft.cancel_when_exits(builder)
    |> weft.cancel_when_exits(consumer)
    |> weft.start_witnessed

  // The scope may lose its starter before publication. Its death is an error,
  // never permission for an unowned builder to proceed.
  let watch = process.monitor(weft.witness_pid(run))
  let outcome =
    process.new_selector()
    |> process.select(handoff)
    |> process.select_specific_monitor(watch, fn(_down) {
      Error("instance custody stopped before publication")
    })
    |> process.selector_receive_forever()
  process.demonitor_process(watch)
  result.map(outcome, fn(publication) { Owner(run:, publication:) })
}

fn prepare(
  ledger: weft.Ledger,
  builder: Pid,
  stop_builder: fn() -> Nil,
  failures: Subject(Failure),
) -> Result(Subject(Message), String) {
  use Nil <- result.try(
    permitted(weft.adopt_leaf(ledger, owner: builder, cancel: stop_builder)),
  )
  use holder <- result.try(
    sm.new_with_initialiser(1000, fn(subject) {
      let reports = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(reports, Reported)
      sm.initialised(Filling, Book(dict.new(), reports, failures))
      |> sm.selecting(selector)
      |> sm.returning(subject)
      |> Ok
    })
    |> sm.on_event(handle)
    |> sm.start
    |> result.map_error(string.inspect),
  )

  // Keep the startup link until the scope has custody. Afterwards the holder
  // must survive the short-lived publication worker's exit.
  let adoption =
    weft.adopt_under(ledger, parent: builder, owner: holder.pid, cancel: fn() {
      process.send(holder.data, Cancel)
    })
  process.unlink(holder.pid)
  use Nil <- result.try(permitted(adoption))
  Ok(holder.data)
}

fn permitted(adoption: weft.Adoption) -> Result(Nil, String) {
  case adoption {
    weft.Adopted -> Ok(Nil)
    weft.Refused -> Error("instance custody is already cancelling")
  }
}

/// Publishes one boundary's complete cleanup capability, exactly once.
///
/// Success is the acknowledgement that the builder may begin the next step.
/// Runtime publication belongs in its pre-recovery callback. A refused
/// publication must never be followed by beginning the unpublished work.
///
/// ## Examples
///
/// ```gleam
/// // instance_owner.publish(owner, Runtime, fn() {
/// //   api.close(runtime) |> result.map_error(string.inspect)
/// // })
/// ```
@internal
pub fn publish(
  owner: Owner,
  part: Part,
  cleanup: fn() -> Result(Nil, String),
) -> Result(Nil, String) {
  process.call_forever(owner.publication, Publish(part, cleanup, _))
}

/// Returns the transitive witness; only its normal exit proves cleanup.
///
/// ## Examples
///
/// ```gleam
/// let watch = process.monitor(instance_owner.owner(custody))
/// ```
@internal
pub fn owner(owner: Owner) -> Pid {
  weft.witness_pid(owner.run)
}

/// Requests builder termination followed by ordered cleanup, idempotently.
///
/// ## Examples
///
/// ```gleam
/// instance_owner.cancel(custody)
/// ```
@internal
pub fn cancel(owner: Owner) -> Nil {
  weft.cancel_witnessed(owner.run)
}

/// Requests cleanup and waits at most `within_ms` for a conclusive report.
///
/// The timeout bounds this caller, never the cleanup witness. A later caller
/// can observe continuing cleanup or the retained failure. A witness already
/// dead before this call cannot supply a new proof; the daemon must retain a
/// previously observed `Closed` result in its own catalogue state.
///
/// ## Examples
///
/// ```gleam
/// let outcome = instance_owner.close(custody, within_ms: 5000)
/// // StillClosing keeps the session reserved while its effects drain.
/// ```
@internal
pub fn close(owner: Owner, within_ms within_ms: Int) -> CloseOutcome {
  let watch = process.monitor(weft.witness_pid(owner.run))
  let failure = process.new_subject()
  process.send(owner.publication, AwaitFailure(failure))
  cancel(owner)

  let outcome =
    process.new_selector()
    |> process.select_map(failure, RecoveryBlocked)
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Closed
        process.ProcessDown(reason:, ..) | process.PortDown(reason:, ..) ->
          RecoveryBlocked(Interrupted(string.inspect(reason)))
      }
    })
    |> process.selector_receive(within_ms)
  process.demonitor_process(watch)
  result.unwrap(outcome, StillClosing)
}

fn handle(
  phase: Phase,
  book: Book,
  message: Message,
) -> sm.Step(Phase, Book, Message, sm.Postponable) {
  case phase, message {
    Filling, Publish(part, cleanup, reply) -> {
      case dict.has_key(book.cleanups, part) {
        True -> {
          process.send(reply, Error("instance boundary was already published"))
          sm.keep(book)
        }
        False -> {
          process.send(reply, Ok(Nil))
          sm.keep(
            Book(..book, cleanups: dict.insert(book.cleanups, part, cleanup)),
          )
        }
      }
    }
    Closing, Publish(_part, _cleanup, reply)
    | Blocked(_failure), Publish(_part, _cleanup, reply)
    -> {
      process.send(reply, Error("instance custody is already closing"))
      sm.keep(book)
    }
    Filling, Cancel -> {
      let _relay =
        weft.new([fn() { clean(book.cleanups) }])
        |> weft.start_relayed(to: book.reports)
      sm.transition(Closing, book)
    }
    Closing, Cancel | Blocked(_failure), Cancel -> sm.keep(book)
    Filling, AwaitFailure(_reply) | Closing, AwaitFailure(_reply) ->
      sm.keep(book) |> sm.postpone
    Blocked(failure), AwaitFailure(reply) -> {
      process.send(reply, failure)
      sm.keep(book)
    }
    Closing, Reported(weft.PulledOutcome(outcome)) -> {
      case outcome {
        weft.Completed(..) -> sm.stop()
        weft.Failed(error:, ..) -> block(book, error)

        // A callback crash loses the current boundary as well as its result.
        // No remaining cleanup is allowed to run after that loss.
        weft.Crashed(reason:, ..) | weft.DrainProofLost(reason:, ..) ->
          block(book, Interrupted(string.inspect(reason)))
        weft.Abandoned(..)
        | weft.NeverStarted(..)
        | weft.CancellationUnconfirmed(..) ->
          block(book, Interrupted("instance cleanup did not complete"))
      }
    }
    Closing, Reported(weft.RunLost(reason)) ->
      block(book, Interrupted(string.inspect(reason)))
    Closing, Reported(weft.AllDelivered) | Closing, Reported(weft.NotYet) ->
      sm.keep(book)

    // Reports belong only to the one cleanup run. Filling has none, and a
    // blocked reservation never starts another run or forgets its failure.
    Filling, Reported(_report) | Blocked(_failure), Reported(_report) ->
      sm.keep(book)
  }
}

fn block(
  book: Book,
  failure: Failure,
) -> sm.Step(Phase, Book, Message, sm.Postponable) {
  process.send(book.failures, failure)
  sm.transition(Blocked(failure), book)
}

fn clean(
  cleanups: Dict(Part, fn() -> Result(Nil, String)),
) -> Result(Nil, Failure) {
  [Runtime, Services, Broker, Helpers, Mcp, Storage, Namespace]
  |> list.try_each(fn(part) {
    case dict.get(cleanups, part) {
      Error(Nil) -> Ok(Nil)
      Ok(cleanup) ->
        cleanup() |> result.map_error(fn(reason) { Failed(part, reason) })
    }
  })
}
