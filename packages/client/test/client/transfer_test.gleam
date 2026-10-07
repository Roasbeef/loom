//// Pure transfer regressions pin bounded pieces and exclusive cursor math.
//// No backend or socket exists here: every requested read is inspected before
//// the fixture supplies its bounded result.

import client/daemon/transfer
import client/protocol
import core/clock
import core/ids
import core/json
import core/register
import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import runtime/effects
import storage/snapshot
import storage/storage

fn cut(recent) {
  snapshot.Cut(
    101,
    storage.SessionStats(0, effects.zero_usage()),
    [],
    0,
    recent,
  )
}

fn field(value, key) {
  let assert json.Object(fields) = value as "the wire body is an object"
  let assert Ok(value) = list.key_find(fields, key) as "the field is present"
  value
}

pub fn metadata_larger_than_observer_frame_is_credited_in_pieces_test() {
  let metadata =
    json.Object([#("large", json.String(string.repeat("x", 100_000)))])
  let assert Ok(current) =
    transfer.start(cut([]), metadata, "s:1", transfer.Recent, 10)
    as "bounded metadata may exceed one frame"
  let #(pieces, bytes, final) = drain_metadata(current, [], [], 10)
  assert list.length(pieces) > 1
  assert bit_array.concat(list.reverse(bytes))
    == bit_array.from_string(json.to_string(metadata))
  let assert transfer.End(_) = transfer.step(final, now: 10, until: 6000)
    as "metadata alone completes an empty recent window"
}

fn drain_metadata(current, pieces, bytes, remaining) {
  case transfer.step(current, now: 10, until: 6000) {
    transfer.Emit(protocol.SnapshotChunk(body) as event, next)
      if remaining > 0
    -> {
      let encoded =
        protocol.encode_event(protocol.EventEnvelope(None, None, event))
      assert protocol.decode_event(encoded)
        == Ok(protocol.EventEnvelope(None, None, event))
      assert string.byte_size(encoded) <= 65_536
      let assert json.String(data) = field(body, "data")
        as "pieces use base64 data"
      let assert Ok(decoded) = bit_array.base64_decode(data)
        as "base64 fragments decode"
      assert bit_array.byte_size(decoded) <= transfer.piece_bytes
      drain_metadata(next, [body, ..pieces], [decoded, ..bytes], remaining - 1)
    }
    transfer.End(_) -> #(pieces, bytes, current)
    _ -> panic as "bounded metadata finishes within the fixture credit budget"
  }
}

pub fn credited_chunk_decoder_rejects_invalid_bounds_and_record_sequence_test() {
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Recent, 0)
    as "a valid metadata transfer starts"
  let assert transfer.Emit(protocol.SnapshotChunk(body), _) =
    transfer.step(current, now: 0, until: 6000)
    as "one credit exposes a valid metadata fragment"
  let assert json.Object(fields) = body as "chunk fields are inspectable"
  list.each(
    [
      #("offset", json.Int(-1)),
      #("total_bytes", json.Int(0)),
      #("record_seq", json.Int(1)),
      #("data", json.String("!")),
      #("data", json.String(string.repeat("A", 32_769))),
    ],
    fn(change) {
      let changed =
        json.Object(
          list.map(fields, fn(pair) {
            case pair.0 == change.0 {
              True -> change
              False -> pair
            }
          }),
        )
      let frame =
        protocol.encode_event(protocol.EventEnvelope(
          None,
          None,
          protocol.SnapshotChunk(changed),
        ))
      assert result.is_error(protocol.decode_event(frame))
    },
  )
}

pub fn exact_escalation_command_bounds_ids_before_lookup_test() {
  let command =
    protocol.CommandEnvelope(1, protocol.EscalationsGet(["esc-1", "missing"]))
  assert protocol.decode_command(protocol.encode_command(command))
    == Ok(command)
  list.each([[], list.repeat("esc-1", 9), [""]], fn(ids) {
    let invalid = protocol.CommandEnvelope(1, protocol.EscalationsGet(ids))
    assert result.is_error(
      protocol.decode_command(protocol.encode_command(invalid)),
    )
  })
}

pub fn continuation_checks_absolute_deadline_without_reset_test() {
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Recent, 10)
    as "the transfer starts"
  assert transfer.matches(current, "s:1", 0, 30_009)
  assert !transfer.matches(current, "s:1", 0, 30_010)
  assert !transfer.matches(current, "old", 0, 11)
  assert !transfer.matches(current, "s:1", 1, 11)
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 10, until: 6000)
    as "one metadata credit advances"
  assert transfer.expired(next, 30_010)
}

