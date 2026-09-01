//// The `agent_*` tools: how a model starts, addresses, and joins other
//// agents.
////
//// Six tools, one family, each a thin shell over one **Agency** call.
//// The Agency is the messaging plane's single door, the way
//// `Ctx.clear_call` is the outside world's: a record of closures declared
//// here in plain data and filled in by whoever can see a live runtime
//// (`client/agency` in production, a fake in tests). `tools` depends on
//// `core` and `broker` and on neither `runtime` nor `machine`, so every
//// type crossing the seam is mirrored here rather than imported — the
//// same arrangement `effects.ToolOutcome` uses to mirror the broker's
//// `CallOutcome` without a broker dependency.
////
//// ## Why a tool, and where the capability lives instead
////
//// A tool runs in the harness: trusted code, policy-checked, able to
//// commit durably. The messaging doctrine requires the commit — a
//// payload that changes what the recipient does travels through the
//// store, never a mailbox — and it was designed assuming trusted
//// writers. Handing the *model* a messaging tool keeps that assumption
//// intact, because the harness still decides what the call does with the
//// arguments it was given. Every refusal below is therefore enforced by
//// the Agency, never requested in a prompt.
////
//// The objection that used to stand here — that a `cap/strand`
//// capability would run inside the satellite, which executes untrusted
//// model-written Gleam, and so would import an untrusted writer into a
//// plane built for trusted ones — was answered rather than dropped, and
//// the risk it named is still the reason the answer looks as it does.
//// `cap/strand` exists now, on the **orchestration seam**: a code-mode
//// allowlist of `cap/strand` and `cap/report` and nothing else, whose
//// calls are serviced by these same Agency closures, judged against the
//// same `Caller`, under the same descendant-only addressing rule and the
//// same caps. What makes that safe is confinement, not trust — the seam
//// carries no filesystem, no process, no network, so the untrusted
//// writer on the far side of it reaches the store through exactly the
//// door a model's own `agent_send` reaches it through and through no
//// other. The one rule the seam adds is the one thing that changes when
//// a loop replaces a turn: a lifetime ceiling on spawn admissions per
//// execution, because `agent_spawn` is throttled by the cost of a
//// provider round trip and a loop pays nothing.
//// (`docs/design-notes/orchestration-comparison.md`, "The verdict:
//// connect them, through a second seam"; `docs/architecture/code-mode.md`,
//// "Two seams, and why the sets are disjoint".)
////
//// ## What the model is never allowed to say
////
//// Three things the model does not get to supply, each closing a class of
//// attack rather than a single bug:
////
//// - **Its own identity.** Every Agency call is judged against
////   `Ctx.strand`, which the driver set from its own durable name. A model
////   cannot claim to be another strand, so the addressing rule below is
////   enforceable at all.
//// - **A strand name.** `agent_spawn` takes a *purpose*; the Agency mints
////   `sub:{parent}/{slug}-{digest}`, where the slug is the purpose,
////   bounded, and the digest is sixteen fixed hex characters over the
////   call's own durable coordinates and the `Minter` inside them
////   (`call_site_digest`). Minting kills name-squatting, sibling
////   collisions, and shadowing an operator's convention at once — and the
////   determinism is what makes a replayed spawn reach for the same name
////   and reconcile rather than mint a second child. The split of labour
////   between the two halves is deliberate: the model's half is decoration
////   and is allowed to be truncated, while the half that decides *whose
////   child this is* has a constant width and no model input at all, so
////   neither a long purpose nor a chosen one can collapse two minters
////   onto one name.
//// - **A blackboard prefix.** `agent_note` writes under
////   `agent/{caller}/` and cannot escape it; `agent_notes` reads under
////   `agent/` and nothing else. The reserved corners of the fact
////   namespace — escalations, operation results, the lineage ledger, the
////   pinned system prompt — are refused by the runtime one layer further
////   down, so a forged approval record needs two independent failures.
////
//// ## The addressing rule, and why a blocking wait is safe
////
//// > A strand may wait only on a descendant, and may address only its
//// > parent or a descendant.
////
//// Spawning builds a forest — every strand has at most one parent, fixed
//// at spawn and unforgeable — so wait edges point strictly from parent to
//// child and a cycle cannot be drawn. Child-to-parent traffic exists but
//// rides `agent_send`, which never waits. `agent_wait` therefore blocks
//// the *operation's* progress and nothing else: the driver answers
//// `Continue` while a tool effect is live and goes on serving `Nudge`,
//// `Abort` and `PollTick`, the tool body runs on its own spawned process
//// rather than on the driver or the writer, and abort kills a blocked
//// waiter outright.
////
//// Two residual costs, stated rather than hidden. A human steering the
//// waiting strand is queued, not dropped — the steer commits and drains
//// at the next checkpoint, which is after the batch the strand is inside
//// — which is why the deadline is capped and why abort remains the
//// immediate exit. And a child cannot get an answer from its parent while
//// the parent is inside `agent_wait`: the ask-my-parent pattern is
//// unavailable exactly when a child wants it. That is a designed-in hole,
//// not a deadlock; see `send` for the other half of it.
////
//// ## Waiting is per call, not per child
////
//// `agent_wait` takes an **array** of handles and the Agency waits them
//// all against **one** deadline. This is load-bearing, not a convenience,
//// and it stayed load-bearing when `tool_execution: Parallel` became the
//// shipped default. The tool's `Concurrent` declaration does now bite —
//// eight one-handle waits in one batch genuinely overlap — but three
//// things the setting cannot change are why the array is still the unit:
////
//// - **The setting is not a guarantee.** `tool_execution` is a run
////   setting a host or a session may set back to `sequential` (the
////   gateway's config key), and under it eight one-handle waits are
////   eight serial deadline windows again. A fan-out story that only
////   holds on the default is one that breaks when someone turns the
////   default off.
//// - **A batch is only as parallel as its most exclusive member.** One
////   `bash`, `fs_write` or `code_mode` beside the waits fences the whole
////   batch (`runtime/strand_runtime.tool_may_start`), and the serial
////   windows come back inside a session that never changed a setting.
//// - **Overlap is not free where it does happen.** Eight waits are eight
////   effect processes, eight intent commits and eight settlements to
////   reconcile, each against a deadline of its own. One call is one
////   intent, one settlement, and one deadline for the whole set — which
////   is also the only shape in which "wait for the batch" is a single
////   durable fact.
////
//// So the mode makes the degenerate case cheaper; it does not carry the
//// fan-out story, and nothing here rests on it.

import broker/policy.{type SandboxPolicy}
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The tool names this family registers, in registry order.
pub const tool_names = [
  "agent_note", "agent_notes", "agent_roster", "agent_send", "agent_spawn",
  "agent_wait",
]

/// The name of the tool that starts a child. Named as a constant because
/// the depth cap is enforced structurally by leaving it out of a child's
/// active set — a tool the model cannot see is one it never tries.
pub const spawn_tool_name = "agent_spawn"

/// The model-writable blackboard prefix. Every `agent_note` key is forced
/// under `agent/{caller}/` and every `agent_notes` read under `agent/`.
pub const blackboard_prefix = "agent/"

/// Longest slug minted from a `purpose`, in characters. A strand name is
/// a key in three register namespaces and half of a handle's text; a
/// model that pastes a paragraph as its purpose gets a bounded name.
pub const max_slug_length = 24

/// Most handles one `agent_wait` call may name. The wait is one loop over
/// one deadline, so this bounds the store traffic per iteration rather
/// than the wall-clock cost.
pub const max_handles = 32

/// The blackboard key, relative to the child's own namespace, under
/// which a child records the structured result its brief asked for. The
/// cell lands at `agent/{child}/result` and is an ordinary note — the
/// blackboard already carries typed `JsonValue` cells across this seam
/// intact, so the contract needed a key and a check, not a new channel.
pub const result_note_key = "result"

/// Most fields one result schema may declare. A schema is rendered into
/// the child's brief on every one of its requests, so its size is paid
/// for repeatedly and is bounded here rather than by the parent's taste.
pub const max_result_fields = 32

/// Longest declared field name, in characters.
pub const max_field_name_length = 64

/// How deep `{"type": "array", "items": ...}` may nest before a schema
/// is refused. Four is past anything a result shape needs and short of
/// anything that makes rendering expensive.
pub const max_schema_depth = 4

