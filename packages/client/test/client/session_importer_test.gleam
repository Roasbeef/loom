//// The receiving end of a session move, against a real registry and real files
//// (protocol-change/078, phase 5). The sender is played by the test: it cuts a
//// closed session file with the storage package's export, which is what the
//// real mover does, and sends the pieces and the activation by calling the
//// importer directly.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/executors
import client/internal/ffi_os
import client/orchestrators
import client/remote/protocol
import client/remote/scope
import client/session_importer
import client/session_move
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import session/session
import simplifile
import storage/catalogue
import storage/sqlite
import telemetry/log

const op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e"

const other_op = "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9f"

const alpha_node = "alpha@10.0.0.1"

// A receiver in a directory of its own: a registry over an in-memory
// catalogue, a state root, a sessions directory, and the configuration of an
// orchestrator that lists `alpha` and an executor `box`.
type Rig {
  Rig(
    directory: String,
    store: catalogue.Catalogue,
    registry: manager.Manager(String),
    context: session_importer.Context(String),
  )
}

fn rig(label: String, listed: List(executors.Executor)) -> Rig {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory is known"
  let directory =
    here
    <> "/build/test_db/importer-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  // The counter restarts with every emulator, so a name can repeat across runs
  // and must not find the last run's files in it.
  let _removed = simplifile.delete_all([directory])
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the receiver's state root exists"
  let assert Ok(Nil) = simplifile.create_directory_all(directory <> "/sessions")
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          Ok(record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "importer-test",
      limit: 2,
    )
    as "the registry starts"
  Rig(
    directory:,
    store:,
    registry:,
    context: session_importer.Context(
      registry:,
      state_root: directory,
      sessions_directory: directory <> "/sessions",
      domain_configuration: "",
      clock: clock.fixed(at: 5000),
      orchestrators: [orchestrators.plain("alpha", alpha_node)],
      executors: listed,
      logger: log.discard(),
    ),
  )
}

fn finish(rig: Rig) -> Nil {
  // The registry retires every slot before it exits, and it reads the catalogue
  // while it does, so the catalogue is closed only after it is gone.
  let watch = process.monitor(manager.pid(rig.registry))
  manager.shutdown(rig.registry)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "the registry retires within the test deadline"
  let _closed = catalogue.close(rig.store)
  let _removed = simplifile.delete_all([rig.directory])
  Nil
}

// A session the sender has closed: a file with the given scope cell, cut the way
// a mover cuts it. The result is the session identity, the copy's bytes and its
// digest.
type Cut {
  Cut(session: String, bytes: BitArray, digest: String)
}

fn cut(rig: Rig, seed: Int, cell: scope.Scope) -> Cut {
  cut_with(rig, seed, Some(cell))
}

// The same, for a session whose file may hold no scope cell at all.
fn cut_with(rig: Rig, seed: Int, cell: option.Option(scope.Scope)) -> Cut {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(1_700_000_000_000), seed))
  let session = ids.session_id_to_string(id)
  let source = rig.directory <> "/source-" <> session <> ".db"
  let assert Ok(opened) =
    session.open_sqlite(
      path: source,
      owner: "writer",
      lease_ttl_ms: 30_000,
      clock: clock.fixed(at: 1000),
    )
    as "the source session opens"
  let assert Ok(Nil) = case cell {
    Some(recorded) -> scope.write(opened, recorded)
    None -> Ok(Nil)
  }
  let assert Ok(Nil) = session.close(opened)
  let copy = rig.directory <> "/copy-" <> session
  let assert Ok(digest) =
    sqlite.export_closed(
      path: source,
      to: copy,
      owner: session_move.lease_owner(op),
      clock: clock.fixed(at: 2000),
    )
    as "the source is cut"
  let assert Ok(bytes) = simplifile.read_bits(copy)
  Cut(session:, bytes:, digest:)
}

fn clean() -> scope.Scope {
  scope.Scope(3, Some(protocol.AllRetired), Some("box"))
}

fn box() -> List(executors.Executor) {
  [executors.plain("box", "box@10.0.0.9")]
}

// Sends the copy in pieces of `size` bytes, as the mover does, and answers the
// last verdict.
fn send(rig: Rig, copy: Cut, op: String, size: Int) -> session_move.Verdict {
  send_from(rig, copy, op, size, 0)
}

