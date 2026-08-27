//// The orchestration seam's capability router: `cap/strand` calls,
//// serviced by the Agency closures the `agent_*` tools already call.
////
//// # What this is, and what it deliberately is not
////
//// A code-mode program on the orchestration seam holds `cap/strand` and
//// `cap/report` and nothing else (`codemode/vet/policy.orchestration`).
//// Every `strand.*` frame it sends arrives here, is decoded into the
//// vocabulary `tools/agent` declares, and is handed to one of the six
//// `Agency` closures — the same record, the same closures, the same
//// `Caller`-judged decisions that a model's own `agent_spawn` reaches.
//// Nothing about the authorization model is re-derived: descendant-only
//// addressing, the depth and fan-out caps, the lineage ledger, the result
//// contract, and every refusal name are the tools', and this module's job
//// is to carry a call across the wire and carry the answer back.
////
//// That is why the plans it returns are `satellite.ServedHere` and never
//// `satellite.ClearedCall`. An Agency call is a request the harness
//// answers under its own policy; it spawns no process, opens no socket
//// and touches no file the broker would have to jail. So this router
//// builds **no `broker.CallSpec` at all**, which matters beyond tidiness:
//// `CallSpec` is an ordinary public record carrying `{op_id, step_id,
//// budget}`, and `codemode/identity`'s module doc records that an
//// injected router could still hand-write one under coordinates it
//// invented. A router that constructs none cannot. The door that issue
//// #22 left open is untouched by this seam rather than widened by it.
////
//// # The one coordinate this module derives, and why
////
//// A child strand's name is minted by the Agency from the purpose it was
//// given and the caller's durable coordinates:
//// `sub:{parent}/{purpose-slug}-{call-site-digest}`. Everything after the
//// slug comes out of `agent.call_site_digest` — the operation, the
//// minting step, and the planned call's source index — so what this
//// module owes the Agency is a `Caller` that says truthfully *who is
//// minting*, and nothing else.
////
//// A whole code-mode execution is one planned tool call, so a program
//// that spawned twice with one purpose would present one coordinate
//// twice and the second spawn would find the first child sitting under
//// the derived name. `CapRequest.ordinal` is what separates them: the
//// host counts this capability's admissions within the execution, which
//// is what `tool.Ctx.source_index` counts within an assistant message —
//// which call this is inside the artifact that produced it. Distinct per
//// spawn, deterministic, and derived by the host rather than supplied by
//// the program.
////
//// The ordinal travels as `agent.Minter.Program(ordinal:)` and **not** in
//// `Caller.source_index`, which stays the dispatching `code_mode` call's
//// own index within its step. An earlier arrangement spent `source_index`
//// on the ordinal and tried to recover the difference with a `-program`
//// suffix on the step. The suffix did not survive: the name slugged the
//// step, `agent.slug` caps a slug at `agent.max_slug_length`, and a
//// production step id is a 36-character UUID — so `{step}` and
//// `{step}-program` truncated to the same twenty-four characters and a
//// program's first spawn derived exactly the name an `agent_spawn` at
//// source index 0 in the same step derived. Two fields for two facts is
//// what fixes it, and it fixes more than the suffix ever could have:
//// two `code_mode` calls in one batch share their operation, their step
//// and their ordinal tallies alike, and differ only in the source index,
//// so nothing derived from the step alone could have told them apart
//// either.
////
//// The operation is threaded through untouched, so a run end still reaps
//// what the program spawned (the reap predicate is
//// `minted_by.operation`, `client/agency.reap_run`).
////
//// None of this rests on `{op_id, step_id}` being unique per execution,
//// and nothing else does any more either. That pair is the *batch*
//// identity the broker pools budget on; `{op_id, step_id, source_index}`
//// is the execution identity, and `client/codemode.exec_root` digests
//// the triple so an execution's whole working directory — its build
//// root, its cap socket, its token file — is its own. The pooled ledger
//// still keys on the pair, deliberately: two programs in one batch are
//// one batch (`docs/adr/005-budget-pooling-granularity.md`, "Two
//// programs in one batch"). A seam that mints durable names was the
//// first place that had to stop depending on the pair, which is why the
//// argument was written down here first.
////
//// # Every boundary decodes totally
////
//// The satellite is untrusted, so every field of every inbound frame is
//// decoded rather than assumed: a wrong-shaped argument is a `CapDenial`
//// the program reads as `InvalidArgument` and can repair, never a crash
//// and never a call made with a guessed value. The result shape a spawn
//// demands crosses as a list of field descriptors rather than as a schema
//// document, and this module *builds* the schema and runs it through
//// `agent.parse_result_schema` — so a program cannot state a constraint
//// the harness would quote into a child's brief without ever checking.