// Longest rendered JSON value quoted back inside a message. A result
// cell is model-written and unbounded; the sentence naming it is not.
const max_excerpt = 240

// --- what crosses the seam -------------------------------------------------

/// Who is calling, in the driver's own durable coordinates.
///
/// Constructor invariants: every field but `minter` comes from `Ctx`,
/// which the driver built from its own state — `strand` is the
/// dispatching driver's name and the identity every authorization
/// decision is made against, and `{operation, step_id, source_index}` are
/// the persisted coordinates a replayed call arrives under, which is what
/// makes a minted child name stable across replay. `source_index` is
/// always the *planned tool call's* own index within its step, never an
/// index derived from anything running inside that call; who inside the
/// call is minting is `minter`'s job and only `minter`'s.
pub type Caller {
  Caller(
    strand: String,
    operation: OpId,
    step_id: String,
    source_index: Int,
    minter: Minter,
  )
}

/// Who, inside one planned tool call, is minting a child strand.
///
/// `{operation, step_id, source_index}` names a tool call, and for a
/// model's own `agent_spawn` that is the whole story: one planned call
/// mints one child, so the triple is a coordinate a name can be derived
/// from and a replay can find its way back to.
///
/// It stops being the whole story the moment the planned call is a
/// `code_mode` execution. One such call runs a whole *program*, the
/// program may spawn many times, and every one of those spawns arrives
/// under the same triple — so the triple names the call, not the minting.
/// `Program` carries the ordinal that separates them, and carries it as
/// its own field rather than by overwriting `source_index`, because the
/// two facts answer different questions and a name that conflates them
/// cannot tell a program's first spawn from the model's own.
///
/// Constructor invariants: `ordinal` counts a program's spawn admissions
/// within one execution, is assigned by the host rather than supplied by
/// the program, and starts at zero for every execution — so it separates
/// one program's spawns from each other and never one program from
/// another. Separating programs is `source_index`'s job.
pub type Minter {
  /// The planned tool call is itself the minter: a model's `agent_spawn`.
  ToolCall

  /// A code-mode program running under the planned tool call is the
  /// minter, on its `ordinal`-th spawn admission.
  Program(ordinal: Int)
}

/// A durable reference to one child operation. It survives restart and
/// compaction because it names nothing process-local.
///
/// Constructor invariants: `strand` is the child's minted name and
/// `operation` the brief run the spawn accepted. Rendered to the model as
/// `{strand}#{operation}` and parsed back totally.
pub type Handle {
  Handle(strand: String, operation: OpId)
}

/// Where a child's context starts.
pub type Provenance {
  /// At the root of the tree: the child reads its brief and nothing else.
  Fresh

  /// At the caller's current leaf, copying the caller's entire
  /// conversation into the child's context window.
  MyConversation
}

/// The shape a parent may demand of a child's terminal result.
///
/// ## What a schema is here, and why it is not JSON Schema
///
/// A parent that wants to branch on `found.files` has to state the shape
/// up front and the child has to be held to it. Otherwise a
/// deterministic orchestrator regexes prose, which is strictly worse
/// than the model it replaced — which is why this lands before the
/// orchestration seam rather than alongside it.
///
/// Loom has no JSON Schema dependency and taking one is not a decision
/// this seam may make. It does not need one. `tools/tool.object_schema`
/// already emits a JSON-Schema-shaped dialect for every tool definition
/// the model reads on every request — `{"type": "object", "properties":
/// {...}, "required": [...]}`, with `{"type": "string"}` and `{"type":
/// "array", "items": {...}}` underneath — so the parent states the shape
/// in the notation it is already fluent in, and the harness decodes
/// exactly the subset it can enforce: a flat list of named fields, one
/// closed-set type each, required or not.
///
/// The subset is enforced by refusal rather than by omission. A schema
/// carrying `oneOf`, `$ref`, `pattern`, `enum` or a numeric bound is
/// rejected at spawn naming the key, because a schema that quietly means
/// less than it says is worse than no schema at all: the parent would
/// write a constraint, read it back in the brief, and never learn that
/// nothing was checking it.
///
/// Extra keys in a *result*, on the other hand, are allowed, and the
/// rendered schema says so by leaving `additionalProperties` out — which
/// is the JSON Schema default. The contract is a lower bound on the
/// shape: a child that reports more than it owed has still reported what
/// it owed, and failing it would turn a harmless surplus into a failed
/// run.
///
/// Constructor invariants: opaque, because `fields` has a validity
/// condition — at least one field, at most `max_result_fields`, every
/// name matching `[A-Za-z0-9._-]` within `max_field_name_length`, and
/// every `required` name declared. `parse_result_schema` is the only way
/// in and it is total.
pub opaque type ResultSchema {
  ResultSchema(fields: List(ResultField))
}

/// One declared field of a result schema.
///
/// Constructor invariants: `name` has passed `parse_result_schema`'s
/// alphabet and length check, which is not cosmetic — a field name is
/// rendered back into the child's brief and into the refusal a mismatch
/// produces, so an unbounded one carrying newlines could imitate the
/// harness's own framing markers.
pub type ResultField {
  ResultField(name: String, expects: FieldType, required: Bool)
}

/// The closed set of types a declared field may have — the JSON Schema
/// `type` vocabulary, minus what this harness does not enforce.
pub type FieldType {
  /// `{"type": "string"}`.
  StringField

  /// `{"type": "integer"}`: a JSON number with no fraction or exponent.
  IntegerField

  /// `{"type": "number"}`: any JSON number, integral or not.
  NumberField

  /// `{"type": "boolean"}`.
  BooleanField

  /// `{"type": "object"}`. The keys underneath are not described: this
  /// is the smallest thing that says "an object with these keys of these
  /// types", and nesting a second level of that is a schema language.
  ObjectField

  /// `{"type": "array", "items": {...}}`, or `{"type": "array"}` with
  /// `items` absent, which is an array of anything.
  ArrayField(items: FieldType)

  /// A property object with no `type` at all — the shape
  /// `tool.any_property` emits. Anything matches, `null` included.
  AnyField
}

/// Why a value did not match its schema. Every variant names both what
/// was wanted and what arrived: a refusal that says only "did not match"
/// is the anonymous-refusal pattern this repository has been bitten by
/// three times, and it costs the reader a round trip to learn what it
/// could have been told outright.
pub type Mismatch {
  /// The result was not a JSON object at all.
  NotAnObject(received: String)

  /// A required field was not there.
  FieldMissing(name: String, expects: FieldType)

  /// A field was there and had the wrong type.
  FieldWrongType(name: String, expects: FieldType, received: String)
}

/// The verdict on the structured result a `Ready` handle owed.
///
/// Four variants rather than a `Result(JsonValue, String)`, because
/// there are four distinct facts here and three of them are not
/// failures. Collapsing them costs the one property compatibility rests
/// on: with `NoResultAsked` as its own variant, a spawn that named no
/// schema renders exactly the bytes it rendered before this existed —
/// no invented value, no "no schema" sentinel to strip.
pub type TerminalResult {
  /// The spawn asked for no schema. Nothing is rendered for it.
  NoResultAsked

  /// The child recorded a result and it matched.
  ResultGiven(value: JsonValue)

  /// A schema was asked for and the child's run ended without recording
  /// anything under `result_note_key`.
  ResultAbsent(schema: ResultSchema)

  /// A result cell is there and does not match. Reachable even though
  /// the write is checked, because the cell is read back out of the
  /// durable store, and a value crossing that boundary is decoded rather
  /// than trusted.
  ResultUnusable(schema: ResultSchema, received: JsonValue, mismatch: Mismatch)
}

/// One `agent_spawn` request, decoded.
///
/// Constructor invariants: `purpose` is model text the Agency slugs into
/// part of a name and never uses verbatim as a key; `tools`, when present,
/// may only *narrow* the caller's own active set; `within_ms`, when
/// present, is a relative budget the Agency converts to an absolute
/// deadline at spawn; `result_schema`, when present, is already parsed —
/// a malformed one never reaches the seam, because the parent is told
/// about its own mistake in the turn it made it rather than after
/// waiting on a child that was never going to satisfy it.
pub type SpawnRequest {
  SpawnRequest(
    purpose: String,
    brief: String,
    tools: Option(List(String)),
    within_ms: Option(Int),
    result_schema: Option(ResultSchema),
    context: Provenance,
    detach: Bool,
  )
}

