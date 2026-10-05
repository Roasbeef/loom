//// Literal atoms are names inside ETF bytes, never decoded Erlang terms.
//// This bounded iterative walk admits scalar, list, tuple and map literals.
//// Runtime identities and nested compressed ETF are refused before loading.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// Reads every atom name from an already bounded literal table.
///
/// ## Examples
///
/// `read(<<0:32>>)` returns no atom names.
pub fn read(bytes: BitArray) -> Result(List(String), String) {
  case bytes {
    <<count:32, rest:bytes>> if count <= 8192 ->
      literals(rest, count, [], 131_072)
    _ -> Error("invalid BEAM literal table count")
  }
}

fn literals(
  bytes: BitArray,
  remaining: Int,
  atoms: List(String),
  budget: Int,
) -> Result(List(String), String) {
  case remaining, bytes {
    0, <<>> -> Ok(atoms)
    _, <<size:32, 131:8, term:bytes-size(size - 1), rest:bytes>>
      if remaining > 0 && size > 0
    -> {
      use parsed <- result.try(walk(term, [1], atoms, budget))
      case parsed.0 {
        <<>> -> literals(rest, remaining - 1, parsed.1, parsed.2)
        _ -> Error("BEAM literal has trailing term bytes")
      }
    }
    _, _ -> Error("malformed BEAM literal entry")
  }
}

fn walk(
  bytes: BitArray,
  pending: List(Int),
  atoms: List(String),
  budget: Int,
) -> Result(#(BitArray, List(String), Int), String) {
  case pending {
    [] -> Ok(#(bytes, atoms, budget))
    [0, ..rest] -> walk(bytes, rest, atoms, budget)
    [count, ..rest] if budget > 0 -> {
      let next = [count - 1, ..rest]
      node(bytes, next, atoms, budget - 1)
    }
    _ -> Error("BEAM literal node budget exceeded")
  }
}

fn node(
  bytes: BitArray,
  pending: List(Int),
  atoms: List(String),
  budget: Int,
) -> Result(#(BitArray, List(String), Int), String) {
  case bytes {
    <<97:8, _:8, rest:bytes>>
    | <<98:8, _:32, rest:bytes>>
    | <<70:8, _:64, rest:bytes>>
    | <<99:8, _:248, rest:bytes>>
    | <<106:8, rest:bytes>> -> walk(rest, pending, atoms, budget)
    <<107:8, size:16, _:bytes-size(size), rest:bytes>>
    | <<109:8, size:32, _:bytes-size(size), rest:bytes>> ->
      walk(rest, pending, atoms, budget)
    <<77:8, size:32, _:8, _:bytes-size(size), rest:bytes>> ->
      walk(rest, pending, atoms, budget)
    <<110:8, size:8, _:8, _:bytes-size(size), rest:bytes>>
    | <<111:8, size:32, _:8, _:bytes-size(size), rest:bytes>> ->
      walk(rest, pending, atoms, budget)
    <<104:8, count:8, rest:bytes>> | <<105:8, count:32, rest:bytes>> ->
      children(rest, count, pending, atoms, budget)
    <<108:8, count:32, rest:bytes>> ->
      children(rest, count + 1, pending, atoms, budget)
    <<116:8, count:32, rest:bytes>> ->
      children(rest, count * 2, pending, atoms, budget)
    <<113:8, rest:bytes>> -> children(rest, 3, pending, atoms, budget)
    <<119:8, size:8, name:bytes-size(size), rest:bytes>>
    | <<118:8, size:16, name:bytes-size(size), rest:bytes>> -> {
      use name <- result.try(
        bit_array.to_string(name)
        |> result.replace_error("literal atom is not UTF8"),
      )
      walk(rest, pending, [name, ..atoms], budget)
    }
    <<115:8, size:8, name:bytes-size(size), rest:bytes>>
    | <<100:8, size:16, name:bytes-size(size), rest:bytes>> -> {
      use name <- result.try(latin1(name, []))
      walk(rest, pending, [name, ..atoms], budget)
    }
    _ -> Error("unsupported or malformed BEAM literal term")
  }
}

fn children(
  bytes: BitArray,
  count: Int,
  pending: List(Int),
  atoms: List(String),
  budget: Int,
) -> Result(#(BitArray, List(String), Int), String) {
  case count <= budget && list.is_empty(list.drop(pending, 128)) {
    True -> walk(bytes, [count, ..pending], atoms, budget)
    False -> Error("BEAM literal depth or node budget exceeded")
  }
}

fn latin1(
  bytes: BitArray,
  codepoints: List(UtfCodepoint),
) -> Result(String, String) {
  case bytes {
    <<>> -> Ok(string.from_utf_codepoints(list.reverse(codepoints)))
    <<value:8, rest:bytes>> -> {
      use point <- result.try(
        string.utf_codepoint(value)
        |> result.replace_error("invalid literal Latin1 atom"),
      )
      latin1(rest, [point, ..codepoints])
    }
    _ -> Error("invalid literal Latin1 bytes")
  }
}