pub fn reconciliation_requests_first_entry_exactly_at_previous_next_seq_test() {
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Reconcile(50), 0)
    as "reconciliation starts from the adopted cut"
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 0, until: 6000)
    as "metadata precedes entries"
  let assert transfer.ReadPage(49, 101, 5000) =
    transfer.step(next, now: 0, until: 6000)
    as "exclusive reader bounds include seq equal to old next_seq"
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1), 1))
  let descriptor = snapshot.Descriptor(id, 50, 300_000)
  let assert Ok(next) = transfer.accept_page(next, [descriptor])
    as "the boundary entry is accepted"
  let assert transfer.ReadFragment(got, 0, 5000) =
    transfer.step(next, now: 0, until: 6000)
    as "no whole entry read is requested"
  assert got == descriptor
  let assert Ok(next) =
    transfer.accept_fragment(
      next,
      bit_array.from_string(string.repeat("x", 194_560)),
    )
    as "only one reader-sized fragment is retained"
  let assert transfer.Emit(protocol.SnapshotChunk(body), _) =
    transfer.step(next, now: 0, until: 6000)
    as "the large record still emits one observer-sized piece"
  assert field(body, "total_bytes") == json.Int(300_000)
  assert field(body, "offset") == json.Int(0)
}

// A read is funded from the smaller of two remainders — what is left of the
// retention window, and what is left of the request being answered — and a
// budget below the reader floor buys no read at all. Before the floor existed,
// a transfer one millisecond from expiry funded a real SQLite read with that
// millisecond; the `ReadTimedOut` that inevitably came back was then read as
// the storage actor being wedged, which poisoned the hub and stopped the
// session for every attachment on it.
pub fn a_transfer_below_the_reader_floor_requests_no_read_test() {
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Reconcile(50), 0)
    as "reconciliation starts from the adopted cut"
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 0, until: 1_000_000)
    as "metadata precedes entries"

  // One millisecond short of the deadline the transfer is not expired, which
  // is exactly the window the old arithmetic spent on a read.
  let last = transfer.lifetime_ms - 1
  assert !transfer.expired(next, last)
  assert transfer.step(next, now: last, until: 1_000_000) == transfer.Exhausted

  // The floor is the whole of the rule: at it the read is requested with that
  // budget, and one millisecond under it no read is requested at all.
  let edge = transfer.lifetime_ms - transfer.reader_minimum_ms
  assert transfer.step(next, now: edge, until: 1_000_000)
    == transfer.ReadPage(49, 101, transfer.reader_minimum_ms)
  assert transfer.step(next, now: edge + 1, until: 1_000_000)
    == transfer.Exhausted
}

// One continuation may need two reader exchanges — the descriptor page, then
// the first fragment of its first record — and both are answered inside the
// single request the socket is waiting on. They therefore share one wall
// rather than each taking a fresh five seconds, which two of would outlast the
// socket's own wait and land the reply in a mailbox nobody is reading.
pub fn one_continuations_pair_of_reads_shares_a_single_wall_test() {
  let wall = 5000
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Reconcile(50), 0)
    as "reconciliation starts from the adopted cut"
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 0, until: wall)
    as "metadata precedes entries"
  assert transfer.step(next, now: 0, until: wall)
    == transfer.ReadPage(49, 101, transfer.reader_maximum_ms)
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(1), 1))
  let descriptor = snapshot.Descriptor(id, 50, 300_000)
  let assert Ok(next) = transfer.accept_page(next, [descriptor])
    as "the boundary entry is accepted"

  // A page read that spent four of the five seconds leaves the fragment one.
  assert transfer.step(next, now: 4000, until: wall)
    == transfer.ReadFragment(descriptor, 0, 1000)

  // One that spent four and a half leaves less than a read costs, so the
  // continuation ends rather than starting one it cannot wait out.
  assert transfer.step(next, now: 4500, until: wall) == transfer.Exhausted
}

