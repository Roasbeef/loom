//// `cap/strand` — the orchestration seam: starting, joining, and
//// addressing other agents from inside a code-mode program.
////
//// This is the second of the prelude's two seams. A *workspace* program
//// holds `cap/{fs, proc, net, git, lsp, report, task, actor, kv}` and
//// orchestrates effects; an *orchestration* program holds this module and
//// `cap/report` and nothing else, and orchestrates agents. Which
//// capabilities travel together is the whole of the separation: an
//// orchestrator that could also write files would be a materially worse
//// thing to hand a model than one that cannot, so vetting judges a
//// submission against one allowlist or the other and refuses a program
//// that reaches into both (`codemode/vet/policy`).
////
//// # Why this exists at all
////
//// Every fan-out a model performs today is N `agent_spawn` calls plus an
//// `agent_wait`: each a tool call, each a turn, each occupying context,
//// and the plan exists only as a sequence of decisions rather than as an
//// artifact anyone can read, diff, or re-run. A program moves the loop
//// out of the conversation. The join stays exactly where it was — a list
//// of handles against one shared deadline — because that is already the
//// right shape.
////
//// Rule Zero (`docs/loom-design.md` §1.3) is what makes it a capability
//// rather than an interpreter: model-influenced execution never runs in
//// the harness VM, so an orchestration *script* has to run outside it,
//// which means it needs a channel back to the broker — and that channel
//// is this module. Rule Zero forbids running the orchestrator in the
//// harness; it does not forbid model-influenced code from *causing* a
//// harness commit, which every tool call already does.
////
//// # What is reused rather than invented
////
//// Every function here is an RPC stub whose call is serviced by the same
//// `client/agency` closures the `agent_*` tools call, judged against the
//// same `Caller` — the strand the program's own `code_mode` call was
//// dispatched on, which the harness supplies and no program can state.
//// So the authorization model is the tools': a strand may wait only on a
//// descendant and address only its parent or a descendant, the depth and
//// fan-out caps are counted from the durable lineage ledger, and every
//// refusal below carries one of the names those rules already refuse
//// under.
////
//// # The one rule that is new
////
//// `agent_spawn` is throttled by turn cost — the model pays a provider
//// round trip per spawn, so the economics bound the fan-out. **A loop
//// pays nothing.** Replacing the turn with a loop removes an implicit
//// throttle, so the seam adds an explicit one: a hard ceiling on
//// admissions per execution, refused in band *at* the ceiling. It is a
//// lifetime bound on admissions, not a live-children bound;
//// `FanOutCapReached` is still what answers a program that asks for more
//// children at once than its strand may have.
////
//// The same argument covers every call that mints something outliving
//// the execution, so four of the six are capped and two are not:
////
//// | call | ceiling | why |
//// |---|---|---|
//// | `spawn` | 32 | a child strand, durable |
//// | `send` | 128 | a durable commit, and to an idle child it starts a run |
//// | `note` | 256 | a durable write-once register under a chosen key |
//// | `notes` | 64 | a full prefix scan of the session's agent namespaces |
//// | `wait` | none | its cost is time, which the clamp and the deadline bind |
//// | `roster` | none | bounded by `session_strands`, a structural constant |
////
//// A spawn refused at its ceiling is `SpawnCeilingReached`; the other
//// three are `AdmissionCeilingReached`, whose message names the
//// capability and the number. **`note` and `notes` are one decision.**
//// A note/notes loop is quadratic in harness work, and the quadratic
//// needs both factors unbounded — capping either alone leaves it. Relax
//// one and you have relaxed both.
////
//// # What a satellite's death does and does not mean
////
//// The satellite is torn down when `main` returns, so a spawn this
//// program never joins is a spawn whose result cannot reach *this
//// program*. It is not lost: the child's terminal transaction writes its
//// result durably, and the parent strand collects it on a later turn
//// through the ordinary `agent_wait`. By the same token a message a child
//// sends after the program has returned reaches the *strand*, not the
//// program: under the two-channel doctrine a payload travels in a commit
//// and only the wake signal is ephemeral, so it is drained at the
//// parent's next checkpoint rather than dropped.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// How much longer than the requested join window this module will wait
/// on the channel before calling the harness unreachable.
///
/// The harness clamps a join to its own ceiling and answers `Pending`
/// rather than hanging, so this margin covers the round trip and the
/// clamp, never the wait itself.
pub const wait_margin_ms = 10_000

