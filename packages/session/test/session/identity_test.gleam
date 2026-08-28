//// The canonical session id (`protocol-change/008`): minted once at
//// creation, persisted in the reserved `session/id` cell, read back
//// unchanged on every later open, and projected into the SQLite catalog
//// row so an outside reader can see the parent→child edge without taking
//// the writer lease.

import core/clock
import core/ids
import core/json
import core/register
import core/tx.{Expect, SetRegister, Tx}
import gleam/option.{None, Some}
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import session/session
import simplifile
import storage/sqlite
import storage/storage

fn generator(seed seed: Int) -> ids.Generator {
  ids.generator(clock.stepping(from: 1_700_000_000_000, by: 3), seed:)
}

fn fresh_path(name: String) -> String {
  let _ = simplifile.create_directory_all("build/test_db")
  let path = "build/test_db/" <> name <> ".db"
  let _ = simplifile.delete(path)
  let _ = simplifile.delete(path <> "-wal")
  let _ = simplifile.delete(path <> "-shm")
  path
}

fn open_file(path: String, owner: String) -> session.Session {
  let assert Ok(opened) =
    session.open_sqlite(
      path:,
      owner:,
      lease_ttl_ms: 5000,
      clock: clock.stepping(from: 10_000, by: 1),
    )
    as "the session file opens"
  opened
}

// --- minting --------------------------------------------------------------

pub fn a_fresh_session_has_no_id_until_it_is_ensured_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  assert session.id(sess) == Ok(None)
  let assert Ok(#(minted, _generator)) = session.ensure_id(sess, generator(1))
  assert session.id(sess) == Ok(Some(minted))
}

pub fn ensure_id_is_idempotent_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(#(first, _)) = session.ensure_id(sess, generator(1))
  // A *different* generator on the second call: if the id were minted
  // per call rather than read back, these would differ.
  let assert Ok(#(second, _)) = session.ensure_id(sess, generator(2))
  assert first == second
}

pub fn a_minted_id_round_trips_through_its_durable_form_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(#(minted, _)) = session.ensure_id(sess, generator(7))
  let assert Ok(Some(storage.Register(value:, ..))) =
    storage.get_register(
      sess.store,
      register.FactCustom,
      session.session_id_key,
    )
  assert value.payload == json.String(ids.session_id_to_string(minted))
  assert ids.parse_session_id(ids.session_id_to_string(minted)) == Ok(minted)
}

pub fn two_sessions_mint_distinct_ids_test() {
  let assert Ok(first) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(second) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(#(one, _)) = session.ensure_id(first, generator(11))
  let assert Ok(#(two, _)) = session.ensure_id(second, generator(12))
  assert one != two
}

pub fn a_corrupt_id_cell_is_a_report_not_a_crash_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          SetRegister(
            ns: register.FactCustom,
            key: session.session_id_key,
            value: register.value(json.String("not-a-session-id")),
          ),
        ],
        expected: [
          Expect(
            ns: register.FactCustom,
            key: session.session_id_key,
            seq: None,
          ),
        ],
      ),
    )
  let assert Error(session.SessionCorrupt(..)) = session.id(sess)
}

// --- persistence across close and reopen ----------------------------------

pub fn a_reopened_session_yields_the_same_id_test() {
  let path = fresh_path("identity_reopen")
  let first = open_file(path, "writer-1")
  let assert Ok(#(minted, _)) = session.ensure_id(first, generator(3))
  let assert Ok(Nil) = session.close(first)

  let second = open_file(path, "writer-2")
  // The reopen reads the persisted cell; the fresh generator would mint a
  // different id if anything re-minted here.
  let assert Ok(#(reopened, _)) = session.ensure_id(second, generator(4))
  assert reopened == minted
  assert session.id(second) == Ok(Some(minted))
  let assert Ok(Nil) = session.close(second)
}

pub fn a_session_that_predates_the_id_gains_one_and_keeps_it_test() {
  // A file created and closed without ever ensuring an id is exactly the
  // pre-`protocol-change/008` session: no cell, no catalog record.
  let path = fresh_path("identity_pre_existing")
  let before = open_file(path, "writer-1")
  let assert Ok(Nil) = session.ensure_strand(before, "main", configuration())
  assert session.id(before) == Ok(None)
  let assert Ok(Nil) = session.close(before)
  let assert Ok(#(None, None)) = sqlite.identity(path:)

  let first_open = open_file(path, "writer-2")
  let assert Ok(#(minted, _)) = session.ensure_id(first_open, generator(5))
  let assert Ok(Nil) = session.close(first_open)

  let second_open = open_file(path, "writer-3")
  let assert Ok(#(kept, _)) = session.ensure_id(second_open, generator(6))
  assert kept == minted
  let assert Ok(Nil) = session.close(second_open)
}

// --- the catalog projection ------------------------------------------------

pub fn the_catalog_row_records_the_id_without_a_lease_test() {
  let path = fresh_path("identity_catalog")
  let sess = open_file(path, "writer-1")
  let assert Ok(#(minted, _)) = session.ensure_id(sess, generator(8))
  let assert Ok(Nil) = session.close(sess)
  assert sqlite.identity(path:)
    == Ok(#(Some(ids.session_id_to_string(minted)), None))
}

pub fn the_projection_survives_a_reopen_test() {
  let path = fresh_path("identity_catalog_repair")
  let sess = open_file(path, "writer-1")
  let assert Ok(#(minted, _)) = session.ensure_id(sess, generator(9))
  let assert Ok(Nil) = session.close(sess)

  let reopened = open_file(path, "writer-2")
  let assert Ok(#(_, _)) = session.ensure_id(reopened, generator(10))
  let assert Ok(Nil) = session.close(reopened)
  assert sqlite.identity(path:)
    == Ok(#(Some(ids.session_id_to_string(minted)), None))
}

// A memory session has no catalog to project onto, and `ensure_id` must
// not treat that as a failure.
pub fn a_memory_session_ensures_without_a_catalog_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(#(minted, _)) = session.ensure_id(sess, generator(13))
  assert session.id(sess) == Ok(Some(minted))
  assert session.parent_id(sess) == Ok(None)
}

// --- helpers ---------------------------------------------------------------

fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}
