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
  assert scope.attach_at(Some(scope.Scope(3, Some(protocol.AllRetired)))) == 4
}

pub fn every_other_shape_attaches_at_the_stored_incarnation_test() {
  assert scope.attach_at(Some(scope.Scope(3, None))) == 3
  assert scope.attach_at(Some(scope.Scope(3, Some(protocol.UnknownCleanup(2)))))
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
  each(scope.Scope(1, None))
  each(scope.Scope(2, Some(protocol.AllRetired)))
  each(scope.Scope(7, Some(protocol.UnknownCleanup(3))))
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
