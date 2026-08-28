//// The scratch store: the ephemeral, byte-capped key/value space
//// `cap/kv` reads and writes.
////
//// # Ephemeral is the contract, not a limitation
////
//// `cap/kv`'s own module doc says it plainly: "the scratch store may be
//// evicted or reset between calls, so a program must always tolerate a
//// vanished value — `get` returns `Ok(None)`, never an error, when a key
//// is absent. Treat it as a cache, never a database." This actor is
//// exactly that and nothing more. It holds its entries in process
//// memory, it evicts under pressure, and it dies with the session. There
//// is no file, no table and no journal, and adding one would be a
//// different feature with a different name — anything a program wants to
//// keep leaves through a `cap/report` artifact, which is content
//// addressed, durable, and the thing a strand can actually be handed.
////
//// A durable kv was on issue #16's cut list for a reason worth
//// restating: a store a program can write to across sessions is a
//// channel from one execution's model output into a later execution's
//// input, which is prompt injection with a persistence layer. The
//// ephemeral store has the same shape and a lifetime short enough that
//// the operator who started the session is still the one in the room.
////
//// # What bounds it
////
//// Three numbers, each bounding a different way to grow.
////
//// `max_entry_bytes` (256 KiB) refuses one oversized value in band. It
//// is the "this is a cache" line: a program with more than a quarter of
//// a megabyte to stash is holding an artifact, and `report.emit` is
//// where an artifact goes.
////
//// `max_total_bytes` (8 MiB) bounds the whole store, by **evicting**
//// rather than refusing — which is the right direction for a cache and
//// the one `cap/kv` documents. Eviction is least-recently-*written*: the
//// entry whose last `set` is oldest goes first. Not least-recently-used,
//// deliberately — an LRU has to mutate on every read, which makes a
//// `get` a write and a concurrent read storm a rewrite storm, and buys a
//// hit-rate property no program here is shaped to want. A program that
//// wants a value kept re-sets it.
////
//// `max_entries` (1024) bounds the *count*, which the byte cap alone
//// does not: eight megabytes of one-byte values is eight million
//// entries, and every operation here walks the entry list. With both
//// bounds in force the list is at most a thousand long, which is what
//// makes the walk the simplest correct thing rather than a problem.
////
//// # Why an actor, and why one per session
////
//// State shared by every capability call of every execution in the
//// session, mutated by some of them. That is what an actor is for. It is
//// started by the host (`client/serve`) under a process *name*, the same
//// indirection the Agency and the escalation plane use, so the seam that
//// reaches it can be built before it exists and a restart under the same
//// name is the same address. A restart empties it, which the contract
//// permits and this doc says out loud rather than leaving to be
//// discovered.

import codemode/workspace.{type KvRefusal, EntryTooLarge, StoreUnavailable}
import gleam/bit_array
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result

/// The largest value one key may hold.
pub const default_max_entry_bytes = 262_144

/// The largest the whole store may grow before it evicts.
pub const default_max_total_bytes = 8_388_608

/// The most keys the store may hold before it evicts.
pub const default_max_entries = 1024

/// How long a call waits for the store to answer.
///
/// The store does no I/O — every message is a walk of a list bounded by
/// `max_entries` — so a store that has not answered in a second is a
/// store that is wedged, and a capability call is better refused in band
/// than left hanging inside an execution's wall deadline.
pub const default_timeout_ms = 1000

/// What the store is allowed to hold.
///
/// Constructor invariants: every field is positive, and
/// `max_entry_bytes` is at most `max_total_bytes` — a per-entry bound
/// above the total would admit a value the store must immediately evict
/// itself to make room for and then evict again.
pub type Bounds {
  Bounds(max_entry_bytes: Int, max_total_bytes: Int, max_entries: Int)
}

/// The shipped bounds. See the module doc for what each one bounds and
/// why the count bound is not redundant with the byte bound.
pub fn default_bounds() -> Bounds {
  Bounds(
    max_entry_bytes: default_max_entry_bytes,
    max_total_bytes: default_max_total_bytes,
    max_entries: default_max_entries,
  )
}

