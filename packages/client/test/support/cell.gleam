//// A value one process owns and others read and change, for a test whose stubs
//// run in the processes of the code under test.
////
//// A closure handed to the code under test runs in whatever process that code
//// uses, so a test cannot keep a counter in a variable. The cell is the smallest
//// shared state: reads and updates are messages to one process, so every
//// operation is ordered by that process's mailbox and there is no race to wait
//// out.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

/// A cell holding a value of type `a`.
pub opaque type Cell(a) {
  Cell(inbox: Subject(Message(a)))
}

type Message(a) {
  Get(reply: Subject(a))
  Update(change: fn(a) -> a)
}

/// A cell holding `initial`.
///
/// ## Examples
///
/// ```gleam
/// let count = cell.new(0)
/// cell.update(count, fn(held) { held + 1 })
/// assert cell.get(count) == 1
/// ```
pub fn new(initial: a) -> Cell(a) {
  let assert Ok(started) =
    actor.new(initial)
    |> actor.on_message(fn(held, message) {
      case message {
        Get(reply:) -> {
          process.send(reply, held)
          actor.continue(held)
        }
        Update(change:) -> actor.continue(change(held))
      }
    })
    |> actor.start
    as "the cell starts"
  Cell(inbox: started.data)
}

/// The value the cell holds after every update sent before this call.
pub fn get(cell: Cell(a)) -> a {
  process.call(cell.inbox, 5000, Get)
}

/// Replaces the value with `change` applied to it.
pub fn update(cell: Cell(a), change: fn(a) -> a) -> Nil {
  process.send(cell.inbox, Update(change))
}