import broker/framing.{type CapOutcome}
import codemode/identity
import codemode/satellite.{
  type CapCeiling, type CapDenial, type CapPlan, type CapRequest, type CapRouter,
  CapCeiling, CapDenial, ServedHere,
}
import core/ids
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/agent.{type Agency, type Caller, type Refusal}

// --- the capability names --------------------------------------------------

/// The capability a program starts a child strand with.
pub const spawn_cap = "strand.spawn"

/// The capability a program joins on.
pub const wait_cap = "strand.wait"

/// The capability a program addresses a peer with.
pub const send_cap = "strand.send"

/// The capability a program writes one blackboard cell with.
pub const note_cap = "strand.note"

/// The capability a program reads blackboard cells with.
pub const notes_cap = "strand.notes"

/// The capability a program reads its lineage with.
pub const roster_cap = "strand.roster"

/// Every capability this router services, in the order `cap/strand`
/// declares them. Published so the tool description a model reads states
/// the real set rather than a copy that can drift.
pub const serviced_caps = [
  spawn_cap, wait_cap, send_cap, note_cap, notes_cap, roster_cap,
]

/// The default lifetime ceiling on spawn admissions in one execution.
///
/// Above `session_strands` (16) on purpose. The Agency's live caps —
/// `fan_out` at 8 per strand and `session_strands` at 16 per session — are
/// meant to stay the binding constraint in ordinary use, and a ceiling
/// below them would shadow them and change what a well-behaved program
/// can do. What this bounds is the pathological case those caps cannot
/// see: a loop that spawns, joins, and spawns again frees a live slot
/// every time round and would pass every live check forever. Thirty-two
/// is two full sessions' worth of strands, which is more fan-out than any
/// deterministic plan we have written needs and far less than an
/// unbounded loop reaches in a second.
pub const default_spawn_ceiling = 32

/// The lifetime ceiling on `strand.send` admissions in one execution.
///
/// A send is a durable commit per call, and to an *idle* descendant it
/// **starts a run** — a provider round trip the harness pays for. A send
/// loop to a child that keeps going idle is spawn-join-spawn with the
/// mint replaced by a wake, so it costs what a spawn loop costs while
/// passing every live cap. Sized as four messages per potential child at
/// the spawn ceiling: a plan that needs more conversation than that with
/// each of thirty-two children is not a plan a program should be running
/// unattended.
pub const send_ceiling = 128

/// The lifetime ceiling on `strand.note` admissions in one execution.
///
/// One durable write-once register per call, under a key the program
/// chooses — so a loop mints unbounded *distinct* registers and the
/// session store grows by exactly as much as the program felt like
/// writing, permanently, after the execution is gone. That is the "mints
/// something that outlives the execution" test met head on. Eight cells
/// per potential child at the spawn ceiling, which is a generous
/// blackboard for a deterministic plan and nowhere near a loop.
pub const note_ceiling = 256

/// The lifetime ceiling on `strand.notes` admissions in one execution.
///
/// A full prefix scan of every agent namespace in the session, per call.
/// It mints nothing, but its cost grows with what the program's own
/// writes just added, so a note/notes loop is quadratic in harness work
/// where every other call here is linear.
///
/// **This number and `note_ceiling` hold together and must be relaxed
/// together, or not at all.** The quadratic needs both factors unbounded:
/// with notes at 64 and note at 256, the worst case is 64 scans over
/// (whatever the session already held + 256) cells, which is linear in
/// each factor separately. Raising `note_ceiling` alone puts the
/// superlinear term back, and so does raising this one. The alternative —
/// charging a read by the size of what it returned, or giving a program a
/// work budget it can read — is the model-readable budget issue #23
/// forbids, arriving by the side door; a flat count is the whole of the
/// instrument on purpose.
pub const notes_ceiling = 64

