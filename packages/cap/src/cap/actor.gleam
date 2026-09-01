//// `cap/actor` — typed, program-scoped actors: a deliberately
//// constrained `gen_server` for the cases that earn ongoing state and
//// asynchronous input (watching a build's output and reacting to the
//// first error, a stepping coordinator, a work-stealing queue where
//// items generate items).
////
//// What is *not* here is as important as what is (design §6.5): no links
//// or monitors with custom trap-exit logic, no self-defined supervision
//// strategies, no global registration. The policy is fixed — an actor is
//// spawned linked to whichever process called `spawn`, and killing the
//// satellite reaps them all. Those exotic OTP surfaces are for L3
//// extensions, where a human approved them.
////
//// ## What the link actually propagates
////
//// "All-for-one" describes the common case, not a guarantee that holds
//// from anywhere. The link runs between the actor and its *spawner*, so an
//// abnormal actor crash kills that process — which is the program root
//// when `main` spawned it, and so does fail the program as a unit. An
//// actor spawned inside a `cap/task` branch is linked to that branch's
//// worker instead, so its crash is contained to the branch and reported as
//// a `Crashed` failure; the program carries on. That is fault isolation
//// rather than all-for-one, and it is worth knowing which one a given
//// spawn site gets (M4 triage C-F2).
////
//// ## Bounded mailbox (backpressure, not OOM)
////
//// A BEAM mailbox is unbounded, so this actor keeps its own bounded work
//// queue. `send` admits a message only when the queue has room; when it
//// is full the sender parks inside `send` until a slot frees — real
//// backpressure. Admission is synchronous (the sender waits to be let
//// in); handling is asynchronous (the actor drains its queue on its own
//// turns). Parked senders are bounded by how many processes are pushing
//// at once, never by message rate, so a fast producer cannot grow memory
//// without bound.
////
//// The `Address(state, msg)` type carries both the state and message
//// types, which is what makes `call` and `get` fully typed and the
//// address unforgeable — a program cannot fabricate one without the
//// spawn that produced it.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result

/// The default mailbox bound `spawn` uses.
pub const default_mailbox_limit = 64

const init_timeout_ms = 1000

const admit_timeout_ms = 5000

/// What a message handler decides after handling a message.
pub type Next(state) {
  /// Keep running with this (possibly updated) state.
  Continue(state: state)

  /// Stop the actor.
  Stop
}

/// Continue with a (possibly updated) state — the usual handler return.
pub fn continue(state: state) -> Next(state) {
  Continue(state:)
}

/// Stop the actor after this message.
pub fn stop() -> Next(state) {
  Stop
}

/// An unforgeable handle to a spawned actor. Both type parameters are
/// load-bearing: `msg` types `send`/`call`, `state` types `get`.
pub opaque type Address(state, msg) {
  Address(subject: Subject(In(state, msg)))
}

/// An opaque, single-use reply channel handed to a handler during `call`.
/// The handler answers it with `reply`; the program never sees a raw
/// `Subject`.
pub opaque type Reply(value) {
  Reply(subject: Subject(value))
}

/// Why an actor operation failed.
pub type ActorError {
  /// The actor failed to start.
  StartFailed(message: String)

  /// The mailbox stayed full past the timeout; the message was not
  /// admitted.
  MailboxTimeout

  /// The actor did not answer a `call`/`get` within the timeout.
  NoReply
}

// The internal work item: a user message, or a state query.
type Item(state, msg) {
  UserMsg(message: msg)
  Query(reply: Subject(state))
}

// The actor's real message set. `Admit` is the backpressure gate; the
// sender waits on `ack`. `Drain` is the self-trigger that processes one
// queued item. `Halt` stops the actor.
type In(state, msg) {
  Admit(item: Item(state, msg), ack: Subject(Nil))
  Drain
  Halt
}

