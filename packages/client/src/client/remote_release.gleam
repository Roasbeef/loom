//// What a deleted session still owes the orchestrators that ran its subagents
//// (protocol-change/084, phase 2).
////
//// A child that runs on another orchestrator is detached, so it outlives the run
//// that asked for it and is bounded only by its own deadline and the other
//// orchestrator's retention sweep. When the parent session is deleted, nobody is
//// left to read the child's result, and the other orchestrator holds a session
//// and possibly a running child for nothing. The laptop therefore tells each
//// orchestrator that may hold a child: `Release`
//// (`client/remote/orchestrator_port`).
////
//// ## Why a row, and why before the delete
////
//// The session is gone once it is deleted, and so is the stub that said which
//// orchestrators to tell. So the delete first reads the stubs of the closed
//// session file (`stubs_at`), writes one row for each distinct orchestrator that
//// is not refused into the catalogue (`catalogue_remote_releases`), and only then
//// removes the session. The two writes are in that order on purpose, and a crash
//// between them is safe in both directions. Rows without a deleted session
//// release a pair that still has its children's session on the other side,
//// which the next ordinary release or the retention sweep would have ended
//// anyway. A session without rows is the state before this slice: its children
//// run to their deadlines.
////
//// ## The pass
////
//// The rows belong to no session, so the drainer that sends them is not a
//// session's. It is the third instance of the outbox drainer
//// (`client/peer_outbox_drain`), one for the daemon, given `pass` below. Each
//// pass asks for every row once and settles a row when the orchestrator answers:
//// `Ok` means it released, and `Refused` is a definitive no. A refusal is
//// recorded as settled, not retried. Silence leaves the row, and the
//// orchestrator is not asked again in the same pass, the way the other two
//// instances skip a silent peer. The retry interval is the drainer's fixed five
//// seconds.
////
//// A row has no time to live. The thing it concerns, a child on another machine,
//// lives as long as the longest deadline the spawner allows plus its retention
//// (`client/spawners`), so a row that expired sooner could give up on a child
//// that is still running. The only things that end a row are an answer and the
//// orchestrator leaving the configuration, which is itself an answer: the name no
//// longer resolves, and the refusal settles the row.
////
//// ## Flow
////
//// `stubs_at` → `pass` → `release_group`
////
//// 1. `stubs_at` reads the stubs of a closed session file, for the delete that
////    writes the rows and for the move that refuses a live child.
//// 2. `pass` reads the rows once, groups them by orchestrator, and reports
////    whether any is still owed.
//// 3. `release_group` sends the rows of one orchestrator, until the first
////    silence, and settles those that were answered.

import client/peer_mail
import client/peer_outbox_drain.{type Backlog, Clear, Owed, Quick}
import client/remote_child.{type Kept}
import client/remote_spawn.{type Parent}
import core/clock.{type Clock}
import core/register
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import runtime/api
import session/session
import simplifile
import storage/catalogue.{type RemoteRelease}
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}

// How long the lease of one read of a closed file lasts, in milliseconds. The
// read lists one prefix and closes, so this only has to outlast a slow disk; a
// crash leaves the lease to lapse, and the next access steals it.
const file_lease_ttl_ms = 30_000