/// The in-band code a spawn refused at its ceiling travels under.
///
/// Shipped vocabulary: `cap/strand.map_error` decodes it to
/// `SpawnCeilingReached` and #23's exit criteria assert on it, so it
/// stays its own code rather than being folded into the generic one
/// below.
pub const spawn_ceiling_code = "spawn_ceiling"

/// The in-band code every other ceiling refusal travels under.
///
/// One code and one decoded variant for the three, not three of each. A
/// program at any of them does the same thing — stop looping — and the
/// message names the capability and the number, so a third arm would buy
/// a distinction nothing acts on. `cap/strand.map_error` decodes this to
/// `AdmissionCeilingReached`.
pub const admission_ceiling_code = "admission_ceiling"

// --- the seam --------------------------------------------------------------

/// What the router needs beyond the request: the Agency to call, the
/// strand every call is judged as, and where in its own step the
/// dispatching call sits.
///
/// `strand` is the strand whose driver dispatched the `code_mode` tool
/// call, taken from the dispatching `Ctx` and never from anything the
/// program says. It is the identity the whole authorization model is
/// stated against, so a program that could name its own would be able to
/// address any strand in the session.
///
/// `source_index` comes from the same `Ctx` and for a related reason: it
/// is what tells this execution apart from every other call in its batch,
/// including another `code_mode` call, and a spawn's name has to say
/// which execution minted it. See the module doc.
pub type Orchestration {
  Orchestration(agency: Agency, strand: String, source_index: Int)
}

/// The lifetime admission ceilings an orchestration execution runs under:
/// four of the six capabilities, sized by what each one costs. See
/// `satellite.CapCeiling` for the test a capability has to meet to earn a
/// ceiling at all, and for why the unit is the execution.
///
/// `strand.wait` and `strand.roster` have none, and their absence is a
/// decision rather than an omission. A `wait`'s whole cost is time, which
/// the Agency's own per-call clamp and the execution's wall deadline
/// already bind; it mints nothing and it cannot outlive the program that
/// is blocked in it. A `roster` is bounded structurally — it reads a
/// lineage whose size is `session_strands` (16) — so a loop over it
/// re-reads a constant.
///
/// Only the spawn ceiling is configurable, because it is the one an
/// operator has a reason to tune against a session's own `fan_out` and
/// `session_strands`. The other three are constants of this seam: they
/// are sized against what the harness pays, not against what a session
/// affords.
///
/// ## Examples
///
/// ```gleam
/// // orchestration.ceilings(32) |> list.length == 4
/// ```
///
pub fn ceilings(spawn_admissions: Int) -> List(CapCeiling) {
  [
    CapCeiling(
      cap: spawn_cap,
      admissions: spawn_admissions,
      code: spawn_ceiling_code,
    ),
    CapCeiling(
      cap: send_cap,
      admissions: send_ceiling,
      code: admission_ceiling_code,
    ),
    CapCeiling(
      cap: note_cap,
      admissions: note_ceiling,
      code: admission_ceiling_code,
    ),
    CapCeiling(
      cap: notes_cap,
      admissions: notes_ceiling,
      code: admission_ceiling_code,
    ),
  ]
}

/// The capability router for the orchestration seam.
///
/// Every capability outside the six is refused as `unsupported_cap`, the
/// same answer `satellite.default_router` gives a name it does not map —
/// a vetted orchestration program cannot reach one, since it cannot
/// import the module that would send it, so this arm answers a
/// hand-written `.beam` rather than a program.
///
/// ## Examples
///
/// ```gleam
/// // satellite.SatelliteConfig(..config, router: orchestration.router(seam))
/// ```
///
pub fn router(seam: Orchestration) -> CapRouter {
  fn(request: CapRequest) {
    // Gleam patterns cannot name a constant, so the arms below are string
    // literals while `serviced_caps` holds the constants — two lists that
    // could drift. `orchestration_test` walks `serviced_caps` and asserts
    // each one routes, which is what keeps them the same list.
    case request.cap {
      "strand.spawn" -> spawn_plan(seam, request)
      "strand.wait" -> wait_plan(seam, request)
      "strand.send" -> send_plan(seam, request)
      "strand.note" -> note_plan(seam, request)
      "strand.notes" -> notes_plan(seam, request)
      "strand.roster" -> roster_plan(seam, request)
      other ->
        Error(CapDenial(
          code: "unsupported_cap",
          message: "capability "
            <> other
            <> " is not on the orchestration seam, which services only "
            <> string.join(serviced_caps, ", "),
        ))
    }
  }
}

