//// The daemon's table of running project actors, and the supervisor that owns
//// them.
////
//// A session's builder runs inside the registry, long before it is known
//// which projects exist, and a project's actor needs the registry to create
//// sessions. A table in a process of its own breaks that circle: the daemon
//// starts it first, the builder asks it for a project's handle when it builds
//// a router or a worker, and `client/daemon/project_start` fills it as actors
//// start. The table holds handles and nothing else; a project's state lives in
//// its actor and its ledger.
////
//// ## Who owns an actor
////
//// A project's actor is the only writer of its ledger, so it must not end
//// because of a process that merely asked for it. An actor started with a plain
//// `start` is linked to its caller, which in the daemon is the handler of a
//// control request or of the boot that reopens projects, and a handler that
//// ends abnormally takes every link down with it: one failed request would
//// stop a project's board and every ticket's worker with it, and nothing
//// would start it again.
////
//// So `start` also starts a supervisor, linked to the daemon's own process,
//// and `launch` starts each actor as that supervisor's child. The children are
//// temporary: a crashed actor is not restarted behind the daemon's back,
//// because its ledger decides what the next one does and the next boot or the
//// next control request starts it again, as it does today. What the supervisor
//// guarantees is the other direction only: an actor lives as long as the
//// daemon, whoever asked for it.

import broker/internal/call
import client/daemon/project_host.{type Handle}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import weft/actor

/// The table's address, and the supervisor the actors it lists run under.
pub opaque type Book {
  Book(
    inbox: Subject(Message),
    actors: factory_supervisor.Supervisor(project_host.Config, Handle),
  )
}

type Message {
  Put(handle: Handle)
  Get(project: String, reply: Subject(Result(Handle, Nil)))
  All(reply: Subject(List(Handle)))
}

/// Starts the table and the supervisor for the project actors, linked to the
/// caller. The daemon calls it once from its own process, so both live as long
/// as the daemon does.
///
/// ## Examples
///
/// ```gleam
/// // project_book.start()
/// ```
pub fn start() -> Result(Book, String) {
  use table <- result.try(
    actor.new_with_initialiser(1000, fn(inbox) {
      actor.initialised(dict.new()) |> actor.returning(inbox) |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
    |> result.replace_error("the project table did not start"),
  )
  use supervisor <- result.map(
    factory_supervisor.worker_child(project_host.start_child)
    |> factory_supervisor.restart_strategy(supervision.Temporary)
    |> factory_supervisor.start
    |> result.map_error(fn(error) {
      "the project supervisor did not start: " <> string.inspect(error)
    }),
  )
  Book(table.data, supervisor.data)
}

/// Starts a project's actor under the supervisor and records its handle. The
/// caller waits while the actor replays its ledger and performs what the last
/// run left queued, and its own ending afterwards, abnormal or not, changes
/// nothing for the actor.
///
/// ## Examples
///
/// ```gleam
/// // project_book.launch(book, config)
/// ```
pub fn launch(
  book: Book,
  config: project_host.Config,
) -> Result(Handle, String) {
  use started <- result.map(
    factory_supervisor.start_child(book.actors, config)
    |> result.map_error(fn(error) {
      "the project actor did not start: " <> string.inspect(error)
    }),
  )
  put(book, started.data)
  started.data
}

/// The table's message handler. It never calls into a project's actor, so a
/// lookup cannot wait on a project that is busy or stopped.
fn handle(
  table: Dict(String, Handle),
  message: Message,
) -> actor.Next(Dict(String, Handle), Message) {
  // A put replaces any earlier handle for the project, which is how a
  // restarted actor takes over its name.
  case message {
    Put(found) -> actor.continue(dict.insert(table, found.project, found))
    Get(project, reply) -> {
      process.send(reply, dict.get(table, project))
      actor.continue(table)
    }
    All(reply) -> {
      process.send(reply, dict.values(table))
      actor.continue(table)
    }
  }
}

/// Records a running project's handle, replacing an earlier one.
///
/// ## Examples
///
/// ```gleam
/// // project_book.put(book, handle)
/// ```
pub fn put(book: Book, found: Handle) -> Nil {
  process.send(book.inbox, Put(found))
}

/// The handle of a running project.
///
/// ## Examples
///
/// ```gleam
/// // project_book.get(book, "p-1a2b3c")
/// ```
pub fn get(book: Book, project: String) -> Result(Handle, Nil) {
  call.try_call(book.inbox, waiting: 2000, sending: Get(project, _))
  |> result.replace_error(Nil)
  |> result.flatten
}

/// Every running project's handle, in no order.
///
/// ## Examples
///
/// ```gleam
/// // project_book.all(book)
/// ```
pub fn all(book: Book) -> List(Handle) {
  call.try_call(book.inbox, waiting: 2000, sending: All)
  |> result.unwrap([])
  |> list.sort(fn(a, b) { string.compare(a.project, b.project) })
}
