//// The lineage ledger: the durable record of who spawned whom.
////
//// A subagent strand is an ordinary strand — same tree, own registers —
//// so nothing in `machine` distinguishes one a model started from one an
//// operator started. The Agency (`client/agency`) needs that distinction
//// for three separate reasons, and all three want the same answer to
//// survive a restart:
////
//// - **Addressing.** A strand may wait only on a descendant and may
////   address only its parent or a descendant. That rule is what makes the
////   wait graph acyclic, and it is decided from the parent edge recorded
////   here, never from anything the model says.
//// - **Bounds.** Depth and fan-out are counted from this ledger against
////   the live strand set, so a restart does not reset a counter and an
////   operator can read the whole tree with one prefix scan.
//// - **Idempotent spawning.** `agent_spawn` is `ReplaySafe` because the
////   child's name is derived from the persisted call site; the cell
////   written here is what tells a replayed spawn that the first execution
////   already landed.
////
//// It is a `fact.custom` cell rather than a field on `StrandConfiguration`
//// because adding a field there touches a `machine` type and every
//// strand's register payload for state only the Agency reads. Revisit if
//// lineage ever becomes load-bearing elsewhere.
////
//// ## Why the prefix is `lineage/` and not `agency/`
////
//// The model-writable blackboard namespace is `agent/`. An
//// integrity-critical ledger whose prefix differs from the model-writable
//// one by two letters is one typo in `api.reserved_fact_key` away from
//// letting a blackboard write forge a parent edge — and the acyclicity
//// argument rests entirely on parent edges being unforgeable. `lineage/`
//// shares no prefix with `agent/` at all, so the guard cannot be
//// weakened by a near-miss. `api.put_fact` refuses this prefix; the
//// Agency writes through `api.put_reserved_fact` and reads through
//// `api.reserved_facts`, both of which are harness-only paths that no
//// model argument reaches.

import core/corruption.{type CorruptionReport}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The persisted coordinates of the tool call that minted a strand: the
/// exact triple the planner replays a tool call under.
///
/// Constructor invariants: `operation`, `step_id` and `source_index` are
/// the planner's own coordinates for the planned call (the same triple
/// `escalation.CallScope` carries, and the same triple
/// `build.tool_args_key` keys replayed arguments by). Because all three
/// are durable in the intent, a replayed `agent_spawn` derives the same
/// child name and finds this cell instead of minting a second child.
pub type CallSite {
  CallSite(operation: OpId, step_id: String, source_index: Int)
}

/// One strand's lineage cell — the `fact.custom` payload stored under
/// `lineage/{strand}`.
///
/// Constructor invariants: `strand` is the cell's own key, repeated in
/// the payload so a scan needs no key parsing; `parent` is the strand
/// that spawned it and never changes; `depth` is `parent.depth + 1`, with
/// a strand that has no cell at all counting as depth 0 (a root);
/// `minted_by` is the call site the name was derived from; `brief` is the
/// operation id of the run the spawn accepted, which is what a handle
/// names; `tools` is the child's active tool set as configured;
/// `deadline` is an **absolute** wall-clock instant in milliseconds on
/// the session's own time base (`None` means no budget) — absolute rather
/// than a relative budget so a replayed wait resumes toward the same
/// instant instead of restarting its clock; `detached` records whether
/// the parent's run end should reap it; `reaped` is the durable record
/// that a reap was decided, so a reap whose `api.abort` was dropped
/// (no live driver) is re-issued on the next observation rather than
/// evaporating.
pub type Lineage {
  Lineage(
    strand: String,
    parent: String,
    depth: Int,
    minted_by: CallSite,
    brief: OpId,
    tools: List(String),
    deadline: Option(Int),
    detached: Bool,
    reaped: Bool,
  )
}

/// The reserved `fact.custom` key prefix lineage cells live under. Fact
/// writes through `api.put_fact` refuse keys under this prefix.
pub const key_prefix = "lineage/"

/// The `fact.custom` register key for a strand's lineage cell.
///
/// ## Examples
///
/// ```gleam
/// assert lineage.register_key("sub:main/reviewer-1")
///   == "lineage/sub:main/reviewer-1"
/// ```
///
pub fn register_key(strand: String) -> String {
  key_prefix <> strand
}

/// The strand a lineage key names, or `Error(Nil)` for a key outside the
/// namespace.
///
/// ## Examples
///
/// ```gleam
/// assert lineage.strand_of_key("lineage/sub:1") == Ok("sub:1")
/// ```
///
/// ```gleam
/// assert lineage.strand_of_key("agent/main/note") == Error(Nil)
/// ```
///
pub fn strand_of_key(key: String) -> Result(String, Nil) {
  case key {
    "lineage/" <> strand -> Ok(strand)
    _ -> Error(Nil)
  }
}

/// Encodes a lineage cell as its stored register payload.
///
/// ## Examples
///
/// ```gleam
/// // lineage.encode(cell) |> lineage.decode == Ok(cell)
/// ```
///
pub fn encode(cell: Lineage) -> JsonValue {
  json.Object([
    #("strand", json.String(cell.strand)),
    #("parent", json.String(cell.parent)),
    #("depth", json.Int(cell.depth)),
    #(
      "mintedBy",
      json.Object([
        #(
          "operation",
          json.String(ids.op_id_to_string(cell.minted_by.operation)),
        ),
        #("stepId", json.String(cell.minted_by.step_id)),
        #("sourceIndex", json.Int(cell.minted_by.source_index)),
      ]),
    ),
    #("brief", json.String(ids.op_id_to_string(cell.brief))),
    #("tools", json.Array(list.map(cell.tools, json.String))),
    #("deadline", case cell.deadline {
      None -> json.Null
      Some(at) -> json.Int(at)
    }),
    #("detached", json.Bool(cell.detached)),
    #("reaped", json.Bool(cell.reaped)),
  ])
}