fn send_from(
  rig: Rig,
  copy: Cut,
  op: String,
  size: Int,
  offset: Int,
) -> session_move.Verdict {
  let total = bit_array.byte_size(copy.bytes)
  let length = int.min(size, total - offset)
  let assert Ok(piece) = bit_array.slice(copy.bytes, offset, length)
  let verdict =
    session_importer.take(
      rig.context,
      session_move.Chunk(
        session: copy.session,
        op:,
        offset:,
        total:,
        bytes: piece,
      ),
    )
  case verdict, offset + length >= total {
    session_move.Accepted, False ->
      send_from(rig, copy, op, size, offset + length)
    other, _ -> other
  }
}

fn hex_digest(bytes: BitArray) -> String {
  bootstrap.sha256(bytes) |> bit_array.base16_encode |> string.lowercase
}

fn manifest() -> session_move.Manifest {
  session_move.Manifest(
    workspace: "repo",
    name: "moved session",
    profile: None,
    executor: "box",
    pool: "",
    subtitle: Some("first words"),
    created_at: 1_700_000_000_000,
  )
}

fn activation(copy: Cut, op: String) -> session_move.Activation {
  session_move.Activation(
    session: copy.session,
    op:,
    from_node: alpha_node,
    digest: copy.digest,
    incarnation: 3,
    manifest: manifest(),
  )
}

fn waiting(rig: Rig, copy: Cut, op: String) -> String {
  session_move.incoming_path(rig.directory, copy.session, op)
}

// --- the pieces -------------------------------------------------------------

pub fn pieces_make_a_complete_copy_only_when_the_last_one_lands_test() {
  let rig = rig("pieces", box())
  let copy = cut(rig, 1, clean())
  let total = bit_array.byte_size(copy.bytes)
  assert total > 4096
  let half = total / 2
  let assert Ok(first) = bit_array.slice(copy.bytes, 0, half)
  let assert Ok(rest) = bit_array.slice(copy.bytes, half, total - half)

  // Half the file is not a copy: no name exists for it, and the move is absent.
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 0, total, first),
    )
    == session_move.Accepted
  assert simplifile.is_file(waiting(rig, copy, op)) == Ok(False)
  assert session_importer.stage(rig.context, copy.session, op)
    == Ok(session_move.Absent)

  // The last piece completes it, byte for byte.
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, half, total, rest),
    )
    == session_move.Accepted
  assert simplifile.read_bits(waiting(rig, copy, op)) == Ok(copy.bytes)
  assert session_importer.stage(rig.context, copy.session, op)
    == Ok(session_move.Received)
  finish(rig)
}

pub fn a_piece_that_does_not_start_where_the_file_stands_is_refused_test() {
  let rig = rig("order", box())
  let copy = cut(rig, 2, clean())
  let total = bit_array.byte_size(copy.bytes)
  let assert Ok(first) = bit_array.slice(copy.bytes, 0, 1000)
  let assert Ok(later) = bit_array.slice(copy.bytes, 2000, 1000)
  let assert Ok(next) = bit_array.slice(copy.bytes, 1000, 1000)

  // Nothing has been received, so a piece in the middle has nowhere to go and
  // the sender is told to begin again.
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 2000, total, later),
    )
    == session_move.Refused(session_move.OutOfOrder(expected: 0))
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 0, total, first),
    )
    == session_move.Accepted

  // A gap and a repeat are both refused with where the file stands, and the
  // file is unchanged by either.
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 2000, total, later),
    )
    == session_move.Refused(session_move.OutOfOrder(expected: 1000))
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 0, total, first),
    )
    == session_move.Accepted
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 1000, total, next),
    )
    == session_move.Accepted
  finish(rig)
}

