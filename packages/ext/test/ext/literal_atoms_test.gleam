//// Literal constructor atoms must be accounted before any term decoder.

import ext/internal/literal_atoms
import gleam/bit_array
import gleam/result

pub fn atom_hidden_in_list_literal_is_counted_test() {
  let table = <<
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    37,
    131,
    108,
    0,
    0,
    0,
    1,
    119,
    28,
    114,
    101,
    118,
    105,
    101,
    119,
    95,
    117,
    110,
    105,
    113,
    117,
    101,
    95,
    108,
    105,
    116,
    101,
    114,
    97,
    108,
    95,
    97,
    98,
    99,
    120,
    121,
    122,
    106,
  >>
  assert literal_atoms.read(table) == Ok(["review_unique_literal_abcxyz"])
}

pub fn literal_depth_is_bounded_test() {
  let term = nested(130, <<106>>)
  let table = <<1:32, { bit_array.byte_size(term) + 1 }:32, 131, term:bits>>
  assert literal_atoms.read(table) |> result.is_error
}

pub fn malformed_and_runtime_identity_literals_are_refused_test() {
  assert literal_atoms.read(<<1:32, 2:32, 131, 88>>) |> result.is_error
  assert literal_atoms.read(<<1:32, 8:32, 131, 119, 5, "a">>) |> result.is_error
}

fn nested(depth: Int, tail: BitArray) -> BitArray {
  case depth {
    0 -> tail
    _ -> nested(depth - 1, <<104, 1, tail:bits>>)
  }
}

pub fn nested_maps_lists_tuples_and_latin1_atoms_test() {
  let term = <<
    131,
    116,
    1:32,
    119,
    3,
    "key",
    104,
    2,
    100,
    1:16,
    233,
    108,
    1:32,
    119,
    4,
    "item",
    106,
  >>
  let bytes = <<1:32, { bit_array.byte_size(term) }:32, term:bits>>
  assert literal_atoms.read(bytes) == Ok(["item", "é", "key"])
}

pub fn unreasonable_child_count_is_refused_without_expansion_test() {
  let term = <<131, 116, 4_294_967_295:32>>
  let bytes = <<1:32, { bit_array.byte_size(term) }:32, term:bits>>
  assert literal_atoms.read(bytes)
    == Error("BEAM literal depth or node budget exceeded")
}
