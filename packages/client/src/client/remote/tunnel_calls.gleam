//// The table of tunnelled calls an untrusted link holds (protocol-change/117),
//// and every rule for how an entry changes, with no process in sight.
////
//// A session's non-tool callers (goal checks, the Changes tab, the baseline
//// probe and the peer view) clear calls on the executor's broker through the
//// link. The link keeps each such call here, by the request id it minted,
//// never beside the requests it re-sends, because a broker call has no key
//// and must never run twice. The executor on the other end may be hostile and
//// may send any frame at any time, so every frame it can send about a call is
//// an event of this module, and every event ends in one stated outcome.
////
//// The module decides and does not act. `step` takes the table and one event
//// and returns the new table and a list of effects as data: answer an asker,
//// deliver an event to a caller's subject, send `clear_call` or `cancel`,
//// refuse a request at once, forget an entry's monitor, or close the
//// connection for a violation. The link applies them in order. Keeping the
//// decision here is what lets a stateful model test drive arbitrary
//// interleavings of the orchestrator's events and an executor's forged frames
//// without a socket.
////
//// The table is generic in the asker's reply handle and the caller's events
//// handle. The link uses subjects; the model test uses integers, so it can
//// count what each asker heard.
////
//// ## Flow
////
//// `new` → `step` → `entries`
////
//// 1. `new` is the empty table a link starts with.
//// 2. `step` is the transition function. `Opened` admits a request or refuses
////    it; `Cleared`, `EventOutput` and `EventSettled` are the executor's frames,
////    which `from_executor` sorts into dropped, violation and held; the rest
////    are the orchestrator's own events. A violation and a dropped connection
////    both end every entry through `dropped`.
//// 3. `entries` reads the table, for the link's bounds and for the tests.
////
//// ## The rows
////
//// | What happens | Entry | Asker hears | Effect sent |
//// | --- | --- | --- | --- |
//// | `Cleared(Ok)` while clearing | becomes running | `Ok` | none |
//// | `Cleared(Error(r))` while clearing | removed | `Error(r)` | none |
//// | `WaitPassed` while clearing | removed | `BrokerUnavailable` | `cancel` |
//// | `Withdrawn` | removed if held | nothing more | `cancel` if held |
//// | `EventOutput` while running | stays | nothing yet; bytes buffered | none |
//// | `EventSettled` while running | removed | the buffered output, then `CallSettled` | none |
//// | `Cancelled` while running | removed | `ExecutionLost(RelayDown)` | `cancel` |
//// | `AskerDied` | removed | nobody | `cancel` |
//// | `ConnectionDropped` | all removed | `BrokerUnavailable` if clearing, `ExecutionLost(RelayDown)` if running | none |
//// | a frame for a tunnel id no longer held | none | nothing | none (dropped) |
//// | `Cleared` while running, an event while clearing, more output than the limit, or a frame for an id never issued or held as another request | all removed, as for a dropped connection | as for a dropped connection | violation |

import broker/broker
import broker/exec
import broker/framing.{type OutputStream}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list

/// The most tunnelled calls one binding holds at once. A ninth is refused, so
/// a session whose executor holds every entry open is refused its later
/// checks and observations, and no other session is.
pub const max_per_binding = 8

/// The most tunnelled calls one link holds at once.
pub const max_per_link = 64

/// The largest per-stream output limit a tunnelled call may name, the goal
/// check's own cap. The link holds a running call's output until it settles,
/// so this bounds what one entry holds to two streams of this many bytes.
pub const max_call_output_bytes = 1_048_576

/// The tunnelled calls a link holds, by request id.
pub opaque type Table(reply, events) {
  Table(entries: Dict(Int, Entry(reply, events)))
}

/// One tunnelled call.
pub type Entry(reply, events) {
  Entry(
    /// The binding of the session the call clears under.
    binding: BitArray,
    /// Where the asker hears whether the call cleared.
    reply: reply,
    /// Where the caller's events go once the call is running.
    events: events,
    /// The per-stream output limit the spec named, in bytes.
    limit: Int,
    /// How far the call has got.
    state: State,
  )
}

/// How far a tunnelled call has got.
pub type State {
  /// `clear_call` was sent and its `cleared` is awaited.
  Clearing

  /// The call cleared; its output is held until it settles.
  Running(stdout: BitArray, stderr: BitArray)
}

/// What the link knows about the id an executor frame names, before the table
/// is asked. The link holds its other requests and the counter that mints ids,
/// so it is the one that can tell them apart.
pub type Origin {
  /// The id is outside 1 up to the link's next id: never issued.
  Unissued

  /// The id is held by the link as a request of another kind.
  OtherRequest

  /// The id was issued and is not another request's, so it is a tunnelled
  /// call's or was one that has since been removed.
  Issued
}