/// What the store is asked. Opaque: a caller reaches it through `seam`,
/// never by building a message, so there is one place that decides what
/// a wedged or absent store answers.
pub opaque type Message {
  Get(key: String, reply_with: Subject(Option(BitArray)))
  Set(key: String, value: BitArray, reply_with: Subject(Result(Nil, KvRefusal)))
  Delete(key: String, reply_with: Subject(Nil))
  /// How many entries and how many bytes the store holds. For a test and
  /// for an operator's line; nothing in the capability path reads it.
  Stat(reply_with: Subject(#(Int, Int)))
  Stop
}

/// The three closures the workspace seam's `kv.*` arms are built from,
/// bound to one store.
pub type Scratch {
  Scratch(
    get: fn(String) -> Result(Option(BitArray), KvRefusal),
    set: fn(String, BitArray) -> Result(Nil, KvRefusal),
    delete: fn(String) -> Result(Nil, KvRefusal),
  )
}

type Entry {
  Entry(key: String, value: BitArray, bytes: Int)
}

// `entries` is newest-written first, so the eviction victim is the last
// element and a `set` is a prepend. `total_bytes` and `count` are
// tracked rather than recomputed: both are asked on every `set`, and
// `list.length` on every write is the shape lint R5 exists to find.
type State {
  State(bounds: Bounds, entries: List(Entry), total_bytes: Int, count: Int)
}

/// Starts the store under `name`.
///
/// ## Examples
///
/// ```gleam
/// // scratch.start(name, scratch.default_bounds())
/// ```
///
pub fn start(
  name: Name(Message),
  bounds: Bounds,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new(State(bounds:, entries: [], total_bytes: 0, count: 0))
  |> actor.on_message(handle)
  |> actor.named(name)
  |> actor.start
}

/// The store as a supervisable child, which is how a host should wire it.
///
/// A restart empties the store, and that is within the contract: `cap/kv`
/// requires every caller to tolerate a vanished value, so the worst a
/// restart costs a running program is a cache miss it was already written
/// to handle.
pub fn supervised(
  name: Name(Message),
  bounds: Bounds,
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(name, bounds) })
}

/// Stops the store and everything in it.
pub fn stop(name: Name(Message)) -> Nil {
  process.send(process.named_subject(name), Stop)
}

/// The `kv.*` closures over the store registered under `name`.
///
/// Closes over the *name* rather than a subject for the reason
/// `client/agency.seam` does: the seam is built while the configuration
/// is assembled and the store is started later, under a supervisor, and a
/// captured subject would go stale the first time the store restarted.
///
/// A store that is not running, or does not answer inside
/// `timeout_ms`, is `StoreUnavailable` — an in-band refusal the program
/// reads as `cap/kv.KvDenied` — and never a dead caller. `process.call`
/// exits its caller on a timeout or a dead callee, and this runs on the
/// host's served-call process inside a live execution, so the failure
/// mode that must not happen is exactly the one `call` has.
///
/// ## Examples
///
/// ```gleam
/// // scratch.seam(name).get("k") == Ok(option.None)
/// ```
///
pub fn seam(name: Name(Message), timeout_ms timeout_ms: Int) -> Scratch {
  Scratch(
    get: fn(key) { ask(name, timeout_ms, Get(key, _)) },
    // Two `Result`s, because two different things can refuse: the store
    // can be unreachable (the outer one, this module's) and the value can
    // be too large (the inner one, the store's). A program is owed one
    // refusal, so they flatten.
    set: fn(key, value) {
      ask(name, timeout_ms, Set(key, value, _)) |> result.flatten
    },
    delete: fn(key) { ask(name, timeout_ms, Delete(key, _)) },
  )
}

/// The seam a host with no scratch store hands out: every call refuses in
/// band, naming the reason.
///
/// Not a silent success. A `set` that answered `Ok` and a `get` that
/// answered `None` would look to a program exactly like an eviction, and
/// it would loop forever re-setting a key that never lands.
pub fn none() -> Scratch {
  Scratch(
    get: fn(_key) { Error(no_store()) },
    set: fn(_key, _value) { Error(no_store()) },
    delete: fn(_key) { Error(no_store()) },
  )
}

fn no_store() -> KvRefusal {
  StoreUnavailable(
    reason: "this host runs no scratch store, so kv.* is unavailable; keep "
    <> "the value in your program, or emit it as an artifact",
  )
}

fn wedged() -> KvRefusal {
  StoreUnavailable(
    reason: "the scratch store did not answer; treat the value as evicted "
    <> "and carry on",
  )
}

