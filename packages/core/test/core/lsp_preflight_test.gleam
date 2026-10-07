//// Fixed LSP raw profiles reject allocation bombs before semantic decoding.

import core/internal/msgpack_scan as scan
import core/msgpack as m
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

pub fn complete_header_8192_boundary_counts_timing_inside_reservation_test() {
  let assert Ok(exact) = m.encode(m.StringValue(string.repeat("a", 8189)))
    as "The exact header-sized raw value encodes."
  assert bit_array.byte_size(exact) == 8192
  assert scan.lsp_header(exact) == Ok(Nil)
  let assert Ok(over) = m.encode(m.StringValue(string.repeat("a", 8190)))
    as "The one-byte-over raw value encodes."
  assert bit_array.byte_size(over) == 8193
  assert scan.lsp_header(over) |> result.is_error
}

pub fn request_aggregate_nodes_and_nesting_are_not_per_array_budgets_test() {
  let assert Ok(exact) = m.encode(m.ArrayValue(list.repeat(m.NilValue, 1023)))
    as "One root plus 1023 leaves uses the exact shared node budget."
  assert scan.lsp_request(exact) == Ok(Nil)
  let assert Ok(over) = m.encode(m.ArrayValue(list.repeat(m.NilValue, 1024)))
    as "The one-node-over raw value encodes."
  assert scan.lsp_request(over) |> result.is_error
  let exact_depth =
    list.fold(list.repeat(Nil, 8), m.NilValue, fn(value, _) {
      m.ArrayValue([value])
    })
  let assert Ok(bytes) = m.encode(exact_depth)
    as "The exact fixed nesting boundary encodes."
  assert scan.lsp_request(bytes) == Ok(Nil)
  let assert Ok(over) = m.encode(m.ArrayValue([exact_depth]))
    as "A ninth nested container encodes."
  assert scan.lsp_request(over) |> result.is_error
}

pub fn result_full_enclosing_budget_and_row_arrays_have_exact_limits_test() {
  let assert Ok(exact) = m.encode(m.StringValue(string.repeat("a", 4_464_891)))
    as "The complete result shell fits its independent raw reservation."
  assert bit_array.byte_size(exact) == 4_464_896
  assert scan.lsp_result(exact) == Ok(Nil)
  let assert Ok(over) = m.encode(m.StringValue(string.repeat("a", 4_464_892)))
    as "The one-byte-over body encodes."
  assert scan.lsp_result(over) |> result.is_error
  let assert Ok(rows) = m.encode(m.ArrayValue(list.repeat(m.NilValue, 10_000)))
    as "The exact per-array row boundary encodes."
  assert scan.lsp_result(rows) == Ok(Nil)
  assert scan.lsp_result(<<0xdc, 10_001:16>>) |> result.is_error
}

pub fn declared_length_node_bombs_and_alignment_refuse_raw_test() {
  assert scan.lsp_request(<<0xdb, 131_073:32>>) |> result.is_error
  assert scan.lsp_result(<<0xdb, 4_464_897:32>>) |> result.is_error
  assert scan.lsp_result(<<0xdd, 200_001:32>>) |> result.is_error
  assert scan.lsp_header(<<0xc4, 33, 0:size(264)>>) |> result.is_error
  assert scan.lsp_result(<<1:size(1)>>) |> result.is_error
  assert scan.lsp_result(<<0xc0, 0xc0>>) |> result.is_error
}

pub fn result_node_budget_is_shared_across_individually_legal_arrays_test() {
  let full = m.ArrayValue(list.repeat(m.NilValue, 10_000))
  let exact =
    m.ArrayValue(
      list.append(list.repeat(full, 19), [
        m.ArrayValue(list.repeat(m.NilValue, 9979)),
      ]),
    )
  let assert Ok(bytes) = m.encode(exact)
    as "One root, twenty arrays and 199979 leaves use exactly 200000 nodes."
  assert scan.lsp_result(bytes) == Ok(Nil)
  let over =
    m.ArrayValue(
      list.append(list.repeat(full, 19), [
        m.ArrayValue(list.repeat(m.NilValue, 9980)),
      ]),
    )
  let assert Ok(bytes) = m.encode(over)
    as "Every individual array remains below its own ceiling."
  assert scan.lsp_result(bytes) |> result.is_error
}