/// One thing that happens to the table.
pub type Event(reply, events) {
  /// A `Clear` the link has checked against what only it knows (the
  /// connection, the binding, the spec's shape), with the id it would send
  /// it under.
  Opened(
    /// The request id.
    id: Int,
    /// The session's binding.
    binding: BitArray,
    /// The asker's reply handle.
    reply: reply,
    /// The caller's events handle.
    events: events,
    /// The spec's per-stream output limit.
    limit: Int,
  )

  /// The executor's `cleared` for request `id`.
  Cleared(id: Int, answer: Result(Nil, broker.Refusal), origin: Origin)

  /// The executor's `call_event` carrying a chunk of output.
  EventOutput(id: Int, stream: OutputStream, data: BitArray, origin: Origin)

  /// The executor's `call_event` carrying the settlement.
  EventSettled(id: Int, outcome: broker.CallOutcome, origin: Origin)

  /// The clearance wait of request `id` passed.
  WaitPassed(id: Int)

  /// The clearing function's own wait ended and it gave the call up.
  Withdrawn(reply: reply)

  /// The caller called `RunningCall.cancel()`.
  Cancelled(reply: reply)

  /// The asker of request `id` died.
  AskerDied(id: Int)

  /// The connection ended, for whatever reason.
  ConnectionDropped
}

/// What the link must do after a step, in order.
pub type Effect(reply, events) {
  /// Tell the asker whether the call cleared.
  Answer(reply: reply, answer: Result(Nil, broker.Refusal))

  /// Hand one event to the caller.
  Deliver(events: events, event: broker.CallEvent)

  /// Send the `clear_call` frame of request `id`, and arm its clearance wait.
  SendClear(id: Int)

  /// Send `cancel` for request `id`.
  SendCancel(id: Int)

  /// Refuse the request at once with `BrokerUnavailable`; nothing is sent.
  Refuse(reply: reply, reason: String)

  /// Entry `id` left the table: forget its asker's monitor.
  Released(id: Int)

  /// The executor broke the protocol: close the connection.
  Violation(reason: String)
}

/// The empty table a link starts with.
///
/// ## Examples
///
/// ```gleam
/// assert tunnel_calls.entries(tunnel_calls.new()) == []
/// ```
pub fn new() -> Table(reply, events) {
  Table(entries: dict.new())
}

/// The transition function: the table after `event`, and what the link must
/// do. Every row of the proposal's ordering table is one arm here or in the
/// helpers it names.
///
/// ## Examples
///
/// ```gleam
/// let #(table, effects) =
///   tunnel_calls.step(tunnel_calls.new(), tunnel_calls.Opened(
///     id: 1, binding: <<1>>, reply: 1, events: 1, limit: 4096,
///   ))
/// assert effects == [tunnel_calls.SendClear(1)]
/// ```
pub fn step(
  table: Table(reply, events),
  event: Event(reply, events),
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // The executor's three frames are sorted by origin first; the
  // orchestrator's events act on an entry only if it is still held.
  case event {
    Opened(id:, binding:, reply:, events:, limit:) ->
      opened(
        table,
        id,
        Entry(binding:, reply:, events:, limit:, state: Clearing),
      )
    Cleared(id:, answer:, origin:) ->
      from_executor(table, id, origin, fn(entry) {
        cleared(table, id, entry, answer)
      })
    EventOutput(id:, stream:, data:, origin:) ->
      from_executor(table, id, origin, fn(entry) {
        output(table, id, entry, stream, data)
      })
    EventSettled(id:, outcome:, origin:) ->
      from_executor(table, id, origin, fn(entry) {
        settled(table, id, entry, outcome)
      })
    WaitPassed(id:) -> wait_passed(table, id)
    Withdrawn(reply:) -> withdrawn(table, reply)
    Cancelled(reply:) -> cancelled(table, reply)
    AskerDied(id:) -> asker_died(table, id)
    ConnectionDropped -> dropped(table)
  }
}

/// The entries the table holds, by id, in no particular order.
///
/// ## Examples
///
/// ```gleam
/// assert tunnel_calls.entries(tunnel_calls.new()) == []
/// ```
pub fn entries(
  table: Table(reply, events),
) -> List(#(Int, Entry(reply, events))) {
  dict.to_list(table.entries)
}

/// Whether the table holds a call under request `id`, which is how the link
/// knows to read a response for that id as a `cleared`.
///
/// ## Examples
///
/// ```gleam
/// assert !tunnel_calls.holds(tunnel_calls.new(), 1)
/// ```
pub fn holds(table: Table(reply, events), id: Int) -> Bool {
  dict.has_key(table.entries, id)
}

