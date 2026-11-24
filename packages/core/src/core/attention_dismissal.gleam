//// The owner's acknowledgement of a stuck strand's failure, as the session
//// store keeps it (protocol-change/131).
////
//// A strand is stuck while its last terminal result is a failed run. Nothing
//// else records that a person has read the failure and decided to leave it, so
//// the feed listed the strand until it ran again. A dismissal is that record:
//// one reserved cell per strand, naming the strand and the operation of the
//// failed run it covers.
////
//// ## Why the failure is part of the key's meaning
////
//// A dismissal covers one failure, not one strand. A strand that was dismissed
//// and later failed again has a new operation, so `covers` is false for it and
//// the strand is listed again, with no change to the record. Keying by the
//// strand alone would hide that second failure from a person who never saw it.
////
//// ## Why `core`
////
//// The daemon writes the record and the feed reads it, and the codec has no
//// process or external, so it compiles for both targets as `core/attention`
//// does. The decision of whether a dismissal covers a failure is pure and lives
//// here so the feed and its tests name one rule.
////
//// ## Flow
////
//// `key` → `encode` → `decode` → `covers`
////
//// 1. The host names the strand's cell with `key` and writes `encode`'s payload.
//// 2. A reader scans the cells under the reserved prefix, runs `decode` on each cell and drops the ones that
////    come back `Error`, so a damaged cell covers nothing.
//// 3. The feed asks `covers` of each stuck strand's name and failed operation.

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/list

/// The reserved prefix a dismissal's cell lives under.
pub const prefix = "attention/stuck/"

/// One acknowledged failure of one strand.
pub type Dismissal {
  Dismissal(
    /// The strand, repeated from the key so a scan needs no key parsing.
    strand: String,
    /// The operation identifier of the failed run that was dismissed, in
    /// canonical UUID text: the identity of the failure.
    operation: String,
    /// Unix milliseconds on the daemon's clock when the dismissal was written.
    at: Int,
    /// The principal the registry resolved for the caller.
    by: String,
  )
}

/// The cell a strand's dismissal lives in.
///
/// ## Examples
///
/// ```gleam
/// assert attention_dismissal.key("sub:main/a")
///   == "attention/stuck/sub:main/a"
/// ```
pub fn key(strand: String) -> String {
  prefix <> strand
}

/// The stored payload of a dismissal.
///
/// ## Examples
///
/// ```gleam
/// let stored = attention_dismissal.Dismissal("sub:a", "op-1", 5, "owner")
/// assert attention_dismissal.decode(attention_dismissal.encode(stored))
///   == Ok(stored)
/// ```
pub fn encode(dismissal: Dismissal) -> JsonValue {
  json.Object([
    #("strand", json.String(dismissal.strand)),
    #("operation", json.String(dismissal.operation)),
    #("at", json.Int(dismissal.at)),
    #("by", json.String(dismissal.by)),
  ])
}

/// Decodes a stored dismissal. Total: anything `encode` did not produce is a
/// `CorruptionReport` naming what was expected.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = attention_dismissal.decode(json.Null)
/// ```
pub fn decode(value: JsonValue) -> Result(Dismissal, CorruptionReport) {
  // A dismissal is an object whose four fields all have their stored types.
  case value {
    json.Object(fields) ->
      case
        list.key_find(fields, "strand"),
        list.key_find(fields, "operation"),
        list.key_find(fields, "at"),
        list.key_find(fields, "by")
      {
        Ok(json.String(strand)),
          Ok(json.String(operation)),
          Ok(json.Int(at)),
          Ok(json.String(by))
        -> Ok(Dismissal(strand:, operation:, at:, by:))
        _, _, _, _ -> Error(corrupt(value))
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(corrupt(value))
  }
}

/// Whether some dismissal acknowledges this failure: the same strand and the
/// same failed operation. A failure with another operation is a new failure,
/// and another strand's dismissal covers nothing.
///
/// ## Examples
///
/// ```gleam
/// let seen = attention_dismissal.Dismissal("sub:a", "op-1", 5, "owner")
/// assert attention_dismissal.covers([seen], "sub:a", "op-1")
/// assert !attention_dismissal.covers([seen], "sub:a", "op-2")
/// ```
pub fn covers(
  dismissals: List(Dismissal),
  strand: String,
  operation: String,
) -> Bool {
  list.any(dismissals, fn(each) {
    each.strand == strand && each.operation == operation
  })
}

/// The report for a cell that is not a dismissal.
fn corrupt(seen: JsonValue) -> CorruptionReport {
  corruption.report(
    at: "core/attention_dismissal",
    on: "attention dismissal",
    expected: "an object with string `strand`, `operation` and `by` and an integer `at`",
    context: json.to_string(seen),
  )
}