type Runner(state, msg) {
  Runner(
    user: state,
    behaviour: fn(state, msg) -> Next(state),
    bound: Int,
    self: Subject(In(state, msg)),
    queue: Queue(Item(state, msg)),
    waiting: List(#(Item(state, msg), Subject(Nil))),
    draining: Bool,
  )
}

// A FIFO queue of O(1) push and amortised O(1) pop, with its length
// tracked rather than recomputed. `front` is popped from directly; `back`
// accumulates pushes in reverse and is only reversed onto `front` once
// the latter runs dry. `len` answers "how many, against the bound" in
// one field read, which is the point: `handle_admit` asks that question
// on every message, and `list.length` beside a `list.append` made
// filling a bounded queue to its bound cost O(bound²) (issue #45).
type Queue(a) {
  Queue(front: List(a), back: List(a), len: Int)
}

fn queue_new() -> Queue(a) {
  Queue(front: [], back: [], len: 0)
}

fn queue_push(queue: Queue(a), item: a) -> Queue(a) {
  Queue(..queue, back: [item, ..queue.back], len: queue.len + 1)
}

// Pops the oldest item, if any. Reversing `back` onto an empty `front` is
// the one O(n) step this structure ever pays, and it is amortised: each
// item is reversed at most once across its whole lifetime in the queue.
fn queue_pop(queue: Queue(a)) -> Result(#(a, Queue(a)), Nil) {
  case queue.front {
    [item, ..rest] ->
      Ok(#(item, Queue(..queue, front: rest, len: queue.len - 1)))
    [] ->
      case list.reverse(queue.back) {
        [] -> Error(Nil)
        [item, ..rest] ->
          Ok(#(item, Queue(front: rest, back: [], len: queue.len - 1)))
      }
  }
}

/// Spawns an actor with a default mailbox bound.
///
/// The handler is `fn(state, message) -> Next(state)`: return
/// `continue(new_state)` to keep running or `stop()` to finish.
pub fn spawn(
  initial_state: state,
  handler: fn(state, msg) -> Next(state),
) -> Result(Address(state, msg), ActorError) {
  spawn_bounded(initial_state, default_mailbox_limit, handler)
}

/// Spawns an actor with an explicit mailbox bound (the maximum number of
/// admitted-but-unhandled messages before senders park).
pub fn spawn_bounded(
  initial_state: state,
  mailbox_limit: Int,
  handler: fn(state, msg) -> Next(state),
) -> Result(Address(state, msg), ActorError) {
  let bound = case mailbox_limit < 1 {
    True -> 1
    False -> mailbox_limit
  }
  actor.new_with_initialiser(init_timeout_ms, fn(subject) {
    let state =
      Runner(
        user: initial_state,
        behaviour: handler,
        bound:,
        self: subject,
        queue: queue_new(),
        waiting: [],
        draining: False,
      )
    actor.initialised(state)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(run)
  |> actor.start
  |> result.map(fn(started) { Address(subject: started.data) })
  |> result.map_error(fn(_) { StartFailed("actor failed to start") })
}

/// Sends a message. Blocks only if the mailbox is full, until a slot
/// frees or the admission timeout lapses (in which case the message is
/// dropped — the actor is stalled or dead).
pub fn send(address: Address(state, msg), message: msg) -> Nil {
  let _ = admit(address.subject, UserMsg(message))
  Nil
}

/// Sends a message that expects a reply and waits for it. The `build`
/// function receives a `Reply` handle to embed in the message; the
/// handler answers it with `reply`.
pub fn call(
  address: Address(state, msg),
  build: fn(Reply(value)) -> msg,
  timeout timeout: Int,
) -> Result(value, ActorError) {
  let reply_subject = process.new_subject()
  let message = build(Reply(subject: reply_subject))
  use _ <- result.try(admit(address.subject, UserMsg(message)))
  case process.receive(reply_subject, timeout) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error(NoReply)
  }
}

/// Answers a `call` from inside a handler.
pub fn reply(reply: Reply(value), value: value) -> Nil {
  process.send(reply.subject, value)
}

/// Reads the actor's current state. Ordered after any messages already
/// admitted from this process.
pub fn get(
  address: Address(state, msg),
  timeout timeout: Int,
) -> Result(state, ActorError) {
  let reply_subject = process.new_subject()
  use _ <- result.try(admit(address.subject, Query(reply: reply_subject)))
  case process.receive(reply_subject, timeout) {
    Ok(state) -> Ok(state)
    Error(Nil) -> Error(NoReply)
  }
}

/// Stops the actor. Fire-and-forget.
pub fn shutdown(address: Address(state, msg)) -> Nil {
  process.send(address.subject, Halt)
}

// Admission: send an Admit and block on its ack. Returns Error when the
// mailbox stays full past the timeout.
fn admit(
  subject: Subject(In(state, msg)),
  item: Item(state, msg),
) -> Result(Nil, ActorError) {
  let ack = process.new_subject()
  process.send(subject, Admit(item:, ack:))
  case process.receive(ack, admit_timeout_ms) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> Error(MailboxTimeout)
  }
}

fn run(
  state: Runner(state, msg),
  message: In(state, msg),
) -> actor.Next(Runner(state, msg), In(state, msg)) {
  case message {
    Admit(item:, ack:) -> handle_admit(state, item, ack)
    Drain -> handle_drain(state)
    Halt -> actor.stop()
  }
}

fn handle_admit(
  state: Runner(state, msg),
  item: Item(state, msg),
  ack: Subject(Nil),
) -> actor.Next(Runner(state, msg), In(state, msg)) {
  case state.queue.len < state.bound {
    True -> {
      process.send(ack, Nil)
      let admitted = Runner(..state, queue: queue_push(state.queue, item))
      actor.continue(kick(admitted))
    }

    // Full: park the sender (do not ack) until a slot frees.
    False ->
      actor.continue(
        Runner(..state, waiting: list.append(state.waiting, [#(item, ack)])),
      )
  }
}

fn handle_drain(
  state: Runner(state, msg),
) -> actor.Next(Runner(state, msg), In(state, msg)) {
  case queue_pop(state.queue) {
    Error(Nil) -> actor.continue(Runner(..state, draining: False))
    Ok(#(item, rest)) ->
      case handle_item(state, item) {
        Error(Nil) -> actor.stop()
        Ok(user) -> continue_draining(state, user, rest)
      }
  }
}

// One item handled: promote the oldest parked sender (if any) into the
// slot it freed, then either schedule another drain turn or, if the
// queue is now empty, stop draining.
fn continue_draining(
  state: Runner(state, msg),
  user: state,
  rest: Queue(Item(state, msg)),
) -> actor.Next(Runner(state, msg), In(state, msg)) {
  let #(queue, waiting) = promote(rest, state.waiting, state.bound)
  let state = Runner(..state, user:, queue:, waiting:)
  case state.queue.len {
    0 -> actor.continue(Runner(..state, draining: False))
    _ -> {
      process.send(state.self, Drain)
      actor.continue(state)
    }
  }
}

// Handle one item. `Error(Nil)` means the handler asked to stop.
fn handle_item(
  state: Runner(state, msg),
  item: Item(state, msg),
) -> Result(state, Nil) {
  case item {
    Query(reply:) -> {
      process.send(reply, state.user)
      Ok(state.user)
    }
    UserMsg(message:) ->
      case state.behaviour(state.user, message) {
        Continue(state: user) -> Ok(user)
        Stop -> Error(Nil)
      }
  }
}

// Schedule a drain turn if one is not already pending.
fn kick(state: Runner(state, msg)) -> Runner(state, msg) {
  case state.draining {
    True -> state
    False -> {
      process.send(state.self, Drain)
      Runner(..state, draining: True)
    }
  }
}

// Move parked senders into the queue (FIFO) while there is room, acking
// each as it is admitted.
fn promote(
  queue: Queue(Item(state, msg)),
  waiting: List(#(Item(state, msg), Subject(Nil))),
  bound: Int,
) -> #(Queue(Item(state, msg)), List(#(Item(state, msg), Subject(Nil)))) {
  case waiting, queue.len < bound {
    [#(item, ack), ..rest], True -> {
      process.send(ack, Nil)
      promote(queue_push(queue, item), rest, bound)
    }
    _, _ -> #(queue, waiting)
  }
}
