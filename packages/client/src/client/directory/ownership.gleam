//// The writes an orchestrator makes to the session directory's owner records
//// (protocol-change/081), as one record of functions.
////
//// Every change of ownership is one compare-and-set on one record, and each
//// function here names the exact value it expects, so two daemons racing for a
//// session cannot both succeed. The functions are bound to this daemon's node
//// name: `create` writes this node as owner, `begin_move` expects this node to
//// be serving, `activate` expects the sender to be moving the session to this
//// node, and so on. A test binds two values to two names over one store and
//// races them in one VM.
////
//// Only an orchestrator builds one: an executor that is a directory member
//// votes and replicates but never writes, and the way that is held is that
//// the executor role has no value of this type.
////
//// A repeat of a write that already committed is answered as committed where
//// the record says so unambiguously: a create that finds this node serving,
//// and a `begin_move` that finds the same move already recorded. Everything
//// else is returned as the store's refusal, because what the record holds
//// decides what the caller does next, and only the caller knows.

import client/directory/record.{type Record, Local, Moving, Record, Serving}
import client/directory/store.{type Unavailable, type WriteRefusal, Mismatch}
import gleam/option.{type Option, Some}

/// The directory writes and reads an orchestrator uses.
pub type Ownership {
  Ownership(
    /// This daemon's distribution node name, the owner its writes name.
    node: String,
    /// This member's own copy of a session's record.
    read: fn(String) -> Result(Option(Record), Unavailable),
    /// A session's record after this member has caught up with the leader.
    read_consistent: fn(String) -> Result(Option(Record), Unavailable),
    /// Records this node as the new owner of a remote session it is creating.
    create: fn(String) -> Result(Nil, WriteRefusal),
    /// Records that this node has begun handing a session to `to` under the
    /// move `op`: given the session, the op and the receiver's node.
    begin_move: fn(String, String, String) -> Result(Nil, WriteRefusal),
    /// Takes a session the node `from` is moving to this node under `op`:
    /// given the session, the op and the sender's node.
    activate: fn(String, String, String) -> Result(Nil, WriteRefusal),
    /// Takes back a session this node was moving to `to` under `op`: given the
    /// session, the op and the receiver's node.
    abandon: fn(String, String, String) -> Result(Nil, WriteRefusal),
    /// Deletes the record of a session this node serves.
    release: fn(String) -> Result(Nil, WriteRefusal),
    /// Records this node as the owner of a local session, as a lookup hint.
    /// Best-effort: nothing waits on it, and a record already saying so is
    /// success.
    record_local: fn(String) -> Result(Nil, WriteRefusal),
    /// Deletes the record of a local session this node deleted, best-effort.
    release_local: fn(String) -> Result(Nil, WriteRefusal),
    /// Whether an orchestrator, by node name, has seeded the store from its
    /// catalogue.
    migrated: fn(String) -> Result(Bool, Unavailable),
    /// Records that this node has seeded the store from its catalogue.
    mark_migrated: fn() -> Result(Nil, WriteRefusal),
    /// Creates the record of a session this node was moving to `to` under
    /// `op` when the store was seeded: given the session, the op and the
    /// receiver's node.
    seed_moving: fn(String, String, String) -> Result(Nil, WriteRefusal),
  )
}

/// The ownership of `node` over the VM's directory store.
///
/// ## Examples
///
/// ```gleam
/// // let ownership = ownership.over_store("alpha@10.0.0.1")
/// ```
pub fn over_store(node: String) -> Ownership {
  let serving = Record(owner: node, state: Serving)
  let local = Record(owner: node, state: Local)
  Ownership(
    node:,
    read: store.read,
    read_consistent: store.read_consistent,
    create: fn(session) {
      case store.create(session, serving) {
        Error(Mismatch(Some(found))) if found == serving -> Ok(Nil)
        outcome -> outcome
      }
    },
    begin_move: fn(session, op, to) {
      let moving = Record(owner: node, state: Moving(op:, to:))
      case store.swap(session, serving, moving, store.write_ms) {
        Error(Mismatch(Some(found))) if found == moving -> Ok(Nil)
        outcome -> outcome
      }
    },
    activate: fn(session, op, from) {
      store.swap(
        session,
        Record(owner: from, state: Moving(op:, to: node)),
        serving,
        store.activation_ms,
      )
    },
    abandon: fn(session, op, to) {
      store.swap(
        session,
        Record(owner: node, state: Moving(op:, to:)),
        serving,
        store.write_ms,
      )
    },
    release: fn(session) { store.delete_if(session, serving) },
    record_local: fn(session) {
      case store.create(session, local) {
        Error(Mismatch(Some(found))) if found == local -> Ok(Nil)
        outcome -> outcome
      }
    },
    release_local: fn(session) { store.delete_if(session, local) },
    migrated: store.migrated,
    mark_migrated: fn() { store.mark_migrated(node) },
    seed_moving: fn(session, op, to) {
      let moving = Record(owner: node, state: Moving(op:, to:))
      case store.create(session, moving) {
        Error(Mismatch(Some(found))) if found == moving -> Ok(Nil)
        outcome -> outcome
      }
    },
  )
}