// --- what a call answers with --------------------------------------------

/// A durable reference to one child operation, as `spawn` minted it. It
/// names nothing process-local, so it survives a restart.
pub type Handle {
  Handle(strand: String, operation: String)
}

/// Where a child's context starts.
pub type Provenance {
  /// At the root: the child reads its brief and nothing else.
  Fresh
  /// At the calling strand's current leaf, copying its whole conversation
  /// into the child's context window.
  MyConversation
}

/// The closed set of types a declared result field may have — the same
/// vocabulary the harness enforces, and no wider. A schema the harness
/// cannot check is refused rather than accepted and ignored, so there is
/// deliberately no way to spell a pattern, an enum, or a bound.
pub type FieldType {
  /// Text.
  StringField
  /// A whole number.
  IntegerField
  /// Any number, whole or not.
  NumberField
  /// A boolean.
  BooleanField
  /// An object, its own fields undescribed.
  ObjectField
  /// A list of `items`.
  ArrayField(items: FieldType)
  /// Anything at all, `null` included.
  AnyField
}

/// One field of the result shape a spawn demands of its child.
pub type Field {
  Field(name: String, expects: FieldType, required: Bool)
}

/// A field the child must report.
///
/// ## Examples
///
/// ```gleam
/// assert strand.required("count", strand.IntegerField).required
/// ```
///
pub fn required(name: String, expects: FieldType) -> Field {
  Field(name:, expects:, required: True)
}

