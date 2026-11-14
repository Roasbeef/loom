//// The daemon's untrusted executor rows and the processes that link to them
//// (protocol-change/115).
////
//// An untrusted executor is reached by a link process that registers a name on
//// this node, and a session's placement finds the executor by that name. The
//// daemon used to start every link once, at its start, and forget it. A guest
//// made while the daemon runs was unreachable, and a link that died stayed
//// dead. This module is the one process that owns both facts: the rows, and
//// the pid of the link that serves each of them. `executors.reload` asks it to
//// make the links match a file, and the roster reads its rows when a session is
//// placed.
////
//// ## Who owns a link
////
//// The registry starts each link from its own process and unlinks it at once.
//// Unlinking means a link's crash does not end the registry, and a registry
//// that ended would not end the links, so the next owner replaces what is
//// left. A link's death is seen by the next reload, which reads whether each
//// held pid is alive, logs a dead one and starts the link again. A link is
//// never started while another process holds its name: the registry kills
//// whatever holds it and waits for the name to be free, so a link that an
//// earlier owner left is replaced and never refused as a taken name.
////
//// ## One reload at a time
////
//// A reload reads the file inside the registry's own process, through the
//// `load` function the caller gives. Two reloads are therefore handled in the
//// order their messages arrive, and the second reads the file after the first
//// has applied what it read. One deadline of three seconds (`reconcile_ms`)
//// starts before `load` runs and covers the whole turn, so a slow read leaves
//// less for the links. A row that is not reached by the deadline is `Failed`
//// and is left as it was, and the next reload tries it again. A link is
//// started only when its own timeout (`link_start_ms`) fits in what is left,
//// and the old link of a row is killed only when that start is certain to be
//// tried, so a row never loses its link to a start that was not attempted.
////
//// ## What a reader sees
////
//// The registry answers one message at a time, so `rows` waits while a
//// reconcile runs. Both waits are longer than the turn's bound, so a caller
//// always gets the turn's answer: a reload is never applied and then reported
//// `Unavailable`, and a session placed during a reload sees the rows after it.
//// When the registry does not answer at all, the answer is no rows: placement
//// then finds no untrusted executor, which refuses a session instead of
//// placing it on a row that may be gone.
////
//// ## Flow
////
//// `start` → `reconcile` → `handle` → `loaded` → `perform` → `replace` or
//// `retire`; and `rows` for the roster.
////
//// 1. `reconcile` sends the loader to the registry and waits for the reply.
//// 2. `loaded` checks the caps and plans the steps with `client/executor_reload`.
//// 3. `perform` carries out each step before the deadline.
//// 4. `replace` and `retire` clear the link's name and start or drop a link.

import broker/internal/call
import client/executor_reload.{type Reply, type Row}
import client/executors.{type Executor}
import client/internal/ffi_tls_stream.{type Credentials}
import client/remote/untrusted_link
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor
import weft/poll

/// The deadline of one registry turn, in milliseconds, counted from before the
/// file is read. The client waits five seconds for a reply, and this is inside
/// that.
pub const reconcile_ms = 3000

/// How long a link start is given by the link itself: the initialiser's
/// timeout in `untrusted_link.start`. A start is not begun with less than this
/// left of the deadline, so it ends by the deadline.
const link_start_ms = 1000

/// How long a caller waits for the registry to answer a reconcile.
///
/// The turn is bounded as follows. The deadline is `reconcile_ms` from before
/// `load`. `load` takes a file read and decode and at most one second of
/// ledger wait, so it ends well inside the deadline, or the rest of the turn
/// fails at once. Every later step is gated on the deadline: a kill and the
/// wait for a name are cut at it, and a link start begins only with
/// `link_start_ms` left and ends within that. The turn therefore ends at
/// `reconcile_ms` plus the cost of the replies, and this wait is a full second
/// above it.
const call_ms = 4000

/// How long a caller waits for the rows. It equals `call_ms`, so a read that
/// arrives behind a whole turn still gets an answer instead of an empty list.
const rows_ms = call_ms

/// The registry's address.
pub opaque type Registry {
  Registry(inbox: Subject(Message))
}

