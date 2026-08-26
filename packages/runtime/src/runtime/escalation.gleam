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
////
//// An approval is attributed, never ambient (design §5.3: *one*
//// re-execution of the denied action, not a session-wide widening). The
//// record therefore carries the exact call identity it is currently
//// raised for — `{operation, strand, step, source index, call id}` — and
//// the driver's clearance path spends a grant only on a clearance whose
//// coordinates match. A record raised without a scope can still be spent
//// explicitly (`api.consume_escalation`) by a host that re-executes
//// outside the strand's own clearance, but no tool clearance will ever
//// load it: an unattributable grant failing to widen anything is the
//// safe direction.
////
//// The scope is the call holding the *claim*, and a claim moves
//// (`claimed`, committed under CAS by `api.claim_escalation`). It has to:
//// a record's id is a digest of the want rather than of the call, so a
//// model that reads an in-band refusal and retries arrives under a call
//// id the provider has only just minted, and a scope frozen to the first
//// attempt would name a call nothing can re-clear. What the exactness
//// buys is unchanged by that — one claimant at a time, one CAS from
//// `Approved` to `Consumed`, so one approval is one widened execution of
//// one call — and only a call whose denial digests to the same record id
//// can ever hold the claim, which is to say the same want, on the same
//// strand, through the same tool.

import core/corruption.{type CorruptionReport}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
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

/// The exact call a denial was raised for: which planned tool call, on
/// which strand, inside which operation and step. This is the unit an
/// approval attaches to — a clearance spends a grant only when every
/// coordinate matches, so an approval granted for one call can never
/// widen a different one (a different strand's, or a different step's).
///
/// A record's scope is the call that *currently holds the claim*, not
/// the call that first raised it. A later call whose denial digests to
/// the same record id — the same strand, the same tool, the same wanted
/// diff — takes the claim over (`claimed`, committed CAS-guarded by
/// `api.claim_escalation`), because a model that reads an in-band
/// refusal and retries always arrives under a call id the provider has
/// only just minted, and a scope frozen to a call that will never come
/// back is an approval nothing can ever spend. What the exactness buys
/// is still the whole of it: at any instant exactly one call holds the
/// claim, so exactly one call can consume the approval.
///
/// Constructor invariants: `operation`, `step_id`, and `source_index`
/// are the planner's coordinates for the planned call (the same triple
/// `ToolClearanceKey` carries); `strand` is the strand whose driver
/// clears it; `call_id` is the provider-minted tool call id, which names
/// exactly one call in the tree.
pub type CallScope {
  CallScope(
    operation: OpId,
    strand: String,
    step_id: String,
    source_index: Int,
    call_id: String,
  )
}

/// One durable escalation record — the `fact.custom` payload stored
/// under `escalation/{id}`.
///
/// Constructor invariants: `id` is the caller-assigned stable escalation
/// id; `denial` is the structured denial as opaque JSON (reason, source,
/// wanted grants); `scope` is the exact call the denial was raised for
/// (`None` only for records raised through the unscoped legacy path,
/// which no clearance will ever spend); `grants` is empty until approval
/// and then holds the approved grant JSON values, a subset of the
/// denial's wanted diff (enforced by the broker layer that raises and
/// approves, not re-checked here); `status` moves only Pending →
/// Approved → Consumed or Pending → Rejected within one decision cycle,
/// and a fresh raise for the same want (`claimed`) starts a new cycle
/// from a decided record.
pub type Escalation {
  Escalation(
    id: String,
    denial: JsonValue,
    scope: Option(CallScope),
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
    #("scope", encode_scope(escalation.scope)),
    #("grants", json.Array(escalation.grants)),
    #("status", json.String(status_to_string(escalation.status))),
  ])
}

