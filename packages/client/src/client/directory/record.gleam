//// The owner record of one session in the directory store
//// (protocol-change/079).
////
//// A deployment with a `[directory]` table keeps one record per session, at
//// `[loom, sessions, <id>]` in the Khepri store `loom_directory`. The record
//// says which orchestrator owns the session, by distribution node name, and
//// in what state. For a session on an executor that state is `serving` or
//// `{moving, Op, To}`, and every change of ownership is one compare-and-set
//// against the record, so the record is what decides when two daemons race;
//// the catalogue rows only remember what each daemon began.
////
//// A local session, whose checkout is a directory on its orchestrator, never
//// moves, so its record is only where to find it: state `local`. It is written
//// after the session exists, best-effort, and nothing waits on it. Keeping it
//// a state of its own means no move's compare-and-set can take a local
//// session's record as its base: every move write expects `serving` or
//// `moving`, and `local` matches neither.
////
//// The payload is a plain Erlang term, `{loom_owner, 1, Owner, State}`, with
//// `State` one of `serving`, `local` or `{moving, Op, To}`. The Gleam constructors below
//// compile to exactly that term, so encoding is building a value. Decoding is
//// the other direction across a durability boundary (Ra's log and snapshots are
//// on disk), so it is total: a payload with another tag, another version, a
//// node name or operation identity outside its grammar, or any other shape is
//// an error and never an absent record.

import client/distribution
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/result
import storage/catalogue

/// Who owns a session, and in what state.
pub type Record {
  Record(
    /// The owning orchestrator's distribution node name, `name@host`.
    owner: String,
    /// Whether the owner serves the session or is handing it on.
    state: OwnerState,
  )
}

/// The owner's state. The constructors compile to the stored atoms and tuples.
pub type OwnerState {
  /// The owner serves a session on an executor, or will when a client opens
  /// it.
  Serving

  /// The session is local to its owner: its checkout is a directory on the
  /// owner's machine, it never moves, and the record is a lookup hint only.
  Local

  /// The owner has begun handing the session to the node `to` under the move
  /// `op`, and has stopped serving it.
  Moving(
    /// The move's identity, as in `catalogue_session_moves`.
    op: String,
    /// The receiving orchestrator's node name.
    to: String,
  )
}

/// The stored term of a record. The constructor's name and arity make the
/// tuple `{loom_owner, Version, Owner, State}`, so encoding is a constructor
/// call and no Erlang code is needed to build what Khepri stores. It is opaque
/// so that only `encode` makes one.
pub opaque type Payload {
  LoomOwner(version: Int, owner: String, state: OwnerState)
}

/// The marker an orchestrator writes once it has seeded the store from its
/// catalogue, stored as `{loom_migrated, 1}`.
pub opaque type Marker {
  LoomMigrated(version: Int)
}

/// The version this build writes and the only one it reads.
pub const version = 1

/// The store path of a session's record.
///
/// ## Examples
///
/// ```gleam
/// assert record.path("0198c0de-0000-7000-8000-000000000001")
///   == ["loom", "sessions", "0198c0de-0000-7000-8000-000000000001"]
/// ```
pub fn path(session: String) -> List(String) {
  ["loom", "sessions", session]
}

/// The store path of an orchestrator's migration marker.
///
/// ## Examples
///
/// ```gleam
/// assert record.migrated_path("alpha@10.0.0.1")
///   == ["loom", "migrated", "alpha@10.0.0.1"]
/// ```
pub fn migrated_path(node: String) -> List(String) {
  ["loom", "migrated", node]
}

/// The term Khepri stores for a record. It is opaque to the caller, which
/// passes it to the store's writes as the value or the expected value.
///
/// ## Examples
///
/// ```gleam
/// // store.create(id, record.encode(Record("a@h.x", Serving)))
/// ```
pub fn encode(record: Record) -> Payload {
  LoomOwner(version:, owner: record.owner, state: record.state)
}

/// The term Khepri stores for a migration marker.
///
/// ## Examples
///
/// ```gleam
/// // store.put(record.migrated_path(node), record.migrated())
/// ```
pub fn migrated() -> Marker {
  LoomMigrated(version:)
}

/// Decodes a stored payload. Anything that is not a version 1 owner record with
/// valid node names and operation identity is an error naming what it expected.
///
/// ## Examples
///
/// ```gleam
/// // record.decode(payload_read_from_the_store)
/// // -> Ok(Record("a@h.x", Serving))
/// ```
pub fn decode(payload: Dynamic) -> Result(Record, String) {
  decode.run(payload, decoder())
  |> result.replace_error("the directory holds a record this build cannot read")
}

/// Whether a stored payload is a version 1 migration marker.
///
/// ## Examples
///
/// ```gleam
/// // record.is_migrated(payload_read_from_the_store) // -> True
/// ```
pub fn is_migrated(payload: Dynamic) -> Bool {
  decode.run(payload, migrated_decoder()) == Ok(Nil)
}

fn decoder() -> decode.Decoder(Record) {
  use tag <- decode.field(0, atom.decoder())
  use stored <- decode.field(1, decode.int)
  use owner <- decode.field(2, node_name())
  use state <- decode.field(3, state_decoder())
  case atom.to_string(tag) == "loom_owner" && stored == version {
    True -> decode.success(Record(owner:, state:))
    False -> decode.failure(Record(owner:, state:), "a loom_owner record, v1")
  }
}

// `serving` and `local` are atoms and `{moving, Op, To}` a tuple, so they are
// tried in turn and a payload that is none of them fails all three.
fn state_decoder() -> decode.Decoder(OwnerState) {
  decode.one_of(atom_state("serving", Serving), [
    atom_state("local", Local),
    moving_decoder(),
  ])
}

fn atom_state(name: String, state: OwnerState) -> decode.Decoder(OwnerState) {
  use tag <- decode.then(atom.decoder())
  case atom.to_string(tag) == name {
    True -> decode.success(state)
    False -> decode.failure(state, name)
  }
}

fn moving_decoder() -> decode.Decoder(OwnerState) {
  use tag <- decode.field(0, atom.decoder())
  use op <- decode.field(1, move_op())
  use to <- decode.field(2, node_name())
  case atom.to_string(tag) == "moving" {
    True -> decode.success(Moving(op:, to:))
    False -> decode.failure(Moving(op:, to:), "a moving state")
  }
}

fn migrated_decoder() -> decode.Decoder(Nil) {
  use tag <- decode.field(0, atom.decoder())
  use stored <- decode.field(1, decode.int)
  case atom.to_string(tag) == "loom_migrated" && stored == version {
    True -> decode.success(Nil)
    False -> decode.failure(Nil, "a loom_migrated marker, v1")
  }
}

fn node_name() -> decode.Decoder(String) {
  use text <- decode.then(decode.string)
  case distribution.check_node_name("owner", text) {
    Ok(Nil) -> decode.success(text)
    Error(_) -> decode.failure(text, "a node name")
  }
}

fn move_op() -> decode.Decoder(String) {
  use text <- decode.then(decode.string)
  case catalogue.is_move_op(text) {
    True -> decode.success(text)
    False -> decode.failure(text, "a move identity")
  }
}