/// Admits a new call or refuses it. The two bounds and the output limit are
/// the table's to check, because they are about what the table holds.
fn opened(
  table: Table(reply, events),
  id: Int,
  entry: Entry(reply, events),
) -> #(Table(reply, events), List(Effect(reply, events))) {
  let on_binding =
    dict.values(table.entries)
    |> list.count(fn(held) { held.binding == entry.binding })

  // A limit of zero would hold nothing, and one past the cap would let a
  // single entry hold more than the link promises; each bound is a refusal
  // that sends nothing.
  case
    entry.limit <= 0 || entry.limit > max_call_output_bytes,
    on_binding >= max_per_binding,
    dict.size(table.entries) >= max_per_link
  {
    True, _, _ -> #(table, [
      Refuse(
        entry.reply,
        "the call's output limit is outside what the link holds",
      ),
    ])
    False, True, _ -> #(table, [
      Refuse(entry.reply, "the session already holds its most tunnelled calls"),
    ])
    False, False, True -> #(table, [
      Refuse(entry.reply, "the link already holds its most tunnelled calls"),
    ])
    False, False, False -> #(
      Table(entries: dict.insert(table.entries, id, entry)),
      [SendClear(id)],
    )
  }
}

/// Sorts an executor frame: an id never issued, or held as another request,
/// is a violation; an issued id the table no longer holds crossed a removal
/// and is dropped; a held one goes to `held`.
fn from_executor(
  table: Table(reply, events),
  id: Int,
  origin: Origin,
  held: fn(Entry(reply, events)) ->
    #(Table(reply, events), List(Effect(reply, events))),
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // A cancel and a `cleared` or an event can cross, and so can a settlement
  // and a second settlement, so a frame for an issued id that is gone is not
  // the executor's fault.
  case origin, dict.get(table.entries, id) {
    Unissued, _ -> broken(table, "a tunnel frame for a request never sent")
    OtherRequest, _ ->
      broken(table, "a tunnel frame for a request that is not a tunnelled call")
    Issued, Error(Nil) -> #(table, [])
    Issued, Ok(entry) -> held(entry)
  }
}

/// The executor's `cleared` for a held entry.
fn cleared(
  table: Table(reply, events),
  id: Int,
  entry: Entry(reply, events),
  answer: Result(Nil, broker.Refusal),
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // Only a clearing entry waits for `cleared`; a second one for a running
  // call is a frame an honest executor never sends.
  case entry.state, answer {
    Clearing, Ok(Nil) -> #(
      Table(entries: dict.insert(
        table.entries,
        id,
        Entry(..entry, state: Running(stdout: <<>>, stderr: <<>>)),
      )),
      [Answer(entry.reply, Ok(Nil))],
    )
    Clearing, Error(refusal) -> #(removed(table, id), [
      Answer(entry.reply, Error(refusal)),
      Released(id),
    ])
    Running(..), _ -> broken(table, "a second clearance for a running call")
  }
}

/// A chunk of a held entry's output: buffered while the stream stays within
/// the spec's limit.
fn output(
  table: Table(reply, events),
  id: Int,
  entry: Entry(reply, events),
  stream: OutputStream,
  data: BitArray,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // An event before the call cleared is out of order; output past the limit
  // is more than the helper could have admitted.
  case entry.state {
    Clearing -> broken(table, "output for a call that has not cleared")
    Running(stdout:, stderr:) -> {
      // Each stream is held to the limit on its own, as the helper caps it.
      let held = case stream {
        framing.Stdout -> stdout
        framing.Stderr -> stderr
      }

      // A stream past the limit ends the connection; within it, the chunk
      // joins the buffer.
      case bit_array.byte_size(held) + bit_array.byte_size(data) > entry.limit {
        True -> broken(table, "more output on a stream than the call's limit")
        False -> #(
          Table(entries: dict.insert(
            table.entries,
            id,
            Entry(..entry, state: appended(stdout, stderr, stream, data)),
          )),
          [],
        )
      }
    }
  }
}

/// A running state with `data` added to the end of one stream's buffer. The
/// buffer grows with a bit-array expression, which the runtime extends in
/// place while the buffer is not shared; `bit_array.append` would copy the
/// whole buffer for every chunk.
fn appended(
  stdout: BitArray,
  stderr: BitArray,
  stream: OutputStream,
  data: BitArray,
) -> State {
  // Only the named stream grows.
  case stream {
    framing.Stdout -> Running(stdout: <<stdout:bits, data:bits>>, stderr:)
    framing.Stderr -> Running(stdout:, stderr: <<stderr:bits, data:bits>>)
  }
}

