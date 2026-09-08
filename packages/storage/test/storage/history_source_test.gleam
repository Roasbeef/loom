//// Owned read-only history reads against actual SQLite connections.
//// Test SQL constructs sparse histories and corrupt bounds directly; production
//// source reads use named generated statements and never acquire writer leases.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import gleam/bit_array
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/string
import simplifile
import sqlight
import storage/internal/history_source as source
import storage/session_schema
import storage/snapshot

/// Sparse immutable continuation survives later appends without moving its cut.
pub fn history_source_owned_sparse_fragments_and_append_test() {
  fixture("fragments", fn(path, db, id) {
    let first = row(1, string.repeat("界", 90_000))
    let last = row(5, "last")
    insert(db, first)
    insert(db, last)
    assert sqlight.exec("UPDATE session SET next_seq = 6", db) == Ok(Nil)
    assert sqlight.exec("INSERT INTO writer_lease VALUES ('live',7,9000)", db)
      == Ok(Nil)
    let assert Ok(opened) = source.acquire(path) as "read-only source opens"
    assert source.initialize(opened, 1000) == Ok(Nil)
    let assert Ok(cut) = source.inspect(opened, id)
      as "identity and generation share the owned connection"
    assert cut.generation == 0
    assert cut.next_seq == 6
    let assert Ok([descriptor]) = source.page(opened, cut, 0, 1)
      as "page must honor its positive count bound"
    assert descriptor.id == first.id
    let assert Ok(a) = source.fragment(opened, descriptor, 0)
      as "first byte fragment must read"
    assert bit_array.byte_size(a) == snapshot.fragment_bytes_limit
    let assert Ok(b) =
      source.fragment(opened, descriptor, bit_array.byte_size(a))
      as "the remainder must read without decoding partial UTF-8"
    let original =
      codec.encode_entry(first) |> json.to_string |> bit_array.from_string
    assert bit_array.concat([a, b]) == original
    assert source.fragment(opened, descriptor, descriptor.byte_length)
      == Ok(<<>>)

    insert(db, row(6, "later append"))
    assert sqlight.exec("UPDATE session SET next_seq = 7", db) == Ok(Nil)
    let assert Ok([remaining]) = source.page(opened, cut, 1, 100)
      as "an old cut excludes appended entries and crosses sparse sequences"
    assert remaining.id == last.id
    assert source.page(opened, cut, 5, 100) == Ok([])
    let assert Ok(current) = source.inspect(opened, id)
      as "later high-water is observable without invalidating immutable rows"
    assert current.next_seq == 7
    assert current.generation == cut.generation
    assert source.close(opened) == Ok(Nil)
    let assert Ok([#("live", 7, 9000)]) =
      sqlight.query(
        "SELECT owner_id,fence,expires_at_ms FROM writer_lease",
        db,
        [],
        {
          use owner <- decode.field(0, decode.string)
          use fence <- decode.field(1, decode.int)
          use expiry <- decode.field(2, decode.int)
          decode.success(#(owner, fence, expiry))
        },
      )
      as "history reads must leave the active writer lease unchanged"
  })
}

/// Source identity, oversized metadata, and oversized records refuse explicitly.
pub fn history_source_identity_and_allocation_bounds_test() {
  fixture("bounds", fn(path, db, id) {
    let assert Ok(opened) = source.acquire(path) as "read-only source opens"
    assert source.initialize(opened, 1000) == Ok(Nil)
    let #(wrong, _) = ids.mint_session(ids.generator(clock.fixed(0), 900))
    assert source.inspect(opened, wrong)
      == Error("history source session identity mismatch")
    let assert Ok(cut) = source.inspect(opened, id)
      as "expected source is valid"
    let item = row(1, "replaced with oversized payload")
    insert(db, item)
    assert sqlight.exec("UPDATE entries SET payload = zeroblob(33554433)", db)
      == Ok(Nil)
    let assert Error(_) = source.entry(opened, cut, item.id)
      as "an oversized record is refused using its descriptor, before payload fetch"
    assert sqlight.exec("UPDATE session SET metadata = zeroblob(1048577)", db)
      == Ok(Nil)
    assert source.inspect(opened, id)
      == Error("history source metadata exceeds its byte budget")
    assert source.close(opened) == Ok(Nil)
  })
}

/// Generation changes and truncation are visible on the retained connection.
pub fn history_source_rewrite_and_missing_source_test() {
  fixture("rewrite", fn(path, db, id) {
    let assert Ok(opened) = source.acquire(path) as "read-only source opens"
    assert source.initialize(opened, 1000) == Ok(Nil)
    let assert Ok(before) = source.inspect(opened, id) as "initial cut reads"
    metadata(db, id, 2)
    assert sqlight.exec("UPDATE session SET next_seq = 1", db) == Ok(Nil)
    let assert Ok(after) = source.inspect(opened, id)
      as "same-handle rewrite is observable"
    assert after.generation != before.generation
    assert after.next_seq < before.next_seq
    assert source.close(opened) == Ok(Nil)
    let missing = path <> ".missing"
    let assert Error(_) = source.acquire(missing)
      as "read-only open must not create a missing source"
    assert simplifile.is_file(missing) == Ok(False)
  })
}

/// A source registered earlier and since removed is refused before SQLite is
/// asked to open it. The refusal is not tidiness: `mode=ro` fails such an open
/// with `SQLITE_CANTOPEN`, and the binding then closes the connection twice, so
/// the cost lands on whichever other connection in this emulator is handed the
/// freed block. Naming the path in the refusal is what distinguishes the guard
/// from the SQLite error it replaces.
pub fn a_removed_source_is_refused_before_the_open_test() {
  fixture("removed", fn(path, _db, _id) {
    let removed = path <> ".removed"
    let assert Error(reason) = source.acquire(removed)
      as "a source that is not there is refused before the open"
    assert string.contains(reason, removed)
    assert string.contains(reason, "read-only")
    assert simplifile.is_file(removed) == Ok(False)
  })
}

fn fixture(lane, run) {
  let assert Ok(here) = simplifile.current_directory() as "test cwd resolves"
  let directory = here <> "/build/test_db/history-source-" <> lane
  let _old = simplifile.delete(directory)
  assert simplifile.create_directory_all(directory) == Ok(Nil)
  let path = directory <> "/source.db"
  let assert Ok(db) = sqlight.open(path) as "fixture database opens"
  assert sqlight.exec(session_schema.schema, db) == Ok(Nil)
  assert sqlight.exec("INSERT INTO session(next_seq) VALUES(2)", db) == Ok(Nil)
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(1000), 100))
  metadata(db, id, 0)
  run(path, db, id)
  assert sqlight.close(db) == Ok(Nil)
}

fn metadata(db, id, generation) {
  let encoded =
    json.Object([
      #("session_id", json.String(ids.session_id_to_string(id))),
      #("generation", json.Int(generation)),
    ])
    |> json.to_string
    |> bit_array.from_string
  assert sqlight.query(
      "UPDATE session SET metadata = ?",
      db,
      [sqlight.blob(encoded)],
      decode.success(Nil),
    )
    == Ok([])
}

fn row(seq, text) {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), seq))
  entry.CustomEntry(
    id,
    None,
    seq,
    1000,
    "history-fixture",
    Some(json.String(text)),
  )
}

fn insert(db, item: entry.Entry) {
  let encoded =
    codec.encode_entry(item) |> json.to_string |> bit_array.from_string
  assert sqlight.query(
      "INSERT INTO entries(id,seq,payload) VALUES(?,?,?)",
      db,
      [
        sqlight.text(ids.entry_id_to_string(item.id)),
        sqlight.int(item.seq),
        sqlight.blob(encoded),
      ],
      decode.success(Nil),
    )
    == Ok([])
}