// One question to the store, degrading an absent or wedged store to an
// in-band refusal rather than to the caller's death. Sent and selected by
// hand, watching the callee's monitor, which is the pattern
// `client/escalate.borrow` and `client/gateway.attached` already use for
// the same reason: `process.call` exits its *caller* on a timeout or a
// dead callee, and this runs on a served-call process inside a live
// execution, where a dead caller is a capability call that never settles.
fn ask(
  name: Name(Message),
  timeout_ms: Int,
  message: fn(Subject(answer)) -> Message,
) -> Result(answer, KvRefusal) {
  case process.named(name) {
    Error(Nil) -> Error(no_store())
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(process.named_subject(name), message(reply))
      let answered =
        process.new_selector()
        |> process.select_map(reply, Some)
        |> process.select_specific_monitor(monitor, fn(_down) { None })
        |> process.selector_receive(within: timeout_ms)
      process.demonitor_process(monitor)
      case answered {
        Ok(Some(value)) -> Ok(value)
        Ok(None) | Error(Nil) -> Error(wedged())
      }
    }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Get(key:, reply_with:) -> {
      process.send(reply_with, lookup(state.entries, key))
      actor.continue(state)
    }
    Set(key:, value:, reply_with:) -> {
      let #(state, answer) = store(state, key, value)
      process.send(reply_with, answer)
      actor.continue(state)
    }
    Delete(key:, reply_with:) -> {
      process.send(reply_with, Nil)
      actor.continue(remove(state, key))
    }
    Stat(reply_with:) -> {
      process.send(reply_with, #(state.count, state.total_bytes))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

// A read leaves the write order alone: see the module doc on why this is
// least-recently-written and not least-recently-used.
fn lookup(entries: List(Entry), key: String) -> Option(BitArray) {
  case list.find(entries, fn(entry) { entry.key == key }) {
    Ok(entry) -> Some(entry.value)
    Error(Nil) -> None
  }
}

// Replace-then-prepend-then-evict, in that order. Removing any prior
// value first is what makes the accounting right for an overwrite — the
// old bytes are gone before the new ones are counted — and it is also
// what makes a re-`set` refresh the entry's position in the write order.
fn store(
  state: State,
  key: String,
  value: BitArray,
) -> #(State, Result(Nil, KvRefusal)) {
  let bytes = bit_array.byte_size(value)
  case bytes > state.bounds.max_entry_bytes {
    True -> #(
      state,
      Error(EntryTooLarge(bytes:, limit: state.bounds.max_entry_bytes)),
    )
    False -> {
      let cleared = remove(state, key)
      let admitted =
        State(
          ..cleared,
          entries: [Entry(key:, value:, bytes:), ..cleared.entries],
          total_bytes: cleared.total_bytes + bytes,
          count: cleared.count + 1,
        )
      #(evict(admitted), Ok(Nil))
    }
  }
}

fn remove(state: State, key: String) -> State {
  case list.find(state.entries, fn(entry) { entry.key == key }) {
    Error(Nil) -> state
    Ok(found) ->
      State(
        ..state,
        entries: list.filter(state.entries, fn(entry) { entry.key != key }),
        total_bytes: state.total_bytes - found.bytes,
        count: state.count - 1,
      )
  }
}

// Drops oldest-written entries until both bounds hold. Recursion rather
// than a fold because the condition is over the *accumulated* state and
// the list is walked from the wrong end for a fold anyway; it terminates
// because every step removes an entry and an empty store satisfies both
// bounds (a value larger than `max_total_bytes` cannot get here — the
// per-entry bound refuses it first, and `Bounds` requires the per-entry
// bound to be the smaller of the two).
fn evict(state: State) -> State {
  case
    state.total_bytes > state.bounds.max_total_bytes
    || state.count > state.bounds.max_entries
  {
    False -> state
    True ->
      case list.reverse(state.entries) {
        [] -> state
        [oldest, ..newer] ->
          evict(
            State(
              ..state,
              entries: list.reverse(newer),
              total_bytes: state.total_bytes - oldest.bytes,
              count: state.count - 1,
            ),
          )
      }
  }
}

/// How many entries and how many bytes the store holds right now.
///
/// For a test and for an operator's line. Nothing in the capability path
/// reads it, and no program can reach it: `cap/kv` has no such call.
pub fn stat(name: Name(Message), timeout_ms timeout_ms: Int) -> #(Int, Int) {
  // The eager fallback is right here: a bare tuple of two integers is
  // cheaper to build than the guard that would defer it.
  result.unwrap(ask(name, timeout_ms, Stat), #(0, 0))
}
