//// Bounded field witnesses for the adapters' usage snapshots.
////
//// Numeric defaults preserve compatible endpoints, but cannot prove that an
//// endpoint reported a bucket. `observe` remembers only the fixed field paths
//// supplied by an adapter. Repeated snapshots replace counts in that adapter;
//// this witness only retains which buckets were actually measured.
//// `snapshot` remains partial before the final usage witness, and `finished`
//// can establish complete coverage only when every required bucket is known.

import core/json.{type JsonValue}
import core/usage_evidence.{type Billing, type Evidence}
import gleam/list
import gleam/result
import gleam/string
import provider/internal/wire

/// Only adapter-selected paths enter this bounded set.
pub opaque type Witness {
  /// Every retained path comes from the adapter's fixed bucket vocabulary.
  Witness(
    /// Valid bucket paths observed at least once in this attempt.
    fields: List(String),
  )
}

/// No remote usage has been observed yet.
///
/// ## Examples
///
/// ```gleam
/// // usage_witness.new()
/// ```
pub fn new() -> Witness {
  Witness([])
}

/// Retains valid integer witnesses without adding repeated token snapshots.
/// Invalid and saturated counters keep their lenient numeric interpretation,
/// but do not establish complete measurement coverage.
///
/// ## Examples
///
/// ```gleam
/// // usage_witness.observe(witness, usage, ["input_tokens"])
/// ```
pub fn observe(
  previous: Witness,
  value: JsonValue,
  paths: List(String),
) -> Witness {
  Witness(
    list.fold(paths, previous.fields, fn(fields, path) {
      case counter(value, string.split(path, ".")) {
        Ok(count) if count >= 0 && count <= wire.max_usage_count ->
          case list.contains(fields, path) {
            True -> fields
            False -> [path, ..fields]
          }

        Ok(_) -> list.filter(fields, fn(known) { known != path })
        Error(Nil) -> fields
      }
    }),
  )
}

/// A live snapshot cannot prove the final output count.
///
/// ## Examples
///
/// ```gleam
/// // usage_witness.snapshot(witness, usage_evidence.Api)
/// ```
pub fn snapshot(witness: Witness, billing: Billing) -> Evidence {
  case witness.fields {
    [] -> usage_evidence.unknown(billing)
    [_, ..] -> usage_evidence.partial(billing)
  }
}

/// Final usage is complete only with witnesses for every priced bucket.
///
/// ## Examples
///
/// ```gleam
/// // usage_witness.finished(witness, required, usage_evidence.Api)
/// ```
pub fn finished(
  witness: Witness,
  required: List(String),
  billing: Billing,
) -> Evidence {
  case list.all(required, fn(path) { list.contains(witness.fields, path) }) {
    True -> usage_evidence.reported(billing)
    False -> snapshot(witness, billing)
  }
}

// Paths are fixed by the adapter, so their depth cannot grow with remote input.
fn counter(value: JsonValue, path: List(String)) -> Result(Int, Nil) {
  case path {
    [field] -> wire.int_field(value, field)
    [field, ..rest] -> {
      use child <- result.try(wire.field(value, field))
      counter(child, rest)
    }
    [] -> Error(Nil)
  }
}
