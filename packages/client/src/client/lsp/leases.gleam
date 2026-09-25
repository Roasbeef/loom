//// The ceiling on how many jailed helpers a session may hold for the whole
//// of its life, as opposed to borrowing one for a command.
////
//// A language server is a lease, not a call (ADR-013 §1). It checks a
//// `loom-exec` helper out of the session's pool when it starts and keeps it
//// until it exits, which can be hours. The pool is small on purpose — it
//// clamps to `exec.min_pool_size`..`exec.max_pool_size` — and the rest of the
//// session still needs it: a `bash` call borrows one helper, a code-mode
//// satellite holds another, and each capability call that satellite makes
//// borrows a third while the satellite waits. A lease that took any of those
//// three would turn an ordinary code-mode run into a wait that ends in a
//// refusal. So leases are capped at `pool_size - reserved_helpers`, and a
//// server asked for at the cap is refused with a sentence naming the cap
//// rather than queued behind helpers that may never come back.
////
//// **The scope is the session, because the pool is.** ADR-013 says the pool
//// is per daemon; the code says otherwise. `client/serve.assemble_in` calls
//// `start_effect_plane_in` once per assembled session, so every session owns
//// its own pool of `helper_pool_size` helpers and its own broker, and no
//// helper is ever lent across sessions. A daemon-wide counter would
//// therefore cap one session's leases by another's, which protects nothing:
//// the helpers it would be rationing are not shared. One `Leases` actor is
//// started beside each session's effect plane, from the same pool size.
////
//// **A lease is released by its holder's settlement, or by its holder's
//// death.** The holder is the process that owns the running server — the
//// jailed transport's relay — and it releases explicitly once the broker has
//// said the server's execution settled, because that is the moment the helper
//// is back in the pool. The actor also monitors every holder, so a relay that
//// crashes, or is killed with the manager above it, gives its lease back
//// without anybody having to remember to. Releasing is idempotent: the
//// explicit release and the monitor's can both arrive, and the second finds
//// nothing to do.
////
//// Extension hosts also hold session-lived helpers and are not counted here.
//// ADR-013 files that as a follow-up rather than widening this change.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/int
import gleam/result
import mcp/call
import weft/actor

/// How many helpers of a pool are kept out of reach of session-lived
/// leases: one for a `bash` call, one for a code-mode satellite, and one
/// for the capability call that satellite makes while it waits
/// (ADR-013 §1, "Pool pressure").
pub const reserved_helpers = 3

/// The number of leases a pool of `pool_size` helpers admits:
/// `pool_size - reserved_helpers`, and never below zero.
///
/// At `exec.min_pool_size` (four) that is one, which is exactly the one
/// language server a session runs; at the largest default pool it is
/// thirteen. A pool smaller than the reservation — reachable only in a
/// test, since the boot clamps — admits none.
///
/// ## Examples
///
/// ```gleam
/// assert leases.cap_for(4) == 1
/// assert leases.cap_for(16) == 13
/// assert leases.cap_for(2) == 0
/// ```
///
pub fn cap_for(pool_size: Int) -> Int {
  int.max(pool_size - reserved_helpers, 0)
}

/// The running counter: an actor holding one entry per granted lease.
///
/// Opaque, so a lease can only be granted through `acquire` and given back
/// through `release`.
pub opaque type Leases {
  Leases(subject: Subject(Message))
}

/// One granted lease: the right to hold a helper for the life of one
/// server. Give it back with `release` once that server has settled.
pub opaque type Lease {
  Lease(subject: Subject(Message), id: Int)
}

/// Why a lease was not granted.
pub type Refusal {
  /// Every lease the pool admits is held. `cap` is the ceiling and
  /// `pool_size` the pool it was derived from, so the refusal can say both.
  AtCap(cap: Int, pool_size: Int)

  /// The counter did not answer inside the wait, or is gone. Nothing was
  /// granted that the caller will ever be told about; a grant racing the
  /// timeout is released when the caller's process exits.
  LeasesUnavailable
}

/// A refusal as the sentence a server's `no_server` answer carries.
///
/// ## Examples
///
/// ```gleam
/// assert leases.refusal_text(leases.AtCap(cap: 1, pool_size: 4))
///   == "all 1 session-lived helper lease(s) a pool of 4 admits are held (pool size - 3, the three kept for bash, a code-mode satellite and its nested call)"
/// ```
///
pub fn refusal_text(refusal: Refusal) -> String {
  case refusal {
    AtCap(cap:, pool_size:) ->
      "all "
      <> int.to_string(cap)
      <> " session-lived helper lease(s) a pool of "
      <> int.to_string(pool_size)
      <> " admits are held (pool size - "
      <> int.to_string(reserved_helpers)
      <> ", the three kept for bash, a code-mode satellite and its nested call)"
    LeasesUnavailable -> "the session's helper lease counter did not answer"
  }
}