pub fn a_registry_that_cannot_be_read_gives_no_stage_test() {
  let rig = rig("silent-stage", box())
  let copy = cut(rig, 42, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert session_importer.stage(rig.context, copy.session, op)
    == Ok(session_move.Received)

  // The registry is gone, so the row cannot be read. The copy is on disk, but a
  // stage built from the disk alone could say `Absent` for a session that has
  // already been taken in, and the sender would send the file again.
  let watch = process.monitor(manager.pid(rig.registry))
  manager.shutdown(rig.registry)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "the registry retires within the test deadline"
  assert session_importer.stage(rig.context, copy.session, op) == Error(Nil)
  let _closed = catalogue.close(rig.store)
  let _removed = simplifile.delete_all([rig.directory])
  Nil
}

pub fn a_copy_path_that_cannot_be_examined_gives_no_stage_test() {
  let rig = rig("silent-path", box())
  let copy = cut(rig, 43, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Accepted
  assert session_importer.stage(rig.context, copy.session, op)
    == Ok(session_move.Activated)

  // The directory the copies wait in is replaced by a plain file, so no path
  // below it can be examined. The row says `imported`, and an unplaced copy
  // might be waiting there for all the importer can tell, so `Activated` would
  // let the source retire over a session whose file is not in place.
  let incoming = session_move.incoming_directory(rig.directory)
  let assert Ok(Nil) = simplifile.delete_all([incoming])
  let assert Ok(Nil) = simplifile.write(incoming, "not a directory")
  assert session_importer.stage(rig.context, copy.session, op) == Error(Nil)
  finish(rig)
}

pub fn a_restart_at_zero_replaces_what_was_received_test() {
  let rig = rig("restart", box())
  let copy = cut(rig, 3, clean())
  let total = bit_array.byte_size(copy.bytes)
  let assert Ok(first) = bit_array.slice(copy.bytes, 0, 1000)
  assert session_importer.take(
      rig.context,
      session_move.Chunk(copy.session, op, 0, total, first),
    )
    == session_move.Accepted

  // The sender lost its place and starts the whole file again, which is the
  // only recovery there is. The full send then completes a whole, correct copy.
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert simplifile.read_bits(waiting(rig, copy, op)) == Ok(copy.bytes)

  // A copy already whole is replaced by a new send, not appended to.
  assert send(rig, copy, op, 100_000) == session_move.Accepted
  assert simplifile.read_bits(waiting(rig, copy, op)) == Ok(copy.bytes)
  finish(rig)
}

pub fn a_declared_size_outside_what_a_move_carries_is_refused_test() {
  let rig = rig("size", box())
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 4))
  let session = ids.session_id_to_string(id)
  let refused =
    session_move.Refused(session_move.BadSize(limit: session_move.size_limit))
  assert session_importer.take(
      rig.context,
      session_move.Chunk(session, op, 0, session_move.size_limit + 1, <<1>>),
    )
    == refused
  assert session_importer.take(
      rig.context,
      session_move.Chunk(session, op, 0, 0, <<>>),
    )
    == refused

  // A piece that would run past the declared size is refused too.
  assert session_importer.take(
      rig.context,
      session_move.Chunk(session, op, 0, 2, <<1, 2, 3>>),
    )
    == refused
  assert simplifile.is_file(session_move.part_path(rig.directory, session, op))
    == Ok(False)
  finish(rig)
}

pub fn identities_that_name_files_are_held_to_their_grammars_test() {
  let rig = rig("grammar", box())
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1), 5))
  let session = ids.session_id_to_string(id)
  let malformed = fn(verdict) {
    case verdict {
      session_move.Refused(session_move.Malformed(..)) -> True
      _ -> False
    }
  }
  assert malformed(session_importer.take(
    rig.context,
    session_move.Chunk(session, "../escape", 0, 1, <<1>>),
  ))
  assert malformed(session_importer.take(
    rig.context,
    session_move.Chunk("../../escape", op, 0, 1, <<1>>),
  ))
  assert malformed(session_importer.take(
    rig.context,
    session_move.Chunk("", op, 0, 1, <<1>>),
  ))
  assert list.is_empty(
    case simplifile.read_directory(rig.directory <> "/incoming") {
      Ok(names) -> names
      Error(_) -> []
    },
  )
  finish(rig)
}

// --- the activation ---------------------------------------------------------