/// Decodes a stored lineage payload. Total: anything malformed is a
/// corruption report, never a crash — and a cell that fails to decode is
/// treated by every caller as "not a descendant", which is the safe
/// direction for an addressing check.
///
/// ## Examples
///
/// ```gleam
/// // lineage.decode(payload)
/// ```
///
pub fn decode(payload: JsonValue) -> Result(Lineage, CorruptionReport) {
  let where = "runtime/lineage.decode"
  case payload {
    json.Object(fields) -> {
      use strand <- result.try(require_string(fields, "strand", where))
      use parent <- result.try(require_string(fields, "parent", where))
      use depth <- result.try(require_int(fields, "depth", where))
      use minted_by <- result.try(decode_call_site(fields, where))
      use brief_text <- result.try(require_string(fields, "brief", where))
      use brief <- result.try(ids.parse_op_id(brief_text))
      use tools <- result.try(require_string_list(fields, "tools", where))
      use deadline <- result.try(decode_deadline(fields, where))
      use detached <- result.try(require_bool(fields, "detached", where))
      use reaped <- result.try(require_bool(fields, "reaped", where))
      Ok(Lineage(
        strand:,
        parent:,
        depth:,
        minted_by:,
        brief:,
        tools:,
        deadline:,
        detached:,
        reaped:,
      ))
    }
    other ->
      Error(corruption.report(
        at: where,
        on: "payload",
        expected: "a lineage object",
        context: json.to_string(other),
      ))
  }
}

// A stored call site decodes in full or not at all: a half-readable one
// would change which replayed spawn recognizes which child, and guessing
// there mints a second strand.
fn decode_call_site(
  fields: List(#(String, JsonValue)),
  where: String,
) -> Result(CallSite, CorruptionReport) {
  case list.key_find(fields, "mintedBy") {
    Ok(json.Object(site)) -> {
      use operation_text <- result.try(require_string(site, "operation", where))
      use operation <- result.try(ids.parse_op_id(operation_text))
      use step_id <- result.try(require_string(site, "stepId", where))
      use source_index <- result.try(require_int(site, "sourceIndex", where))
      Ok(CallSite(operation:, step_id:, source_index:))
    }
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: "mintedBy",
        expected: "a call-site object",
        context: json.to_string(other),
      ))
    Error(Nil) ->
      Error(corruption.report(
        at: where,
        on: "mintedBy",
        expected: "a present field",
        context: "absent",
      ))
  }
}

// An absent or null deadline is "no budget"; anything else must be an
// integer instant. A deadline that failed to read as "no budget" would
// silently un-bound a child, so a malformed one is corruption.
fn decode_deadline(
  fields: List(#(String, JsonValue)),
  where: String,
) -> Result(Option(Int), CorruptionReport) {
  case list.key_find(fields, "deadline") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(at)) -> Ok(Some(at))
    Ok(other) ->
      Error(corruption.report(
        at: where,
        on: "deadline",
        expected: "null or an absolute instant in milliseconds",
        context: json.to_string(other),
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

fn require_bool(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(Bool, CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Bool(flag) -> Ok(flag)
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "a boolean",
        context: json.to_string(other),
      ))
  }
}

fn require_string_list(
  fields: List(#(String, JsonValue)),
  key: String,
  where: String,
) -> Result(List(String), CorruptionReport) {
  use value <- result.try(require(fields, key, where))
  case value {
    json.Array(items) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(text) -> Ok(text)
          other ->
            Error(corruption.report(
              at: where,
              on: key,
              expected: "an array of strings",
              context: json.to_string(other),
            ))
        }
      })
    other ->
      Error(corruption.report(
        at: where,
        on: key,
        expected: "an array of strings",
        context: json.to_string(other),
      ))
  }
}

/// Whether `candidate` is a strict descendant of `ancestor`, given a
/// lookup of lineage cells. **Fails closed**: a strand with no cell is a
/// root and is nobody's descendant, and a cell that will not decode is
/// treated the same way — "no lineage fact" must never read as "unknown,
/// allow", because the whole acyclicity argument rests on this test.
///
/// The walk is bounded by `limit` hops so a ledger that somehow held a
/// cycle (which would require a strand name to have been claimed twice,
/// and `seed_strand` claims each name under a `seq: None` CAS) still
/// terminates.
///
/// ## Examples
///
/// ```gleam
/// // lineage.is_descendant(of: "main", strand: "sub:main/x", cells:, limit: 32)
/// ```
///
pub fn is_descendant(
  of ancestor: String,
  strand candidate: String,
  cells cells: fn(String) -> Option(Lineage),
  limit limit: Int,
) -> Bool {
  use <- bool.guard(when: limit <= 0 || candidate == ancestor, return: False)
  case cells(candidate) {
    None -> False
    Some(cell) ->
      case cell.parent == ancestor {
        True -> True
        False ->
          is_descendant(
            of: ancestor,
            strand: cell.parent,
            cells:,
            limit: limit - 1,
          )
      }
  }
}