/// What the registry needs from the world: starting a link and finding the
/// process that holds a link's name. A test hands in fakes; the daemon uses
/// `production`.
pub type Links {
  Links(
    /// Starts the link for a row and answers its process, linked to the caller.
    start: fn(Row, Credentials) -> Result(Pid, String),
    /// The process that holds the link's name for an executor, if any.
    holder: fn(String) -> Result(Pid, Nil),
  )
}

/// What a reload wants: the executor rows of the file, of which the registry
/// keeps the untrusted ones, and the `[executor_link]` credentials the links
/// present.
pub type Wanted {
  Wanted(rows: List(Executor), credentials: Option(Credentials))
}

/// Why a reconcile gave no reply.
pub type Failure {
  /// The `load` function refused, with its reason, and nothing changed.
  Refused(reason: String)

  /// The registry did not answer in time.
  Unavailable
}

type Message {
  Reconcile(
    load: fn() -> Result(Wanted, String),
    reply: Subject(Result(Reply, Failure)),
  )
  Rows(reply: Subject(List(Executor)))
}

/// A row the registry holds: the executor as the file wrote it and the process
/// of its link.
type Slot {
  Slot(executor: Executor, pid: Pid)
}

/// What the registry process keeps.
type Book {
  Book(
    inbox: Subject(Message),
    links: Links,
    logger: Logger,
    slots: Dict(String, Slot),
    seen: Set(String),
  )
}

/// The links of the daemon: `untrusted_link` processes, registered under
/// `untrusted_link.name_for`, with `logger` as their log.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_links.start(untrusted_links.production(logger), logger)
/// ```
pub fn production(logger: Logger) -> Links {
  Links(
    start: fn(row, credentials) {
      untrusted_link.start(untrusted_link.Config(
        executor: row.name,
        name: untrusted_link.name_for(row.name),
        host: row.host,
        port: row.port,
        pin: row.pin,
        credentials:,
        mint: untrusted_link.strong_binding,
        logger:,
      ))
    },
    holder: fn(executor) { process.named(untrusted_link.name_for(executor)) },
  )
}

/// Starts the registry with no rows, linked to the caller. The daemon calls it
/// once from its own process, so the registry lives as long as the daemon.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(registry) = untrusted_links.start(untrusted_links.production(logger), logger)
/// ```
pub fn start(links: Links, logger: Logger) -> Result(Registry, String) {
  actor.new_with_initialiser(1000, fn(inbox) {
    actor.initialised(Book(inbox, links, logger, dict.new(), set.new()))
    |> actor.returning(inbox)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Registry(started.data) })
  |> result.replace_error("the untrusted executor registry did not start")
}

/// Reads the wanted rows with `load`, inside the registry's process, and
/// brings the links to match them. The reply lists every row that was held or
/// wanted, sorted by name, with what was done to it.
///
/// `load` refusing leaves everything as it was and answers `Refused`. A reply
/// that does not come in time answers `Unavailable`, and the reconcile may
/// still finish afterwards.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_links.reconcile(registry, fn() { Ok(Wanted(rows, link)) })
/// ```
pub fn reconcile(
  registry: Registry,
  load: fn() -> Result(Wanted, String),
) -> Result(Reply, Failure) {
  call.try_call(registry.inbox, waiting: call_ms, sending: Reconcile(load, _))
  |> result.replace_error(Unavailable)
  |> result.flatten
}

/// The untrusted rows the registry holds, sorted by name. A registry that does
/// not answer holds none as far as the caller can tell: the caller then offers
/// no untrusted executor, which is the safe direction to be wrong in.
///
/// ## Examples
///
/// ```gleam
/// // untrusted_links.rows(registry)
/// ```
pub fn rows(registry: Registry) -> List(Executor) {
  call.try_call(registry.inbox, waiting: rows_ms, sending: Rows)
  |> result.unwrap([])
}

/// The registry's message handler.
fn handle(book: Book, message: Message) -> actor.Next(Book, Message) {
  // A reconcile changes the book and answers its reply; a read changes nothing.
  case message {
    Reconcile(load, reply) -> {
      let #(next, answer) = loaded(book, load)
      process.send(reply, answer)
      actor.continue(next)
    }

    Rows(reply) -> {
      process.send(reply, held_rows(book))
      actor.continue(book)
    }
  }
}

