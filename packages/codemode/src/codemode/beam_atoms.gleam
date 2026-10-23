//// BEAM atom names are inspected as bytes before any VM loader sees them.
//// Reading an atom table with beam_lib would itself intern untrusted names.
//// This total IFF reader instead returns strings, letting the native host
//// enforce a finite vocabulary across both reusable implementation slots.

import codemode/internal/ffi_zlib
import codemode/literal_atoms
import gleam/bit_array
import gleam/list
import gleam/result

/// Reads the UTF8 atom table without creating any Erlang atoms.
///
/// ## Examples
///
/// ```gleam
/// assert beam_atoms.read(<<>>) == Error("invalid BEAM container")
/// ```
///
pub fn read(bytes: BitArray) -> Result(List(String), String) {
  case bytes {
    <<"FOR1", size:32, "BEAM", payload:bytes>> if size >= 4 -> {
      case bit_array.byte_size(payload) == size - 4 {
        True -> chunks(payload, [])
        False -> Error("BEAM container length differs")
      }
    }
    _ -> Error("invalid BEAM container")
  }
}

fn chunks(
  bytes: BitArray,
  atoms: List(String),
) -> Result(List(String), String) {
  case bytes {
    <<name:bytes-size(4), size:32, rest:bytes>> -> {
      let padding = { 4 - size % 4 } % 4
      case rest {
        <<payload:bytes-size(size), _:bytes-size(padding), tail:bytes>> -> {
          case name {
            <<"AtU8">> | <<"Atom">> -> {
              use found <- result.try(atom_table(payload))
              chunks(tail, list.append(atoms, found))
            }
            <<"LitT">> -> {
              use inflated <- result.try(ffi_zlib.literal_bytes(payload))
              use found <- result.try(literal_atoms.read(inflated))
              chunks(tail, list.append(atoms, found))
            }
            _ -> chunks(tail, atoms)
          }
        }
        _ -> Error("truncated BEAM chunk")
      }
    }
    <<>> if atoms != [] -> Ok(atoms)
    _ -> Error("BEAM atom table is absent or malformed")
  }
}

fn atom_table(bytes: BitArray) -> Result(List(String), String) {
  case bytes {
    <<count:32-signed, rest:bytes>> if count < 0 && count >= -8192 ->
      compact_names(rest, -count, [])
    <<count:32, rest:bytes>> if count <= 8192 -> names(rest, count, [])
    _ -> Error("BEAM atom count exceeds native bound")
  }
}

fn compact_names(
  bytes: BitArray,
  remaining: Int,
  found: List(String),
) -> Result(List(String), String) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(found))
    _, <<size:4, 0:4, text:bytes-size(size), tail:bytes>> if remaining > 0 -> {
      use name <- result.try(
        bit_array.to_string(text)
        |> result.replace_error("BEAM atom name is not UTF8"),
      )
      compact_names(tail, remaining - 1, [name, ..found])
    }
    _, <<high:3, 0:1, 1:1, 0:3, low:8, tail:bytes>> if remaining > 0 -> {
      let size = high * 256 + low
      case tail {
        <<text:bytes-size(size), rest:bytes>> if size <= 1020 -> {
          use name <- result.try(
            bit_array.to_string(text)
            |> result.replace_error("BEAM atom name is not UTF8"),
          )
          compact_names(rest, remaining - 1, [name, ..found])
        }
        _ -> Error("truncated compact BEAM atom")
      }
    }
    _, _ -> Error("invalid compact BEAM atom table")
  }
}

fn names(
  bytes: BitArray,
  remaining: Int,
  found: List(String),
) -> Result(List(String), String) {
  case remaining, bytes {
    0, <<>> -> Ok(list.reverse(found))
    0, _ -> Error("BEAM atom table has trailing bytes")
    _, <<size:8, text:bytes-size(size), tail:bytes>> -> {
      use name <- result.try(
        bit_array.to_string(text)
        |> result.replace_error("BEAM atom name is not UTF8"),
      )
      names(tail, remaining - 1, [name, ..found])
    }
    _, _ -> Error("truncated BEAM atom table")
  }
}