/// The stubs a closed session file holds, read directly from the file.
///
/// The file is opened under `owner`, which must not be the owner of a running
/// writer, and closed before this returns. A file that is not there holds no
/// stubs. A file that cannot be opened or listed is an error with the storage's
/// reason, and the caller decides what that means: a delete goes on without
/// rows, because a session whose file is unreadable could not have been waited
/// on anyway, and a move refuses.
///
/// ## Examples
///
/// ```gleam
/// // remote_release.stubs_at("/state/sessions/0198c0de.db", "delete-read", clock) == Ok([])
/// ```
pub fn stubs_at(
  path: String,
  owner: String,
  time: Clock,
) -> Result(List(Kept), String) {
  case simplifile.is_file(path) {
    Ok(True) -> {
      use opened <- result.try(
        session.open_sqlite(
          path:,
          owner:,
          lease_ttl_ms: file_lease_ttl_ms,
          clock: time,
        )
        |> result.map_error(fn(error) {
          "the session file "
          <> path
          <> " did not open: "
          <> string.inspect(error)
        }),
      )
      let listed =
        storage.list_registers(
          opened.store,
          register.FactCustom,
          Some(api.remote_child_fact_prefix),
        )
        |> result.map_error(fn(error) {
          "the remote children are unreadable: " <> string.inspect(error)
        })
      let _closed = session.close(opened)
      use cells <- result.map(listed)
      remote_child.kept_of(
        list.map(cells, fn(pair) { #(pair.0, pair.1.value.payload) }),
      )
    }
    Ok(False) | Error(_) -> Ok([])
  }
}

/// The pass of the daemon's release drainer, over the rows the catalogue holds.
///
/// `rows` reads every row still owed, `settle` deletes one, and `release` tells
/// an orchestrator that a parent session was deleted, answering as a call to
/// another orchestrator can end (`client/remote_reach`). The catalogue belongs to
/// the registry, so the caller supplies the first two as calls into it, and the
/// third is `remote_spawner.release_over`. An unreadable list is `Owed`: the rows
/// may exist, and the next pass reads again.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.over(remote_release.pass(rows, settle, release, logger), after)
/// ```
pub fn pass(
  rows: fn() -> Result(List(RemoteRelease), String),
  settle: fn(RemoteRelease) -> Result(Nil, String),
  release: fn(String, Parent) -> Result(Int, peer_mail.Failure),
  logger: Logger,
) -> fn() -> Backlog {
  fn() {
    case rows() {
      Error(reason) -> {
        log.warn(logger, "remote_release.unreadable", [
          field.text("reason", reason),
        ])
        Owed(Quick)
      }
      Ok([]) -> Clear
      Ok(owed) -> {
        let remaining =
          owed
          |> group_by_orchestrator
          |> list.flat_map(fn(group) {
            release_group(group.1, settle, release, logger)
          })
        case remaining {
          [] -> Clear
          [_, ..] -> Owed(Quick)
        }
      }
    }
  }
}

// The rows keyed by the orchestrator they are owed to, in name order, each
// group in the order the rows came.
fn group_by_orchestrator(
  rows: List(RemoteRelease),
) -> List(#(String, List(RemoteRelease))) {
  rows
  |> list.fold(dict.new(), fn(groups, row) {
    dict.upsert(groups, row.orchestrator, fn(found) {
      case found {
        Some(held) -> [row, ..held]
        None -> [row]
      }
    })
  })
  |> dict.to_list
  |> list.map(fn(group) { #(group.0, list.reverse(group.1)) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

// The rows of one orchestrator, sent in order until the first silence. A row
// that was answered is settled and leaves the list. Everything after a silence
// stays owed without being sent, since each would wait out the same deadline to
// learn the same thing.
fn release_group(
  rows: List(RemoteRelease),
  settle: fn(RemoteRelease) -> Result(Nil, String),
  release: fn(String, Parent) -> Result(Int, peer_mail.Failure),
  logger: Logger,
) -> List(RemoteRelease) {
  case rows {
    [] -> []
    [row, ..rest] ->
      case release(row.orchestrator, parent_of(row)) {
        Ok(stopped) ->
          after_answer(row, rest, settle, release, logger, [
            field.count("stopped", stopped),
          ])
        Error(peer_mail.Refused(reason)) ->
          after_answer(row, rest, settle, release, logger, [
            field.text("refused", reason),
          ])
        Error(peer_mail.Unreachable) | Error(peer_mail.NotOpen) -> rows
      }
  }
}

// Settles the row an orchestrator answered and goes on to the rest. A row whose
// settlement the store refused stays owed: the release is idempotent, and the
// next pass sends it again.
fn after_answer(
  row: RemoteRelease,
  rest: List(RemoteRelease),
  settle: fn(RemoteRelease) -> Result(Nil, String),
  release: fn(String, Parent) -> Result(Int, peer_mail.Failure),
  logger: Logger,
  answer: List(field.Field),
) -> List(RemoteRelease) {
  let unsettled = case settle(row) {
    Ok(Nil) -> {
      log.info(
        logger,
        "remote_release.settled",
        list.append(answer, [
          field.text("orchestrator", row.orchestrator),
          field.text("parent", row.parent_session),
        ]),
      )
      []
    }
    Error(reason) -> {
      log.warn(logger, "remote_release.unsettled", [
        field.text("orchestrator", row.orchestrator),
        field.text("reason", reason),
      ])
      [row]
    }
  }
  list.append(unsettled, release_group(rest, settle, release, logger))
}

// The parent a release names. Only the session says what is released, and the
// strand is the one the spawner's profile never reads.
fn parent_of(row: RemoteRelease) -> Parent {
  remote_spawn.Parent(session: row.parent_session, strand: "main")
}
