//// The scope record decides which incarnation an open attaches at, and must
//// read back exactly what it wrote.

import client/remote/protocol
import client/remote/scope
import core/clock
import core/json
import core/register
import core/tx
import gleam/option.{None, Some}
import gleam/string
import session/session
import storage/storage

fn store() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 0))
    as "the store opens"
  opened
}

pub fn the_first_open_attaches_at_one_test() {
  assert scope.attach_at(None) == 1
}

pub fn a_clean_close_attaches_one_higher_test() {
  assert scope.attach_at(Some(scope.Scope(3, Some(protocol.AllRetired), None)))
    == 4
}

pub fn every_other_shape_attaches_at_the_stored_incarnation_test() {
  assert scope.attach_at(Some(scope.Scope(3, None, None))) == 3
  assert scope.attach_at(
      Some(scope.Scope(3, Some(protocol.UnknownCleanup(2)), None)),
    )
    == 3
}

pub fn a_session_with_no_record_reads_as_absent_test() {
  assert scope.read(store()) == Ok(None)
}

pub fn the_record_reads_back_what_was_written_test() {
  let opened = store()
  let each = fn(shape) {
    let assert Ok(Nil) = scope.write(opened, shape)
    assert scope.read(opened) == Ok(Some(shape))
  }
  each(scope.Scope(1, None, None))
  each(scope.Scope(1, None, Some("box")))
  each(scope.Scope(2, Some(protocol.AllRetired), Some("build-box")))
  each(scope.Scope(7, Some(protocol.UnknownCleanup(3)), Some("box")))
}

pub fn a_malformed_record_is_an_error_and_not_absence_test() {
  let opened = store()
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.FactCustom,
            scope.key,
            register.value(json.Object([#("incarnation", json.Int(0))])),
          ),
        ],
        expected: [],
      ),
    )

  let assert Error(reason) = scope.read(opened)

  assert string.contains(reason, "malformed")
}

pub fn the_key_is_in_the_reserved_client_namespace_test() {
  assert string.starts_with(scope.key, "client/")
}

fn commit_cell(opened: session.Session, payload: json.JsonValue) -> Nil {
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.FactCustom,
            scope.key,
            register.value(payload),
          ),
        ],
        expected: [],
      ),
    )
    as "the cell is written"
  Nil
}

pub fn a_cell_from_before_the_executor_was_recorded_still_decodes_test() {
  // The shape phase 1 wrote: an incarnation and a close, no executor.
  let opened = store()
  commit_cell(
    opened,
    json.Object([
      #("incarnation", json.Int(2)),
      #("closed", json.String("all_retired")),
    ]),
  )

  assert scope.read(opened)
    == Ok(Some(scope.Scope(2, Some(protocol.AllRetired), None)))

  // A null executor is the same as none.
  commit_cell(
    opened,
    json.Object([
      #("incarnation", json.Int(2)),
      #("closed", json.Null),
      #("executor", json.Null),
    ]),
  )
  assert scope.read(opened) == Ok(Some(scope.Scope(2, None, None)))
}

pub fn a_malformed_executor_is_an_error_and_never_another_executor_test() {
  let with = fn(executor) {
    let opened = store()
    commit_cell(
      opened,
      json.Object([
        #("incarnation", json.Int(1)),
        #("closed", json.Null),
        #("executor", executor),
      ]),
    )
    scope.read(opened)
  }

  let assert Error(not_a_name) = with(json.String("Build Box"))
  assert string.contains(not_a_name, "malformed")
  assert string.contains(not_a_name, "executor is not an executor name")
  let assert Error(not_text) = with(json.Int(3))
  assert string.contains(not_text, "executor is not a string")
}

pub fn the_executor_a_cell_names_is_the_only_one_it_offers_test() {
  assert scope.executor_of(None) == None
  assert scope.executor_of(Some(scope.Scope(1, None, None))) == None
  assert scope.executor_of(Some(scope.Scope(4, None, Some("box"))))
    == Some("box")
}

pub fn clearing_removes_the_cell_and_is_idempotent_test() {
  let opened = store()
  let assert Ok(Nil) = scope.write(opened, scope.Scope(1, None, Some("box")))

  assert scope.clear(opened) == Ok(Nil)
  assert scope.read(opened) == Ok(None)
  assert scope.clear(opened) == Ok(Nil)
}