/// The held rows, sorted by name.
fn held_rows(book: Book) -> List(Executor) {
  dict.values(book.slots)
  |> list.map(fn(slot) { slot.executor })
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// The row a link is started for, or `Error(Nil)` for a trusted executor,
/// which has no link.
///
/// ## Examples
///
/// ```gleam
/// assert untrusted_links.row_of(executors.plain("box", "n@h")) == Error(Nil)
/// ```
pub fn row_of(executor: Executor) -> Result(Row, Nil) {
  case executor.trust {
    executors.Untrusted(host:, port:, pin:) ->
      Ok(executor_reload.Row(name: executor.name, host:, port:, pin:))
    executors.Trusted -> Error(Nil)
  }
}

/// Runs `load`, checks the caps, and performs the plan.
fn loaded(
  book: Book,
  load: fn() -> Result(Wanted, String),
) -> #(Book, Result(Reply, Failure)) {
  // The deadline starts before the file is read, so a slow read is paid for
  // out of the time the links have.
  let deadline = poll.monotonic().now() + reconcile_ms

  // A refusal from the loader changes nothing, and neither does a cap.
  case load() |> result.try(admitted(book, _)) {
    Error(reason) -> #(book, Error(Refused(reason)))
    Ok(wanted) -> reconciled(book, wanted, deadline)
  }
}

/// The untrusted rows of the file, once they are within the caps.
fn admitted(book: Book, wanted: Wanted) -> Result(Wanted, String) {
  let untrusted =
    list.filter(wanted.rows, fn(executor) { result.is_ok(row_of(executor)) })
  let names = list.map(untrusted, fn(executor) { executor.name })
  use Nil <- result.try(executor_reload.check_rows(list.length(untrusted)))
  use Nil <- result.map(
    executor_reload.check_names(
      set.size(set.union(book.seen, set.from_list(names))),
    ),
  )
  Wanted(..wanted, rows: untrusted)
}

/// Plans against the held rows and performs the steps before the deadline.
fn reconciled(
  book: Book,
  wanted: Wanted,
  deadline: Int,
) -> #(Book, Result(Reply, Failure)) {
  let held =
    dict.values(book.slots)
    |> list.filter_map(fn(slot) {
      use row <- result.map(row_of(slot.executor))
      executor_reload.Held(row:, link: liveness(slot.pid))
    })
  log_dead_links(book.logger, held)
  let by_name =
    list.map(wanted.rows, fn(executor) { #(executor.name, executor) })
    |> dict.from_list
  let planned = executor_reload.plan(held, list.filter_map(wanted.rows, row_of))
  let book =
    Book(..book, seen: set.union(book.seen, set.from_list(dict.keys(by_name))))

  let #(book, steps) =
    list.fold(planned, #(book, []), fn(state, step) {
      let #(book, done) = state
      let #(book, finished) = perform(book, step, by_name, wanted, deadline)
      #(book, [finished, ..done])
    })
  #(book, Ok(executor_reload.reply_of(steps)))
}

/// Logs each held link found dead, which is how a link that ended on its own
/// is noticed: the reload that finds it starts it again.
fn log_dead_links(logger: Logger, held: List(executor_reload.Held)) -> Nil {
  list.each(held, fn(found) {
    case found.link {
      executor_reload.Dead ->
        log.warn(logger, "daemon.untrusted_link_ended", [
          field.text("executor", found.row.name),
        ])
      executor_reload.Alive -> Nil
    }
  })
}

fn liveness(pid: Pid) -> executor_reload.Liveness {
  case process.is_alive(pid) {
    True -> executor_reload.Alive
    False -> executor_reload.Dead
  }
}

/// Carries out one step. A step that cannot be done is `Failed`, and the book is
/// left as it was for that row.
fn perform(
  book: Book,
  step: executor_reload.Step,
  by_name: Dict(String, Executor),
  wanted: Wanted,
  deadline: Int,
) -> #(Book, executor_reload.Step) {
  // Each kind of step has one way to be carried out, and one way to fail.
  let outcome = case step.change, dict.get(by_name, step.name) {
    // The link stays. The file's other keys, which declare the machine, are
    // taken, because they cost no link to change.
    executor_reload.Unchanged, Ok(executor) -> Ok(refreshed(book, executor))
    executor_reload.Unchanged, Error(Nil) -> Ok(book)

    executor_reload.Stopped, _ -> retire(book, step.name, deadline)

    executor_reload.Started, Ok(executor)
    | executor_reload.Restarted, Ok(executor)
    -> replace(book, executor, wanted.credentials, deadline)

    // A started or restarted step always has a wanted row, since `plan`
    // makes one only from a row of the file.
    executor_reload.Started, Error(Nil)
    | executor_reload.Restarted, Error(Nil)
    -> Error("the row is not in the file")

    // `plan` never produces a failed step.
    executor_reload.Failed, _ -> Ok(book)
  }

  // A step that failed leaves the book as it was and says why.
  case outcome {
    Ok(next) -> {
      announce(book.logger, step, None)
      #(next, step)
    }
    Error(reason) -> {
      let failed = executor_reload.Step(..step, change: executor_reload.Failed)
      announce(book.logger, failed, Some(reason))
      #(book, failed)
    }
  }
}

