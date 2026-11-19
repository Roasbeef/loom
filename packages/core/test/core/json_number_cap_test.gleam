//// The digit cap on JSON numbers: a run at `max_number_digits` parses, a run
//// one past it is refused, and so is a run far past it, in each of the
//// integer part, the fraction and the exponent.

import core/json
import gleam/int
import gleam/result
import gleam/string

fn digits(count: Int) -> String {
  string.repeat("7", count)
}

fn refused(text: String) -> Bool {
  result.is_error(json.parse(text))
}

pub fn integer_at_cap_parses_test() {
  let assert Ok(json.Int(value)) = json.parse(digits(json.max_number_digits))
  assert int.to_string(value) == digits(json.max_number_digits)
}

pub fn integer_past_cap_refused_test() {
  assert refused(digits(json.max_number_digits + 1))
  assert refused(digits(10_000))
  assert refused("-" <> digits(10_000))
}

pub fn fraction_at_cap_parses_test() {
  let assert Ok(json.Float(_)) =
    json.parse("0." <> digits(json.max_number_digits))
}

pub fn fraction_past_cap_refused_test() {
  assert refused("0." <> digits(json.max_number_digits + 1))
  assert refused("0." <> digits(10_000))
}

pub fn exponent_at_cap_parses_test() {
  let assert Ok(json.Float(_)) =
    json.parse("1e-" <> string.repeat("0", json.max_number_digits))
}

pub fn exponent_past_cap_refused_test() {
  assert refused("1e-" <> string.repeat("0", json.max_number_digits + 1))
  assert refused("1e" <> string.repeat("0", 10_000))
}

pub fn cap_applies_inside_a_container_test() {
  assert refused("[" <> digits(10_000) <> "]")
  assert refused("{\"n\": " <> digits(10_000) <> "}")
}