/// A field the child may report.
///
/// ## Examples
///
/// ```gleam
/// assert !strand.optional("note", strand.StringField).required
/// ```
///
pub fn optional(name: String, expects: FieldType) -> Field {
  Field(name:, expects:, required: False)
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

/// The verdict on the structured result a spawn asked for.
///
/// Four facts, three of which are not failures, so a program branches on
/// what it actually got rather than on a `Result` that flattens "nobody
/// asked" into "nobody answered".
pub type TerminalResult {
  /// The spawn declared no result shape.
  NoResultAsked
  /// The child recorded a result and it matched the declared shape.
  ResultGiven(value: Value)
  /// A shape was asked for and the child's run ended without recording
  /// one.
  ResultAbsent(schema: String)
  /// A result is there and does not match. `reason` names the field, the
  /// type wanted and the type found.
  ResultUnusable(schema: String, received: Value, reason: String)
}

/// One handle's position when a join returned.
pub type Waited {
  /// The operation settled. `report` is the child's final assistant text,
  /// `result` the verdict on the shape the spawn demanded, and `notes`
  /// its blackboard cells.
  Ready(
    handle: Handle,
    outcome: Outcome,
    report: String,
    result: TerminalResult,
    notes: List(#(String, Value)),
  )
  /// The deadline expired first. An answer, not a failure: join again, or
  /// do other work and come back.
  Pending(handle: Handle, waited_ms: Int)
}

/// How a `send` payload landed.
pub type Delivery {
  /// The target had an open run: the message is a durable steer on it.
  Steered(entry: String)
  /// The target was idle: the message was accepted as a fresh run.
  Started(operation: String)
}

/// How a peer stands in relation to the calling strand.
pub type Relation {
  /// The strand that spawned the caller.
  ParentOf
  /// A strand the caller spawned.
  ChildOf
}

/// One entry in the roster: a durable read of the lineage ledger, not of
/// process state, so it is still correct after a restart and after
/// compaction has erased every handle from a model's context.
pub type Peer {
  Peer(
    strand: String,
    relation: Relation,
    handle: Option(Handle),
    outcome: Option(Outcome),
    tools: List(String),
  )
}

/// Why a call was refused.
///
/// Every variant but the last two is one of the harness's own refusal
/// names, carrying the harness's own sentence verbatim: the authorization
/// model this seam runs under is `client/agency`'s, reused rather than
/// re-derived, and a refusal renamed on the way out would be a second
/// vocabulary for one decision. `message` is not decoration — it names
/// the strand, the cap, or the field that the name alone does not.
pub type StrandError {
  /// This host wired no messaging plane, or its holder is not up yet.
  StrandsUnavailable(message: String)
  /// A handle did not parse.
  MalformedHandle(message: String)
  /// The named strand is not the caller's parent and not a descendant of
  /// it. Also the answer for a strand with no lineage cell at all: "no
  /// lineage fact" means "not a descendant", never "unknown, allow".
  NotAddressable(message: String)
  /// A join named a strand that is not a descendant of the caller. Joins
  /// are strictly downward — that is what keeps the wait graph acyclic.
  NotADescendant(message: String)
  /// The calling strand is already at the spawning depth cap.
  DepthCapReached(message: String)
  /// The caller, or the session, already has as many live strands as it
  /// may have.
  FanOutCapReached(message: String)
  /// The spawn asked for a tool the calling strand does not itself hold.
  /// A child may narrow its parent's set, never widen it.
  UnknownTool(message: String)
  /// An argument was unusable — an empty purpose, too many handles, a
  /// blackboard key outside the allowed shape, a result shape the
  /// harness cannot enforce.
  InvalidArgument(message: String)
  /// A send upward would have *started* a run rather than steered one:
  /// the parent has finished and nobody is watching it.
  ParentRunEnded(message: String)
  /// A note did not match the result shape this strand's own spawn
  /// demanded of it.
  ResultSchemaUnmet(message: String)
  /// This execution has admitted as many spawns as it may. The seam's own
  /// ceiling; see the module doc for why a loop needs one where a turn
  /// did not.
  SpawnCeilingReached(message: String)
  /// This execution has admitted as many calls of some *other* capped
  /// capability — `send`, `note` or `notes` — as it may. One variant for
  /// the three because the answer to all three is the same, stop looping,
  /// and the message names which capability, what the number was, and
  /// that the bound is for the execution's whole lifetime. Retrying, or
  /// waiting first, will not free one.
  AdmissionCeilingReached(message: String)
  /// Any other in-band refusal, its code preserved.
  StrandRefused(code: String, message: String)
  /// The capability channel could not carry the call.
  StrandUnavailable(reason: String)
}

// --- spawning --------------------------------------------------------------

/// One assignment, built up before it is spawned.
///
/// Opaque, so a non-empty purpose and brief hold by construction and the
/// wire shape stays this module's to change. Build it with `assignment`
/// and narrow it with the pipeable steps below.
pub opaque type Assignment {
  Assignment(
    purpose: String,
    brief: String,
    within_ms: Option(Int),
    detach: Bool,
    context: Provenance,
    tools: Option(List(String)),
    result_schema: List(Field),
  )
}

/// An assignment: what the child is for, and what it is being told.
///
/// `purpose` is what the child's minted name is derived from, so two
/// spawns in one program that share a purpose are two spawns the harness
/// cannot tell apart — give each one its own.
///
/// ## Examples
///
/// ```gleam
/// // strand.assignment(purpose: "review core", brief: "look for …")
/// ```
///
pub fn assignment(purpose purpose: String, brief brief: String) -> Assignment {
  Assignment(
    purpose:,
    brief:,
    within_ms: None,
    detach: False,
    context: Fresh,
    tools: None,
    result_schema: [],
  )
}

/// Gives the child a wall budget of its own, in milliseconds.
pub fn within(assignment: Assignment, milliseconds: Int) -> Assignment {
  Assignment(..assignment, within_ms: Some(milliseconds))
}

/// Detaches the child, so the calling strand's run end does not reap it.
pub fn detached(assignment: Assignment) -> Assignment {
  Assignment(..assignment, detach: True)
}

/// Starts the child at the calling strand's own leaf, copying its whole
/// conversation, rather than at the root with only its brief.
pub fn from_my_conversation(assignment: Assignment) -> Assignment {
  Assignment(..assignment, context: MyConversation)
}

/// Narrows the child's tool set. It may only ever narrow the calling
/// strand's own set; naming a tool the caller does not hold is
/// `UnknownTool`.
pub fn with_tools(assignment: Assignment, names: List(String)) -> Assignment {
  Assignment(..assignment, tools: Some(names))
}

/// Demands a result shape of the child, which the harness holds it to on
/// its own terminal write — so a program that joins can branch on typed
/// fields instead of parsing prose.
///
/// ## Examples
///
/// ```gleam
/// // strand.assignment(purpose: p, brief: b)
/// // |> strand.expecting([strand.required("count", strand.IntegerField)])
/// ```
///
pub fn expecting(assignment: Assignment, fields: List(Field)) -> Assignment {
  Assignment(..assignment, result_schema: fields)
}

/// Starts a child strand and returns a durable handle to its brief run.
///
/// Returns as soon as the harness has admitted the child; the work
/// happens on the child's own strand, and `wait` is how a program learns
/// what it produced.
///
/// Capability: `strand.spawn`.
pub fn spawn(assignment: Assignment) -> Result(Handle, StrandError) {
  let args =
    wire.args([
      #("purpose", wire.string(assignment.purpose)),
      #("brief", wire.string(assignment.brief)),
      #("within_ms", optional_int(assignment.within_ms)),
      #("detach", wire.bool(assignment.detach)),
      #("context", wire.string(provenance_name(assignment.context))),
      #("tools", optional_strings(assignment.tools)),
      #("result_schema", encode_schema(assignment.result_schema)),
    ])
  use value <- result.try(
    dispatch.call("strand.spawn", args) |> result.map_error(map_error),
  )
  decode_handle(value) |> result.map_error(malformed("strand.spawn"))
}

// --- joining ---------------------------------------------------------------

/// Waits for every handle against **one** shared deadline and answers one
/// `Waited` per handle, in the order given.
///
/// One deadline rather than one per handle is the whole point: joining
/// eight children costs one window, not eight. A handle whose operation
/// has not settled by then comes back `Pending`, which is an answer — the
/// program may join again, or go on and let the parent strand collect the
/// result on a later turn.
///
/// Capability: `strand.wait`.
pub fn wait(
  handles: List(Handle),
  within_ms within_ms: Int,
) -> Result(List(Waited), StrandError) {
  let args =
    wire.args([
      #("handles", encode_handles(handles)),
      #("within_ms", wire.int(within_ms)),
    ])
  use value <- result.try(
    dispatch.call_within("strand.wait", args, within_ms + wait_margin_ms)
    |> result.map_error(map_error),
  )
  wire.array_of(value, "waited", of: decode_waited)
  |> result.map_error(malformed("strand.wait"))
}

// --- addressing ------------------------------------------------------------

/// Delivers one attributed message to the calling strand's parent or to
/// one of its descendants.
///
/// The payload travels in a commit and only the wake signal is
/// ephemeral, so a message to a strand that is not running now is drained
/// at its next checkpoint rather than lost.
///
/// Capability: `strand.send`.
pub fn send(to to: String, text text: String) -> Result(Delivery, StrandError) {
  let args = wire.args([#("to", wire.string(to)), #("text", wire.string(text))])
  use value <- result.try(
    dispatch.call("strand.send", args) |> result.map_error(map_error),
  )
  decode_delivery(value) |> result.map_error(malformed("strand.send"))
}

/// Writes one blackboard cell under the calling strand's own namespace.
/// The key is forced under that namespace by the harness, so a program
/// cannot address another strand's notes or a reserved cell.
///
/// Capability: `strand.note`.
pub fn note(key key: String, value value: Value) -> Result(Nil, StrandError) {
  let args = wire.args([#("key", wire.string(key)), #("value", value)])
  dispatch.call("strand.note", args)
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

/// Reads blackboard cells under a key prefix, relative to the shared
/// blackboard namespace. `None` reads the whole blackboard.
///
/// Capability: `strand.notes`.
pub fn notes(
  prefix: Option(String),
) -> Result(List(#(String, Value)), StrandError) {
  let args = wire.args([#("prefix", optional_string(prefix))])
  use value <- result.try(
    dispatch.call("strand.notes", args) |> result.map_error(map_error),
  )
  wire.array_of(value, "notes", of: decode_note)
  |> result.map_error(malformed("strand.notes"))
}

/// The calling strand's parent and its live descendants, read from the
/// durable lineage ledger.
///
/// Capability: `strand.roster`.
pub fn roster() -> Result(List(Peer), StrandError) {
  use value <- result.try(
    dispatch.call("strand.roster", wire.args([]))
    |> result.map_error(map_error),
  )
  wire.array_of(value, "peers", of: decode_peer)
  |> result.map_error(malformed("strand.roster"))
}

// --- encoding --------------------------------------------------------------

fn provenance_name(context: Provenance) -> String {
  case context {
    Fresh -> "fresh"
    MyConversation -> "my_conversation"
  }
}

fn optional_int(value: Option(Int)) -> Value {
  case value {
    None -> report.null()
    Some(number) -> wire.int(number)
  }
}

fn optional_string(value: Option(String)) -> Value {
  case value {
    None -> report.null()
    Some(text) -> wire.string(text)
  }
}

fn optional_strings(value: Option(List(String))) -> Value {
  case value {
    None -> report.null()
    Some(names) -> wire.string_array(names)
  }
}

// The declared shape crosses as a list of field descriptors, not as a
// schema document. The harness builds the schema itself from these and
// runs it through its own total parser, so a program cannot smuggle a
// constraint the harness would render into a child's brief without ever
// checking (`tools/agent.parse_result_schema`).
fn encode_schema(fields: List(Field)) -> Value {
  // Nothing asked for is *nothing*, not an empty list: a program that
  // declared no shape and one that declared an empty one would otherwise
  // be the same frame, and the harness's `NoResultAsked` verdict exists
  // to keep them apart.
  use <- unless_empty(fields)
  report.list(
    list.map(fields, fn(field) {
      wire.args([
        #("name", wire.string(field.name)),
        #("type", wire.string(field_type_name(field.expects))),
        #("items", encode_items(field.expects)),
        #("required", wire.bool(field.required)),
      ])
    }),
  )
}

// `use <- unless_empty(fields)` — answers `null` for an empty list and
// otherwise runs the continuation. A tiny combinator rather than a
// `case`, so the encoder below reads as one expression.
fn unless_empty(fields: List(Field), then: fn() -> Value) -> Value {
  case fields {
    [] -> report.null()
    [_, ..] -> then()
  }
}

fn field_type_name(expects: FieldType) -> String {
  case expects {
    StringField -> "string"
    IntegerField -> "integer"
    NumberField -> "number"
    BooleanField -> "boolean"
    ObjectField -> "object"
    ArrayField(items: _) -> "array"
    AnyField -> "any"
  }
}

// An array's element type nests, so it is carried as a nested descriptor
// rather than flattened into the type name.
fn encode_items(expects: FieldType) -> Value {
  case expects {
    ArrayField(items:) ->
      wire.args([
        #("type", wire.string(field_type_name(items))),
        #("items", encode_items(items)),
      ])
    StringField
    | IntegerField
    | NumberField
    | BooleanField
    | ObjectField
    | AnyField -> report.null()
  }
}

fn encode_handles(handles: List(Handle)) -> Value {
  report.list(
    list.map(handles, fn(handle) {
      wire.args([
        #("strand", wire.string(handle.strand)),
        #("operation", wire.string(handle.operation)),
      ])
    }),
  )
}

// --- decoding --------------------------------------------------------------
//
// Every decoder here is total over the wire's value type: a field of the
// wrong shape is a `String` fault this module turns into
// `StrandUnavailable`, never a crash. The harness is trusted to be
// well-behaved; the decoders exist because a malformed answer must still
// settle in band (design §9).

fn malformed(cap: String) -> fn(String) -> StrandError {
  fn(reason) { StrandUnavailable("bad " <> cap <> " result: " <> reason) }
}

fn decode_handle(value: Value) -> Result(Handle, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use operation <- result.try(wire.string_field(value, "operation"))
  Ok(Handle(strand:, operation:))
}

fn decode_waited(value: Value) -> Result(Waited, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  use handle <- result.try(decode_handle(value))
  case kind {
    "pending" -> {
      use waited_ms <- result.try(wire.int_field(value, "waited_ms"))
      Ok(Pending(handle:, waited_ms:))
    }
    "ready" -> {
      use outcome <- result.try(decode_outcome_field(value, "outcome"))
      use report <- result.try(wire.string_field(value, "report"))
      use result <- result.try(decode_terminal_result(value))
      use notes <- result.try(wire.array_of(value, "notes", of: decode_note))
      Ok(Ready(handle:, outcome:, report:, result:, notes:))
    }
    other -> Error("unknown waited kind " <> other)
  }
}

fn decode_outcome_field(value: Value, key: String) -> Result(Outcome, String) {
  use found <- result.try(wire.field(value, key))
  decode_outcome(found)
}

fn decode_outcome(value: Value) -> Result(Outcome, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  case kind {
    "completed" -> Ok(Completed)
    "aborted" -> Ok(Aborted)
    "failed" -> {
      use reason <- result.try(wire.string_field(value, "reason"))
      Ok(Failed(reason:))
    }
    other -> Error("unknown outcome kind " <> other)
  }
}

fn decode_terminal_result(value: Value) -> Result(TerminalResult, String) {
  use found <- result.try(wire.field(value, "result"))
  use kind <- result.try(wire.string_field(found, "kind"))
  case kind {
    "none" -> Ok(NoResultAsked)
    "given" -> {
      use given <- result.try(wire.field(found, "value"))
      Ok(ResultGiven(value: given))
    }
    "absent" -> {
      use schema <- result.try(wire.string_field(found, "schema"))
      Ok(ResultAbsent(schema:))
    }
    "unusable" -> {
      use schema <- result.try(wire.string_field(found, "schema"))
      use received <- result.try(wire.field(found, "received"))
      use reason <- result.try(wire.string_field(found, "reason"))
      Ok(ResultUnusable(schema:, received:, reason:))
    }
    other -> Error("unknown result kind " <> other)
  }
}

fn decode_note(value: Value) -> Result(#(String, Value), String) {
  use key <- result.try(wire.string_field(value, "key"))
  use held <- result.try(wire.field(value, "value"))
  Ok(#(key, held))
}

fn decode_delivery(value: Value) -> Result(Delivery, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  case kind {
    "steered" -> {
      use entry <- result.try(wire.string_field(value, "entry"))
      Ok(Steered(entry:))
    }
    "started" -> {
      use operation <- result.try(wire.string_field(value, "operation"))
      Ok(Started(operation:))
    }
    other -> Error("unknown delivery kind " <> other)
  }
}

fn decode_peer(value: Value) -> Result(Peer, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use relation <- result.try(decode_relation(value))
  use handle <- result.try(case wire.optional_field(value, "handle") {
    None -> Ok(None)
    Some(found) -> decode_handle(found) |> result.map(Some)
  })
  use outcome <- result.try(case wire.optional_field(value, "outcome") {
    None -> Ok(None)
    Some(found) -> decode_outcome(found) |> result.map(Some)
  })
  use tools <- result.try(decode_tools(value))
  Ok(Peer(strand:, relation:, handle:, outcome:, tools:))
}

fn decode_relation(value: Value) -> Result(Relation, String) {
  use relation <- result.try(wire.string_field(value, "relation"))
  case relation {
    "parent" -> Ok(ParentOf)
    "child" -> Ok(ChildOf)
    other -> Error("unknown relation " <> other)
  }
}

fn decode_tools(value: Value) -> Result(List(String), String) {
  wire.array_of(value, "tools", of: fn(item) {
    report.as_string(item) |> result.replace_error("a tool name is not text")
  })
}

// --- refusals --------------------------------------------------------------

// The harness's own refusal name, recovered from the broker's in-band
// code. An unrecognized code is not swallowed: it comes back as
// `StrandRefused` carrying the code verbatim, so a name this module has
// not learned yet still reaches the program as itself.
fn map_error(error: CallError) -> StrandError {
  case error {
    Unreachable(reason:) -> StrandUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "strands_unavailable" -> StrandsUnavailable(message:)
        "malformed_handle" -> MalformedHandle(message:)
        "not_addressable" -> NotAddressable(message:)
        "not_a_descendant" -> NotADescendant(message:)
        "depth_cap" -> DepthCapReached(message:)
        "fan_out_cap" -> FanOutCapReached(message:)
        "unknown_tool" -> UnknownTool(message:)
        "invalid_argument" -> InvalidArgument(message:)
        "parent_run_ended" -> ParentRunEnded(message:)
        "result_schema_unmet" -> ResultSchemaUnmet(message:)
        "spawn_ceiling" -> SpawnCeilingReached(message:)
        "admission_ceiling" -> AdmissionCeilingReached(message:)
        _ -> StrandRefused(code:, message:)
      }
  }
}

/// A one-line rendering of a refusal, for a program building a report out
/// of what went wrong rather than branching on it.
///
/// ## Examples
///
/// ```gleam
/// assert strand.error_text(strand.NotADescendant("x")) == "not_a_descendant: x"
/// ```
///
pub fn error_text(error: StrandError) -> String {
  case error {
    StrandsUnavailable(message:) -> "strands_unavailable: " <> message
    MalformedHandle(message:) -> "malformed_handle: " <> message
    NotAddressable(message:) -> "not_addressable: " <> message
    NotADescendant(message:) -> "not_a_descendant: " <> message
    DepthCapReached(message:) -> "depth_cap: " <> message
    FanOutCapReached(message:) -> "fan_out_cap: " <> message
    UnknownTool(message:) -> "unknown_tool: " <> message
    InvalidArgument(message:) -> "invalid_argument: " <> message
    ParentRunEnded(message:) -> "parent_run_ended: " <> message
    ResultSchemaUnmet(message:) -> "result_schema_unmet: " <> message
    SpawnCeilingReached(message:) -> "spawn_ceiling: " <> message
    AdmissionCeilingReached(message:) -> "admission_ceiling: " <> message
    StrandRefused(code:, message:) -> code <> ": " <> message
    StrandUnavailable(reason:) -> "unavailable: " <> reason
  }
}

/// A handle rendered as the text the harness and the model both use,
/// `{strand}#{operation}`.
///
/// ## Examples
///
/// ```gleam
/// assert strand.handle_text(strand.Handle("sub:a", "op_1")) == "sub:a#op_1"
/// ```
///
pub fn handle_text(handle: Handle) -> String {
  handle.strand <> "#" <> handle.operation
}

/// How long a join actually waited, summed over the handles still
/// pending — a program pacing itself against its own deadline needs the
/// number and would otherwise fold it out of `Waited` by hand.
///
/// ## Examples
///
/// ```gleam
/// assert strand.pending_count([]) == 0
/// ```
///
pub fn pending_count(waited: List(Waited)) -> Int {
  list.fold(waited, 0, fn(count, one) {
    case one {
      Pending(..) -> count + 1
      Ready(..) -> count
    }
  })
}

/// A one-line rendering of one joined handle, for the same reason
/// `error_text` exists: a program that reduces a fan-out to a report
/// should not have to spell the vocabulary out itself.
///
/// ## Examples
///
/// ```gleam
/// // strand.waited_text(ready) == "sub:a#op_1 completed"
/// ```
///
pub fn waited_text(one: Waited) -> String {
  case one {
    Pending(handle:, waited_ms:) ->
      handle_text(handle)
      <> " pending after "
      <> int.to_string(waited_ms)
      <> "ms"
    Ready(handle:, outcome:, ..) ->
      handle_text(handle) <> " " <> outcome_text(outcome)
  }
}

fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Completed -> "completed"
    Failed(reason:) -> "failed: " <> reason
    Aborted -> "aborted"
  }
}