// The caller every Agency call is judged against. Every field is
// somebody else's: the strand and the source index are the dispatching
// `Ctx`'s, the operation and step come off the threaded `PhaseIdentity`
// — this module writes neither — and the only thing derived here is the
// `Minter`, which is the module doc's subject.
fn caller_of(seam: Orchestration, request: CapRequest) -> Caller {
  agent.Caller(
    strand: seam.strand,
    operation: identity.op_id(request.identity),
    step_id: identity.step_id(request.identity),
    source_index: seam.source_index,
    minter: agent.Program(ordinal: request.ordinal),
  )
}

// --- spawn -----------------------------------------------------------------

fn spawn_plan(
  seam: Orchestration,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use spawn_request <- result.try(decode_spawn(request.args))
  let caller = caller_of(seam, request)
  Ok(
    ServedHere(fn() {
      case seam.agency.spawn(caller, spawn_request) {
        Error(refusal) -> refused(refusal)
        Ok(spawned) -> answered(handle_value(spawned.handle))
      }
    }),
  )
}

fn decode_spawn(args: MsgPackValue) -> Result(agent.SpawnRequest, CapDenial) {
  use purpose <- result.try(string_arg(args, "purpose"))
  use brief <- result.try(string_arg(args, "brief"))
  use within_ms <- result.try(optional_int_arg(args, "within_ms"))
  use detach <- result.try(bool_arg(args, "detach"))
  use context <- result.try(provenance_arg(args))
  use tools <- result.try(optional_names_arg(args, "tools"))
  use result_schema <- result.try(schema_arg(args))
  Ok(agent.SpawnRequest(
    purpose:,
    brief:,
    tools:,
    within_ms:,
    result_schema:,
    context:,
    detach:,
  ))
}

fn provenance_arg(args: MsgPackValue) -> Result(agent.Provenance, CapDenial) {
  use context <- result.try(string_arg(args, "context"))
  case context {
    "fresh" -> Ok(agent.Fresh)
    "my_conversation" -> Ok(agent.MyConversation)
    other ->
      Error(invalid("`context` must be fresh or my_conversation, not " <> other))
  }
}

// The declared result shape, built into the schema dialect the harness
// already parses totally rather than accepted as one. A program sends
// field descriptors; `agent.parse_result_schema` decides whether they
// amount to a schema this harness can actually enforce, and its refusal
// text names the key it objected to.
fn schema_arg(
  args: MsgPackValue,
) -> Result(Option(agent.ResultSchema), CapDenial) {
  use fields <- result.try(case msgpack_field(args, "result_schema") {
    Error(_) | Ok(msgpack.NilValue) -> Ok([])
    Ok(msgpack.ArrayValue(items:)) -> Ok(items)
    Ok(_other) -> Error(invalid("`result_schema` must be a list of fields"))
  })
  case fields {
    [] -> Ok(None)
    [_, ..] -> {
      use declared <- result.try(list.try_map(fields, decode_field))
      agent.parse_result_schema(schema_json(declared))
      |> result.map(Some)
      |> result.map_error(fn(reason) {
        invalid("the result shape you asked for " <> reason)
      })
    }
  }
}

// One field descriptor, as `cap/strand.encode_schema` sends it.
type Declared {
  Declared(name: String, expects: JsonValue, required: Bool)
}

fn decode_field(value: MsgPackValue) -> Result(Declared, CapDenial) {
  use name <- result.try(string_arg(value, "name"))
  use required <- result.try(bool_arg(value, "required"))
  use expects <- result.try(field_type_json(value))
  Ok(Declared(name:, expects:, required:))
}

