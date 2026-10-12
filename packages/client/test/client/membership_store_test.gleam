//// The membership ledger's file (protocol-change/086): append and reopen, the
//// repair of a torn last line, and the refusal of a corrupt one with its line
//// number. Whether a write survives a crash is the file system's promise and
//// the tests do not show it. They show what the two states a crash can leave
//// behind do to the next boot.

import client/membership_entry
import client/membership_ledger
import client/membership_store.{Clean, Corrupt, Repaired, Unreadable, Unwritable}
import gleam/bit_array
import gleam/list
import gleam/string
import simplifile
import support/membership_fixture as fixture
import support/membership_log as history
import support/remote_fixtures

// A log of three entries after genesis: two members and a revoke.
fn log() -> history.Log {
  history.genesis()
  |> history.enroll("hub", [])
  |> history.enroll("laptop", ["hub"])
  |> history.revoke("laptop")
}

fn text_of(lines: List(BitArray)) -> String {
  string.concat(
    list.map(lines, fn(line) {
      let assert Ok(text) = bit_array.to_string(line)
        as "the fixture lines are text"
      text <> "\n"
    }),
  )
}

fn write(directory: String, text: String) -> String {
  let path = directory <> "/ledger.log"
  let assert Ok(Nil) = simplifile.write(path, text)
  path
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path)
  text
}

pub fn a_whole_file_opens_as_the_fold_of_its_lines_test() {
  let log = log()
  let path =
    write(remote_fixtures.scratch("store-open"), text_of(history.lines(log)))
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())
  assert opened.ledger == log.ledger
  assert opened.tail == Clean
  assert membership_store.count(opened.store) == 4
}

pub fn an_appended_entry_is_there_after_a_reopen_test() {
  let start = history.genesis() |> history.enroll("hub", [])
  let path =
    write(
      remote_fixtures.scratch("store-append"),
      text_of(history.lines(start)),
    )
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())

  // The entry the fold accepts next is the one the store is given.
  let next = history.next_entry(start, fixture.revoke_kind("hub"))
  let signed = fixture.seal(next)
  let assert Ok(membership_ledger.Applied(ledger:, ..)) =
    membership_ledger.apply(opened.ledger, signed)
  let assert Ok(store) = membership_store.append(opened.store, signed)
  assert membership_store.count(store) == 3
  assert read(path)
    == text_of(history.lines(start)) <> text_of([membership_entry.line(signed)])

  let assert Ok(again) = membership_store.open(path, fixture.verifier())
  assert again.ledger == ledger
  assert again.tail == Clean
  assert membership_ledger.members(again.ledger) == []
}

pub fn a_torn_last_line_is_dropped_and_cut_from_the_file_test() {
  let log = log()
  let whole = text_of(history.lines(log))
  let fragment = "eyJmb3JtYXQiOiJsb29tLW1lbWJlcnNoaXAtbGVkZ2Vy"
  let path = write(remote_fixtures.scratch("store-torn"), whole <> fragment)
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())
  assert opened.ledger == log.ledger
  assert opened.tail == Repaired(bytes: string.byte_size(fragment))

  // The file is whole again, so the next append starts on a line boundary.
  assert read(path) == whole
  let next = history.next_entry(log, fixture.revoke_kind("hub"))
  let signed = fixture.seal(next)
  let assert Ok(store) = membership_store.append(opened.store, signed)
  assert membership_store.count(store) == 5
  let assert Ok(again) = membership_store.open(path, fixture.verifier())
  assert again.tail == Clean
  assert membership_ledger.head(again.ledger).seq == 4
}

pub fn a_valid_last_line_without_its_terminator_is_still_torn_test() {
  // The terminator is written with the line, so a line without one was never
  // acknowledged, however well formed it looks.
  let log = log()
  let lines = history.lines(log)
  let assert Ok(last) = list.last(lines)
  let assert Ok(last_text) = bit_array.to_string(last)
  let path =
    write(
      remote_fixtures.scratch("store-unterminated"),
      text_of(list.take(lines, 3)) <> last_text,
    )
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())
  assert membership_ledger.head(opened.ledger).seq == 2
  assert opened.tail == Repaired(bytes: string.byte_size(last_text))
}