pub fn oversized_metadata_is_refused_before_serialization_test() {
  let assert Error(_) =
    transfer.start(
      cut([]),
      json.String(string.repeat("x", 2_097_153)),
      "s:1",
      transfer.Recent,
      0,
    )
    as "metadata has its own serialization ceiling"
}

pub fn decided_escalations_command_round_trips_and_takes_no_fields_test() {
  let command = protocol.CommandEnvelope(1, protocol.EscalationsDecided)
  assert protocol.decode_command(protocol.encode_command(command))
    == Ok(command)
  let named =
    "{\"v\":2,\"id\":1,\"cmd\":\"escalations_decided\",\"body\":{\"ids\":[\"esc-1\"]}}"
  assert result.is_error(protocol.decode_command(named))
}

fn decided_cell(key: String, seq: Int) {
  snapshot.Cell(
    register.FactCustom,
    key,
    storage.Register(register.value(json.Null), seq),
  )
}

pub fn decided_read_keeps_the_newest_cells_oldest_first_test() {
  let cells =
    list.map(numbers(1, 20), fn(index) {
      decided_cell("escalation/e" <> string.inspect(index), index * 3)
    })
  let kept = transfer.newest(cells, transfer.decided_limit)
  assert list.length(kept) == transfer.decided_limit
  assert list.map(kept, fn(cell) { cell.register.seq })
    == list.map(numbers(5, 20), fn(index) { index * 3 })
  assert transfer.newest([], transfer.decided_limit) == []
}

pub fn decided_window_carries_metadata_and_no_entries_test() {
  let assert Ok(current) =
    transfer.start(
      cut([]),
      json.Object([#("missing", json.Array([])), #("cells", json.Array([]))]),
      "s:2",
      transfer.Decided,
      10,
    )
    as "a decided read starts like any metadata-only transfer"
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 10, until: 6000)
    as "one credit carries the metadata"
  let assert transfer.End(_) = transfer.step(next, now: 10, until: 6000)
    as "no descriptors follow the metadata"
}

pub fn the_lineage_command_round_trips_and_names_one_entry_test() {
  let command =
    protocol.CommandEnvelope(3, protocol.HistoryLineage("0198-entry"))
  assert protocol.decode_command(protocol.encode_command(command))
    == Ok(command)
  let missing =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("id", json.Int(3)),
        #("cmd", json.String("history_lineage")),
        #("body", json.Object([])),
      ]),
    )
  assert result.is_error(protocol.decode_command(missing))
}

// A lineage read is one descriptor read from the entry it was asked about and
// nothing else: the transfer asks the reader for the walk below its own
// high-water, accepts what comes back once, and then streams the records. It
// never asks for a second page, because the client pages by naming a parent.
pub fn a_lineage_transfer_reads_one_walk_and_then_the_records_test() {
  let #(leaf, _) = ids.mint_entry(ids.generator(clock.fixed(1), 1))
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Lineage(leaf), 0)
    as "a lineage read starts"
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 0, until: 6000)
    as "metadata precedes the walk"
  assert transfer.step(next, now: 0, until: 6000)
    == transfer.ReadLineage(leaf, 101, transfer.reader_maximum_ms)
  let #(parent, _) = ids.mint_entry(ids.generator(clock.fixed(2), 2))
  let older = snapshot.Descriptor(parent, 7, 300)
  let newer = snapshot.Descriptor(leaf, 40, 300)

  // The walk is oldest first, as a page is, so the client's reassembly sees
  // ascending sequences whichever read produced them.
  let assert Ok(next) = transfer.accept_lineage(next, [older, newer])
    as "an ascending walk below the high-water is accepted"
  let assert transfer.ReadFragment(first, 0, _) =
    transfer.step(next, now: 0, until: 6000)
    as "the oldest record is read first"
  assert first == older
  assert result.is_error(transfer.accept_lineage(next, [newer, older]))
  assert result.is_error(
    transfer.accept_lineage(next, [
      snapshot.Descriptor(leaf, 101, 300),
    ]),
  )
}