// What the counter's mailbox carries. `Acquire` and `Held` are exchanges;
// `Release` is a cast, because a holder releasing on its way out must not
// block on the counter; `HolderDown` is the monitor's word for the same
// release when the holder could not say it.
type Message {
  Acquire(holder: Pid, reply: Subject(Result(Lease, Refusal)))
  Release(id: Int)
  HolderDown(monitor: Monitor)
  Held(reply: Subject(Int))
  Stop
}

// The counter's whole state. `held` maps a lease id to the monitor on its
// holder; the ids are never reused, so a late release of an old lease can
// never free a newer one.
type State {
  State(
    self: Subject(Message),
    pool_size: Int,
    cap: Int,
    next_id: Int,
    held: Dict(Int, Monitor),
  )
}

/// Starts the counter for a pool of `pool_size` helpers, linked to the
/// caller, which is the session assembly that also starts the pool.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(counter) = leases.start(exec.min_pool_size)
/// ```
///
pub fn start(pool_size: Int) -> Result(Leases, actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    // Every holder monitor lands on this one selector; the monitor
    // reference is what finds the lease it guards.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) { HolderDown(monitor: down.monitor) })
    actor.initialised(State(
      self: subject,
      pool_size:,
      cap: cap_for(pool_size),
      next_id: 1,
      held: dict.new(),
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Leases(subject: started.data) })
}

/// Asks for a lease on behalf of `holder`, the process that will own the
/// server and release the lease when it settles. The counter monitors
/// `holder`, so its death releases the lease too.
///
/// `waiting` bounds the exchange. It is a monitored try-call rather than
/// `process.call`, because the caller is a relay that owes its client a
/// `TransportClosed` whatever happens here, and a panic would lose it.
///
/// ## Examples
///
/// ```gleam
/// // leases.acquire(counter, holder: process.self(), waiting: 1000)
/// // -> Ok(lease), or Error(AtCap(cap: 1, pool_size: 4))
/// ```
///
pub fn acquire(
  leases: Leases,
  holder holder: Pid,
  waiting timeout: Int,
) -> Result(Lease, Refusal) {
  call.try_call(leases.subject, waiting: timeout, sending: fn(reply) {
    Acquire(holder:, reply:)
  })
  |> result.replace_error(LeasesUnavailable)
  |> result.flatten
}

/// Gives a lease back. Idempotent, and a cast: releasing a lease the
/// counter has already dropped — because its holder's monitor fired
/// first — does nothing.
///
/// ## Examples
///
/// ```gleam
/// // leases.release(lease)
/// ```
///
pub fn release(lease: Lease) -> Nil {
  process.send(lease.subject, Release(id: lease.id))
}

/// How many leases are held right now, for tests and for a status line.
/// `Error(Nil)` when the counter does not answer inside `waiting`.
///
/// ## Examples
///
/// ```gleam
/// // leases.held(counter, waiting: 1000) == Ok(0)
/// ```
///
pub fn held(leases: Leases, waiting timeout: Int) -> Result(Int, Nil) {
  call.try_call(leases.subject, waiting: timeout, sending: Held)
  |> result.replace_error(Nil)
}

/// Stops the counter. Holders keep running; nothing more is granted.
///
/// ## Examples
///
/// ```gleam
/// // leases.stop(counter)
/// ```
///
pub fn stop(leases: Leases) -> Nil {
  process.send(leases.subject, Stop)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    // A grant at the cap is a refusal, never a queue: the helpers a lease
    // would wait for are held by servers that can live for hours.
    Acquire(holder:, reply:) ->
      case dict.size(state.held) >= state.cap {
        True -> {
          process.send(
            reply,
            Error(AtCap(cap: state.cap, pool_size: state.pool_size)),
          )
          actor.continue(state)
        }
        False -> actor.continue(grant(state, holder, reply))
      }

    // An explicit release drops the holder's monitor with the entry, so
    // the monitor cannot later fire against an id that no longer exists.
    Release(id:) -> {
      case dict.get(state.held, id) {
        Ok(monitor) -> process.demonitor_process(monitor)
        Error(Nil) -> Nil
      }
      actor.continue(State(..state, held: dict.delete(state.held, id)))
    }

    // The holder died holding its lease: the relay crashed, or was killed
    // with the manager that started it. Its helper settles on its own
    // through the broker's caller watch; the lease goes now.
    HolderDown(monitor:) -> {
      let held = dict.filter(state.held, fn(_id, held) { held != monitor })
      actor.continue(State(..state, held:))
    }

    Held(reply:) -> {
      process.send(reply, dict.size(state.held))
      actor.continue(state)
    }

    Stop -> actor.stop()
  }
}

// Grants one lease: a fresh id, a monitor on the holder, and the reply.
fn grant(
  state: State,
  holder: Pid,
  reply: Subject(Result(Lease, Refusal)),
) -> State {
  let id = state.next_id
  let monitor = process.monitor(holder)
  process.send(reply, Ok(Lease(subject: state.self, id:)))
  State(..state, next_id: id + 1, held: dict.insert(state.held, id, monitor))
}
