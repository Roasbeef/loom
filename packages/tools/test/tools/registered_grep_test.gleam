//// Registered rg output fails as a whole while ordinary local skip behavior stays intact.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import tools/grep

pub fn strict_event_vocabulary_and_ordinary_skip_test() {
  let valid = line("a.gleam", 1)
  let assert Ok(hits) =
    parse(
      "{\"type\":\"begin\",\"data\":{}}\n"
      <> valid
      <> "{\"type\":\"end\",\"data\":{}}\n{\"type\":\"summary\",\"data\":{}}\n",
    )
    as "All fixed rg event kinds are recognized explicitly."
  assert grep.registered_hits(hits) == [grep.SearchHit("a.gleam", 1)]
  assert grep.registered_charge(hits) == 39
  list.each(
    [
      "garbage\n",
      "{\"type\":\"other\",\"data\":{}}\n",
      "{\"type\":\"match\",\"data\":{}}\n",
      string.drop_end(valid, 1),
    ],
    fn(bad) {
      assert parse(valid <> bad) == Error(grep.MalformedRegisteredSearch)
    },
  )
  assert grep.parse_matches("garbage\n" <> valid)
    == [grep.Match("a.gleam", 1, "hit")]
  let assert Ok(empty) = parse("")
    as "Zero matches have a valid empty projection."
  assert grep.registered_hits(empty) == []
}

pub fn fixed_file_hit_and_path_boundaries_test() {
  let four = string.repeat(line("a", 1), 4)
  assert parse(four) |> is_ok
  assert parse(four <> line("a", 1)) == Error(grep.RegisteredSearchLimit)
  let fifty =
    int.range(0, 50, with: [], run: fn(acc, n) { [n, ..acc] })
    |> list.map(fn(n) { line("p" <> int.to_string(n), 1) })
    |> string.concat
  assert parse(fifty) |> is_ok
  assert parse(fifty <> line("extra", 1)) == Error(grep.RegisteredSearchLimit)
  assert parse(line(string.repeat("x", 8192), 1)) |> is_ok
  assert parse(line(string.repeat("x", 8193), 1))
    == Error(grep.RegisteredSearchLimit)
  assert parse(line("x", 0)) == Error(grep.MalformedRegisteredSearch)
  assert parse(line("x", 9_223_372_036_854_775_807)) |> is_ok
  assert parse(line("x", 9_223_372_036_854_775_808))
    == Error(grep.MalformedRegisteredSearch)
}

pub fn complete_two_hundred_hit_reservation_and_raw_bound_test() {
  let output =
    int.range(0, 50, with: [], run: fn(acc, n) { [n, ..acc] })
    |> list.map(fn(n) {
      let path =
        int.to_string(n)
        <> string.repeat("x", 8192 - string.byte_size(int.to_string(n)))
      string.repeat(line(path, 1), 4)
    })
    |> string.concat
  let assert Ok(hits) = parse(output)
    as "Exactly200 path charges fit the complete reservation."
  assert list.length(grep.registered_hits(hits)) == 200
  assert grep.registered_charge(hits) == 1_644_800
  assert parse(output <> line("extra", 1)) == Error(grep.RegisteredSearchLimit)
  assert grep.registered_matches(
      bit_array.from_string(string.repeat("x", 4_194_305)),
    )
    == Error(grep.RegisteredSearchLimit)
  assert grep.registered_matches(<<255>>)
    == Error(grep.MalformedRegisteredSearch)
}

fn parse(text: String) {
  grep.registered_matches(bit_array.from_string(text))
}

fn line(path: String, number: Int) -> String {
  "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\""
  <> path
  <> "\"},\"line_number\":"
  <> int.to_string(number)
  <> ",\"lines\":{\"text\":\"hit\"}}}\n"
}

fn is_ok(value: Result(a, e)) -> Bool {
  case value {
    Ok(_) -> True
    Error(_) -> False
  }
}