/// What a spawn produced.
pub type Spawned {
  Spawned(handle: Handle, strand: String, tools: List(String))
}

/// How a child's operation ended.
pub type Outcome {
  /// The run finished normally.
  Completed

  /// The run failed terminally.
  Failed(reason: String)

  /// The run was aborted — deadline, reap, or operator.
  Aborted
}

/// One handle's position when a wait returned.
pub type Waited {
  /// The operation settled; `report` is the child's final assistant text,
  /// empty when the child ended without one (a failure, an abort, or a
  /// run completed by terminated tools), `result` is the verdict on the
  /// structured result the spawn asked for, and `notes` are its
  /// blackboard cells.
  ///
  /// `report` and `result` are both here on purpose. Prose is what a
  /// human and a reading model want; typed JSON is what a program
  /// branching on `found.files` wants. Neither replaces the other, so
  /// removing the prose to make room for the JSON would trade one
  /// audience for the other.
  Ready(
    handle: Handle,
    outcome: Outcome,
    report: String,
    result: TerminalResult,
    notes: List(#(String, JsonValue)),
  )

  /// The deadline expired first. Not an error: call again, or do other
  /// work and come back.
  Pending(handle: Handle, waited_ms: Int)
}

/// How a `send` payload landed — mirrors `runtime/api.Delivery`, which
/// `tools` cannot import.
pub type Delivery {
  /// The target had an open run: the message is a durable steer on it.
  Steered(entry: EntryId)

  /// The target was idle: the message was accepted as a fresh run.
  Started(operation: OpId)
}

/// How a peer stands in relation to the caller.
pub type Relation {
  /// The strand that spawned the caller.
  ParentOf

  /// A strand the caller spawned.
  ChildOf
}

/// One entry in the caller's roster: a durable read of the lineage
/// ledger, not of process state, so it is correct across restarts —
/// which is the whole point, because compaction can erase every handle
/// from a model's context and this is then the only way back.
pub type Peer {
  Peer(
    strand: String,
    relation: Relation,
    handle: Option(Handle),
    outcome: Option(Outcome),
    tools: List(String),
  )
}

/// Why an Agency call was refused. Every one settles as an ordinary
/// in-band `is_error` result: a refusal is something for the model to
/// read and act on, never a harness fault.
pub type Refusal {
  /// This host wired no messaging plane, or its holder is not up yet.
  AgencyUnavailable

  /// The handle text did not parse.
  MalformedHandle(text: String)

  /// The named strand is not the caller's parent and not a descendant of
  /// it. Also the answer for a strand with no lineage cell at all: "no
  /// lineage fact" means "not a descendant", never "unknown, allow".
  NotAddressable(strand: String)

  /// A wait named a strand that is not a descendant of the caller. Waits
  /// are strictly downward — that is what makes the wait graph acyclic.
  NotADescendant(strand: String)

  /// The caller is already at the spawning depth cap.
  DepthCapReached(depth: Int)

  /// The caller, or the session, already has as many live strands as it
  /// may have.
  FanOutCapReached(live: Int, cap: Int)

  /// The spawn asked for a tool the caller does not itself hold. A child
  /// may narrow its parent's set, never widen it.
  UnknownTool(name: String)

  /// An argument was unusable — an empty purpose, an unusable one, too
  /// many handles, a blackboard key outside the allowed shape.
  InvalidArgument(reason: String)

  /// A send upward would have *started* a run rather than steered one:
  /// the parent has finished and nobody is watching it. Reporting into a
  /// finished parent burns tokens with no human present, which is the
  /// exact property auto-enqueued results were rejected over.
  ParentRunEnded(strand: String)

  /// A child's terminal result did not match the schema its parent asked
  /// for. Refused to the *child*, on the child's own `agent_note` call:
  /// the child is the party that can fix it, and it can fix it now,
  /// inside the run that produced the value, with its whole context
  /// still live.
  ResultSchemaUnmet(
    schema: ResultSchema,
    received: JsonValue,
    mismatch: Mismatch,
  )

  /// The name this spawn derives is already a child's, and the ledger
  /// says a different minter made it. Reconciliation hands an existing
  /// child back on a name match — that is what makes a replayed spawn
  /// idempotent — but only when the recorded call site is the caller's
  /// own; anything else would be an ownership transfer rather than a
  /// reconciliation, quietly discarding this spawn's brief, tools,
  /// deadline and result contract and handing back a strand already busy
  /// with somebody else's work. Refused rather than adopted, because a
  /// wrong answer that reads like a right one is the worse outcome.
  NameAlreadyMinted(strand: String)

  /// The durable plane refused or failed — a commit, a read, a decode.
  PlaneFailed(reason: String)
}

/// The messaging seam: everything a tool may do to another strand.
/// Production wiring fills it with closures reaching a live runtime
/// through a named process; tests fill it with a fake and the tools
/// cannot tell the difference.
///
/// Constructor invariants: every closure is total — it returns a
/// `Refusal`, it does not crash — and every one is judged against the
/// `Caller` it is handed rather than against anything in its other
/// arguments. `wait` waits *all* the handles it is given against one
/// deadline and answers one `Waited` per handle, in argument order.
/// `max_wait_ms` is the ceiling `wait` clamps its budget to, and is
/// published here so the tool's own schema can state the real number.
pub type Agency {
  Agency(
    /// Mints a child strand, seeds it, and accepts its brief.
    spawn: fn(Caller, SpawnRequest) -> Result(Spawned, Refusal),
    /// Delivers one attributed message to an addressable peer.
    send: fn(Caller, String, String) -> Result(Delivery, Refusal),
    /// Waits, up to one shared deadline, for descendants' operations.
    wait: fn(Caller, List(Handle), Int) -> Result(List(Waited), Refusal),
    /// Writes one blackboard cell under the caller's own namespace.
    note: fn(Caller, String, JsonValue) -> Result(Nil, Refusal),
    /// Reads blackboard cells under an `agent/`-relative key prefix.
    notes: fn(Caller, Option(String)) ->
      Result(List(#(String, JsonValue)), Refusal),
    /// The caller's parent and live descendants, from durable state.
    roster: fn(Caller) -> Result(List(Peer), Refusal),
    /// The ceiling a wait's budget is clamped to, in milliseconds.
    max_wait_ms: Int,
  )
}

// --- handles ---------------------------------------------------------------

/// Renders a handle as the text the model sees and hands back.
///
/// ## Examples
///
/// ```gleam
/// // agent.handle_to_string(handle) == "sub:main/reviewer-1#op_01J…"
/// ```
///
pub fn handle_to_string(handle: Handle) -> String {
  handle.strand <> "#" <> ids.op_id_to_string(handle.operation)
}

/// Parses a handle back. Total: a model will hand back something mangled
/// sooner or later, and that must be a refusal rather than a crash.
///
/// The split is on the **last** `#`, because a minted slug rejects `#`
/// but an operator-created strand name is not required to.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = agent.parse_handle("not a handle")
/// ```
///
pub fn parse_handle(text: String) -> Result(Handle, Refusal) {
  case list.reverse(string.split(text, "#")) {
    [operation_text, first, ..rest] ->
      handle_from_parts(text, operation_text, first, rest)
    _ -> Error(MalformedHandle(text:))
  }
}

// The strand half is everything before the last `#`, rejoined — a
// minted slug never contains one, but an operator-created strand name
// is not required to avoid it.
fn handle_from_parts(
  text: String,
  operation_text: String,
  first: String,
  rest: List(String),
) -> Result(Handle, Refusal) {
  use operation <- result.try(
    ids.parse_op_id(operation_text)
    |> result.replace_error(MalformedHandle(text:)),
  )
  case string.join(list.reverse([first, ..rest]), "#") {
    "" -> Error(MalformedHandle(text:))
    strand -> Ok(Handle(strand:, operation:))
  }
}

/// Slugs a model-supplied purpose into the name-safe fragment a minted
/// strand name embeds: lowercase, `[a-z0-9-]` only, runs of anything else
/// collapsed to one `-`, trimmed of leading and trailing `-`, and capped
/// at `max_slug_length`. `Error(Nil)` when nothing usable survives.
///
/// `/` and `#` are rejected by construction, which is what keeps a handle
/// unambiguously splittable and keeps a name from claiming a path shape
/// it did not earn.
///
/// ## Examples
///
/// ```gleam
/// assert agent.slug("Review the auth code") == Ok("review-the-auth-code")
/// ```
///
/// ```gleam
/// assert agent.slug("main/../#") == Ok("main")
/// ```
///
/// ```gleam
/// assert agent.slug("///") == Error(Nil)
/// ```
///
pub fn slug(purpose: String) -> Result(String, Nil) {
  let slugged =
    purpose
    |> string.lowercase
    |> string.to_graphemes
    |> list.map(fn(character) {
      case is_slug_character(character) {
        True -> character
        False -> "-"
      }
    })
    |> string.concat
    |> collapse_dashes
    |> string.slice(at_index: 0, length: max_slug_length)
    |> trim_dashes
  case slugged {
    "" -> Error(Nil)
    text -> Ok(text)
  }
}

fn is_slug_character(character: String) -> Bool {
  case character {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "-" -> True
    _ -> False
  }
}

fn collapse_dashes(text: String) -> String {
  case string.contains(text, "--") {
    True -> collapse_dashes(string.replace(text, "--", "-"))
    False -> text
  }
}

fn trim_dashes(text: String) -> String {
  case text {
    "-" <> rest -> trim_dashes(rest)
    _ ->
      case string.ends_with(text, "-") {
        True ->
          trim_dashes(string.slice(
            text,
            at_index: 0,
            length: string.length(text) - 1,
          ))
        False -> text
      }
  }
}

// --- the result contract ---------------------------------------------------

/// Parses a parent-supplied result schema. Total: every malformed shape
/// comes back as a reason the parent can read and repair, never a crash
/// and never a silently narrowed contract.
///
/// This runs at spawn, in the parent's own turn, so a parent that writes
/// a bad schema learns it immediately instead of after joining a child
/// that could never have satisfied it.
///
/// ## Examples
///
/// ```gleam
/// // agent.parse_result_schema(json.Object([
/// //   #("type", json.String("object")),
/// //   #("properties", json.Object([#("ok", json.Object([
/// //     #("type", json.String("boolean")),
/// //   ]))])),
/// //   #("required", json.Array([json.String("ok")])),
/// // ]))
/// ```
///
pub fn parse_result_schema(value: JsonValue) -> Result(ResultSchema, String) {
  use fields <- result.try(case value {
    json.Object(fields:) -> Ok(fields)
    other -> Error("must be a JSON object, not `" <> type_name(other) <> "`")
  })
  use Nil <- result.try(only_keys(fields, envelope_keys, "a result schema"))
  use Nil <- result.try(case list.key_find(fields, "type") {
    Ok(json.String("object")) -> Ok(Nil)
    Ok(_other) | Error(Nil) ->
      Error("must declare `\"type\": \"object\"` at its top level")
  })
  use properties <- result.try(case list.key_find(fields, "properties") {
    Ok(json.Object(fields: properties)) -> Ok(properties)
    Ok(other) ->
      Error("`properties` must be an object, not `" <> type_name(other) <> "`")
    Error(Nil) -> Error("must carry a `properties` object")
  })
  use required <- result.try(required_names(fields))

  // The bound sits above the walk, and that ordering is the whole of its
  // protection: `list.drop` answers a question about the first
  // `max_result_fields` entries without walking whatever a model pasted
  // after them, and refusing here means `parse_property` never runs over
  // the excess at all. A program drives this path at up to a frame's
  // worth of properties per call, so the walk is the cost being avoided
  // rather than the drop.
  use Nil <- result.try(case list.drop(properties, max_result_fields) {
    [] -> Ok(Nil)
    [_, ..] ->
      Error(
        "may declare at most "
        <> int.to_string(max_result_fields)
        <> " properties",
      )
  })
  use declared <- result.try(list.try_map(properties, parse_property))
  use Nil <- result.try(case declared {
    [] -> Error("must declare at least one property to be worth demanding")
    [_, ..] -> Ok(Nil)
  })
  use Nil <- result.try(
    list.try_each(required, fn(name) {
      case list.key_find(declared, name) {
        Ok(_type) -> Ok(Nil)
        Error(Nil) ->
          Error(
            "lists `"
            <> name
            <> "` as required without declaring it in `properties`",
          )
      }
    }),
  )
  Ok(
    ResultSchema(
      fields: list.map(declared, fn(pair) {
        ResultField(
          name: pair.0,
          expects: pair.1,
          required: list.contains(required, pair.0),
        )
      }),
    ),
  )
}

/// The declared fields of a schema, in the order the parent wrote them.
///
/// ## Examples
///
/// ```gleam
/// // list.map(agent.result_fields(schema), fn(field) { field.name })
/// ```
///
pub fn result_fields(schema: ResultSchema) -> List(ResultField) {
  schema.fields
}

/// Renders a schema back to the dialect it was parsed from. This is the
/// canonical form: it is what the child's brief quotes, what a refusal
/// names, and what the Agency stores durably, so a schema read back out
/// of the store parses to the value that was written.
///
/// `additionalProperties` is deliberately absent — JSON Schema's default
/// is to allow extra keys, and that is exactly what validation does.
///
/// ## Examples
///
/// ```gleam
/// // json.to_string(agent.render_result_schema(schema))
/// ```
///
pub fn render_result_schema(schema: ResultSchema) -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object(
        list.map(schema.fields, fn(field) {
          #(field.name, render_field_type(field.expects))
        }),
      ),
    ),
    #(
      "required",
      json.Array(
        schema.fields
        |> list.filter(fn(field) { field.required })
        |> list.map(fn(field) { json.String(field.name) }),
      ),
    ),
  ])
}

