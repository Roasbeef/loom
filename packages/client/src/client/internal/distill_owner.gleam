//// SQLite custody for one resource in an owned distillation pass.
////
//// The managed ledger adopts this parked holder before it opens a database.
//// Opening happens in the holder, so builder cancellation cannot discard an
//// unpublished close capability. The session reaches the builder only after
//// retirement is retained and the startup link has transferred.
////
//// Cancellation follows the builder's death. Cleanup runs on a Weft worker
//// under a wall deadline, so a wedged close is reported rather than waited on
//// forever; only successful close and original SQLite actor retirement permit
//// this holder's normal exit. Failure retains the holder and therefore the
//// ledger's unconfirmed custody. There is no second PID registry here.

import core/clock.{type Clock}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session/session
import storage/storage
import weft
import weft/state_machine as sm

/// Open failures retain the session error so a live writer lease remains distinct.
pub type Error {
  /// The session failed before it could be lent to the builder.
  OpenFailed(session.OpenError)

  /// Publication, transfer, or retirement did not establish ownership.
  CustodyFailed(String)
}

/// A session borrowed from its independently adopted cleanup holder.
pub opaque type Owned {
  Owned(session: session.Session, holder: Subject(Message))
}

type Message {
  Open(Subject(Result(session.Session, Error)))
  Close(Subject(Result(Nil, String)))
  Cancel
  Reported(weft.Pulled(Nil, String))
}

type Phase {
  Parked
  Live
  Closing
  Blocked(String)
}

type Book {
  Book(
    acquire: Acquisition,
    retire: fn() -> Result(Nil, String),
    reply: Option(Subject(Result(Nil, String))),
    reports: Subject(weft.Pulled(Nil, String)),
  )
}

/// The existing SQLite custody triple, with its retirement error rendered.
/// Acquisition executes inside the adopted holder, never in the builder.
pub type Acquisition =
  fn() ->
    Result(
      #(
        session.Session,
        fn() -> Result(Nil, String),
        fn() -> Result(Pid, storage.StorageError),
      ),
      Error,
    )

/// Registers the builder as the cancellation parent before any resource opens.
///
/// ## Examples
///
/// ```gleam
/// // use builder <- result.try(distill_owner.builder(ledger))
/// ```
@internal
pub fn builder(ledger: weft.Ledger) -> Result(Pid, String) {
  let pid = process.self()
  weft.adopt_leaf(ledger, owner: pid, cancel: fn() { process.kill(pid) })
  |> admitted
  |> result.replace(pid)
}

/// Opens only after the holder has been adopted beneath the original builder.
///
/// ## Examples
///
/// ```gleam
/// // distill_owner.open(ledger, builder, path, owner, ttl, clock)
/// ```
@internal
pub fn open(
  ledger: weft.Ledger,
  builder: Pid,
  path: String,
  owner: String,
  ttl: Int,
  clock: Clock,
) -> Result(Owned, Error) {
  let acquire = fn() {
    use #(opened, retire, transfer) <- result.try(
      session.open_sqlite_custody(path:, owner:, lease_ttl_ms: ttl, clock:)
      |> result.map_error(OpenFailed),
    )

    // The adopted holder still owns this stack if transfer fails. Its startup
    // link is retained until transfer succeeds; abnormal exit loses proof.
    let retirement = fn() { retire() |> result.map_error(string.inspect) }
    Ok(#(opened, retirement, transfer))
  }
  open_with(ledger, builder, acquire)
}

/// Internal acquisition seam for observing exact publication/transfer boundaries.
/// Production uses `open`; a custom acquisition must retain the same retirement
/// and startup-link contract as `session.open_sqlite_custody`.
///
/// ## Examples
///
/// ```gleam
/// // distill_owner.open_with(ledger, builder, acquisition)
/// ```
@internal
pub fn open_with(
  ledger: weft.Ledger,
  builder: Pid,
  acquire: Acquisition,
) -> Result(Owned, Error) {
  use holder <- result.try(
    sm.new_with_initialiser(1000, fn(subject) {
      let reports = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(reports, Reported)
      sm.initialised(Parked, Book(acquire, fn() { Ok(Nil) }, None, reports))
      |> sm.selecting(selector)
      |> sm.returning(subject)
      |> Ok
    })
    |> sm.on_event(handle)
    |> sm.start
    |> result.map_error(fn(error) { CustodyFailed(string.inspect(error)) }),
  )
  let adoption =
    weft.adopt_under(ledger, parent: builder, owner: holder.pid, cancel: fn() {
      process.send(holder.data, Cancel)
    })
  process.unlink(holder.pid)
  use Nil <- result.try(admitted(adoption) |> result.map_error(CustodyFailed))
  use opened <- result.map(process.call_forever(holder.data, Open))
  Owned(opened, holder.data)
}

fn admitted(adoption: weft.Adoption) -> Result(Nil, String) {
  case adoption {
    weft.Adopted -> Ok(Nil)
    weft.Refused -> Error("distillation custody is cancelling")
  }
}

/// Borrows the session; its retirement remains with the holder.
///
/// ## Examples
///
/// ```gleam
/// // let session = distill_owner.session(owned)
/// ```
@internal
pub fn session(owned: Owned) -> session.Session {
  owned.session
}

