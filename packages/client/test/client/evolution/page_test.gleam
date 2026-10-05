//// Inspection fragments reconstruct exact UTF-8 JSON and fit control framing.

import client/evolution/page
import client/protocol
import core/json
import gleam/bit_array
import gleam/list
import gleam/option
import gleam/string

pub fn small_envelope_keeps_full_record_test() {
  let value = json.Object([#("id", json.String("native-id"))])
  assert page.envelope("native-id", json.to_string(value), json.Object([]))
    == Ok(value)
}

pub fn unicode_pages_reconstruct_exact_canonical_bytes_test() {
  let encoded =
    json.to_string(
      json.Object([#("source", json.String(string.repeat("🌿", 20_000)))]),
    )
  let assert Ok(first) = page.envelope("verified", encoded, json.Object([]))
    as "large records are paged before control framing"
  let assert json.Object(fields) = first as "a page is an object"
  assert list.key_find(fields, "identity") == Ok(json.String("verified"))
  let frame =
    protocol.encode_event(protocol.EventEnvelope(
      seq: option.Some(1),
      reply_to: option.Some(1),
      event: protocol.SnapshotEvent(protocol.EvolutionSnapshot(first)),
    ))
  assert bit_array.byte_size(bit_array.from_string(frame)) < 32_768
  let rebuilt = rebuild("verified", encoded, 0, <<>>)
  assert rebuilt == bit_array.from_string(encoded)
}

fn rebuild(
  identity: String,
  encoded: String,
  offset: Int,
  retained: BitArray,
) -> BitArray {
  let assert Ok(json.Object(fields)) =
    page.envelope(
      identity,
      encoded,
      json.Object([
        #("offset_bytes", json.Int(offset)),
      ]),
    )
    as "each page uses the exact verified envelope"
  let assert Ok(json.String(fragment)) =
    list.key_find(fields, "fragment_base64")
    as "the fragment is encoded bytes rather than clipped text"
  let assert Ok(bytes) = bit_array.base64_decode(fragment)
    as "the fragment decodes without losing a Unicode boundary"
  let retained = <<retained:bits, bytes:bits>>
  let assert Ok(next) = list.key_find(fields, "next_offset_bytes")
    as "the page names its continuation"
  case next {
    json.Null -> retained
    json.Int(next) -> rebuild(identity, encoded, next, retained)
    _ -> {
      panic as "a continuation is a byte offset or the terminal null"
    }
  }
}

pub fn invalid_offsets_refuse_before_slicing_test() {
  assert page.envelope(
      "id",
      "{}",
      json.Object([#("offset_bytes", json.Int(-1))]),
    )
    == Error("Bounds: envelope byte offset is outside this record")
  assert page.envelope(
      "id",
      "{}",
      json.Object([#("offset_bytes", json.Int(3))]),
    )
    == Error("Bounds: envelope byte offset is outside this record")
}