pub fn a_lineage_transfer_that_found_nothing_ends_with_no_cursor_test() {
  let #(leaf, _) = ids.mint_entry(ids.generator(clock.fixed(1), 1))
  let assert Ok(current) =
    transfer.start(cut([]), json.Object([]), "s:1", transfer.Lineage(leaf), 0)
    as "a lineage read starts"
  let assert transfer.Emit(_, next) =
    transfer.step(current, now: 0, until: 6000)
    as "metadata precedes the walk"
  let assert Ok(next) = transfer.accept_lineage(next, [])
    as "an entry the store does not hold is the end of a walk"
  let assert transfer.End(protocol.SnapshotEnd(body)) =
    transfer.step(next, now: 0, until: 6000)
    as "the transfer ends"
  assert field(body, "more_after") == json.Null
}

pub fn quoted_metadata_size_preserves_codepoint_budget_test() {
  let controls =
    list.map(numbers(0, 31), fn(code) {
      let assert Ok(point) = string.utf_codepoint(code)
        as "every C0 control is a Unicode codepoint"
      string.from_utf_codepoints([point])
    })
  let texts =
    list.append(
      ["", "ordinary words", "\"", "\\", "é", "界", "🧶", "é"],
      controls,
    )

  // Prefixes move every escape and UTF-8 sequence across each byte in a
  // four-byte chunk. The codepoint oracle pins the old conservative budget,
  // which deliberately exceeds the serializer's size for short C0 escapes.
  list.each(numbers(0, 7), fn(prefix) {
    list.each(texts, fn(text) {
      let text = string.repeat("x", prefix) <> text <> "界🧶\"\\\n"
      let expected = codepoint_quoted_size(text)
      assert transfer.encoded_size(json.String(text), expected) == Ok(expected)
      assert result.is_error(transfer.encoded_size(
        json.String(text),
        expected - 1,
      ))

      // Object keys have the same quoting boundary as values, while the
      // wrapper and separator retain the transfer's existing overestimate.
      let object_size = 4 + expected + expected
      let object = json.Object([#(text, json.String(text))])
      assert transfer.encoded_size(object, object_size) == Ok(object_size)
      assert result.is_error(transfer.encoded_size(object, object_size - 1))
      assert string.byte_size(json.to_string(object)) <= object_size
    })
  })
}

pub fn metadata_sizing_does_not_build_a_codepoint_list_test() {
  let text = string.repeat("ordinary words 界🧶\"\\\n", 4096)
  let metadata = json.Object([#("description", json.String(text))])
  let expected =
    4 + codepoint_quoted_size("description") + codepoint_quoted_size(text)
  let #(sized, calls) =
    utf_codepoint_calls(fn() {
      transfer.encoded_size(metadata, transfer.metadata_encoded_limit)
    })
  assert sized == Ok(expected)
  assert calls == 0
}

// Function-call counters are an OTP observation that Gleam cannot express.
// The test-side adapter stops its private session on success or exception.
@external(erlang, "client_test_ffi", "utf_codepoint_calls")
fn utf_codepoint_calls(run: fn() -> a) -> #(a, Int)

// This oracle counts Unicode codepoints independently of the byte scanner.
fn codepoint_quoted_size(text: String) -> Int {
  list.fold(string.to_utf_codepoints(text), 2, fn(size, point) {
    let code = string.utf_codepoint_to_int(point)
    let bytes = case code {
      code if code < 32 -> 6
      34 | 92 -> 2
      code if code < 128 -> 1
      code if code < 2048 -> 2
      code if code < 65_536 -> 3
      _ -> 4
    }
    size + bytes
  })
}

// The integers from `first` to `last`, inclusive.
fn numbers(first: Int, last: Int) -> List(Int) {
  list.repeat(0, last - first + 1)
  |> list.index_map(fn(_, index) { first + index })
}