/// The settlement of a held entry: its buffered output, one `CallOutput` per
/// stream that has bytes, then `CallSettled`.
fn settled(
  table: Table(reply, events),
  id: Int,
  entry: Entry(reply, events),
  outcome: broker.CallOutcome,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // A settlement before the clearance is as out of order as any event.
  case entry.state {
    Clearing -> broken(table, "a settlement for a call that has not cleared")
    Running(stdout:, stderr:) -> {
      let outputs =
        [#(framing.Stdout, stdout), #(framing.Stderr, stderr)]
        |> list.filter(fn(pair) { bit_array.byte_size(pair.1) > 0 })
        |> list.map(fn(pair) {
          let #(stream, bytes) = pair
          Deliver(
            entry.events,
            broker.CallOutput(
              stream:,
              data: bytes,
              total_bytes: bit_array.byte_size(bytes),
              truncated: False,
            ),
          )
        })
      #(
        removed(table, id),
        list.append(outputs, [
          Deliver(entry.events, broker.CallSettled(outcome)),
          Released(id),
        ]),
      )
    }
  }
}

/// The clearance wait passed. A running entry's wait is over already, so only
/// a clearing one is ended.
fn wait_passed(
  table: Table(reply, events),
  id: Int,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // A timer for an entry that cleared or left is stale.
  case dict.get(table.entries, id) {
    Ok(Entry(state: Clearing, reply:, ..)) -> #(removed(table, id), [
      Answer(reply, Error(broker.BrokerUnavailable)),
      SendCancel(id),
      Released(id),
    ])
    Ok(Entry(state: Running(..), ..)) | Error(Nil) -> #(table, [])
  }
}

/// The clearing function gave the call up. Its asker reads nothing more, so
/// nothing is answered.
fn withdrawn(
  table: Table(reply, events),
  reply: reply,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // A withdraw after the entry left changes nothing.
  case held_for(table, reply) {
    Ok(#(id, _entry)) -> #(removed(table, id), [SendCancel(id), Released(id)])
    Error(Nil) -> #(table, [])
  }
}

/// The caller cancelled a running call. The link settles it for the caller
/// at once, as a relay that went down would.
fn cancelled(
  table: Table(reply, events),
  reply: reply,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // Only a running call has a `RunningCall` to cancel through.
  case held_for(table, reply) {
    Ok(#(id, Entry(state: Running(..), events:, ..))) -> #(removed(table, id), [
      Deliver(events, lost()),
      SendCancel(id),
      Released(id),
    ])
    Ok(#(_id, Entry(state: Clearing, ..))) | Error(Nil) -> #(table, [])
  }
}

/// The asker died, so nobody hears anything and the executor is told to stop.
fn asker_died(
  table: Table(reply, events),
  id: Int,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  // A monitor that fired after its entry left has nothing to end.
  case dict.has_key(table.entries, id) {
    True -> #(removed(table, id), [SendCancel(id), Released(id)])
    False -> #(table, [])
  }
}

/// Every entry ends as the connection's loss says: a clearing one is refused,
/// a running one is settled as lost. Nothing is sent, because there is no
/// connection to send on, and nothing is kept for the next one.
fn dropped(
  table: Table(reply, events),
) -> #(Table(reply, events), List(Effect(reply, events))) {
  let effects =
    dict.to_list(table.entries)
    |> list.flat_map(fn(pair) {
      let #(id, entry) = pair

      // What the asker is told depends only on how far its call got.
      case entry.state {
        Clearing -> [
          Answer(entry.reply, Error(broker.BrokerUnavailable)),
          Released(id),
        ]
        Running(..) -> [Deliver(entry.events, lost()), Released(id)]
      }
    })
  #(new(), effects)
}

/// A violation: every entry ends as for a dropped connection, and the link is
/// told to close it.
fn broken(
  table: Table(reply, events),
  reason: String,
) -> #(Table(reply, events), List(Effect(reply, events))) {
  let #(table, effects) = dropped(table)
  #(table, list.append(effects, [Violation(reason)]))
}

/// The entry whose asker holds `reply`.
fn held_for(
  table: Table(reply, events),
  reply: reply,
) -> Result(#(Int, Entry(reply, events)), Nil) {
  dict.to_list(table.entries)
  |> list.find(fn(pair) { { pair.1 }.reply == reply })
}

/// The table without entry `id`.
fn removed(table: Table(reply, events), id: Int) -> Table(reply, events) {
  Table(entries: dict.delete(table.entries, id))
}

/// The settlement a caller hears for a call the link can no longer follow:
/// the one failure that says the effect may have run and must not be
/// replayed, with the link standing where a relay would stand.
fn lost() -> broker.CallEvent {
  broker.CallSettled(broker.CallFailed(exec.ExecutionLost(exec.RelayDown)))
}
