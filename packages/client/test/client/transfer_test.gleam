//// Pure transfer regressions pin bounded pieces and exclusive cursor math.
//// No backend or socket exists here: every requested read is inspected before
//// the fixture supplies its bounded result.

import client/daemon/transfer
import client/protocol
import core/clock
import core/ids
import core/json
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
