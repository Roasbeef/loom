//// Seeding the directory store from an orchestrator's catalogue, once
//// (protocol-change/080).
////
//// A deployment that adds a `[directory]` has its ownership in its catalogues:
//// every remote session an orchestrator serves, plus the `moving`, `moved` and
//// `imported` rows of moves in flight or finished. The first time this
//// orchestrator's store is joined and has a quorum, `seed` writes one record
//// per remote registration, then the marker `[loom, migrated, <node>]`. It is
//// safe to run again: every write is a create or a compare-and-set that
//// accepts a record already holding what it would write, and a run that stops
//// part way writes no marker, so the next run repeats it.
////
//// | Custody row | What is written |
//// |---|---|
//// | resident | `{self, serving}` |
//// | `imported(op, from)` | `{self, serving}`; if the sender already wrote `{from, moving(op, self)}`, the activation compare-and-set instead |
//// | `moving(op, to)` | `{self, moving(op, to)}`; nothing if the record already names `to` as owner, since the move finished and the mover retires |
//// | `moved(op, to)` | nothing; the receiver writes its own |
////
//// A record that names another daemon for a session this catalogue serves is a
//// conflict. It is logged and left standing: the existing record decides, and
//// an operator resolves it. A restored backup is the case that produces one.
//// Until the marker exists this daemon's movers do not act on the store.
////
//// `cover_local` is the second pass, for local sessions. Their records are
//// lookup hints, written after the session exists and never waited on, so
//// the pass runs whenever one may be missing: at boot, and after a local
//// session is created, until a run succeeds. It writes `{self, local}` for
//// every local session whose record is absent from this member's copy, so a
//// creation made without a majority is recorded once the majority returns.

import client/daemon/manager
import client/directory/ownership.{type Ownership}
import client/directory/record.{Moving, Record}
import client/directory/store.{Mismatch, NoQuorum}
import client/orchestrators.{type Orchestrator}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import storage/catalogue
import telemetry/field
import telemetry/log.{type Logger}

/// What one run did.
pub type Seeded {
  /// The marker already existed; nothing was read or written.
  AlreadyDone

  /// Every remote registration was seeded and the marker written.
  Done(
    /// Records written or found already in place.
    written: Int,
    /// Sessions whose record names another daemon, left standing.
    conflicts: List(String),
  )
}

/// Seeds the store from this orchestrator's catalogue unless it already has.
/// An error is a stall: the store had no quorum or the registry did not answer,
/// and the next run starts again.
///
/// ## Examples
///
/// ```gleam
/// // migrate.seed(registry, ownership, config.orchestrators, logger)
/// ```
pub fn seed(
  registry: manager.Manager(instance),
  ownership: Ownership,
  listed: List(Orchestrator),
  logger: Logger,
) -> Result(Seeded, String) {
  use done <- result.try(
    ownership.migrated(ownership.node)
    |> result.map_error(fn(unavailable) { unavailable.reason }),
  )
  case done {
    True -> Ok(AlreadyDone)
    False -> {
      use registrations <- result.try(
        manager.remote_registrations(registry)
        |> result.replace_error("the registry could not list its sessions"),
      )
      use outcomes <- result.try(
        list.try_map(registrations, fn(entry) {
          seed_one(ownership, listed, entry.0, entry.1)
        }),
      )
      let conflicts =
        list.filter_map(outcomes, fn(outcome) {
          case outcome {
            Conflicted(session:) -> Ok(session)
            Written | Skipped -> Error(Nil)
          }
        })
      list.each(conflicts, fn(session) {
        log.warn(logger, "directory.migration_conflict", [
          field.ident("session", session),
        ])
      })
      use Nil <- result.try(
        ownership.mark_migrated()
        |> result.map_error(store.describe_refusal),
      )
      let written = list.count(outcomes, fn(outcome) { outcome == Written })
      log.info(logger, "directory.migrated", [
        field.count("records", written),
        field.count("conflicts", list.length(conflicts)),
      ])
      Ok(Done(written:, conflicts:))
    }
  }
}

// What seeding one registration did.
type Outcome {
  Written
  Skipped
  Conflicted(session: String)
}