// A field's type as the schema dialect spells it. An array's element type
// nests through `items`, and the recursion is bounded by the sender's own
// nesting: a descriptor with no `items` ends it, and `parse_result_schema`
// refuses anything deeper than `agent.max_schema_depth` afterwards.
fn field_type_json(value: MsgPackValue) -> Result(JsonValue, CapDenial) {
  use declared <- result.try(string_arg(value, "type"))
  case declared {
    "any" -> Ok(json.Object([]))
    "string" | "integer" | "number" | "boolean" | "object" ->
      Ok(json.Object([#("type", json.String(declared))]))
    "array" -> {
      use items <- result.try(case msgpack_field(value, "items") {
        Error(_) | Ok(msgpack.NilValue) -> Ok(json.Object([]))
        Ok(nested) -> field_type_json(nested)
      })
      Ok(json.Object([#("type", json.String("array")), #("items", items)]))
    }
    other -> Error(invalid("`" <> other <> "` is not a result field type"))
  }
}

fn schema_json(declared: List(Declared)) -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object(
        list.map(declared, fn(field) { #(field.name, field.expects) }),
      ),
    ),
    #(
      "required",
      json.Array(
        declared
        |> list.filter(fn(field) { field.required })
        |> list.map(fn(field) { json.String(field.name) }),
      ),
    ),
  ])
}

// --- wait ------------------------------------------------------------------

fn wait_plan(
  seam: Orchestration,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use handles <- result.try(handles_arg(request.args))
  use within_ms <- result.try(int_arg(request.args, "within_ms"))
  let caller = caller_of(seam, request)
  Ok(
    ServedHere(fn() {
      case seam.agency.wait(caller, handles, within_ms) {
        Error(refusal) -> refused(refusal)
        Ok(waited) ->
          answered(
            msgpack.MapValue([
              field(
                "waited",
                msgpack.ArrayValue(list.map(waited, waited_value)),
              ),
            ]),
          )
      }
    }),
  )
}

fn handles_arg(args: MsgPackValue) -> Result(List(agent.Handle), CapDenial) {
  use items <- result.try(case msgpack_field(args, "handles") {
    Ok(msgpack.ArrayValue(items:)) -> Ok(items)
    Ok(_other) | Error(_) -> Error(invalid("`handles` must be a list"))
  })
  list.try_map(items, decode_handle)
}

// Parsed through the tools' own grammar rather than assembled here, so
// the harness has exactly one definition of what a handle is.
fn decode_handle(value: MsgPackValue) -> Result(agent.Handle, CapDenial) {
  use strand <- result.try(string_arg(value, "strand"))
  use operation <- result.try(string_arg(value, "operation"))
  agent.parse_handle(strand <> "#" <> operation)
  |> result.map_error(refusal_denial)
}

fn waited_value(waited: agent.Waited) -> MsgPackValue {
  case waited {
    agent.Pending(handle:, waited_ms:) ->
      msgpack.MapValue([
        field("kind", msgpack.StringValue("pending")),
        field("strand", msgpack.StringValue(handle.strand)),
        field("operation", msgpack.StringValue(operation_text(handle))),
        field("waited_ms", msgpack.IntValue(waited_ms)),
      ])
    agent.Ready(handle:, outcome:, report:, result:, notes:) ->
      msgpack.MapValue([
        field("kind", msgpack.StringValue("ready")),
        field("strand", msgpack.StringValue(handle.strand)),
        field("operation", msgpack.StringValue(operation_text(handle))),
        field("outcome", outcome_value(outcome)),
        field("report", msgpack.StringValue(report)),
        field("result", terminal_value(result)),
        field("notes", notes_value(notes)),
      ])
  }
}

fn outcome_value(outcome: agent.Outcome) -> MsgPackValue {
  case outcome {
    agent.Completed -> msgpack.MapValue([field("kind", text("completed"))])
    agent.Aborted -> msgpack.MapValue([field("kind", text("aborted"))])
    agent.Failed(reason:) ->
      msgpack.MapValue([
        field("kind", text("failed")),
        field("reason", text(reason)),
      ])
  }
}

// The verdict on the child's structured result. A schema is rendered to
// its canonical text rather than sent as structure: a program branches on
// *which* verdict it got and reports the schema, it does not re-derive
// the shape from it.
fn terminal_value(result: agent.TerminalResult) -> MsgPackValue {
  case result {
    agent.NoResultAsked -> msgpack.MapValue([field("kind", text("none"))])
    agent.ResultGiven(value:) ->
      msgpack.MapValue([
        field("kind", text("given")),
        field("value", of_json(value)),
      ])
    agent.ResultAbsent(schema:) ->
      msgpack.MapValue([
        field("kind", text("absent")),
        field("schema", text(schema_text(schema))),
      ])
    agent.ResultUnusable(schema:, received:, mismatch:) ->
      msgpack.MapValue([
        field("kind", text("unusable")),
        field("schema", text(schema_text(schema))),
        field("received", of_json(received)),
        field("reason", text(agent.describe_mismatch(mismatch))),
      ])
  }
}

fn schema_text(schema: agent.ResultSchema) -> String {
  json.to_string(agent.render_result_schema(schema))
}

// --- send, notes, roster ---------------------------------------------------

fn send_plan(
  seam: Orchestration,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use to <- result.try(string_arg(request.args, "to"))
  use body <- result.try(string_arg(request.args, "text"))
  let caller = caller_of(seam, request)
  Ok(
    ServedHere(fn() {
      case seam.agency.send(caller, to, body) {
        Error(refusal) -> refused(refusal)
        Ok(agent.Steered(entry:)) ->
          answered(
            msgpack.MapValue([
              field("kind", text("steered")),
              field("entry", text(ids.entry_id_to_string(entry))),
            ]),
          )
        Ok(agent.Started(operation:)) ->
          answered(
            msgpack.MapValue([
              field("kind", text("started")),
              field("operation", text(ids.op_id_to_string(operation))),
            ]),
          )
      }
    }),
  )
}

fn note_plan(
  seam: Orchestration,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(string_arg(request.args, "key"))
  use held <- result.try(msgpack_field(request.args, "value"))
  use value <- result.try(
    to_json(held)
    |> result.map_error(fn(reason) { invalid("a note's `value` " <> reason) }),
  )
  let caller = caller_of(seam, request)
  Ok(
    ServedHere(fn() {
      case seam.agency.note(caller, key, value) {
        Error(refusal) -> refused(refusal)
        Ok(Nil) -> answered(msgpack.MapValue([]))
      }
    }),
  )
}

fn notes_plan(
  seam: Orchestration,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use prefix <- result.try(optional_string_arg(request.args, "prefix"))
  let caller = caller_of(seam, request)
  Ok(
    ServedHere(fn() {
      case seam.agency.notes(caller, prefix) {
        Error(refusal) -> refused(refusal)
        Ok(cells) ->
          answered(msgpack.MapValue([field("notes", notes_value(cells))]))
      }
    }),
  )
}

fn roster_plan(
  seam: Orchestration,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  let caller = caller_of(seam, request)
  Ok(
    ServedHere(fn() {
      case seam.agency.roster(caller) {
        Error(refusal) -> refused(refusal)
        Ok(peers) ->
          answered(
            msgpack.MapValue([
              field("peers", msgpack.ArrayValue(list.map(peers, peer_value))),
            ]),
          )
      }
    }),
  )
}

fn peer_value(peer: agent.Peer) -> MsgPackValue {
  msgpack.MapValue([
    field("strand", text(peer.strand)),
    field("relation", text(relation_text(peer.relation))),
    field("handle", case peer.handle {
      None -> msgpack.NilValue
      Some(handle) -> handle_value(handle)
    }),
    field("outcome", case peer.outcome {
      None -> msgpack.NilValue
      Some(outcome) -> outcome_value(outcome)
    }),
    field(
      "tools",
      msgpack.ArrayValue(list.map(peer.tools, msgpack.StringValue)),
    ),
  ])
}

fn relation_text(relation: agent.Relation) -> String {
  case relation {
    agent.ParentOf -> "parent"
    agent.ChildOf -> "child"
  }
}

fn notes_value(cells: List(#(String, JsonValue))) -> MsgPackValue {
  msgpack.ArrayValue(
    list.map(cells, fn(cell) {
      msgpack.MapValue([
        field("key", text(cell.0)),
        field("value", of_json(cell.1)),
      ])
    }),
  )
}

fn handle_value(handle: agent.Handle) -> MsgPackValue {
  msgpack.MapValue([
    field("strand", text(handle.strand)),
    field("operation", text(operation_text(handle))),
  ])
}

fn operation_text(handle: agent.Handle) -> String {
  ids.op_id_to_string(handle.operation)
}

// --- the value bridge ------------------------------------------------------
//
// The blackboard speaks `core/json` and the cap channel speaks
// `core/msgpack`, and neither package knows the other. The two directions
// are not symmetric, and the asymmetry is the honest part: every JSON
// value has a msgpack form, but msgpack has two shapes JSON does not —
// raw binary, and a map keyed by something other than text. Those are
// refused in band rather than coerced, because a note silently stored
// under a stringified key is a note the program cannot read back.

/// One `JsonValue` as the msgpack value the wire carries.
fn of_json(value: JsonValue) -> MsgPackValue {
  case value {
    json.Null -> msgpack.NilValue
    json.Bool(value:) -> msgpack.BoolValue(value)
    json.Int(value:) -> msgpack.IntValue(value)
    json.Float(value:) -> msgpack.FloatValue(value)
    json.String(value:) -> msgpack.StringValue(value)
    json.Array(items:) -> msgpack.ArrayValue(list.map(items, of_json))
    json.Object(fields:) ->
      msgpack.MapValue(
        list.map(fields, fn(entry) { field(entry.0, of_json(entry.1)) }),
      )
  }
}

/// One msgpack value as a `JsonValue`, or why it has no JSON form.
fn to_json(value: MsgPackValue) -> Result(JsonValue, String) {
  case value {
    msgpack.NilValue -> Ok(json.Null)
    msgpack.BoolValue(value:) -> Ok(json.Bool(value))
    msgpack.IntValue(value:) -> Ok(json.Int(value))
    msgpack.FloatValue(value:) -> Ok(json.Float(value))
    msgpack.StringValue(value:) -> Ok(json.String(value))
    msgpack.BinaryValue(bytes: _) ->
      Error(
        "must not hold raw bytes: the blackboard stores JSON, which has no "
        <> "binary form; send text instead",
      )
    msgpack.ArrayValue(items:) ->
      list.try_map(items, to_json) |> result.map(json.Array)
    msgpack.MapValue(entries:) ->
      list.try_map(entries, fn(entry) {
        case entry.0 {
          msgpack.StringValue(key) ->
            to_json(entry.1) |> result.map(fn(held) { #(key, held) })
          msgpack.NilValue
          | msgpack.BoolValue(..)
          | msgpack.IntValue(..)
          | msgpack.FloatValue(..)
          | msgpack.BinaryValue(..)
          | msgpack.ArrayValue(..)
          | msgpack.MapValue(..) ->
            Error(
              "must key its objects by text: the blackboard stores JSON, "
              <> "whose object keys are always strings",
            )
        }
      })
      |> result.map(json.Object)
  }
}

// --- argument decoding -----------------------------------------------------
//
// Total over anything a satellite can send. Each answers a `CapDenial`
// naming the field, so a program repairs the call rather than guessing.

fn msgpack_field(
  value: MsgPackValue,
  key: String,
) -> Result(MsgPackValue, CapDenial) {
  case value {
    msgpack.MapValue(entries:) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == msgpack.StringValue(key) {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
      |> result.map_error(fn(_nil) { invalid("`" <> key <> "` is missing") })
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..) -> Error(invalid("arguments must be a map"))
  }
}

fn string_arg(value: MsgPackValue, key: String) -> Result(String, CapDenial) {
  use found <- result.try(msgpack_field(value, key))
  case found {
    msgpack.StringValue(text) -> Ok(text)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) -> Error(invalid("`" <> key <> "` must be text"))
  }
}

fn int_arg(value: MsgPackValue, key: String) -> Result(Int, CapDenial) {
  use found <- result.try(msgpack_field(value, key))
  case found {
    msgpack.IntValue(number) -> Ok(number)
    msgpack.NilValue
    | msgpack.BoolValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) ->
      Error(invalid("`" <> key <> "` must be a whole number"))
  }
}

fn bool_arg(value: MsgPackValue, key: String) -> Result(Bool, CapDenial) {
  use found <- result.try(msgpack_field(value, key))
  case found {
    msgpack.BoolValue(flag) -> Ok(flag)
    msgpack.NilValue
    | msgpack.IntValue(..)
    | msgpack.FloatValue(..)
    | msgpack.StringValue(..)
    | msgpack.BinaryValue(..)
    | msgpack.ArrayValue(..)
    | msgpack.MapValue(..) ->
      Error(invalid("`" <> key <> "` must be true or false"))
  }
}

fn optional_int_arg(
  value: MsgPackValue,
  key: String,
) -> Result(Option(Int), CapDenial) {
  case msgpack_field(value, key) {
    Error(_absent) | Ok(msgpack.NilValue) -> Ok(None)
    Ok(msgpack.IntValue(number)) -> Ok(Some(number))
    Ok(_other) -> Error(invalid("`" <> key <> "` must be a whole number"))
  }
}

fn optional_string_arg(
  value: MsgPackValue,
  key: String,
) -> Result(Option(String), CapDenial) {
  case msgpack_field(value, key) {
    Error(_absent) | Ok(msgpack.NilValue) -> Ok(None)
    Ok(msgpack.StringValue(text)) -> Ok(Some(text))
    Ok(_other) -> Error(invalid("`" <> key <> "` must be text"))
  }
}

fn optional_names_arg(
  value: MsgPackValue,
  key: String,
) -> Result(Option(List(String)), CapDenial) {
  case msgpack_field(value, key) {
    Error(_absent) | Ok(msgpack.NilValue) -> Ok(None)
    Ok(msgpack.ArrayValue(items:)) ->
      list.try_map(items, fn(item) {
        case item {
          msgpack.StringValue(name) -> Ok(name)
          msgpack.NilValue
          | msgpack.BoolValue(..)
          | msgpack.IntValue(..)
          | msgpack.FloatValue(..)
          | msgpack.BinaryValue(..)
          | msgpack.ArrayValue(..)
          | msgpack.MapValue(..) ->
            Error(invalid("`" <> key <> "` must be a list of names"))
        }
      })
      |> result.map(Some)
    Ok(_other) -> Error(invalid("`" <> key <> "` must be a list of names"))
  }
}

// --- answers and refusals --------------------------------------------------

fn answered(value: MsgPackValue) -> CapOutcome {
  framing.CapOk(value:)
}

// The harness's own refusal, forwarded under its own name. The code is
// what `cap/strand` maps back to a variant and the message is the
// Agency's own sentence, so a program reads the same words a model reads
// from `agent_spawn` — one refusal, one vocabulary, two audiences.
fn refused(refusal: Refusal) -> CapOutcome {
  let CapDenial(code:, message:) = refusal_denial(refusal)
  framing.CapErr(code:, message:)
}

/// The in-band code one Agency refusal travels under.
///
/// Named rather than inlined because it is half of a contract: the other
/// half is `cap/strand.map_error`, which turns each code back into the
/// variant of the same name. `cap` and `codemode` do not share a
/// dependency — they are the two ends of the wire, not peers — so the
/// strings are restated on each side and pinned by tests on each side.
///
/// ## Examples
///
/// ```gleam
/// // orchestration.refusal_code(agent.NotADescendant("x")) == "not_a_descendant"
/// ```
///
pub fn refusal_code(refusal: Refusal) -> String {
  case refusal {
    agent.AgencyUnavailable -> "strands_unavailable"
    agent.MalformedHandle(..) -> "malformed_handle"
    agent.NotAddressable(..) -> "not_addressable"
    agent.NotADescendant(..) -> "not_a_descendant"
    agent.DepthCapReached(..) -> "depth_cap"
    agent.FanOutCapReached(..) -> "fan_out_cap"
    agent.UnknownTool(..) -> "unknown_tool"
    agent.InvalidArgument(..) -> "invalid_argument"
    agent.NameAlreadyMinted(..) -> "name_already_minted"
    agent.ParentRunEnded(..) -> "parent_run_ended"
    agent.ResultSchemaUnmet(..) -> "result_schema_unmet"
    agent.PlaneFailed(..) -> "plane_failed"
  }
}

fn refusal_denial(refusal: Refusal) -> CapDenial {
  CapDenial(code: refusal_code(refusal), message: agent.describe(refusal))
}

fn invalid(reason: String) -> CapDenial {
  CapDenial(code: "invalid_argument", message: reason)
}

fn field(key: String, value: MsgPackValue) -> #(MsgPackValue, MsgPackValue) {
  #(msgpack.StringValue(key), value)
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}
