//// Evolution inspection stays inside the existing bounded control frame.
////
//// Small verified envelopes keep their ordinary JSON shape. Large envelopes
//// travel as bounded base64 byte fragments of the same canonical JSON, so a
//// client can reconstruct and verify the original identity without clipping
//// source or evidence. Byte offsets cannot split or corrupt UTF-8 semantics:
//// decoding happens after the client joins the exact bytes.

import core/json
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/tool

/// Returns a verified envelope or one bounded fragment of its canonical bytes.
/// The identity is supplied by the verified native record, never by arguments.
///
/// ## Examples
///
/// ```gleam
/// // page.envelope(candidate_id, canonical_candidate_json, inspect_arguments)
/// ```
pub fn envelope(
  identity: String,
  encoded: String,
  arguments: json.JsonValue,
) -> Result(json.JsonValue, String) {
  use requested <- result.try(tool.optional_int(arguments, "offset_bytes"))
  let bytes = bit_array.from_string(encoded)
  let total = bit_array.byte_size(bytes)
  case requested, total <= 32_768 {
    None, True ->
      json.parse(encoded)
      |> result.replace_error("Corrupt: verified envelope JSON")
    _, _ -> {
      let offset = case requested {
        None -> 0
        Some(offset) -> offset
      }
      use Nil <- result.try(case offset >= 0 && offset <= total {
        True -> Ok(Nil)
        False -> Error("Bounds: envelope byte offset is outside this record")
      })
      let count = int.min(16_384, total - offset)
      use fragment <- result.try(
        bit_array.slice(bytes, offset, count)
        |> result.replace_error("Bounds: envelope byte slice is invalid"),
      )
      let next = offset + count
      Ok(
        json.Object([
          #("identity", json.String(identity)),
          #("encoding", json.String("base64")),
          #("total_bytes", json.Int(total)),
          #("offset_bytes", json.Int(offset)),
          #(
            "fragment_base64",
            json.String(bit_array.base64_encode(fragment, True)),
          ),
          #("next_offset_bytes", case next < total {
            True -> json.Int(next)
            False -> json.Null
          }),
        ]),
      )
    }
  }
}

/// A stable slice retains complete callable identities and schemas.
pub type Items {
  Items(
    /// Whole records in their original order, never truncated fields.
    values: List(json.JsonValue),
    /// The first requested position in this visible catalogue.
    offset: Int,
    /// The next position, absent only at the end of the catalogue.
    next_offset: Option(Int),
    /// The visible item count before this page was selected.
    total: Int,
  )
}

/// Selects at most eight whole items under a caller's byte budget.
/// The budget includes array punctuation; callers reserve envelope space.
///
/// ## Examples
///
/// `items(records, json.Object([]), 30_720)` starts a bounded catalogue page.
pub fn items(
  values: List(json.JsonValue),
  arguments: json.JsonValue,
  byte_budget: Int,
) -> Result(Items, String) {
  use offset <- result.try(tool.optional_int(arguments, "offset"))
  use count <- result.try(tool.optional_int(arguments, "count"))
  let offset = option.unwrap(offset, 0)
  let count = option.unwrap(count, 8)
  let total = list.length(values)
  use Nil <- result.try(
    case
      offset >= 0
      && offset <= total
      && count >= 1
      && count <= 8
      && byte_budget >= 2
      && byte_budget <= 30_720
    {
      True -> Ok(Nil)
      False -> Error("Bounds: catalogue offset, count or byte budget")
    },
  )
  use selected <- result.try(
    take_items(list.drop(values, offset), count, byte_budget - 2, []),
  )
  let next = offset + list.length(selected)
  Ok(Items(
    selected,
    offset,
    case next < total {
      True -> Some(next)
      False -> None
    },
    total,
  ))
}

/// Renders a page without adding or changing any item fields.
///
/// ## Examples
///
/// `items_json(page)` exposes an exact continuation offset to a CLI reader.
pub fn items_json(page: Items) -> json.JsonValue {
  json.Object([
    #("items", json.Array(page.values)),
    #("offset", json.Int(page.offset)),
    #("next_offset", offset_json(page.next_offset)),
    #("total", json.Int(page.total)),
  ])
}

/// Encodes a continuation without treating an absent offset as zero.
///
/// ## Examples
///
/// `offset_json(None)` is the terminal JSON null.
pub fn offset_json(offset: Option(Int)) -> json.JsonValue {
  case offset {
    Some(offset) -> json.Int(offset)
    None -> json.Null
  }
}

fn take_items(
  remaining: List(json.JsonValue),
  count: Int,
  bytes: Int,
  selected: List(json.JsonValue),
) -> Result(List(json.JsonValue), String) {
  case remaining, count {
    [], _ | _, 0 -> Ok(list.reverse(selected))
    [item, ..rest], _ -> {
      let size =
        bit_array.byte_size(bit_array.from_string(json.to_string(item))) + 1
      case size <= bytes, selected {
        True, _ -> take_items(rest, count - 1, bytes - size, [item, ..selected])
        False, [] ->
          Error("Bounds: one complete catalogue item exceeds the page budget")
        False, _ -> Ok(list.reverse(selected))
      }
    }
  }
}