/// Checks one value against a schema.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = agent.validate_result(schema, value)
/// ```
///
pub fn validate_result(
  schema: ResultSchema,
  value: JsonValue,
) -> Result(Nil, Mismatch) {
  use fields <- result.try(case value {
    json.Object(fields:) -> Ok(fields)
    other -> Error(NotAnObject(received: type_name(other)))
  })
  list.try_each(schema.fields, fn(field) { check_field(fields, field) })
}

/// A mismatch as one neutral sentence. Neutral rather than second person
/// because both sides read it: the child that wrote the value, and the
/// parent that joined the child and found the cell unusable.
///
/// ## Examples
///
/// ```gleam
/// assert agent.describe_mismatch(agent.NotAnObject(received: "array"))
///   == "a result must be a JSON object, not `array`"
/// ```
///
pub fn describe_mismatch(mismatch: Mismatch) -> String {
  case mismatch {
    NotAnObject(received:) ->
      "a result must be a JSON object, not `" <> received <> "`"
    FieldMissing(name:, expects:) ->
      "`"
      <> name
      <> "` is required and was not recorded; it must be `"
      <> field_type_name(expects)
      <> "`"
    FieldWrongType(name:, expects:, received:) ->
      "`"
      <> name
      <> "` must be `"
      <> field_type_name(expects)
      <> "`, not `"
      <> received
      <> "`"
  }
}

// The envelope keys a result schema may carry. `description` rides along
// because a parent writing a schema for a model to read will want one,
// and it changes nothing this side enforces.
const envelope_keys = ["type", "properties", "required", "description"]

// The keys one property object may carry — and the whole of the refusal
// rule for the unsupported half of JSON Schema. `oneOf`, `$ref`,
// `pattern`, `enum`, `minimum` and the rest are not on this list, so a
// schema using them is refused naming the key rather than accepted with
// the constraint quietly dropped.
const property_keys = ["type", "items", "description"]

