//// The summary sink: where a settled structural-summary response waits
//// between the effect process that received it and the hook that has to
//// report on it.
////
//// ## Why this exists at all
////
//// The machine's structural loop is deliberately two-step. A nested
//// summary request settles (`ObservedSummaryReturned`, which carries
//// only the *usage* — the ledger row is what the transaction is for),
//// and the runtime then asks the `summary_progress` hook whether the
//// attempt produced a summary, needs another request, or failed. The
//// hook's arguments are `(operation, task_id, attempt)`: the response
//// text is not among them, and that signature is a frozen contract.
////
//// The two halves also run on different processes. `client/wiring`'s
//// dispatch runs on the effect process the driver spawned; the hook
//// runs on the driver itself. So the text needs a rendezvous, and this
//// actor is it — keyed by the same `(operation, task, attempt)` triple
//// the hook is asked about.
////
//// ## What a lost record means
////
//// Nothing here is durable, and it deliberately is not. A record lost
//// to a crash, a reaped effect, or a sink restart reads back as
//// `absent`, which `client/wiring` reports as a **retryable** summary
//// failure — so the machine starts the attempt over and asks the
//// provider again, which is exactly what it does for an orphaned
//// summary request. The alternative, inventing a summary the provider
//// never produced, would publish a `CompactionEntry` whose summary is
//// fiction. Losing the text costs one request; trusting a gap costs the
//// conversation.
////
//// Records are therefore held only long enough to be read: the sink
//// keeps the newest `capacity` of them and drops the oldest beyond
//// that. A session compacts a handful of times; the bound exists so a
//// long-lived server cannot accumulate summary text it will never be
//// asked for again.

import core/ids.{type OpId}
import core/message.{type Usage}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result

/// How many settled summaries the sink holds before evicting the oldest.
pub const capacity = 32

/// How long a record or a read waits on the sink, in milliseconds.
pub const timeout_ms = 5000

/// How one nested summary request settled.
pub type Settlement {
  /// The provider produced summary text.
  Produced(summary: String, usage: Option(Usage))
  /// The request failed. `retryable` is the adapter's own judgment,
  /// carried through so the machine's retry ladder decides rather than
  /// this module.
  Failed(message: String, retryable: Bool)
}

/// What the sink holds for one structural attempt, or `Absent` when it
/// holds nothing — the request never settled here, or its record was
/// evicted or lost with the process that made it.
pub type Record {
  Recorded(settlement: Settlement)
  Absent
}

type Message {
  Put(key: String, settlement: Settlement, reply: Subject(Nil))
  Get(key: String, reply: Subject(Record))
  Halt
}

type State {
  /// `order` is keys oldest-first, and is what bounds `held`.
  State(held: Dict(String, Settlement), order: List(String))
}

/// A running summary sink.
pub opaque type Summaries {
  Summaries(subject: Subject(Message))
}

/// Starts a sink. One per session; `client/wiring` holds it in its
/// config and both ends reach it from there.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(sink) = summaries.start()
/// ```
///
pub fn start() -> Result(Summaries, actor.StartError) {
  actor.new(State(held: dict.new(), order: []))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Summaries(subject: started.data) })
}

/// Stops the sink. Held records are ephemeral by design — a read that
/// finds nothing reports a retryable summary failure — so there is
/// nothing to flush, and this exists so a shutdown leaves no actor
/// behind.
///
/// ## Examples
///
/// ```gleam
/// // summaries.stop(sink)
/// ```
///
pub fn stop(summaries: Summaries) -> Nil {
  process.send(summaries.subject, Halt)
}

/// The sink's pid, for a host that watches the processes whose death
/// ends the server. `Error(Nil)` once it is gone.
///
/// ## Examples
///
/// ```gleam
/// // summaries.pid(sink)
/// ```
///
pub fn pid(summaries: Summaries) -> Result(Pid, Nil) {
  process.subject_owner(summaries.subject)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Halt -> actor.stop()
    Get(key:, reply:) -> {
      let record = case dict.get(state.held, key) {
        Ok(settlement) -> Recorded(settlement:)
        Error(Nil) -> Absent
      }
      process.send(reply, record)
      actor.continue(state)
    }
    Put(key:, settlement:, reply:) -> {
      let order = case dict.has_key(state.held, key) {
        True -> state.order
        False -> list.append(state.order, [key])
      }
      let state =
        evict(State(held: dict.insert(state.held, key, settlement), order:))
      process.send(reply, Nil)
      actor.continue(state)
    }
  }
}

fn evict(state: State) -> State {
  // `list.drop(xs, capacity) != []` answers "more than capacity" in
  // `capacity` steps instead of walking the whole order list.
  case list.drop(state.order, capacity) != [] {
    False -> state
    True ->
      case state.order {
        [] -> state
        [oldest, ..rest] ->
          evict(State(held: dict.delete(state.held, oldest), order: rest))
      }
  }
}

/// The key one structural attempt's settlement is filed under: the same
/// triple `effects.Hooks.summary_progress` is asked about.
///
/// ## Examples
///
/// ```gleam
/// // summaries.key(operation, "task-1", 1)
/// ```
///
pub fn key(operation: OpId, task_id: String, attempt: Int) -> String {
  ids.op_id_to_string(operation)
  <> ":"
  <> task_id
  <> ":"
  <> int.to_string(attempt)
}

/// Files one settlement, synchronously: the caller does not proceed —
/// and so does not let the terminal event reach the driver — until the
/// sink holds it. That ordering is what makes the hook's later read a
/// question about a record that is already there rather than a race.
///
/// A dead sink is not an error here. The record is simply lost, the hook
/// reads `Absent`, and the attempt retries.
///
/// ## Examples
///
/// ```gleam
/// // summaries.record(sink, key, summaries.Produced("…", None))
/// ```
///
pub fn record(
  summaries: Summaries,
  key key: String,
  settlement settlement: Settlement,
) -> Nil {
  case alive(summaries) {
    False -> Nil
    True ->
      process.call(summaries.subject, waiting: timeout_ms, sending: fn(reply) {
        Put(key:, settlement:, reply:)
      })
  }
}

/// Reads what the sink holds for one attempt. `Absent` when it holds
/// nothing, including when the sink itself is gone.
///
/// ## Examples
///
/// ```gleam
/// // summaries.read(sink, key)
/// ```
///
pub fn read(summaries: Summaries, key key: String) -> Record {
  case alive(summaries) {
    False -> Absent
    True ->
      process.call(summaries.subject, waiting: timeout_ms, sending: fn(reply) {
        Get(key:, reply:)
      })
  }
}

// `process.call` exits the caller when the callee is gone, and both ends
// of this sink run on processes whose death must stay in-band: a summary
// effect that crashed would be reported as an orphan rather than as a
// settlement, and a driver must never fault over a lost cache entry.
fn alive(summaries: Summaries) -> Bool {
  case process.subject_owner(summaries.subject) {
    Error(Nil) -> False
    Ok(pid) -> process.is_alive(pid)
  }
}
