//// An in-memory stand-in for the directory store's owner records, for tests
//// that run two orchestrators in one VM (protocol-change/079).
////
//// The real store names owners by node, and two registries in one VM share one
//// node, so their writes could not be told apart. Here each side's ownership
//// has a name of its own ("alpha" and "bravo") and knows its peer's, and the
//// records live in one actor both sides reach. The compare-and-set rules are
//// the store's: a write commits only against the exact value it expects, and a
//// refusal carries what the record holds. A switch makes every write refuse for
//// want of a quorum.

import client/directory/ownership.{type Ownership, Ownership}
import client/directory/record.{type Record, Moving, Record, Serving}
import client/directory/store
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

/// The source's name in the book.
pub const alpha = "alpha@book.test"

/// The receiver's name in the book.
pub const bravo = "bravo@book.test"

type Message {
  Read(session: String, reply: Subject(Option(Record)))
  Swap(
    session: String,
    expected: Option(Record),
    new: Option(Record),
    reply: Subject(Result(Nil, store.WriteRefusal)),
  )
  Put(session: String, new: Option(Record))
  Starve(on: Starving)
}

/// Whether the book refuses every write as if the store had no quorum.
pub type Starving {
  Fed
  Starved
}

type State {
  State(records: Dict(String, Record), starving: Starving)
}

/// The shared records.
pub opaque type Book {
  Book(inbox: Subject(Message))
}

/// Starts an empty book.
pub fn new() -> Book {
  let assert Ok(started) =
    actor.new(State(records: dict.new(), starving: Fed))
    |> actor.on_message(handle)
    |> actor.start
    as "the record book starts"
  Book(inbox: started.data)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Read(session:, reply:) -> {
      process.send(reply, option.from_result(dict.get(state.records, session)))
      actor.continue(state)
    }
    Put(session:, new:) -> actor.continue(put(state, session, new))
    Starve(on:) -> actor.continue(State(..state, starving: on))
    Swap(session:, expected:, new:, reply:) -> {
      let current = option.from_result(dict.get(state.records, session))
      case state.starving, current == expected {
        Starved, _ -> {
          process.send(reply, Error(store.NoQuorum("starved")))
          actor.continue(state)
        }
        Fed, True -> {
          process.send(reply, Ok(Nil))
          actor.continue(put(state, session, new))
        }
        Fed, False -> {
          process.send(reply, Error(store.Mismatch(current)))
          actor.continue(state)
        }
      }
    }
  }
}

fn put(state: State, session: String, new: Option(Record)) -> State {
  case new {
    Some(record) ->
      State(..state, records: dict.insert(state.records, session, record))
    None -> State(..state, records: dict.delete(state.records, session))
  }
}

/// What the book holds for a session.
pub fn read(book: Book, session: String) -> Option(Record) {
  process.call(book.inbox, 1000, Read(session, _))
}

/// Writes a record directly, as the store would hold it.
pub fn set(book: Book, session: String, new: Option(Record)) -> Nil {
  process.send(book.inbox, Put(session, new))
}

/// Makes every write refuse for want of a quorum, or stop refusing.
pub fn starve(book: Book, on: Starving) -> Nil {
  process.send(book.inbox, Starve(on))
}

/// The ownership of `name`, whose moves go to and come from `peer`.
pub fn ownership(book: Book, name: String, peer: String) -> Ownership {
  let swap = fn(session, expected, new) {
    process.call(book.inbox, 1000, Swap(session, expected, new, _))
  }
  let serving = Record(owner: name, state: Serving)
  Ownership(
    node: name,
    read: fn(session) { Ok(read(book, session)) },
    read_consistent: fn(session) { Ok(read(book, session)) },
    create: fn(session) {
      case swap(session, None, Some(serving)) {
        Error(store.Mismatch(Some(found))) if found == serving -> Ok(Nil)
        outcome -> outcome
      }
    },
    begin_move: fn(session, op, _to) {
      let moving = Record(owner: name, state: Moving(op:, to: peer))
      case swap(session, Some(serving), Some(moving)) {
        Error(store.Mismatch(Some(found))) if found == moving -> Ok(Nil)
        outcome -> outcome
      }
    },
    activate: fn(session, op, _from) {
      swap(
        session,
        Some(Record(owner: peer, state: Moving(op:, to: name))),
        Some(serving),
      )
    },
    abandon: fn(session, op, _to) {
      swap(
        session,
        Some(Record(owner: name, state: Moving(op:, to: peer))),
        Some(serving),
      )
    },
    release: fn(session) { swap(session, Some(serving), None) },
    migrated: fn(_node) { Ok(True) },
    mark_migrated: fn() { Ok(Nil) },
    seed_moving: fn(session, op, _to) {
      swap(
        session,
        None,
        Some(Record(owner: name, state: Moving(op:, to: peer))),
      )
    },
  )
}