fn encode_scope(scope: Option(CallScope)) -> JsonValue {
  case scope {
    None -> json.Null
    Some(scope) ->
      json.Object([
        #("operation", json.String(ids.op_id_to_string(scope.operation))),
        #("strand", json.String(scope.strand)),
        #("stepId", json.String(scope.step_id)),
        #("sourceIndex", json.Int(scope.source_index)),
        #("callId", json.String(scope.call_id)),
      ])
  }
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
      use scope <- result.try(decode_scope(fields, where))
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
      Ok(Escalation(id:, denial:, scope:, grants:, status:))
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

// A stored scope decodes totally: an absent or null field is an unscoped
// record (the legacy shape, spendable only explicitly), while a present
// object must decode in full — a half-readable scope is corruption, not
// a record to fall back to unscoped, because falling back would change
// which calls the grant reaches.
fn decode_scope(
  fields: List(#(String, JsonValue)),
  where: String,
) -> Result(Option(CallScope), CorruptionReport) {
  case list.key_find(fields, "scope") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Object(scope_fields)) -> {
      use operation_text <- result.try(require_string(
        scope_fields,
        "operation",
        where,
      ))
      use operation <- result.try(ids.parse_op_id(operation_text))
      use strand <- result.try(require_string(scope_fields, "strand", where))
      use step_id <- result.try(require_string(scope_fields, "stepId", where))
      use source_index <- result.try(require_int(
        scope_fields,
        "sourceIndex",
        where,
      ))
      use call_id <- result.try(require_string(scope_fields, "callId", where))
      Ok(
        Some(CallScope(operation:, strand:, step_id:, source_index:, call_id:)),
      )
    }
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: "scope",
        expected: "null or a call-scope object",
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

fn require_int(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Int(number) -> Ok(number)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an integer",
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

/// A fresh pending record for a raised denial. `scope` is the exact call
/// the denial names; `None` records a legacy unscoped escalation that
/// only an explicit `consume_escalation` can ever spend.
///
/// ## Examples
///
/// ```gleam
/// // escalation.raised("esc-1", denial_json, Some(scope))
/// ```
///
pub fn raised(
  id: String,
  denial: JsonValue,
  scope: Option(CallScope),
) -> Escalation {
  Escalation(id:, denial:, scope:, grants: [], status: Pending)
}

/// The record after `scope`'s call raises the same denial against it —
/// the state transition `api.claim_escalation` commits under a CAS.
///
/// One record is one *question*, identified by the digest of the want
/// (`client/escalate.record_id`), and this is the only thing that moves
/// a question from one call to another. Which call holds it matters
/// because a scoped approval is spent by the claimant and nobody else:
///
/// - **Pending** — nobody has decided yet, so the claim simply moves and
///   the stored denial is refreshed to the live call's. One row, one
///   prompt, and the human reads what the call in hand actually wants.
/// - **Approved** — a human said yes to this want, on this strand, for
///   this tool, and the grants they chose are unchanged; the claim moves
///   so the approval can be spent by a call that exists. It cannot
///   widen anything beyond what was approved: the grants are the
///   record's, not the claimant's.
/// - **Rejected** or **Consumed** — the previous cycle is over. A new
///   raise re-opens the question as `Pending` with no grants, so one
///   approval stays worth exactly one execution and one denial stays a
///   decision about one call rather than a session-lifetime verdict on
///   the want.
///
/// ## Examples
///
/// ```gleam
/// // escalation.claimed(record, denial, scope).scope == option.Some(scope)
/// ```
///
pub fn claimed(
  record: Escalation,
  denial: JsonValue,
  scope: CallScope,
) -> Escalation {
  case record.status {
    Pending -> Escalation(..record, denial:, scope: Some(scope))
    Approved -> Escalation(..record, scope: Some(scope))
    Rejected | Consumed -> raised(record.id, denial, Some(scope))
  }
}

/// Whether an escalation's scope names exactly this call. Unscoped
/// records match nothing — a grant that cannot be attributed must not
/// widen anything (the safe direction: skipping a record can only
/// narrow what a call receives).
///
/// ## Examples
///
/// ```gleam
/// // escalation.scoped_to(record, scope) == True
/// ```
///
pub fn scoped_to(record: Escalation, scope: CallScope) -> Bool {
  record.scope == Some(scope)
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