/// Records the file's version of a row whose link stays.
fn refreshed(book: Book, executor: Executor) -> Book {
  case dict.get(book.slots, executor.name) {
    Ok(slot) ->
      Book(
        ..book,
        slots: dict.insert(book.slots, executor.name, Slot(..slot, executor:)),
      )
    Error(Nil) -> book
  }
}

/// Stops the link of a row that is gone and forgets the row.
fn retire(book: Book, name: String, deadline: Int) -> Result(Book, String) {
  use Nil <- result.map(clear_name(book, name, deadline))
  release(book, name)
}

/// Drops the slot of a row.
fn release(book: Book, name: String) -> Book {
  Book(..book, slots: dict.delete(book.slots, name))
}

/// Replaces the link of a row: clears its name, starts a link and records it.
fn replace(
  book: Book,
  executor: Executor,
  credentials: Option(Credentials),
  deadline: Int,
) -> Result(Book, String) {
  use row <- result.try(
    row_of(executor) |> result.replace_error("the row is not untrusted"),
  )
  use credentials <- result.try(option.to_result(
    credentials,
    "there is no [executor_link] to dial with",
  ))

  // The old link is killed only when a start can still be tried afterwards:
  // the wait for its name is cut `link_start_ms` before the deadline.
  use Nil <- result.try(clear_name(
    book,
    executor.name,
    deadline - link_start_ms,
  ))
  use pid <- result.map(book.links.start(row, credentials))

  // The link was started linked to this process. Unlinking means its crash
  // cannot end the registry, and the next reload reads whether it is alive.
  process.unlink(pid)
  let book = release(book, executor.name)
  let slot = Slot(executor:, pid:)
  Book(..book, slots: dict.insert(book.slots, executor.name, slot))
}

/// Kills whatever holds the link's name, a link of this registry or a process
/// an earlier owner left, and waits for the name to be free. The wait is what
/// the reconcile's deadline leaves.
fn clear_name(book: Book, name: String, deadline: Int) -> Result(Nil, String) {
  let remaining = deadline - poll.monotonic().now()

  // Without time left, nothing is attempted, so nothing is half done.
  case remaining > 0, book.links.holder(name) {
    False, _ -> Error("the reload ran out of time before this row")
    True, Error(Nil) -> Ok(Nil)
    True, Ok(holder) -> {
      process.kill(holder)
      freed(book, name, remaining)
    }
  }
}

/// Waits until no process holds the name.
fn freed(book: Book, name: String, within: Int) -> Result(Nil, String) {
  let outcome =
    poll.until(within:, every: 10, attempt: fn() {
      case book.links.holder(name) {
        Error(Nil) -> poll.Done(Nil)
        Ok(_holder) -> poll.Retry
      }
    })

  // The name was freed, or the wait ran out with a process still holding it.
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("the link's name was still held after it was killed")
  }
}

/// Logs a step that is not `Unchanged` at warning level, with the old and new
/// address and pin. A pin is a public value and a key is never in a row.
fn announce(
  logger: Logger,
  step: executor_reload.Step,
  reason: Option(String),
) -> Nil {
  case step.change {
    executor_reload.Unchanged -> Nil
    _changed ->
      log.warn(logger, "daemon.executors_reload", [
        field.text("executor", step.name),
        field.text("change", executor_reload.change_word(step.change)),
        field.text("from", executor_reload.describe(step.held)),
        field.text("to", executor_reload.describe(step.wanted)),
        field.text("reason", option.unwrap(reason, "")),
      ])
  }
}