fn only_keys(
  fields: List(#(String, JsonValue)),
  allowed: List(String),
  what: String,
) -> Result(Nil, String) {
  case list.find(fields, fn(pair) { !list.contains(allowed, pair.0) }) {
    Error(Nil) -> Ok(Nil)
    Ok(pair) ->
      Error(
        what
        <> " may not carry `"
        <> pair.0
        <> "`; this harness enforces only "
        <> string.join(allowed, ", "),
      )
  }
}

fn required_names(
  fields: List(#(String, JsonValue)),
) -> Result(List(String), String) {
  case list.key_find(fields, "required") {
    Error(Nil) -> Ok([])
    Ok(json.Array(items:)) ->
      list.try_map(items, fn(item) {
        case item {
          json.String(value:) -> Ok(value)
          other ->
            Error(
              "`required` must hold strings; it holds `"
              <> type_name(other)
              <> "`",
            )
        }
      })
    Ok(other) ->
      Error("`required` must be an array, not `" <> type_name(other) <> "`")
  }
}

fn parse_property(
  property: #(String, JsonValue),
) -> Result(#(String, FieldType), String) {
  let #(name, described) = property
  use Nil <- result.try(case usable_field_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "declares an unusable property name `"
        <> excerpt(name)
        <> "`; names hold letters, digits, `.`, `-` and `_`, up to "
        <> int.to_string(max_field_name_length)
        <> " characters",
      )
  })
  use expects <- result.try(
    parse_field_type(described, 0)
    |> result.map_error(fn(reason) { "property `" <> name <> "` " <> reason }),
  )
  Ok(#(name, expects))
}

// A field name is rendered into the child's brief and into the sentence
// a mismatch produces, so its shape is checked rather than trusted: an
// unbounded name carrying newlines could imitate the harness's own
// framing markers in the very text framing exists to make legible.
fn usable_field_name(name: String) -> Bool {
  name != ""
  && string.length(name) <= max_field_name_length
  && list.all(string.to_graphemes(name), fn(character) {
    string.contains(field_name_alphabet, character)
  })
}

const field_name_alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"

fn parse_field_type(
  described: JsonValue,
  depth: Int,
) -> Result(FieldType, String) {
  use <- bool.lazy_guard(when: depth > max_schema_depth, return: fn() {
    Error(
      "nests `items` deeper than "
      <> int.to_string(max_schema_depth)
      <> " levels",
    )
  })
  use fields <- result.try(case described {
    json.Object(fields:) -> Ok(fields)
    other ->
      Error(
        "must be an object like {\"type\": \"string\"}, not `"
        <> type_name(other)
        <> "`",
      )
  })
  use Nil <- result.try(only_keys(fields, property_keys, "a property"))
  case list.key_find(fields, "type") {
    Error(Nil) -> Ok(AnyField)
    Ok(json.String("string")) -> Ok(StringField)
    Ok(json.String("integer")) -> Ok(IntegerField)
    Ok(json.String("number")) -> Ok(NumberField)
    Ok(json.String("boolean")) -> Ok(BooleanField)
    Ok(json.String("object")) -> Ok(ObjectField)
    Ok(json.String("array")) -> parse_array_type(fields, depth)
    Ok(other) ->
      Error(
        "has an unusable `type` "
        <> excerpt(json.to_string(other))
        <> "; it must be one of string, integer, number, boolean, object, "
        <> "array, or absent for any value",
      )
  }
}

fn parse_array_type(
  fields: List(#(String, JsonValue)),
  depth: Int,
) -> Result(FieldType, String) {
  case list.key_find(fields, "items") {
    Error(Nil) -> Ok(ArrayField(items: AnyField))
    Ok(described) ->
      parse_field_type(described, depth + 1)
      |> result.map(fn(items) { ArrayField(items:) })
  }
}

fn render_field_type(expects: FieldType) -> JsonValue {
  case expects {
    AnyField -> json.Object([])
    StringField -> json.Object([#("type", json.String("string"))])
    IntegerField -> json.Object([#("type", json.String("integer"))])
    NumberField -> json.Object([#("type", json.String("number"))])
    BooleanField -> json.Object([#("type", json.String("boolean"))])
    ObjectField -> json.Object([#("type", json.String("object"))])
    ArrayField(items:) ->
      json.Object([
        #("type", json.String("array")),
        #("items", render_field_type(items)),
      ])
  }
}

fn check_field(
  fields: List(#(String, JsonValue)),
  field: ResultField,
) -> Result(Nil, Mismatch) {
  case list.key_find(fields, field.name) {
    Ok(value) -> check_type(field, value)
    Error(Nil) ->
      case field.required {
        True -> Error(FieldMissing(name: field.name, expects: field.expects))
        False -> Ok(Nil)
      }
  }
}

fn check_type(field: ResultField, value: JsonValue) -> Result(Nil, Mismatch) {
  case matches(field.expects, value) {
    True -> Ok(Nil)
    False ->
      Error(FieldWrongType(
        name: field.name,
        expects: field.expects,
        received: received_name(field.expects, value),
      ))
  }
}

// The type test runs through `type_name` rather than re-matching the
// constructors, so the vocabulary a mismatch is reported in and the
// vocabulary it is judged in cannot drift apart.
fn matches(expects: FieldType, value: JsonValue) -> Bool {
  case expects {
    AnyField -> True
    StringField -> type_name(value) == "string"
    IntegerField -> type_name(value) == "integer"
    NumberField -> type_name(value) == "integer" || type_name(value) == "number"
    BooleanField -> type_name(value) == "boolean"
    ObjectField -> type_name(value) == "object"
    ArrayField(items:) ->
      case value {
        json.Array(items: values) -> list.all(values, matches(items, _))
        json.String(..)
        | json.Int(..)
        | json.Float(..)
        | json.Bool(..)
        | json.Object(..)
        | json.Null -> False
      }
  }
}

// What actually arrived, said in the vocabulary the expectation is said
// in — and, for an array, said about the first element that broke the
// promise rather than about the array as a whole, because "array" is not
// the news when an array is what was asked for.
fn received_name(expects: FieldType, value: JsonValue) -> String {
  case expects {
    ArrayField(items:) -> received_array_name(items, value)
    AnyField
    | StringField
    | IntegerField
    | NumberField
    | BooleanField
    | ObjectField -> type_name(value)
  }
}

fn received_array_name(items: FieldType, value: JsonValue) -> String {
  case value {
    json.Array(items: values) ->
      case list.find(values, fn(item) { !matches(items, item) }) {
        Ok(offender) -> "array containing " <> type_name(offender)
        Error(Nil) -> type_name(value)
      }
    json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Object(..)
    | json.Null -> type_name(value)
  }
}

/// The JSON type of a value, in the schema's own vocabulary.
///
/// ## Examples
///
/// ```gleam
/// assert agent.type_name(json.Array([])) == "array"
/// ```
///
pub fn type_name(value: JsonValue) -> String {
  case value {
    json.String(..) -> "string"
    json.Int(..) -> "integer"
    json.Float(..) -> "number"
    json.Bool(..) -> "boolean"
    json.Object(..) -> "object"
    json.Array(..) -> "array"
    json.Null -> "null"
  }
}

/// A declared type in the same vocabulary, so an expectation and what
/// arrived can be set side by side without one of them reading oddly.
///
/// ## Examples
///
/// ```gleam
/// assert agent.field_type_name(agent.ArrayField(items: agent.StringField))
///   == "array of string"
/// ```
///
pub fn field_type_name(expects: FieldType) -> String {
  case expects {
    AnyField -> "any JSON value"
    StringField -> "string"
    IntegerField -> "integer"
    NumberField -> "number"
    BooleanField -> "boolean"
    ObjectField -> "object"
    ArrayField(items:) -> "array of " <> field_type_name(items)
  }
}

// A rendered value quoted inside a message, bounded. `string.slice`
// answers the question the bound asks; comparing the slice back against
// the whole says whether anything was cut without measuring the rest.
fn excerpt(text: String) -> String {
  let cut = string.slice(text, at_index: 0, length: max_excerpt)
  case cut == text {
    True -> text
    False -> cut <> "…"
  }
}

/// A refusal as one line of model-facing prose.
///
/// ## Examples
///
/// ```gleam
/// assert agent.describe(agent.AgencyUnavailable)
///   == "this session has no messaging plane; agent tools are unavailable"
/// ```
///
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    AgencyUnavailable ->
      "this session has no messaging plane; agent tools are unavailable"
    MalformedHandle(text:) ->
      "`" <> text <> "` is not a handle; use one agent_spawn returned"
    NotAddressable(strand:) ->
      "you may address only your parent and your own descendants; `"
      <> strand
      <> "` is neither"
    NotADescendant(strand:) ->
      "you may wait only on your own descendants; `" <> strand <> "` is not one"
    DepthCapReached(depth:) ->
      "spawning is capped at depth "
      <> int.to_string(depth)
      <> "; do this work yourself"
    FanOutCapReached(live:, cap:) ->
      "you already have "
      <> int.to_string(live)
      <> " live agents and the cap is "
      <> int.to_string(cap)
      <> "; wait for one to finish"
    UnknownTool(name:) ->
      "you cannot give a child the tool `"
      <> name
      <> "`, which you do not hold yourself"
    InvalidArgument(reason:) -> "invalid arguments: " <> reason
    ParentRunEnded(strand:) ->
      "`"
      <> strand
      <> "` has finished its run; a message now would start a new one with "
      <> "nobody watching, so it was not delivered. Put this in your own "
      <> "final answer instead"
    ResultSchemaUnmet(schema:, received:, mismatch:) ->
      "your result does not match the schema your brief asked for: "
      <> describe_mismatch(mismatch)
      <> ". The schema is "
      <> json.to_string(render_result_schema(schema))
      <> " and you recorded "
      <> excerpt(json.to_string(received))
      <> ". Nothing was written; fix the value and write the note again"
    NameAlreadyMinted(strand:) ->
      "`"
      <> strand
      <> "` was minted by a different call and is already busy with it; "
      <> "nothing was started. Ask for this with a different purpose"
    PlaneFailed(reason:) -> "the messaging plane failed: " <> reason
  }
}

// --- the tools -------------------------------------------------------------

/// The six agent tools over one Agency.
///
/// Registration is gated on an Agency existing at all, rather than on an
/// `Option` inside `Ctx`, and the reason is arithmetic: the wire tool
/// array is built from the *registry*, sits at the very front of the
/// provider's cached byte prefix, and is paid for on every request of
/// every strand forever. A host with no messaging plane would otherwise
/// ship six tool definitions the model can only ever be refused on.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(core_tools, agent.tools(agency)))
/// ```
///
pub fn tools(agency: Agency) -> List(Tool) {
  [
    note_tool(agency),
    notes_tool(agency),
    roster_tool(agency),
    send_tool(agency),
    spawn_tool(agency),
    wait_tool(agency),
  ]
}

/// The `agent_spawn` tool: start a child strand on a brief.
///
/// `replay: Safe` is earned, not assumed. The child's name derives from
/// `{operation, step, source index}`, all persisted in the intent, so a
/// replayed spawn reaches for the same name; `create_strand` answers
/// "exists", and the Agency reconciles onto the child that is already
/// there. Nothing runs twice — the same promise the effect sandwich makes
/// everywhere else, obtained the same way: mint the identifier before the
/// effect, not after.
pub fn spawn_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: spawn_tool_name,
    description: "Start a subagent on a task brief and get a handle back. "
      <> "The child is a strand in this session with its own context; it "
      <> "sees only the brief you write, so write a complete one. Join it "
      <> "with agent_wait.",
    schema: tool.object_schema(
      [
        #(
          "purpose",
          tool.string_property(
            "two or three words naming the job; becomes part of the child's "
            <> "name",
          ),
        ),
        #(
          "brief",
          tool.string_property(
            "the complete task. The child starts with no other context",
          ),
        ),
        #(
          "tools",
          tool.string_array_property(
            "a subset of your own tools (you cannot grant what you do not "
            <> "hold). Defaults to your set minus agent_spawn",
          ),
        ),
        #(
          "within_ms",
          tool.integer_property(
            "wall-clock budget; the child is aborted when it expires",
          ),
        ),
        #(
          "result_schema",
          tool.any_property(
            "the shape you want the child's result in, as a JSON schema "
            <> "object: {\"type\": \"object\", \"properties\": {\"files\": "
            <> "{\"type\": \"array\", \"items\": {\"type\": \"string\"}}}, "
            <> "\"required\": [\"files\"]}. Property types are string, "
            <> "integer, number, boolean, object, array, or omitted for "
            <> "anything. The child is told to record a matching result and "
            <> "is refused if it does not; agent_wait then hands you the "
            <> "value as JSON instead of prose. Omit it for a prose-only "
            <> "child",
          ),
        ),
        #(
          "context",
          tool.enum_property(
            ["fresh", "my_conversation"],
            "fresh (default) starts the child at the root of the tree. "
              <> "my_conversation forks at your current leaf, copying your "
              <> "entire conversation into the child's context window",
          ),
        ),
        #(
          "detach",
          tool.boolean_property(
            "default false: the child is aborted when your run ends",
          ),
        ),
      ],
      ["purpose", "brief"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_spawn(agency, ctx, args) },
  )
}

fn run_spawn(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use purpose <- tool.with_arg(tool.required_string(args, "purpose"))
  use brief <- tool.with_arg(tool.required_string(args, "brief"))
  use tools <- tool.with_arg(tool.optional_string_list(args, "tools"))
  use within_ms <- tool.with_arg(tool.optional_int(args, "within_ms"))
  use result_schema <- tool.with_arg(decode_result_schema(args))
  use context <- tool.with_arg(decode_provenance(args))
  use detach <- tool.with_arg(tool.optional_bool(args, "detach"))
  let request =
    SpawnRequest(
      purpose:,
      brief:,
      tools:,
      within_ms:,
      result_schema:,
      context:,
      detach: option.unwrap(detach, False),
    )
  case agency.spawn(caller(ctx), request) {
    Error(refusal) -> refusal_outcome(refusal)
    Ok(spawned) ->
      tool.success(
        "started `"
        <> spawned.strand
        <> "` with tools ["
        <> string.join(spawned.tools, ", ")
        <> "]. Handle: "
        <> handle_to_string(spawned.handle),
      )
      |> tool.with_details(
        json.Object([
          #("handle", json.String(handle_to_string(spawned.handle))),
          #("strand", json.String(spawned.strand)),
          #("tools", json.Array(list.map(spawned.tools, json.String))),
        ]),
      )
  }
}

// The schema is parsed in the shell, before the Agency mints anything.
// A malformed schema is the parent's own mistake and nothing about it
// needs a runtime to diagnose, so the parent is told in the turn it made
// the mistake rather than after waiting on a child it had already paid
// for.
fn decode_result_schema(
  args: JsonValue,
) -> Result(Option(ResultSchema), String) {
  use described <- result.try(tool.optional_value(args, "result_schema"))
  case described {
    None | Some(json.Null) -> Ok(None)
    Some(value) ->
      parse_result_schema(value)
      |> result.map(Some)
      |> result.map_error(fn(reason) { "`result_schema` " <> reason })
  }
}

fn decode_provenance(args: JsonValue) -> Result(Provenance, String) {
  case tool.optional_string(args, "context") {
    Error(reason) -> Error(reason)
    Ok(None) -> Ok(Fresh)
    Ok(Some("fresh")) -> Ok(Fresh)
    Ok(Some("my_conversation")) -> Ok(MyConversation)
    Ok(Some(other)) ->
      Error("`context` must be fresh or my_conversation, not `" <> other <> "`")
  }
}

/// The `agent_wait` tool: block, bounded, for descendants' results.
///
/// One call, one deadline, however many handles — see the module doc for
/// why the array is the unit of waiting rather than the tool call.
pub fn wait_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_wait",
    description: "Wait for subagents to finish. Give it every handle you "
      <> "want to join in one call: they are waited together against one "
      <> "deadline, not one after another. A handle that has not settled "
      <> "when the deadline expires comes back pending, which is an answer, "
      <> "not a failure — call again or do other work first.",
    schema: tool.object_schema(
      [
        #(
          "handles",
          tool.string_array_property("handles returned by agent_spawn"),
        ),
        #(
          "within_ms",
          tool.integer_property(
            "how long to wait, for the whole set; clamped to "
            <> int.to_string(agency.max_wait_ms),
          ),
        ),
      ],
      ["handles"],
    ),
    replay: tool.Safe,
    // Honest: the tool only reads. Under the shipped `Parallel` default
    // this is consulted for real, so single-handle waits in one batch do
    // overlap — but the fan-out story still does not rest on it, because
    // an `Exclusive` sibling fences the batch and a session may set
    // `sequential` back. See the module doc.
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_wait(agency, ctx, args) },
  )
}