pub fn a_verified_copy_becomes_the_session_and_a_repeat_answers_again_test() {
  let rig = rig("activate", box())
  let copy = cut(rig, 10, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  let request = activation(copy, op)
  assert session_importer.activate(rig.context, request)
    == session_move.Accepted

  // The registration is saved with what the manifest said, its file is where the
  // sessions directory puts it and is the copy the sender cut, and the row says
  // where it came from.
  let assert Ok(view) = manager.get(rig.registry, copy.session)
  assert view.registration.state == catalogue.Saved
  assert view.registration.workspace == "repo"
  assert view.registration.name == "moved session"
  assert view.registration.executor == "box"
  assert view.registration.configuration == ""
  assert view.registration.subtitle == Some("first words")
  let placed = rig.directory <> "/sessions/" <> copy.session <> ".db"
  assert view.registration.path == placed
  let assert Ok(on_disk) = simplifile.read_bits(placed)
  assert hex_digest(on_disk) == copy.digest
  assert manager.custody(rig.registry, copy.session)
    == Ok(catalogue.Imported(op:, from: "alpha"))
  assert simplifile.is_file(waiting(rig, copy, op)) == Ok(False)
  assert session_importer.stage(rig.context, copy.session, op)
    == Ok(session_move.Activated)

  // The reply may have been lost. Asking again, with no copy left to check,
  // answers the same.
  assert session_importer.activate(rig.context, request)
    == session_move.Accepted
  finish(rig)
}

pub fn a_repeat_is_accepted_while_the_session_runs_here_and_leaves_its_file_alone_test() {
  let rig = rig("running", box())
  let copy = cut(rig, 41, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  let request = activation(copy, op)
  assert session_importer.activate(rig.context, request)
    == session_move.Accepted

  // The reply was lost, and the owner opened the session here meanwhile. The
  // session has run on the placed file since, which the new bytes stand for.
  let assert Ok(manager.Opening(_operation)) =
    manager.open(rig.registry, copy.session)
  let placed = rig.directory <> "/sessions/" <> copy.session <> ".db"
  let ran = <<"the session ran on this file">>
  let assert Ok(Nil) = simplifile.write_bits(placed, ran)

  // The sender retries, and a late duplicate of the copy is waiting beside it.
  // Both are answered yes: a refusal would send the session back to the source
  // while it runs here. The placed file is not replaced, and the duplicate is
  // removed.
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert simplifile.is_file(waiting(rig, copy, op)) == Ok(True)
  assert session_importer.activate(rig.context, request)
    == session_move.Accepted
  assert simplifile.read_bits(placed) == Ok(ran)
  assert simplifile.is_file(waiting(rig, copy, op)) == Ok(False)

  // Any number of retries are answered the same, and the row is unchanged.
  assert session_importer.activate(rig.context, request)
    == session_move.Accepted
  assert manager.custody(rig.registry, copy.session)
    == Ok(catalogue.Imported(op:, from: "alpha"))
  finish(rig)
}

pub fn a_repeat_of_a_committed_move_is_accepted_whatever_the_sender_is_called_now_test() {
  let rig = rig("renamed", box())
  let copy = cut(rig, 40, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  let request = activation(copy, op)
  assert session_importer.activate(rig.context, request)
    == session_move.Accepted

  // The operator renamed the sender in `[orchestrators]` and restarted between
  // the first activation and the retry. The row recorded `alpha`, and the
  // answer to the retry is the row, not a comparison with today's name.
  let renamed =
    session_importer.Context(..rig.context, orchestrators: [
      orchestrators.plain("charlie", alpha_node),
    ])
  assert session_importer.activate(renamed, request) == session_move.Accepted

  // The sender's row is gone altogether, which is the same promise: the commit
  // exists, so the answer is yes.
  let unlisted = session_importer.Context(..rig.context, orchestrators: [])
  assert session_importer.activate(unlisted, request) == session_move.Accepted
  assert manager.custody(rig.registry, copy.session)
    == Ok(catalogue.Imported(op:, from: "alpha"))

  // A node that is not listed still learns nothing about other moves of the
  // session: a different operation is refused as an unknown source.
  assert session_importer.activate(
      unlisted,
      session_move.Activation(..request, op: other_op),
    )
    == session_move.Refused(session_move.UnknownSource(alpha_node))
  finish(rig)
}

pub fn the_session_the_sender_cut_is_admitted_here_and_keeps_its_cell_test() {
  let rig = rig("opens", box())
  let copy = cut(rig, 11, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Accepted

  // The registry admits it like any other session.
  let assert Ok(manager.Opening(operation)) =
    manager.open(rig.registry, copy.session)
  let _ = operation

  // The cell the sender left is the one an attach at the next incarnation
  // reads: a clean close of incarnation three on the executor `box`.
  let placed = rig.directory <> "/sessions/" <> copy.session <> ".db"
  assert scope.read_at(placed, "reader", clock.fixed(at: 6000))
    == Ok(Some(clean()))
  finish(rig)
}

pub fn a_sender_this_daemon_does_not_list_is_refused_before_anything_is_read_test() {
  let rig = rig("source", box())
  let copy = cut(rig, 12, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  let stranger =
    session_move.Activation(
      ..activation(copy, op),
      from_node: "mallory@10.9.9.9",
    )
  assert session_importer.activate(rig.context, stranger)
    == session_move.Refused(session_move.UnknownSource("mallory@10.9.9.9"))
  assert manager.get(rig.registry, copy.session)
    == Error(manager.Catalogue(catalogue.Missing))
  finish(rig)
}

pub fn a_copy_that_was_never_received_is_refused_test() {
  let rig = rig("nothing", box())
  let copy = cut(rig, 13, clean())
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.NothingReceived)
  assert manager.get(rig.registry, copy.session)
    == Error(manager.Catalogue(catalogue.Missing))
  finish(rig)
}

pub fn a_copy_that_is_not_the_one_cut_is_refused_and_registers_nothing_test() {
  let rig = rig("digest", box())
  let copy = cut(rig, 14, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  let wrong =
    session_move.Activation(
      ..activation(copy, op),
      digest: string.repeat("0", 64),
    )
  assert session_importer.activate(rig.context, wrong)
    == session_move.Refused(session_move.DigestMismatch)
  assert manager.get(rig.registry, copy.session)
    == Error(manager.Catalogue(catalogue.Missing))

  // The sender sends the whole file again and asks with the right digest.
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Accepted
  finish(rig)
}

pub fn a_copy_refused_for_good_is_removed_and_one_a_resend_cures_is_kept_test() {
  let rig = rig("discard", [])
  let copy = cut(rig, 16, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted

  // No executor by that name: sending the same copy again would be refused the
  // same way, so the move is over and the copy goes.
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.NoExecutor("box"))
  assert !file_exists(waiting(rig, copy, op))

  // A digest that does not match is cured by a new send, which replaces the
  // file, so the file stays.
  assert send(rig, copy, other_op, 65_536) == session_move.Accepted
  let wrong =
    session_move.Activation(
      ..activation(copy, other_op),
      digest: string.repeat("0", 64),
    )
  assert session_importer.activate(rig.context, wrong)
    == session_move.Refused(session_move.DigestMismatch)
  assert file_exists(waiting(rig, copy, other_op))
  finish(rig)
}

fn file_exists(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
}

pub fn the_scratch_copy_used_to_read_the_cell_does_not_outlive_the_check_test() {
  let rig = rig("scratch", [])
  let copy = cut(rig, 15, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted

  // The activation reads the cell from a copy of the file, because opening a
  // session file rewrites its header, and the file whose digest was just checked
  // must stay what the sender cut. It is the placed file in the success case
  // above that shows the bytes unchanged. Here the activation refuses after the
  // cell was read, and no scratch file is left beside the incoming copy.
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.NoExecutor("box"))
  let leftovers = case simplifile.read_directory(rig.directory <> "/incoming") {
    Ok(names) -> names
    Error(_) -> []
  }
  assert list.filter(leftovers, fn(name) { string.contains(name, copy.session) })
    == []
  finish(rig)
}

pub fn a_copy_whose_scope_is_not_cleanly_closed_is_refused_test() {
  let rig = rig("unclosed", box())
  let refused = fn(seed: Int, cell: scope.Scope, claimed: Int) {
    let copy = cut(rig, seed, cell)
    assert send(rig, copy, op, 65_536) == session_move.Accepted
    let request =
      session_move.Activation(..activation(copy, op), incarnation: claimed)
    let verdict = session_importer.activate(rig.context, request)
    assert manager.get(rig.registry, copy.session)
      == Error(manager.Catalogue(catalogue.Missing))
    verdict
  }
  let not_closed = fn(verdict) {
    case verdict {
      session_move.Refused(session_move.NotClosed(..)) -> True
      _ -> False
    }
  }

  // The last close was never recorded.
  assert not_closed(refused(20, scope.Scope(3, None, Some("box")), 3))

  // The executor could not prove the scope's cleanup.
  assert not_closed(refused(
    21,
    scope.Scope(3, Some(protocol.UnknownCleanup(2)), Some("box")),
    3,
  ))

  // A clean close, but not the incarnation the sender claims.
  assert not_closed(refused(22, clean(), 4))

  // No scope on an executor at all.
  let bare = cut_with(rig, 23, None)
  assert send(rig, bare, op, 65_536) == session_move.Accepted
  assert not_closed(session_importer.activate(rig.context, activation(bare, op)))
  finish(rig)
}

pub fn an_executor_this_daemon_does_not_list_refuses_the_session_test() {
  let rig = rig("executor", [executors.plain("other", "other@10.0.0.9")])
  let copy = cut(rig, 30, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.NoExecutor("box"))
  finish(rig)
}

pub fn a_manifest_that_disagrees_with_the_scope_about_the_executor_is_refused_test() {
  let rig = rig("disagree", box())
  let copy = cut(rig, 31, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted
  let request =
    session_move.Activation(
      ..activation(copy, op),
      manifest: session_move.Manifest(..manifest(), executor: "other"),
    )
  let assert session_move.Refused(session_move.NotClosed(reason)) =
    session_importer.activate(rig.context, request)
  assert string.contains(reason, "box")
  assert string.contains(reason, "other")
  finish(rig)
}

pub fn a_session_held_here_in_any_other_state_is_a_conflict_test() {
  let rig = rig("conflict", box())
  let copy = cut(rig, 40, clean())
  assert send(rig, copy, op, 65_536) == session_move.Accepted

  // A resident registration with no move row: this daemon serves the session.
  let record =
    catalogue.Registration(
      id: copy.session,
      path: rig.directory <> "/sessions/" <> copy.session <> ".db",
      workspace: "repo",
      name: "already here",
      configuration: "",
      profile: None,
      model: None,
      executor: "box",
      pool: "",
      created_at: 1,
      request_key: "already-here",
      state: catalogue.Reserved,
      subtitle: None,
    )
  assert catalogue.reserve(rig.store, record) == Ok(record)
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.Conflict)

  // Imported under another move is a conflict as well, and does not change.
  let assert Ok(_) =
    catalogue.import_session(
      rig.store,
      copy.session,
      op: other_op,
      from: "alpha",
    )
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.Conflict)
  assert manager.custody(rig.registry, copy.session)
    == Ok(catalogue.Imported(op: other_op, from: "alpha"))
  finish(rig)
}

pub fn a_session_that_comes_back_is_taken_in_over_its_tombstone_test() {
  let rig = rig("return", box())
  let copy = cut(rig, 50, clean())
  assert send(rig, copy, other_op, 65_536) == session_move.Accepted

  // This daemon gave the session away under an earlier move and kept its
  // registration. The returning move brings the file back.
  let record =
    catalogue.Registration(
      id: copy.session,
      path: rig.directory <> "/sessions/" <> copy.session <> ".db",
      workspace: "repo",
      name: "went away",
      configuration: "",
      profile: None,
      model: None,
      executor: "box",
      pool: "",
      created_at: 1,
      request_key: "went-away",
      state: catalogue.Reserved,
      subtitle: None,
    )
  assert catalogue.reserve(rig.store, record) == Ok(record)
  let assert Ok(_) = catalogue.confirm(rig.store, copy.session)
  let assert Ok(_) =
    catalogue.begin_move(rig.store, copy.session, op:, to: "alpha")
  let assert Ok(_) = catalogue.finish_move(rig.store, copy.session, op:)

  // The move that gave it away cannot bring it back, and a new one can.
  assert session_importer.activate(rig.context, activation(copy, op))
    == session_move.Refused(session_move.Conflict)
  assert session_importer.activate(rig.context, activation(copy, other_op))
    == session_move.Accepted
  assert manager.custody(rig.registry, copy.session)
    == Ok(catalogue.Imported(op: other_op, from: "alpha"))
  let assert Ok(view) = manager.get(rig.registry, copy.session)
  assert view.registration.name == "went away"
  assert simplifile.is_file(record.path) == Ok(True)
  finish(rig)
}