/// Closes the resource and observes its original holder exit before returning.
/// A failure never removes the ledger's retirement obligation.
///
/// ## Examples
///
/// ```gleam
/// // distill_owner.close(owned)
/// ```
@internal
pub fn close(owned: Owned) -> Result(Nil, String) {
  use pid <- result.try(
    process.subject_owner(owned.holder)
    |> result.replace_error("distillation holder is unavailable"),
  )
  let watch = process.monitor(pid)
  let result = process.call_forever(owned.holder, Close)
  let result = case result {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) {
        case down.reason {
          process.Normal -> Ok(Nil)
          reason ->
            Error(
              "distillation retirement lost proof: " <> string.inspect(reason),
            )
        }
      })
      |> process.selector_receive_forever
  }
  process.demonitor_process(watch)
  result
}

fn handle(
  phase: Phase,
  book: Book,
  message: Message,
) -> sm.Next(Phase, Book, Message) {
  case phase, message {
    Parked, Open(reply) -> {
      case book.acquire() {
        Ok(#(opened, retire, transfer)) -> {
          let outcome =
            transfer()
            |> result.map_error(fn(error) {
              CustodyFailed(string.inspect(error))
            })
            |> result.replace(opened)
          process.send(reply, outcome)
          sm.transition(Live, Book(..book, retire:))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          sm.stop()
        }
      }
    }
    Parked, Cancel -> sm.stop()
    Live, Close(reply) -> cleaning(Book(..book, reply: Some(reply)))
    Live, Cancel -> cleaning(book)
    Closing, Reported(weft.PulledOutcome(weft.Completed(..))) -> {
      respond(book.reply, Ok(Nil))
      sm.stop()
    }
    Closing, Reported(weft.PulledOutcome(weft.Failed(error:, ..))) ->
      blocked(book, error)
    Closing, Reported(weft.PulledOutcome(weft.Crashed(reason:, ..)))
    | Closing, Reported(weft.PulledOutcome(weft.DrainProofLost(reason:, ..)))
    -> blocked(book, string.inspect(reason))
    Closing, Reported(weft.PulledOutcome(weft.Abandoned(..)))
    | Closing, Reported(weft.PulledOutcome(weft.NeverStarted(..)))
    | Closing, Reported(weft.PulledOutcome(weft.CancellationUnconfirmed(..)))
    -> blocked(book, "distillation cleanup did not confirm retirement")
    Closing, Reported(weft.RunLost(reason)) ->
      blocked(book, string.inspect(reason))
    Closing, Reported(weft.AllDelivered) ->
      blocked(book, "distillation cleanup ended without an account")
    Closing, Reported(weft.NotYet) -> sm.keep(book)
    Blocked(reason), Close(reply) -> {
      process.send(reply, Error(reason))
      sm.keep(book)
    }

    // Acquisition happens exactly once, in the parked phase. A second `Open`
    // is a caller holding a handle it already spent, never a retry.
    Live, Open(reply) | Closing, Open(reply) | Blocked(_), Open(reply) -> {
      process.send(
        reply,
        Error(CustodyFailed("distillation holder is no longer parked")),
      )
      sm.keep(book)
    }

    // Unreachable through `close`, which needs an `Owned` and so an answered
    // `Open`. A parked holder has acquired nothing, so there is nothing to
    // retire and nothing for the caller to keep waiting on.
    Parked, Close(reply) -> {
      process.send(reply, Error("distillation holder has opened nothing"))
      sm.keep(book)
    }

    // A second close during cleanup is the caller asking again for an answer
    // already on its way to the first one.
    Closing, Close(reply) -> {
      process.send(reply, Error("distillation retirement is already pending"))
      sm.keep(book)
    }

    // Cancellation is the builder's death arriving. A parked holder stops
    // without opening anything and a live one begins cleanup, both above; once
    // cleanup is running or has failed there is nothing further to ask for.
    Closing, Cancel | Blocked(_), Cancel -> sm.keep(book)

    // Reports belong to the one cleanup run, which only `Closing` has started.
    // A blocked holder keeps its failure rather than reopening on a late one.
    Parked, Reported(_report)
    | Live, Reported(_report)
    | Blocked(_), Reported(_report)
    -> sm.keep(book)
  }
}

// Cleanup is the only unbounded thing this holder does, and `close` waits for
// its account with no deadline of its own: bounding the caller instead would
// leave the holder's verdict unclaimed. So the bound goes on the run. A close
// that wedges — which is exactly the case `Blocked` exists for — reports
// `Abandoned` at the deadline and blocks, rather than hanging every caller
// behind a SQLite handle that will never answer.
const retirement_deadline_ms = 5000

fn cleaning(book: Book) -> sm.Next(Phase, Book, Message) {
  let _relay =
    weft.new([book.retire])
    |> weft.deadline(retirement_deadline_ms)
    |> weft.start_relayed(to: book.reports)
  sm.transition(Closing, book)
}

fn blocked(book: Book, reason: String) -> sm.Next(Phase, Book, Message) {
  respond(book.reply, Error(reason))
  sm.transition(Blocked(reason), book)
}

fn respond(
  reply: Option(Subject(Result(Nil, String))),
  outcome: Result(Nil, String),
) -> Nil {
  case reply {
    Some(reply) -> process.send(reply, outcome)
    None -> Nil
  }
}