fn seed_one(
  ownership: Ownership,
  listed: List(Orchestrator),
  registration: catalogue.Registration,
  custody: catalogue.Custody,
) -> Result(Outcome, String) {
  let id = registration.id
  case custody {
    catalogue.Moved(..) -> Ok(Skipped)
    catalogue.Resident -> serving(ownership, id)
    catalogue.Imported(op:, from:) ->
      case ownership.create(id) {
        Ok(Nil) -> Ok(Written)
        Error(Mismatch(Some(Record(owner:, state: Moving(op: held, to:)))))
          if held == op && to == ownership.node
        -> {
          use from_node <- result.try(node_of(listed, from))
          case owner == from_node {
            True -> activated(ownership, id, op, from_node)
            False -> Ok(Conflicted(id))
          }
        }
        Error(refusal) -> mine_or_conflict(ownership, id, refusal)
      }
    catalogue.Moving(op:, to:) -> {
      use to_node <- result.try(node_of(listed, to))
      case ownership.seed_moving(id, op, to_node) {
        Ok(Nil) -> Ok(Written)
        Error(Mismatch(Some(found))) if found.owner == to_node -> Ok(Skipped)
        Error(refusal) -> mine_or_conflict(ownership, id, refusal)
      }
    }
  }
}

fn serving(ownership: Ownership, id: String) -> Result(Outcome, String) {
  case ownership.create(id) {
    Ok(Nil) -> Ok(Written)
    Error(refusal) -> mine_or_conflict(ownership, id, refusal)
  }
}

fn activated(
  ownership: Ownership,
  id: String,
  op: String,
  from_node: String,
) -> Result(Outcome, String) {
  case ownership.activate(id, op, from_node) {
    Ok(Nil) -> Ok(Written)
    Error(refusal) -> mine_or_conflict(ownership, id, refusal)
  }
}

// A refusal of a seeding write: a record this daemon already holds in any state
// is a repeat, one held by another daemon is a conflict, and no quorum stops the
// run so the next one repeats it.
fn mine_or_conflict(
  ownership: Ownership,
  id: String,
  refusal: store.WriteRefusal,
) -> Result(Outcome, String) {
  case refusal {
    Mismatch(Some(found)) if found.owner == ownership.node -> Ok(Written)
    Mismatch(Some(_)) -> Ok(Conflicted(id))
    Mismatch(None) -> Error("the record vanished while it was being seeded")
    NoQuorum(reason:) -> Error(reason)
  }
}

// The node of an orchestrator a custody row names. A row naming an
// orchestrator this daemon no longer lists cannot be seeded, and the run stops
// with the reason so an operator can restore the row.
fn node_of(listed: List(Orchestrator), name: String) -> Result(String, String) {
  orchestrators.find(listed, name)
  |> result.map(fn(found) { found.node })
  |> result.map_error(fn(_unlisted) {
    "a move names the orchestrator "
    <> name
    <> ", which this daemon no longer lists"
  })
}

/// Writes the owner record of every local session that lacks one, and returns
/// how many it wrote. An error means the store had no quorum or the registry did
/// not answer; the caller runs it again later. A record that names another
/// daemon is logged and left, since a local record decides nothing.
///
/// ## Examples
///
/// ```gleam
/// // migrate.cover_local(registry, ownership, logger) // -> Ok(1)
/// ```
pub fn cover_local(
  registry: manager.Manager(instance),
  ownership: Ownership,
  logger: Logger,
) -> Result(Int, String) {
  use sessions <- result.try(
    manager.local_sessions(registry)
    |> result.replace_error("the registry could not list its sessions"),
  )
  use written <- result.try(
    list.try_map(sessions, fn(id) { cover_one(ownership, logger, id) }),
  )
  Ok(list.count(written, fn(outcome) { outcome == Written }))
}

// One local session: a record already in this member's copy is left alone,
// whoever it names, and an absent one is written.
fn cover_one(
  ownership: Ownership,
  logger: Logger,
  id: String,
) -> Result(Outcome, String) {
  use held <- result.try(
    ownership.read(id)
    |> result.map_error(fn(unavailable) { unavailable.reason }),
  )
  case held {
    Some(Record(owner:, ..)) if owner == ownership.node -> Ok(Skipped)
    Some(_) -> {
      log.warn(logger, "directory.local_record_conflict", [
        field.ident("session", id),
      ])
      Ok(Conflicted(id))
    }
    None ->
      case ownership.record_local(id) {
        Ok(Nil) -> Ok(Written)
        Error(refusal) -> mine_or_conflict(ownership, id, refusal)
      }
  }
}
