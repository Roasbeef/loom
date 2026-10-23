//// Catalogue continuations preserve complete descriptors under escaped byte bounds.

import client/evolution/page
import core/json
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn whole_items_stop_before_byte_budget_and_resume_exactly_test() {
  let first =
    json.Object([
      #("candidate_id", json.String("first")),
      #(
        "schema",
        json.Object([
          #("enum", json.Array([json.String(string.repeat("🌿", 2500))])),
        ]),
      ),
    ])
  let second =
    json.Object([
      #("candidate_id", json.String("second")),
      #(
        "schema",
        json.Object([
          #("enum", json.Array([json.String(string.repeat("x", 8000))])),
        ]),
      ),
    ])
  let assert Ok(start) = page.items([first, second], json.Object([]), 16_384)
    as "the first descriptor fits whole"
  start.values |> should.equal([first])
  start.next_offset |> should.equal(Some(1))
  let assert Ok(end) =
    page.items([first, second], json.Object([#("offset", json.Int(1))]), 16_384)
    as "the second descriptor resumes at its exact position"
  end.values |> should.equal([second])
  end.next_offset |> should.equal(None)
  assert bit_array.byte_size(
      bit_array.from_string(json.to_string(page.items_json(start))),
    )
    < 16_500
    as "one page fits its reserved envelope space"
}

pub fn count_is_bounded_and_invalid_offsets_are_refused_test() {
  let values = list.repeat(json.Int(1), 20)
  let assert Ok(first) = page.items(values, json.Object([]), 30_720)
    as "default count is eight"
  list.length(first.values) |> should.equal(8)
  first.next_offset |> should.equal(Some(8))
  page.items(values, json.Object([#("count", json.Int(9))]), 30_720)
  |> should.be_error
  page.items(values, json.Object([#("offset", json.Int(-1))]), 30_720)
  |> should.be_error
  page.items(values, json.Object([#("offset", json.Int(21))]), 30_720)
  |> should.be_error
}

pub fn escaped_json_is_measured_without_clipping_schema_test() {
  let too_big =
    json.Object([#("schema", json.String(string.repeat("\n", 20_000)))])
  page.items([too_big], json.Object([]), 30_720) |> should.be_error
  let assert Ok(empty) = page.items([], json.Object([]), 30_720)
    as "an empty catalogue is already terminal"
  empty.next_offset |> should.equal(None)
  empty.total |> should.equal(0)
}