fn run_wait(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use texts <- tool.with_arg(tool.optional_string_list(args, "handles"))
  use within_ms <- tool.with_arg(tool.optional_int(args, "within_ms"))
  let texts = option.unwrap(texts, [])
  use <- bool.guard(
    when: texts == [],
    return: tool.failure("invalid arguments: `handles` must not be empty"),
  )

  // `texts` is model-supplied and not otherwise bounded, so a caller
  // that lists far more than `max_handles` handles must not force a walk
  // of the whole array just to say so — `list.drop` stops at the bound.
  use <- bool.guard(
    when: list.drop(texts, max_handles) != [],
    return: tool.failure(
      "invalid arguments: at most "
      <> int.to_string(max_handles)
      <> " handles per call",
    ),
  )
  use handles <- tool.or_outcome(
    list.try_map(texts, parse_handle),
    refusal_outcome,
  )
  use waited <- tool.or_outcome(
    agency.wait(
      caller(ctx),
      handles,
      option.unwrap(within_ms, agency.max_wait_ms),
    ),
    refusal_outcome,
  )
  tool.success(string.join(list.map(waited, waited_text), "\n\n"))
  |> tool.with_details(
    json.Object([
      #("results", json.Array(list.map(waited, waited_json))),
      #("pending", json.Bool(list.any(waited, is_pending))),
    ]),
  )
}