pub fn a_corrupt_middle_line_refuses_with_its_line_number_test() {
  let lines = history.lines(log())
  let assert [genesis, hub, laptop, revoke] = lines
  let assert Ok(laptop_text) = bit_array.to_string(laptop)

  // The first character changed: a line that decodes but whose signature
  // was made over other bytes.
  let damaged = "A" <> string.drop_start(laptop_text, 1)
  let path =
    write(
      remote_fixtures.scratch("store-corrupt"),
      text_of([genesis, hub]) <> damaged <> "\n" <> text_of([revoke]),
    )
  let assert Error(Corrupt(line: 3, refusal: _)) =
    membership_store.open(path, fixture.verifier())
}

pub fn an_entry_that_does_not_chain_refuses_with_its_line_number_test() {
  // The second member entry is dropped, so the revoke's `prev` names an entry
  // the file does not hold at that position.
  let assert [genesis, hub, _laptop, revoke] = history.lines(log())
  let path =
    write(
      remote_fixtures.scratch("store-chain"),
      text_of([genesis, hub, revoke]),
    )
  let assert Error(Corrupt(line: 3, refusal: membership_ledger.Chain)) =
    membership_store.open(path, fixture.verifier())
}

pub fn a_blank_line_in_the_middle_is_corrupt_not_skipped_test() {
  let assert [genesis, hub, laptop, revoke] = history.lines(log())
  let path =
    write(
      remote_fixtures.scratch("store-blank"),
      text_of([genesis, hub]) <> "\n" <> text_of([laptop, revoke]),
    )
  let assert Error(Corrupt(line: 3, refusal: _)) =
    membership_store.open(path, fixture.verifier())
}

pub fn a_forged_line_is_corrupt_under_another_authority_test() {
  let path =
    write(
      remote_fixtures.scratch("store-forged"),
      text_of(history.lines(log())),
    )
  let stranger = fn(_message, _signature) { membership_entry.Forged }
  let assert Error(Corrupt(line: 1, refusal: _)) =
    membership_store.open(path, stranger)
}

pub fn a_file_with_no_complete_line_has_no_genesis_test() {
  let directory = remote_fixtures.scratch("store-empty")
  let empty = write(directory, "")
  assert membership_store.open(empty, fixture.verifier())
    == Error(membership_store.NoGenesis)

  let torn_only = write(directory, "eyJhIjoxfQ")
  assert membership_store.open(torn_only, fixture.verifier())
    == Error(membership_store.NoGenesis)
}

pub fn a_missing_or_binary_file_is_unreadable_test() {
  let directory = remote_fixtures.scratch("store-unreadable")
  let assert Error(Unreadable(_)) =
    membership_store.open(directory <> "/absent.log", fixture.verifier())

  let path = directory <> "/binary.log"
  let assert Ok(Nil) = simplifile.write_bits(path, <<255, 254, 253, 10>>)
  let assert Error(Unreadable(_)) =
    membership_store.open(path, fixture.verifier())
}

pub fn lines_after_honours_both_bounds_test() {
  let lines = history.lines(log())
  let path = write(remote_fixtures.scratch("store-after"), text_of(lines))
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())
  let store = opened.store
  let assert [_, second, third, fourth] = lines

  assert membership_store.lines_after(store, 0, 64, 1_000_000)
    == [second, third, fourth]
  assert membership_store.lines_after(store, 1, 1, 1_000_000) == [third]
  assert membership_store.lines_after(store, 3, 64, 1_000_000) == []
  assert membership_store.lines_after(store, 99, 64, 1_000_000) == []

  // The byte bound stops before the line that would pass it.
  let size = bit_array.byte_size(second)
  assert membership_store.lines_after(store, 0, 64, size) == [second]
  assert membership_store.lines_after(store, 0, 64, size - 1) == []
}

pub fn an_append_that_cannot_write_changes_nothing_test() {
  let start = history.genesis()
  let directory = remote_fixtures.scratch("store-unwritable")
  let path = write(directory, text_of(history.lines(start)))
  let assert Ok(opened) = membership_store.open(path, fixture.verifier())

  // The directory goes away, so the temporary file beside the ledger cannot
  // be created.
  let assert Ok(Nil) = simplifile.delete(directory)
  let signed =
    fixture.seal(history.next_entry(start, fixture.revoke_kind("hub")))
  let assert Error(Unwritable(_)) =
    membership_store.append(opened.store, signed)
  assert membership_store.count(opened.store) == 1
}
