//// The second half of deleting a remote session on a directory member
//// (protocol-change/080), shared by the control command and by the movers'
//// periodic pass.
////
//// The first half, `manager.begin_delete`, writes the session's deletion mark
//// in the registry turn that finds no slot open. This half deletes the owner
//// record on the condition that it names this daemon as serving, and only then
//// removes the registration, its mark and its file. A record that is already
//// absent while the mark stands means this daemon's own earlier delete removed
//// it before a crash, and the mark is what proves that intent; absence alone
//// never deletes anything. A record naming someone else, or a move, clears the
//// mark and refuses. A write that did not commit leaves the mark, so admission
//// keeps refusing the session until a later pass finishes it.

import client/daemon/manager
import client/directory/ownership.{type Ownership}
import client/directory/record
import client/directory/store
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import storage/catalogue

/// Why a deletion did not finish.
pub type Refusal {
  /// The record names this daemon as moving the session.
  Moving

  /// The record names another owner.
  NotOwner

  /// The record write did not commit; the mark stays.
  NoQuorum

  /// The registry refused the last step.
  Registry(error: manager.AdminError)
}

/// Deletes the record of a marked session, then the session.
///
/// ## Examples
///
/// ```gleam
/// // deletion.finish(registry, sessions, ownership, session_id)
/// ```
pub fn finish(
  registry: manager.Manager(instance),
  sessions: String,
  ownership: Ownership,
  id: String,
) -> Result(catalogue.Registration, Refusal) {
  case ownership.release(id) {
    Ok(Nil) | Error(store.Mismatch(None)) ->
      manager.finish_delete(registry, id, sessions)
      |> result.map_error(Registry)
    Error(store.Mismatch(Some(found))) -> {
      let _unmarked = manager.unmark_deleting(registry, id)
      case found.state {
        record.Moving(..) if found.owner == ownership.node -> Error(Moving)
        record.Moving(..) | record.Serving | record.Local -> Error(NotOwner)
      }
    }
    Error(store.NoQuorum(_)) -> Error(NoQuorum)
  }
}

/// Tries to finish every marked deletion, for the movers' periodic pass. A
/// deletion that cannot finish yet is left for the next pass.
///
/// ## Examples
///
/// ```gleam
/// // deletion.finish_pending(registry, sessions, ownership)
/// ```
pub fn finish_pending(
  registry: manager.Manager(instance),
  sessions: String,
  ownership: Ownership,
) -> Nil {
  case manager.deleting_sessions(registry) {
    Ok(marked) ->
      list.each(marked, fn(id) {
        let _finished = finish(registry, sessions, ownership, id)
        Nil
      })
    Error(_) -> Nil
  }
}
