//// Result pages and downloads read bounded fragments of one immutable record.
//// The SQLite case checks the actual committed JSON, including Unicode across
//// fixed page boundaries. Scripted readers cover refusals and HTTP fixtures.

import broker/token
import client/daemon/ui_result
import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/tx
import gleam/bit_array
import gleam/bytes_tree
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/snapshot
import storage/sqlite
import storage/storage
import web_view/tool_result

pub fn result_id() -> ids.EntryId {
  let assert Ok(id) = ids.parse_entry_id("0198c0de-0000-7000-8000-000000000001")
    as "the fixture result identity is valid"
  id
}

pub fn payload() -> String {
  "{\"output\":\"" <> string.repeat("λ😀漢<script>tail", 60_000) <> "\"}"
}

pub fn reader(text: String) -> snapshot.Reader {
  let bytes = bit_array.from_string(text)
  let descriptor =
    snapshot.Descriptor(result_id(), 1, bit_array.byte_size(bytes))
  snapshot.Reader(
    capture: fn(_, _) { Error(snapshot.InvalidRequest) },
    page: fn(_, _, _, _) { Error(snapshot.InvalidRequest) },
    lineage: fn(id, _, limit, _) {
      case id == descriptor.id && limit == 1 {
        True -> Ok([descriptor])
        False -> Ok([])
      }
    },
    fragment: fn(found, offset, _) {
      case
        found == descriptor && offset >= 0 && offset <= descriptor.byte_length
      {
        True ->
          bit_array.slice(
            bytes,
            offset,
            int.min(
              snapshot.fragment_bytes_limit,
              descriptor.byte_length - offset,
            ),
          )
          |> result.replace_error(snapshot.InvalidRequest)
        False -> Error(snapshot.InvalidRequest)
      }
    },
  )
}

fn joined_pages(reader: snapshot.Reader, found: snapshot.Descriptor) -> String {
  let assert Ok(#(_, pages)) = ui_result.page(reader, found, 0)
    as "the first window reports its navigation bound"
  list.index_map(list.repeat(Nil, pages), fn(_, index) { index })
  |> list.map(fn(index) {
    let assert Ok(#(text, count)) = ui_result.page(reader, found, index)
      as "every valid window reads complete codepoints"
    assert count == pages
    assert string.byte_size(text) <= tool_result.page_bytes + 3
    text
  })
  |> string.join("")
}

pub fn pages_partition_large_unicode_and_download_keeps_every_byte_test() {
  let text = payload()
  let reader = reader(text)
  let assert Ok(found) = ui_result.descriptor(reader, result_id())
    as "only the exact immutable result is selected"
  assert joined_pages(reader, found) == text
  let assert Ok(download) = ui_result.download(reader, found)
    as "an explicit complete download reads every bounded fragment"
  assert bytes_tree.to_bit_array(download) == bit_array.from_string(text)
  assert ui_result.page(reader, found, -1) == Error(Nil)
  assert ui_result.page(reader, found, 2098) == Error(Nil)
}

pub fn a_short_fragment_refuses_the_complete_download_test() {
  let reader = reader("{\"output\":\"whole\"}")
  let assert Ok(found) = ui_result.descriptor(reader, result_id())
    as "the result exists"
  let broken = snapshot.Reader(..reader, fragment: fn(_, _, _) { Ok(<<>>) })
  assert ui_result.download(broken, found) == Error(Nil)
  assert ui_result.page(broken, found, 0) == Error(Nil)
}

pub fn a_real_sqlite_result_round_trips_through_pages_and_download_test() {
  let directory =
    "build/test_db/ui-result-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the result fixture has a private directory"
  let assert Ok(store) =
    sqlite.open(
      sqlite.config(directory <> "/conversation.db", "result-writer"),
      clock.fixed(1000),
    )
    as "a real SQLite writer opens"
  let record =
    entry.MessageEntry(
      id: result_id(),
      parent: None,
      seq: 0,
      ts: 0,
      terminate: False,
      message: message.ToolResultMessage(
        tool_call_id: "call",
        tool_name: "code_mode",
        content: [message.ToolResultText(payload(), None)],
        details: None,
        usage: None,
        added_tool_names: None,
        is_error: False,
        timestamp: 1000,
      ),
    )
  let assert Ok(_) = storage.commit(store, tx.Tx([tx.InsertEntry(record)], []))
    as "the complete result is committed before the page can name it"
  let reader = sqlite.snapshot_reader(store.handle)
  let assert Ok(found) = ui_result.descriptor(reader, result_id())
    as "the exact result descriptor is read without a history snapshot"
  let expected =
    codec.encode_entry(storage.stamp(record, 1, 1000)) |> json.to_string
  assert joined_pages(reader, found) == expected
  let assert Ok(download) = ui_result.download(reader, found)
    as "the stored JSON downloads in full"
  assert bytes_tree.to_bit_array(download) == bit_array.from_string(expected)
  assert storage.close(store) == Ok(Nil)
  assert simplifile.delete_all([directory]) == Ok(Nil)
}
