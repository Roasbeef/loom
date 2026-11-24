//// The dismissal record's tests pin its stored shape, its total decoder and the
//// rule that a dismissal covers one failure of one strand and nothing else.

import core/attention_dismissal.{Dismissal}
import core/json
import gleam/list

fn seen() -> attention_dismissal.Dismissal {
  Dismissal(
    strand: "sub:main/audit-1a2b",
    operation: "0194f7b2-aaaa-7000-8000-000000000001",
    at: 1_790_000_000_000,
    by: "owner-1",
  )
}

pub fn key_is_the_prefix_and_the_strand_test() {
  assert attention_dismissal.key("sub:main/a") == "attention/stuck/sub:main/a"
}

pub fn a_dismissal_round_trips_test() {
  assert attention_dismissal.decode(attention_dismissal.encode(seen()))
    == Ok(seen())
}

pub fn the_decoder_refuses_a_missing_or_mistyped_field_test() {
  let fields = [
    #("strand", json.String("sub:a")),
    #("operation", json.String("op")),
    #("at", json.Int(1)),
    #("by", json.String("owner")),
  ]

  // Removing any one field, or giving it another type, is refused.
  list.each(fields, fn(each) {
    let without = list.filter(fields, fn(other) { other.0 != each.0 })
    assert attention_dismissal.decode(json.Object(without))
      != Ok(Dismissal("sub:a", "op", 1, "owner"))
    let assert Error(_) = attention_dismissal.decode(json.Object(without))
    let wrong =
      list.map(fields, fn(other) {
        case other.0 == each.0 {
          True -> #(other.0, json.Bool(True))
          False -> other
        }
      })
    let assert Error(_) = attention_dismissal.decode(json.Object(wrong))
  })
}

pub fn the_decoder_refuses_a_value_that_is_not_an_object_test() {
  let assert Error(_) = attention_dismissal.decode(json.Null)
  let assert Error(_) = attention_dismissal.decode(json.String("seen"))
  let assert Error(_) = attention_dismissal.decode(json.Array([]))
  let assert Error(_) = attention_dismissal.decode(json.Int(3))
}

pub fn a_dismissal_covers_its_own_failure_only_test() {
  let dismissals = [seen()]

  // The same strand and operation is covered.
  assert attention_dismissal.covers(
    dismissals,
    "sub:main/audit-1a2b",
    "0194f7b2-aaaa-7000-8000-000000000001",
  )

  // A new failure of the same strand has another operation.
  assert !attention_dismissal.covers(
    dismissals,
    "sub:main/audit-1a2b",
    "0194f7b2-aaaa-7000-8000-000000000002",
  )

  // Another strand with the same operation is not covered.
  assert !attention_dismissal.covers(
    dismissals,
    "sub:main/other",
    "0194f7b2-aaaa-7000-8000-000000000001",
  )
  assert !attention_dismissal.covers([], "sub:main/audit-1a2b", "x")
}
