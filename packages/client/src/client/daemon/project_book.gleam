//// The daemon's table of running project actors.
////
//// A session's builder runs inside the registry, long before it is known
//// which projects exist, and a project's actor needs the registry to create
//// sessions. A table in a process of its own breaks that circle: the daemon
//// starts it first, the builder asks it for a project's handle when it builds
//// a router or a worker, and `client/daemon/project_start` fills it as actors
//// start. The table holds handles and nothing else; a project's state lives in
//// its actor and its ledger.

import broker/internal/call
import client/daemon/project_host.{type Handle}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/result
import gleam/string
import weft/actor

/// The table's address.
pub opaque type Book {
  Book(inbox: Subject(Message))
}

type Message {
  Put(handle: Handle)
  Get(project: String, reply: Subject(Result(Handle, Nil)))
  All(reply: Subject(List(Handle)))
}

/// Starts the table, linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// // project_book.start()
/// ```
pub fn start() -> Result(Book, String) {
  actor.new_with_initialiser(1000, fn(inbox) {
    actor.initialised(dict.new()) |> actor.returning(inbox) |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Book(started.data) })
  |> result.replace_error("the project table did not start")
}

fn handle(
  table: Dict(String, Handle),
  message: Message,
) -> actor.Next(Dict(String, Handle), Message) {
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