fn is_pending(waited: Waited) -> Bool {
  case waited {
    Pending(..) -> True
    Ready(..) -> False
  }
}

fn waited_text(waited: Waited) -> String {
  case waited {
    Pending(handle:, waited_ms:) ->
      "["
      <> handle.strand
      <> " still working after "
      <> int.to_string(waited_ms)
      <> "ms]"
    Ready(handle:, outcome:, report:, result:, notes:) ->
      "["
      <> handle.strand
      <> " "
      <> outcome_text(outcome)
      <> "]\n"
      <> report_text(report)
      <> result_suffix(result)
      <> notes_suffix(notes)
  }
}

// The result section, or nothing at all when the spawn named no schema —
// which is what keeps a schema-less join rendering exactly the bytes it
// rendered before result contracts existed.
fn result_suffix(result: TerminalResult) -> String {
  case result {
    NoResultAsked -> ""
    ResultGiven(value:) -> "\n[result] " <> json.to_string(value)
    ResultAbsent(schema:) ->
      "\n[no result] this child owed a result matching "
      <> json.to_string(render_result_schema(schema))
      <> " and recorded none"
    ResultUnusable(schema:, received:, mismatch:) ->
      "\n[unusable result] "
      <> describe_mismatch(mismatch)
      <> "; the schema was "
      <> json.to_string(render_result_schema(schema))
      <> " and the cell holds "
      <> excerpt(json.to_string(received))
  }
}

// A `Ready` handle's report, or the explanation for having none — a
// failure, an abort, or a run terminated by its own tools all end
// without a final answer.
fn report_text(report: String) -> String {
  case report {
    "" -> "(no report: the run ended without a final answer)"
    text -> text
  }
}

// The trailing `[notes] key=value, ...` line, empty when the child
// wrote none.
fn notes_suffix(notes: List(#(String, JsonValue))) -> String {
  case notes {
    [] -> ""
    cells ->
      "\n[notes] "
      <> string.join(
        list.map(cells, fn(cell) { cell.0 <> "=" <> json.to_string(cell.1) }),
        ", ",
      )
  }
}

fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Completed -> "completed"
    Failed(reason:) -> "failed: " <> reason
    Aborted -> "aborted"
  }
}

fn waited_json(waited: Waited) -> JsonValue {
  case waited {
    Pending(handle:, waited_ms:) ->
      json.Object([
        #("handle", json.String(handle_to_string(handle))),
        #("strand", json.String(handle.strand)),
        #("state", json.String("pending")),
        #("waited_ms", json.Int(waited_ms)),
      ])
    Ready(handle:, outcome:, report:, result:, notes:) ->
      json.Object(list.append(
        [
          #("handle", json.String(handle_to_string(handle))),
          #("strand", json.String(handle.strand)),
          #("state", json.String("ready")),
          #("outcome", outcome_json(outcome)),
          #("report", json.String(report)),
          #("notes", json.Object(notes)),
        ],
        result_json(result),
      ))
  }
}

// Zero fields or one. A spawn that asked for no schema appends nothing,
// so its details object is byte for byte what it was before — the
// compatibility floor this feature is only allowed to stand on.
//
// The outcome above is left alone deliberately: it says how the child's
// *run* ended, and a run that completed did complete even when the value
// it left behind is unusable. Folding the contract verdict into it would
// make the one field a waiter reads to decide "did this crash" answer a
// different question than it advertises.
fn result_json(result: TerminalResult) -> List(#(String, JsonValue)) {
  case result {
    NoResultAsked -> []
    ResultGiven(value:) -> [
      #(
        "result",
        json.Object([#("state", json.String("given")), #("value", value)]),
      ),
    ]
    ResultAbsent(schema:) -> [
      #(
        "result",
        json.Object([
          #("state", json.String("absent")),
          #("schema", render_result_schema(schema)),
          #("reason", json.String("the run ended without recording a result")),
        ]),
      ),
    ]
    ResultUnusable(schema:, received:, mismatch:) -> [
      #(
        "result",
        json.Object([
          #("state", json.String("unusable")),
          #("schema", render_result_schema(schema)),
          #("received", received),
          #("reason", json.String(describe_mismatch(mismatch))),
        ]),
      ),
    ]
  }
}

fn outcome_json(outcome: Outcome) -> JsonValue {
  case outcome {
    Completed -> json.String("completed")
    Failed(reason:) -> json.String("failed: " <> reason)
    Aborted -> json.String("aborted")
  }
}

/// The `agent_send` tool: deliver one message to an addressable peer.
///
/// `replay: Never` — a send mints a fresh entry id per admission, so a
/// replay would deliver the message twice. A crash mid-send yields the
/// synthetic interrupted result carrying the explicit warning that the
/// call's outcome is unknown; the model can consult `agent_roster` or
/// simply say it again.
pub fn send_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_send",
    description: "Send a message to your parent or to one of your "
      <> "subagents. It arrives as a durable message on their next "
      <> "checkpoint; this does not wait for a reply.",
    schema: tool.object_schema(
      [
        #(
          "to",
          tool.string_property(
            "the strand name of your parent or a " <> "subagent of yours",
          ),
        ),
        #("message", tool.string_property("what to tell them")),
      ],
      ["to", "message"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_send(agency, ctx, args) },
  )
}

fn run_send(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use to <- tool.with_arg(tool.required_string(args, "to"))
  use message <- tool.with_arg(tool.required_string(args, "message"))
  use delivery <- tool.or_outcome(
    agency.send(caller(ctx), to, message),
    refusal_outcome,
  )
  case delivery {
    Steered(entry:) -> steered_outcome(to, entry)
    Started(operation:) -> started_outcome(to, operation)
  }
}

fn steered_outcome(to: String, entry: EntryId) -> ToolOutcome {
  tool.success("delivered to `" <> to <> "` on its open run")
  |> tool.with_details(
    json.Object([
      #("delivery", json.String("steered")),
      #("entry", json.String(ids.entry_id_to_string(entry))),
    ]),
  )
}

fn started_outcome(to: String, operation: OpId) -> ToolOutcome {
  tool.success("delivered to `" <> to <> "`, which started a run on it")
  |> tool.with_details(
    json.Object([
      #("delivery", json.String("started")),
      #("operation", json.String(ids.op_id_to_string(operation))),
    ]),
  )
}

/// The `agent_note` tool: write one blackboard cell.
pub fn note_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_note",
    description: "Write one cell to the shared blackboard, under your own "
      <> "namespace. Other agents in this session can read it with "
      <> "agent_notes; the write itself notifies nobody. If your brief "
      <> "states a result schema, the key `"
      <> result_note_key
      <> "` is where your final structured result goes, and it is checked "
      <> "against that schema before it is written.",
    schema: tool.object_schema(
      [
        #(
          "key",
          tool.string_property(
            "a short key, letters, digits, `.`, " <> "`-`, `_` and `/`",
          ),
        ),
        #("value", tool.any_property("any JSON value")),
      ],
      ["key", "value"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_note(agency, ctx, args) },
  )
}

