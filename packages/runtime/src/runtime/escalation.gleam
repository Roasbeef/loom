//// Durable approval escalations (design §5.3): the runtime-side record
//// of a broker denial awaiting a decision, the decision, and the single
//// consumed re-execution.
////
//// The broker's escalation state machine (`broker/escalation`) is pure
//// and process-local; §5.3 requires every lifecycle event to be
//// "recorded durably" before it is acted on. This module stores that
//// record in `fact.custom` registers under the reserved `escalation/`
//// key prefix, and the choice of registers over custom entries is
//// deliberate:
////
//// - an escalation is *current mutable state* (pending → approved →
////   consumed), which is exactly what registers are for; the tree is
////   write-once, so an entry-based record would need one entry per
////   transition plus a fold to answer "what is pending now";
//// - approval feeds back into tool clearance, which needs a bounded
////   point-lookup on the strand's hot path, not a branch scan;
//// - escalations must not move any strand's leaf or enter any context
////   projection — a mid-batch denial cannot be allowed to reparent the
////   conversation.
////
//// Status transitions are guarded by the register's seq (optimistic
//// CAS through the writer), so a lost race is a refused commit, never a
//// double consume. The denial and grant payloads are opaque JSON in the
//// broker's escalation vocabulary (`tools/tool.denial_to_json`,
//// `grant_to_json`); the runtime records and returns them without
//// interpreting them, keeping the spec's `E → A,B,C,D` dependency
//// direction intact (no broker import here).

import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// The observable lifecycle position of a durable escalation, mirroring
/// `broker/escalation.Status`.
pub type Status {
  /// Raised, awaiting a decision.
  Pending
  /// Approved with grants; the single re-execution has not run yet.
  Approved
  /// Rejected; no re-execution will ever run.
  Rejected
  /// The single approved re-execution has been taken.
  Consumed
}

/// One durable escalation record — the `fact.custom` payload stored
/// under `escalation/{id}`.
///
/// Constructor invariants: `id` is the caller-assigned stable escalation
/// id; `denial` is the structured denial as opaque JSON (reason, source,
/// wanted grants); `grants` is empty until approval and then holds the
/// approved grant JSON values, a subset of the denial's wanted diff
/// (enforced by the broker layer that raises and approves, not re-checked
/// here); `status` moves only Pending → Approved → Consumed or Pending →
/// Rejected.
pub type Escalation {
  Escalation(
    id: String,
    denial: JsonValue,
    grants: List(JsonValue),
    status: Status,
  )
}

/// The reserved `fact.custom` key prefix escalations live under. Fact
/// writes through the api refuse keys under this prefix.
pub const key_prefix = "escalation/"

/// The `fact.custom` register key for an escalation id.
///
/// ## Examples
///
/// ```gleam
/// assert escalation.register_key("esc-1") == "escalation/esc-1"
/// ```
///
pub fn register_key(id: String) -> String {
  key_prefix <> id
}

/// Encodes an escalation record as its stored register payload.
///
/// ## Examples
///
/// ```gleam
/// // escalation.encode(record) |> escalation.decode == Ok(record)
/// ```
///
pub fn encode(escalation: Escalation) -> JsonValue {
  json.Object([
    #("id", json.String(escalation.id)),
    #("denial", escalation.denial),
    #("grants", json.Array(escalation.grants)),
    #("status", json.String(status_to_string(escalation.status))),
  ])
}

