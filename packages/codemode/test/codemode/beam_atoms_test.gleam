//// Binary container checks execute before any atomizing BEAM API.

import codemode/beam_atoms
import codemode/internal/ffi_zlib
import gleam/bit_array
import gleam/list
import simplifile

pub fn otp29_compact_atom_lengths_test() {
  let payload = <<
    "AtU8",
    24:32,
    4_294_967_294:32,
    16:8,
    "a",
    8:8,
    16:8,
    "abcdefghijklmnop",
  >>
  let bytes = <<
    "FOR1",
    { bit_array.byte_size(payload) + 4 }:32,
    "BEAM",
    payload:bits,
  >>
  assert beam_atoms.read(bytes) == Ok(["a", "abcdefghijklmnop"])
}

pub fn scans_literals_after_atom_table_test() {
  let atoms = <<"AtU8", 6:32, 1:32, 1:8, "a", 0:16>>
  let literals = <<"LitT", 4:32, 8_388_609:32>>
  let payload = <<atoms:bits, literals:bits>>
  let bytes = <<
    "FOR1",
    { bit_array.byte_size(payload) + 4 }:32,
    "BEAM",
    payload:bits,
  >>
  assert beam_atoms.read(bytes) == Error("BEAM expanded literals exceed 8 MiB")
}

pub fn accepts_bounded_literal_table_test() {
  let payload = <<"AtU8", 6:32, 1:32, 1:8, "a", 0:16, "LitT", 8:32, 0:32, 0:32>>
  let bytes = <<
    "FOR1",
    { bit_array.byte_size(payload) + 4 }:32,
    "BEAM",
    payload:bits,
  >>
  assert beam_atoms.read(bytes) == Ok(["a"])
}

pub fn malformed_container_refused_test() {
  assert beam_atoms.read(<<"FOR1", 20:32, "BEAM">>)
    == Error("BEAM container length differs")
}

pub fn compressed_literal_constructor_is_counted_before_load_test() {
  let bytes = <<
    70,
    79,
    82,
    49,
    0,
    0,
    0,
    84,
    66,
    69,
    65,
    77,
    65,
    116,
    85,
    56,
    0,
    0,
    0,
    6,
    0,
    0,
    0,
    1,
    1,
    97,
    0,
    0,
    76,
    105,
    116,
    84,
    0,
    0,
    0,
    55,
    0,
    0,
    0,
    45,
    120,
    156,
    99,
    96,
    96,
    96,
    100,
    96,
    96,
    80,
    109,
    206,
    1,
    146,
    140,
    229,
    50,
    69,
    169,
    101,
    153,
    169,
    229,
    241,
    165,
    121,
    153,
    133,
    165,
    169,
    241,
    57,
    153,
    37,
    169,
    69,
    137,
    57,
    241,
    137,
    73,
    201,
    21,
    149,
    85,
    89,
    0,
    240,
    160,
    13,
    216,
    0,
  >>
  assert beam_atoms.read(bytes) == Ok(["a", "review_unique_literal_abcxyz"])
}

/// Reads actual compiler output as bytes; it is never passed to a VM loader.
pub fn actual_compiled_constructor_literal_is_accounted_test() {
  let assert Ok(bytes) =
    simplifile.read_bits("test/fixtures/live_literal_probe.bin")
    as "the actual OTP29 compiler fixture is present"
  let assert Ok(atoms) = beam_atoms.read(bytes)
    as "the real BEAM container is valid"
  assert list.contains(atoms, "review_unique_literal_abcxyz")
    as "constructor atom hidden in LitT is reserved before loading"
}

pub fn compressed_literal_actual_size_is_bounded_test() {
  let assert Ok(bytes) =
    simplifile.read_bits("test/fixtures/live_literal_oversized_zlib.bin")
    as "bounded compressed bomb fixture exists"
  assert ffi_zlib.literal_bytes(bytes)
    == Error("invalid or oversized BEAM literal compression")
  assert ffi_zlib.literal_bytes(<<4:32, 1, 2, 3>>)
    == Error("invalid or oversized BEAM literal compression")
}