fn run_note(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use key <- tool.with_arg(tool.required_string(args, "key"))
  use value <- tool.with_arg(tool.optional_value(args, "value"))
  use value <- tool.with_arg(option.to_result(value, "`value` is required"))
  use Nil <- tool.or_outcome(
    agency.note(caller(ctx), key, value),
    refusal_outcome,
  )
  tool.success("noted " <> blackboard_prefix <> ctx.strand <> "/" <> key)
}

/// The `agent_notes` tool: read blackboard cells by prefix.
pub fn notes_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_notes",
    description: "Read the shared blackboard. Omit the prefix to read every "
      <> "agent's notes in this session; pass one to narrow (for example "
      <> "another agent's strand name).",
    schema: tool.object_schema(
      [
        #(
          "prefix",
          tool.string_property(
            "a key prefix, relative to the shared agent namespace",
          ),
        ),
      ],
      [],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_notes(agency, ctx, args) },
  )
}

fn run_notes(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use prefix <- tool.with_arg(tool.optional_string(args, "prefix"))
  case agency.notes(caller(ctx), prefix) {
    Error(refusal) -> refusal_outcome(refusal)
    Ok([]) -> tool.success("no notes")
    Ok(cells) ->
      tool.success(string.join(
        list.map(cells, fn(cell) { cell.0 <> " = " <> json.to_string(cell.1) }),
        "\n",
      ))
      |> tool.with_details(json.Object([#("notes", json.Object(cells))]))
  }
}

/// The `agent_roster` tool: who the caller's parent and children are.
///
/// It exists because compaction can erase every handle from the model's
/// context, and a durable read of who is running is then the only way
/// back.
pub fn roster_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_roster",
    description: "List your parent and your subagents, with their handles "
      <> "and whether they have finished. Use this when you have lost a "
      <> "handle.",
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, _args) { run_roster(agency, ctx) },
  )
}

fn run_roster(agency: Agency, ctx: Ctx) -> ToolOutcome {
  case agency.roster(caller(ctx)) {
    Error(refusal) -> refusal_outcome(refusal)
    Ok([]) -> tool.success("no parent and no subagents")
    Ok(peers) ->
      tool.success(string.join(list.map(peers, peer_text), "\n"))
      |> tool.with_details(
        json.Object([#("peers", json.Array(list.map(peers, peer_json)))]),
      )
  }
}

fn peer_text(peer: Peer) -> String {
  relation_text(peer.relation)
  <> " "
  <> peer.strand
  <> case peer.handle {
    None -> ""
    Some(handle) -> " (" <> handle_to_string(handle) <> ")"
  }
  <> case peer.outcome {
    None -> " — working"
    Some(outcome) -> " — " <> outcome_text(outcome)
  }
}

fn relation_text(relation: Relation) -> String {
  case relation {
    ParentOf -> "parent"
    ChildOf -> "child"
  }
}

fn peer_json(peer: Peer) -> JsonValue {
  json.Object([
    #("strand", json.String(peer.strand)),
    #("relation", json.String(relation_text(peer.relation))),
    #("handle", case peer.handle {
      None -> json.Null
      Some(handle) -> json.String(handle_to_string(handle))
    }),
    #("outcome", case peer.outcome {
      None -> json.Null
      Some(outcome) -> outcome_json(outcome)
    }),
    #("tools", json.Array(list.map(peer.tools, json.String))),
  ])
}

// --- shared plumbing -------------------------------------------------------

/// The caller identity for a tool context — every field from the driver,
/// none from the model.
///
/// ## Examples
///
/// ```gleam
/// // agent.caller(ctx).strand == ctx.strand
/// ```
///
pub fn caller(ctx: Ctx) -> Caller {
  Caller(
    strand: ctx.strand,
    operation: ctx.op_id,
    step_id: ctx.step_id,
    source_index: ctx.source_index,
    minter: ToolCall,
  )
}

/// The step a spawn's minting is *recorded* under, which is also the step
/// a reconciliation compares against: the caller's own step id, plus the
/// minter whenever the minter is not the planned tool call itself.
///
/// The lineage ledger records a spawn's call site as
/// `{operation, step_id, source_index}` (`runtime/lineage.CallSite`) — a
/// triple with nowhere to put a program's ordinal. Rather than spend
/// `source_index` on it, which is how a program's first spawn came to be
/// indistinguishable from an `agent_spawn` at index 0, the ordinal rides
/// in the step id behind a `#`: a minted step id is a UUID and an
/// operator's is a path-ish label, so neither carries one and the join
/// stays unambiguous. Widening `CallSite` is the better fix and is
/// `runtime`'s to make.
///
/// ## Examples
///
/// ```gleam
/// // agent.minting_step(caller) == caller.step_id  // minter: ToolCall
/// ```
///
/// ```gleam
/// // agent.minting_step(caller) == caller.step_id <> "#program/2"
/// ```
///
pub fn minting_step(caller: Caller) -> String {
  case caller.minter {
    ToolCall -> caller.step_id
    Program(ordinal:) -> caller.step_id <> "#program/" <> int.to_string(ordinal)
  }
}

/// The fixed-width, model-proof half of a minted child's name: sixteen
/// lowercase hex characters standing for the whole of who minted it.
///
/// Everything that distinguishes one minter from another is in here —
/// the operation, the minting step (so the program ordinal with it), and
/// the planned call's source index — and nothing a model says is. That
/// division is the point. A name whose only per-minter component was a
/// *slug* could be erased by the slug's own length cap, and a name whose
/// discriminator shared a field with model text could be steered into a
/// collision by choosing the text; a constant-width digest over
/// coordinates alone has neither opening, because there is no cap left to
/// truncate it against and no input left for a model to choose.
///
/// The encoding is length-prefixed per field, so no field's content can
/// be shifted into its neighbour: two different coordinates cannot hash
/// the same string, whatever separators they happen to contain.
///
/// ## Examples
///
/// ```gleam
/// // string.length(agent.call_site_digest(caller)) == 16
/// ```
///
pub fn call_site_digest(caller: Caller) -> String {
  [
    ids.op_id_to_string(caller.operation),
    minting_step(caller),
    int.to_string(caller.source_index),
  ]
  |> list.map(fn(field) {
    int.to_string(string.byte_size(field)) <> ":" <> field
  })
  |> string.concat
  |> coordinate_hash
  |> int.to_base16
  |> string.lowercase
  |> string.pad_start(to: 16, with: "0")
}

// FNV-1a 64 over the coordinate's UTF-8 bytes.
//
// Written out here rather than borrowed from `tools/hashline` because the
// two digests answer to different masters: hashline's is a
// same-round-trip token, explicitly versioned and free to change with a
// release, while this one is baked into durable strand names and register
// keys and must derive identically forever.
//
// It is not a security primitive and does not need to be. No input to it
// is model-supplied; the one field a program influences at all is its own
// ordinal, which the seam's spawn ceiling bounds to a few dozen reachable
// values; and a collision is caught rather than trusted, because
// `client/agency` refuses to adopt a child whose recorded call site is
// not the caller's own.
fn coordinate_hash(text: String) -> Int {
  hash_loop(<<text:utf8>>, fnv_offset_basis)
}

fn hash_loop(bytes: BitArray, accumulator: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> ->
      hash_loop(
        rest,
        int.bitwise_and(
          int.bitwise_exclusive_or(accumulator, byte) * fnv_prime,
          mask_64,
        ),
      )

    // UTF-8 encoding is always byte-aligned, so the only other shape is
    // the empty array.
    _ -> accumulator
  }
}

const fnv_offset_basis = 14_695_981_039_346_656_037

const fnv_prime = 1_099_511_628_211

const mask_64 = 18_446_744_073_709_551_615

/// A refusal rendered as the in-band error result the model reads.
///
/// ## Examples
///
/// ```gleam
/// assert agent.refusal_outcome(agent.AgencyUnavailable).is_error
/// ```
///
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(describe(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String("agency_refused")),
      #("reason", json.String(describe(refusal))),
    ]),
  )
}

// The agent tools touch no filesystem and spawn no process, so they ask
// the broker for nothing at all and compose with any session base.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