/// Decodes a stored escalation payload. Total: anything malformed is a
/// corruption report, never a crash.
///
/// ## Examples
///
/// ```gleam
/// // escalation.decode(payload)
/// ```
///
pub fn decode(payload: JsonValue) -> Result(Escalation, CorruptionReport) {
  let where = "runtime/escalation.decode"
  case payload {
    json.Object(fields) -> {
      use id <- result.try(require_string(fields, "id", where))
      use denial <- result.try(require(fields, "denial", where))
      use grants_value <- result.try(require(fields, "grants", where))
      use grants <- result.try(case grants_value {
        json.Array(items) -> Ok(items)
        _ ->
          Error(corruption.report(
            at: where,
            on: "grants",
            expected: "an array of grant values",
            context: json.to_string(grants_value),
          ))
      })
      use status_text <- result.try(require_string(fields, "status", where))
      use status <- result.try(status_from_string(status_text, where))
      Ok(Escalation(id:, denial:, grants:, status:))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "payload",
        expected: "an escalation object",
        context: json.to_string(other),
      ))
  }
}

fn status_to_string(status: Status) -> String {
  case status {
    Pending -> "pending"
    Approved -> "approved"
    Rejected -> "rejected"
    Consumed -> "consumed"
  }
}

fn status_from_string(
  text: String,
  where: String,
) -> Result(Status, CorruptionReport) {
  case text {
    "pending" -> Ok(Pending)
    "approved" -> Ok(Approved)
    "rejected" -> Ok(Rejected)
    "consumed" -> Ok(Consumed)
    other ->
      Error(corruption.report(
        at: where,
        on: "status",
        expected: "pending, approved, rejected, or consumed",
        context: other,
      ))
  }
}

fn require(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(JsonValue, CorruptionReport) {
  case list.key_find(fields, key) {
    Ok(value) -> Ok(value)
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a present field",
        context: "absent",
      ))
  }
}

fn require_string(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.String(text) -> Ok(text)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a string",
        context: json.to_string(other),
      ))
  }
}

/// Whether a decided escalation may transition to `to` from its current
/// status: Pending decides (Approved/Rejected), Approved consumes.
///
/// ## Examples
///
/// ```gleam
/// assert escalation.may_become(escalation.Pending, escalation.Approved)
/// assert !escalation.may_become(escalation.Consumed, escalation.Consumed)
/// ```
///
pub fn may_become(from: Status, to: Status) -> Bool {
  case from, to {
    Pending, Approved | Pending, Rejected -> True
    Approved, Consumed -> True
    _, _ -> False
  }
}

/// The approved-but-unconsumed records in a decoded listing — the grants
/// a tool clearance is entitled to.
///
/// ## Examples
///
/// ```gleam
/// // escalation.approved(records)
/// ```
///
pub fn approved(records: List(Escalation)) -> List(Escalation) {
  list.filter(records, fn(record) { record.status == Approved })
}

/// Marks a record consumed (the caller commits it CAS-guarded).
///
/// ## Examples
///
/// ```gleam
/// // escalation.consume(record).status == escalation.Consumed
/// ```
///
pub fn consume(record: Escalation) -> Escalation {
  Escalation(..record, status: Consumed)
}

/// A fresh pending record for a raised denial.
///
/// ## Examples
///
/// ```gleam
/// // escalation.raised("esc-1", denial_json)
/// ```
///
pub fn raised(id: String, denial: JsonValue) -> Escalation {
  Escalation(id:, denial:, grants: [], status: Pending)
}

/// The record after an approval with `grants`.
///
/// ## Examples
///
/// ```gleam
/// // escalation.approve(record, grants)
/// ```
///
pub fn approve(record: Escalation, grants: List(JsonValue)) -> Escalation {
  Escalation(..record, grants:, status: Approved)
}

/// The record after a rejection.
///
/// ## Examples
///
/// ```gleam
/// // escalation.reject(record)
/// ```
///
pub fn reject(record: Escalation) -> Escalation {
  Escalation(..record, status: Rejected)
}

/// The bare escalation id when the register key carries the escalation
/// prefix.
///
/// ## Examples
///
/// ```gleam
/// assert escalation.id_of_key("escalation/esc-1") == option.Some("esc-1")
/// ```
///
pub fn id_of_key(key: String) -> option.Option(String) {
  case string.starts_with(key, key_prefix) {
    True -> Some(string.drop_start(key, string.length(key_prefix)))
    False -> None
  }
}
