//// The tool behaviour: what every Loom tool is, and the seams it runs
//// through (implementation spec WP-I).
////
//// A `Tool` is a record — name, description, JSON schema, replay
//// safety, execution mode, policy-shaped sandbox requirements, and a
//// `run` function taking a `Ctx` and the model-supplied arguments. Tool
//// failures are **data**: `run` always returns a `ToolOutcome`, whose
//// `is_error` marks in-band failure exactly like pi's
//// `ToolResultMessage.isError` (pi harness §3.8). Tools never crash the
//// strand; anything that can go wrong — bad arguments, a policy
//// refusal, a dead helper, a stale anchor — comes back as a structured
//// error result the model can read and react to.
////
//// `Ctx` carries every effect seam a tool may touch: the workspace
//// root, the injected clock, a `FileSystem` record of functions, the
//// blob-overflow directory, and the broker seam (`clear_call`) through
//// which every jailed execution flows. Production wires the seams to
//// simplifile and a live `broker.Broker` (`broker_runner`); tests wire
//// fakes and the tools cannot tell the difference.
////
//// The registry is a name → `Tool` lookup; dispatching an unknown name
//// yields the ordinary in-band unavailable-tool error result (pi §3.8:
//// an `is_error` text result, `details` omitted — the harness must not
//// invent a value for a tool's typed details contract).

import broker/broker.{type CallEvent, type CallOutcome, type Refusal}
import broker/budget
import broker/escalation
import broker/exec
import broker/framing
import broker/policy.{type Grant, type SandboxPolicy}
import core/clock.{type Clock}
import core/corruption
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/message
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Whether a tool execution that crashed mid-flight may be re-executed
/// on recovery (pi §3.8: the `replay` field committed with
/// `effect_pending`).
pub type ReplaySafety {
  /// Re-execution could repeat an external effect; recovery must
  /// synthesize an interrupted result instead (the pi §0.5 scenario).
  Never

  /// Re-execution with the persisted arguments is harmless: the tool is
  /// a read, or its writes are idempotent and guarded (fs_edit's plan
  /// is digest-bound to the exact pre-image content, so a replay after
  /// the write landed is rejected in-band — see `tools/fs`).
  Safe
}

/// How the strand driver may schedule this tool call relative to other
/// calls in the same batch.
///
/// The implementation spec names `execution_mode` in the tool behaviour
/// contract without defining its values; this two-point interpretation
/// mirrors pi's sequential/parallel batch modes at per-tool granularity
/// and is recorded as a spec gap.
pub type ExecutionMode {
  /// Must run alone: the tool mutates shared state (bash, fs_write,
  /// fs_edit).
  Exclusive

  /// May run alongside other `Concurrent` calls: the tool only reads
  /// (fs_read, grep).
  Concurrent
}

/// Why a `FileSystem` operation failed. A small closed vocabulary so
/// tools can phrase precise in-band errors; everything else carries the
/// backend's description.
pub type FsError {
  /// The path does not exist.
  FsNotFound(path: String)

  /// The operating system denied access.
  FsPermissionDenied(path: String)

  /// Any other failure, with the backend's description.
  FsFailure(path: String, reason: String)
}

/// What symlink inspection (lstat semantics — the path itself is never
/// followed) found at a path. This is the primitive workspace
/// containment is built on: `fs.resolve_real` walks a path component
/// by component, following each `LinkTarget` itself, so the final
/// path handed to `read`/`write` contains no symlinks to escape
/// through.
pub type LinkStatus {
  /// The path is a symlink; `target` is its stored target, verbatim —
  /// possibly relative to the symlink's own directory.
  LinkTarget(target: String)

  /// The path exists and is not a symlink.
  NotALink

  /// Nothing exists at the path (including an ancestor that is not a
  /// directory).
  LinkMissing
}

/// The file-system seam: a record of functions over absolute paths.
/// Production uses `fs.real_filesystem` (simplifile plus a confined
/// `file:read_link_all` shim); tests substitute an in-memory fake.
/// Tools must resolve paths under the workspace root against the real
/// filesystem (`fs.resolve_real`) before calling these.
pub type FileSystem {
  FileSystem(
    /// Reads a whole file as bytes.
    read: fn(String) -> Result(BitArray, FsError),
    /// Writes a whole file, creating or replacing it.
    write: fn(String, BitArray) -> Result(Nil, FsError),
    /// Creates a directory and any missing parents; succeeds if it
    /// already exists.
    create_directory_all: fn(String) -> Result(Nil, FsError),
    /// Whether the path names an existing regular file.
    is_file: fn(String) -> Result(Bool, FsError),
    /// The path's own link status, without following it (lstat
    /// semantics).
    read_link: fn(String) -> Result(LinkStatus, FsError),
    /// Renames a path over another, replacing any existing destination.
    ///
    /// The seam exists for exactly one job: a content-addressed blob is
    /// written under a temporary name in its own directory and then
    /// renamed into place, so a crash mid-write can never leave a
    /// half-written file at an address that vouches for its whole
    /// content. That property needs the rename to be **atomic**, which
    /// `rename(2)` is within one filesystem and is not across two — so
    /// an implementation must not fall back to copy-then-delete, and a
    /// caller must keep the temporary in the destination's own
    /// directory.
    rename: fn(String, String) -> Result(Nil, FsError),
  )
}

/// A policy refusal a tool discovered *inside itself*, offered to the
/// host for a human decision.
///
/// Almost every tool meets a policy refusal by getting one back from
/// `Ctx.clear_call`, and the host raises it there without the tool ever
/// knowing. `code_mode` is the exception the whole seam exists for: its
/// clearances happen inside the code-mode pipeline, against the broker
/// the pipeline holds, so a refused execution comes back to the tool as
/// an in-band result and reaches no escalation plane at all (#97). This
/// is the door back.
///
/// Constructor invariants: `denial` is the broker's own structured
/// refusal — its `wanted` is the exact diff an approval may grant, so it
/// must be derived from `policy.compose`'s narrowings and never written
/// by hand, or a human would be approving a diff that satisfies nothing;
/// `deadline_ms` is the refused work's own budget deadline, the instant
/// past which holding this call open buys nothing.
pub type RaisedRefusal {
  RaisedRefusal(denial: escalation.Denial, deadline_ms: Int)
}

/// What the host's escalation plane decided about a raised refusal.
///
/// The mirror of `client/escalate.Decision`, which `tools` cannot see —
/// the same arrangement `codemode`'s `Outcome` and `Seam` types already
/// use across that package boundary.
pub type Escalated {
  /// Nothing to spend: settle the refusal in band, exactly as a tool
  /// with no escalation plane behind it always has. Whether a durable
  /// record was written, and whether anyone was asked, is the host's
  /// business and deliberately not visible here.
  Settle

  /// A human approved exactly these grants, for exactly this call. Retry
  /// the refused work **once** under them; if it is refused again that
  /// second refusal stands (design §5.3: one re-execution under the
  /// widened policy, never a loop).
  Resume(grants: List(Grant))
}

/// A raise seam that escalates nothing: every refusal a tool discovers
/// settles in band, exactly as it did before any of this existed. The
/// default for a host with no escalation plane, and for tests that are
/// about something else.
///
/// ## Examples
///
/// ```gleam
/// assert tool.no_raise()(raised) == tool.Settle
/// ```
///
pub fn no_raise() -> fn(RaisedRefusal) -> Escalated {
  fn(_raised) { Settle }
}

/// A cleared, running broker call, as tools see it. Wraps the broker's
/// opaque `CallHandle` in closures so fakes can stand in for the real
/// broker without minting handles.
pub type RunningCall {
  RunningCall(
    /// Streams stdin to the jailed child; `True` closes stdin after the
    /// chunk.
    stdin: fn(BitArray, Bool) -> Nil,
    /// Cancels the call; the broker still delivers exactly one
    /// `CallSettled`.
    cancel: fn() -> Nil,
  )
}

/// Everything a tool's `run` may touch. Constructed per call by the
/// strand driver (WP-E).
///
/// Constructor invariants: `workspace` and `blob_root` are absolute
/// paths; `env` is the allowlist-constructed child environment for
/// jailed executions (never an inherited one); `clear_call` honors the
/// broker contract — on `Ok` exactly one `CallSettled` eventually
/// arrives on the events subject; `strand`, `op_id`, `step_id` and
/// `source_index` are the driver's own durable coordinates for this call,
/// never anything the model supplied — the agent tools are judged against
/// `strand` and derive a spawned child's name from the other three, so a
/// value invented here would let a model claim an identity or mint a
/// second child on replay; `raise_refusal` answers about *this* call and
/// no other, so a tool may raise through it at most once per `run` and
/// must not build a retry loop out of a `Resume`.
pub type Ctx {
  Ctx(
    /// Absolute workspace root; every tool path resolves under it.
    workspace: String,
    /// The strand whose driver dispatched this call.
    strand: String,
    /// The operation this tool call belongs to.
    op_id: OpId,
    /// The step id of the producing tool batch.
    step_id: String,
    /// This call's index within its source assistant message.
    source_index: Int,
    /// The session's base sandbox policy.
    base_policy: SandboxPolicy,
    /// Grants from consumed escalation approvals, if any.
    grants: List(Grant),
    /// Enforcement strictness for jailed executions.
    demand: exec.EnforcementDemand,
    /// Allowlist-constructed environment for jailed children.
    env: List(#(String, String)),
    /// The injected time source.
    clock: Clock,
    /// The file-system seam.
    filesystem: FileSystem,
    /// Absolute directory for large-output blob overflow (spec §3.2).
    blob_root: String,
    /// The broker seam: clears and dispatches one jailed execution.
    clear_call: fn(broker.CallSpec, Subject(CallEvent)) ->
      Result(RunningCall, Refusal),
    /// The raise seam: reports a policy refusal the tool met somewhere
    /// other than `clear_call`, and says what the host decided about it.
    /// `no_raise()` for a host with no escalation plane.
    raise_refusal: fn(RaisedRefusal) -> Escalated,
  )
}

/// Whether the run this call belongs to carries on after the reply is
/// committed.
///
/// The durable plane already carries the question — `core/entry`'s
/// `MessageEntry.terminate` and the planner's `CompletedByTerminatedTools`
/// — but until now nothing upstream could answer it, so the wiring
/// hardcoded the negative. This is the answer a tool gives, converted at
/// the `wiring.run_tool` boundary into the `Bool` the frozen effect type
/// takes. It is a two-variant type rather than a `Bool` because the
/// polarity of `terminate: False` is exactly the thing a reader of a call
/// site should not have to hold in their head.
pub type Terminate {
  /// The run proceeds: the model sees the reply and plans its next step.
  ContinueRun

  /// The run reaches a terminal state once this batch settles, if every
  /// call in it did — the planner's rule, not this tool's alone, so one
  /// terminating call beside a continuing one ends nothing. Reserved for
  /// a tool whose whole purpose is to end the operation; every built-in
  /// answers `ContinueRun`.
  TerminateRun
}

/// What a tool call produced: content blocks for the model plus
/// machine-readable details, exactly the shape WP-E commits as a
/// `ToolResultMessage`.
///
/// Constructor invariants: `content` is non-empty; `is_error` marks an
/// in-band failure the model should react to, never a harness fault;
/// `terminate` is `ContinueRun` for every built-in, and the constructors
/// below default it there so that a tool ends a run only by saying so.
pub type ToolOutcome {
  ToolOutcome(
    /// Content blocks, in the core message vocabulary.
    content: List(message.ToolResultBlock),
    /// Machine-readable details under the tool's own details contract.
    details: Option(JsonValue),
    /// Whether this outcome is an in-band failure.
    is_error: Bool,
    /// Whether the run ends once this call's batch settles.
    terminate: Terminate,
  )
}

/// One tool: identity, contract, and behaviour.
///
/// Constructor invariants: `name` is unique within a registry; `schema`
/// is a JSON-schema object describing `run`'s arguments;
/// `requirements`, applied to the workspace root, is the policy-shaped
/// statement of exactly what the tool needs (it is composed with the
/// session base by the broker — ask for exactly what you need, nothing
/// more); `run` is total — it returns error outcomes, it does not
/// crash.
///
/// `prompt_snippet` is a second, much smaller model-facing surface than
/// `description`, and the two are paid for on different schedules. The
/// description travels in the provider's tool array whatever happens; the
/// snippet is one line in the system prompt's available-tools index, so
/// it is read before the model has decided to look at any tool at all. A
/// tool without one is simply absent from that index — pi's rule, adopted
/// whole — and is still perfectly callable, because the authoritative
/// definition is the tool array and never the prose.
pub type Tool {
  Tool(
    /// Unique tool name as the model calls it.
    name: String,
    /// Model-facing description.
    description: String,
    /// One line for the system prompt's available-tools index, or `None`
    /// to be omitted from it.
    prompt_snippet: Option(String),
    /// JSON schema for the arguments, as a core `JsonValue`.
    schema: JsonValue,
    /// Crash-recovery replay safety.
    replay: ReplaySafety,
    /// Batch scheduling constraint.
    execution_mode: ExecutionMode,
    /// Policy-shaped sandbox needs, given the workspace root.
    requirements: fn(String) -> SandboxPolicy,
    /// Executes one call.
    run: fn(Ctx, JsonValue) -> ToolOutcome,
  )
}

/// A name → `Tool` table that also remembers the order it was built in.
pub opaque type Registry {
  /// Invariants: `tools` is keyed by each tool's `name`, and `order`
  /// holds every one of those names exactly once, in the order each
  /// first appeared at registration.
  Registry(tools: Dict(String, Tool), order: List(String))
}

/// Builds a registry from a tool list. A duplicated name keeps the
/// later tool, mirroring "last registration wins", while the position
/// stays where the name first appeared: shadowing replaces a definition,
/// it does not move the tool down the prompt's index.
///
/// ## Examples
///
/// ```gleam
/// let registry = tool.registry([bash.tool(), grep.tool()])
/// assert tool.names(registry) == ["bash", "grep"]
/// ```
///
pub fn registry(tools: List(Tool)) -> Registry {
  let table =
    list.fold(tools, dict.new(), fn(table, tool) {
      dict.insert(table, tool.name, tool)
    })

  // The order is read off the argument rather than off the table, since
  // a `Dict` has no order to read; `list.unique` keeps the first
  // occurrence, which is the position the doc above promises.
  Registry(tools: table, order: list.unique(list.map(tools, fn(t) { t.name })))
}

/// Looks a tool up by name.
///
/// ## Examples
///
/// ```gleam
/// assert tool.lookup(tool.registry([]), "bash") == Error(Nil)
/// ```
///
pub fn lookup(registry: Registry, name: String) -> Result(Tool, Nil) {
  dict.get(registry.tools, name)
}

/// The registered tool names, sorted.
///
/// ## Examples
///
/// ```gleam
/// assert tool.names(tool.registry([])) == []
/// ```
///
pub fn names(registry: Registry) -> List(String) {
  registry.tools
  |> dict.keys
  |> list.sort(string.compare)
}

/// The registered tools in registration order.
///
/// Separate from `names` on purpose, and the two orders are not a
/// redundancy. `names` is sorted because the wire tool array and the
/// durable active list are the provider cache's byte prefix, and sorting
/// is what stops a discovery order from reaching those bytes. The prose
/// index in the system prompt is the other case: an operator reading it
/// should meet the five core tools before whatever a host bolted on, and
/// that is the order the contributions arrived in.
///
/// ## Examples
///
/// ```gleam
/// let registry = tool.registry([grep.tool(), bash.tool()])
/// let named = list.map(tool.registered(registry), fn(t) { t.name })
/// assert named == ["grep", "bash"]
/// ```
///
pub fn registered(registry: Registry) -> List(Tool) {
  list.filter_map(registry.order, fn(name) { lookup(registry, name) })
}

/// The available-tools index for the system prompt: each registered
/// tool's `prompt_snippet`, in registration order, with the tools that
/// carry none left out.
///
/// This is the whole of pi's `promptSnippet` rule. It renders to the
/// empty list rather than to a placeholder sentence, because a host with
/// nothing to say here should cost the prompt no bytes at all.
///
/// ## Examples
///
/// ```gleam
/// assert tool.snippets(tool.registry([])) == []
/// ```
///
pub fn snippets(registry: Registry) -> List(String) {
  list.filter_map(registered(registry), fn(tool) {
    option.to_result(tool.prompt_snippet, Nil)
  })
}

/// Runs one call through the registry. An unknown name settles as the
/// ordinary in-band unavailable-tool result (pi §3.8): `is_error` text,
/// no `details` — the registry must not invent a value for a tool's
/// typed details contract.
///
/// ## Examples
///
/// ```gleam
/// let outcome = tool.dispatch(tool.registry([]), ctx, "nope", json.Null)
/// assert outcome.is_error
/// ```
///
pub fn dispatch(
  registry: Registry,
  ctx: Ctx,
  name: String,
  args: JsonValue,
) -> ToolOutcome {
  case lookup(registry, name) {
    Ok(tool) -> tool.run(ctx, args)
    Error(Nil) ->
      ToolOutcome(
        content: [text_block("the tool `" <> name <> "` is unavailable")],
        details: None,
        is_error: True,
        terminate: ContinueRun,
      )
  }
}

// --- outcome construction -----------------------------------------------

/// A successful text outcome.
///
/// ## Examples
///
/// ```gleam
/// assert tool.success("done").is_error == False
/// ```
///
pub fn success(text: String) -> ToolOutcome {
  ToolOutcome(
    content: [text_block(text)],
    details: None,
    is_error: False,
    terminate: ContinueRun,
  )
}

/// An in-band failure outcome.
///
/// ## Examples
///
/// ```gleam
/// assert tool.failure("file not found").is_error
/// ```
///
pub fn failure(text: String) -> ToolOutcome {
  ToolOutcome(
    content: [text_block(text)],
    details: None,
    is_error: True,
    terminate: ContinueRun,
  )
}

/// Attaches machine-readable details to an outcome.
///
/// ## Examples
///
/// ```gleam
/// let outcome = tool.success("ok") |> tool.with_details(json.Object([]))
/// assert outcome.details == option.Some(json.Object([]))
/// ```
///
pub fn with_details(outcome: ToolOutcome, details: JsonValue) -> ToolOutcome {
  ToolOutcome(..outcome, details: Some(details))
}

/// One text content block in the core message vocabulary.
///
/// ## Examples
///
/// ```gleam
/// assert tool.text_block("hi")
///   == message.ToolResultText(text: "hi", text_signature: option.None)
/// ```
///
pub fn text_block(text: String) -> message.ToolResultBlock {
  message.ToolResultText(text:, text_signature: None)
}

/// Wraps an outcome as the `ToolResultMessage` WP-E commits: same
/// content, details, and error flag; no usage; no added tools.
///
/// ## Examples
///
/// ```gleam
/// let assert message.ToolResultMessage(tool_name: "bash", ..) =
///   tool.to_result_message(
///     tool.success("ok"),
///     tool_call_id: "call_1",
///     tool_name: "bash",
///     timestamp: 0,
///   )
/// ```
///
pub fn to_result_message(
  outcome: ToolOutcome,
  tool_call_id tool_call_id: String,
  tool_name tool_name: String,
  timestamp timestamp: Int,
) -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id:,
    tool_name:,
    content: outcome.content,
    details: outcome.details,
    usage: None,
    added_tool_names: None,
    is_error: outcome.is_error,
    timestamp:,
  )
}

// --- argument decoding ---------------------------------------------------

/// Chains argument decoding with `use`: an `Error` becomes the standard
/// invalid-arguments outcome, an `Ok` continues.
///
/// ## Examples
///
/// ```gleam
/// use path <- tool.with_arg(tool.required_string(args, "path"))
/// ```
///
pub fn with_arg(
  decoded: Result(a, String),
  run: fn(a) -> ToolOutcome,
) -> ToolOutcome {
  case decoded {
    Ok(value) -> run(value)
    Error(reason) -> failure("invalid arguments: " <> reason)
  }
}

/// Chains a step of a tool's own body with `use`: run `then` on success,
/// or render the error as a `ToolOutcome` via `to_outcome`. The general
/// form `with_arg` specializes for argument decoding — this package's
/// counterpart to `provider`'s `or_fail` and `machine/planner`'s
/// `or_fault`, for the steps whose error is domain data (a `PathError`,
/// a `Refusal`) rather than already a `ToolOutcome`.
///
/// ## Examples
///
/// ```gleam
/// use resolved <- tool.or_outcome(resolve_path(root, path), path_outcome)
/// ```
///
pub fn or_outcome(
  result: Result(a, e),
  to_outcome: fn(e) -> ToolOutcome,
  then: fn(a) -> ToolOutcome,
) -> ToolOutcome {
  case result {
    Ok(value) -> then(value)
    Error(error) -> to_outcome(error)
  }
}

/// A required string argument.
///
/// ## Examples
///
/// ```gleam
/// let args = json.Object([#("path", json.String("a.txt"))])
/// assert tool.required_string(args, "path") == Ok("a.txt")
/// ```
///
pub fn required_string(args: JsonValue, key: String) -> Result(String, String) {
  case field(args, key) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) -> Error("`" <> key <> "` must be a string")
    Error(Nil) -> Error("`" <> key <> "` is required")
  }
}

/// An optional string argument; absent or null is `None`.
///
/// ## Examples
///
/// ```gleam
/// assert tool.optional_string(json.Object([]), "path") == Ok(option.None)
/// ```
///
pub fn optional_string(
  args: JsonValue,
  key: String,
) -> Result(Option(String), String) {
  case field(args, key) {
    Ok(json.String(value)) -> Ok(Some(value))
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("`" <> key <> "` must be a string")
  }
}

/// An optional integer argument; absent or null is `None`.
///
/// ## Examples
///
/// ```gleam
/// let args = json.Object([#("limit", json.Int(5))])
/// assert tool.optional_int(args, "limit") == Ok(option.Some(5))
/// ```
///
pub fn optional_int(
  args: JsonValue,
  key: String,
) -> Result(Option(Int), String) {
  case field(args, key) {
    Ok(json.Int(value)) -> Ok(Some(value))
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("`" <> key <> "` must be an integer")
  }
}

/// An optional list-of-strings argument; absent or null is `None`.
///
/// ## Examples
///
/// ```gleam
/// let args = json.Object([#("globs", json.Array([json.String("*.gleam")]))])
/// assert tool.optional_string_list(args, "globs")
///   == Ok(option.Some(["*.gleam"]))
/// ```
///
pub fn optional_string_list(
  args: JsonValue,
  key: String,
) -> Result(Option(List(String)), String) {
  case field(args, key) {
    Ok(json.Array(items)) ->
      items
      |> list.try_map(fn(item) {
        case item {
          json.String(value) -> Ok(value)
          _ -> Error("`" <> key <> "` must be an array of strings")
        }
      })
      |> fn(strings) {
        case strings {
          Ok(strings) -> Ok(Some(strings))
          Error(reason) -> Error(reason)
        }
      }
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("`" <> key <> "` must be an array of strings")
  }
}

/// An optional boolean argument; absent or null is `None`.
///
/// ## Examples
///
/// ```gleam
/// let args = json.Object([#("detach", json.Bool(True))])
/// assert tool.optional_bool(args, "detach") == Ok(option.Some(True))
/// ```
///
pub fn optional_bool(
  args: JsonValue,
  key: String,
) -> Result(Option(Bool), String) {
  case field(args, key) {
    Ok(json.Bool(value)) -> Ok(Some(value))
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("`" <> key <> "` must be a boolean")
  }
}

/// An optional argument of any JSON shape; absent is `None`, but an
/// explicit `null` is `Some(json.Null)` — a blackboard cell may legally
/// hold null, and collapsing the two would make "write null" unwritable.
///
/// ## Examples
///
/// ```gleam
/// assert tool.optional_value(json.Object([]), "value") == Ok(option.None)
/// ```
///
pub fn optional_value(
  args: JsonValue,
  key: String,
) -> Result(Option(JsonValue), String) {
  case field(args, key) {
    Ok(value) -> Ok(Some(value))
    Error(Nil) -> Ok(None)
  }
}

// First occurrence of a field in an args object; non-objects have no
// fields.
fn field(args: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case args {
    json.Object(fields:) ->
      list.find_map(fields, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

// --- schema construction -------------------------------------------------

/// A JSON-schema object with the given properties, of which `required`
/// must be present.
///
/// ## Examples
///
/// ```gleam
/// let schema =
///   tool.object_schema([#("path", tool.string_property("the file"))], ["path"])
/// ```
///
pub fn object_schema(
  properties: List(#(String, JsonValue)),
  required: List(String),
) -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #("properties", json.Object(properties)),
    #("required", json.Array(list.map(required, json.String))),
    #("additionalProperties", json.Bool(False)),
  ])
}

/// A string-typed schema property.
pub fn string_property(description: String) -> JsonValue {
  json.Object([
    #("type", json.String("string")),
    #("description", json.String(description)),
  ])
}

/// An integer-typed schema property.
pub fn integer_property(description: String) -> JsonValue {
  json.Object([
    #("type", json.String("integer")),
    #("description", json.String(description)),
  ])
}

/// A boolean-typed schema property.
pub fn boolean_property(description: String) -> JsonValue {
  json.Object([
    #("type", json.String("boolean")),
    #("description", json.String(description)),
  ])
}

/// A closed-vocabulary schema property: a string restricted to `values`.
pub fn enum_property(values: List(String), description: String) -> JsonValue {
  json.Object([
    #("type", json.String("string")),
    #("enum", json.Array(list.map(values, json.String))),
    #("description", json.String(description)),
  ])
}

/// A schema property of any JSON shape.
pub fn any_property(description: String) -> JsonValue {
  json.Object([#("description", json.String(description))])
}

/// An array-of-strings schema property.
pub fn string_array_property(description: String) -> JsonValue {
  json.Object([
    #("type", json.String("array")),
    #("items", json.Object([#("type", json.String("string"))])),
    #("description", json.String(description)),
  ])
}

// --- requirement shapes ---------------------------------------------------

/// Policy-shaped requirements for a tool that only reads the workspace:
/// no writable roots, workspace readable, network off, tmpfs scratch,
/// no environment, and the restrictive default limits.
pub fn read_requirements(workspace: String) -> SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(..base, writable_roots: [], env_allow: [])
}

/// Policy-shaped requirements for a tool that reads and writes the
/// workspace, and nothing else.
pub fn write_requirements(workspace: String) -> SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(..base, env_allow: [])
}

/// The same requirements, asking for whatever network the session base
/// allows instead of stating a network of their own.
///
/// A jailed tool that hard-codes `NetworkOff` is not merely declaring a
/// preference: `policy.compose` takes the *meet* of base and
/// requirements, so an off requirement pins the call off however wide
/// the session's own posture is, and an operator's `[tools] network =
/// "full"` would reach nothing. The tools that run a shell have no
/// opinion of their own about egress — the operator's base is the whole
/// of the policy — so they ask for it rather than restating it.
///
/// This never widens anything. The meet still applies, so a base that is
/// off yields requirements that are off, which is the shipped default
/// and every session nobody configured a `[tools]` table for.
///
/// ## Examples
///
/// ```gleam
/// // tool.asking_base_network(tool.read_requirements("/w"), ctx.base_policy)
/// //   .network == ctx.base_policy.network
/// ```
///
pub fn asking_base_network(
  requirements: SandboxPolicy,
  base: SandboxPolicy,
) -> SandboxPolicy {
  policy.SandboxPolicy(..requirements, network: base.network)
}

// --- the broker seam -----------------------------------------------------

/// The production broker seam: clears calls through a live broker and
/// wraps the opaque handle in `RunningCall` closures. `waiting` bounds
/// the synchronous clearance call.
pub fn broker_runner(
  broker broker_actor: broker.Broker,
  waiting waiting: Int,
) -> fn(broker.CallSpec, Subject(CallEvent)) -> Result(RunningCall, Refusal) {
  fn(spec, events) {
    case broker.clear_call(broker_actor, spec, events:, waiting:) {
      Error(refusal) -> Error(refusal)
      Ok(handle) ->
        Ok(
          RunningCall(
            stdin: fn(data, eof) {
              broker.stdin(broker_actor, handle, data:, eof:)
            },
            cancel: fn() { broker.cancel(broker_actor, handle) },
          ),
        )
    }
  }
}

/// The accumulated output and settlement of one cleared call.
pub type Collected {
  Collected(
    /// All stdout bytes, in arrival order.
    stdout: BitArray,
    /// All stderr bytes, in arrival order.
    stderr: BitArray,
    /// Whether the helper truncated stdout at the output cap.
    stdout_truncated: Bool,
    /// Whether the helper truncated stderr at the output cap.
    stderr_truncated: Bool,
    /// How the call settled.
    outcome: CallOutcome,
  )
}

/// Receives a cleared call's events until its `CallSettled`, bounding
/// each receive by `waiting` milliseconds. `Error(Nil)` means the
/// broker broke its exactly-one-settlement contract within the window —
/// callers should cancel and settle as an in-band failure.
pub fn collect_events(
  events: Subject(CallEvent),
  waiting timeout: Int,
) -> Result(Collected, Nil) {
  collect_loop(events, timeout, [], [], False, False)
}

fn collect_loop(
  events: Subject(CallEvent),
  timeout: Int,
  stdout: List(BitArray),
  stderr: List(BitArray),
  stdout_truncated: Bool,
  stderr_truncated: Bool,
) -> Result(Collected, Nil) {
  case process.receive(events, timeout) {
    Ok(broker.CallOutput(stream:, data:, total_bytes: _, truncated:)) ->
      case stream {
        framing.Stdout ->
          collect_loop(
            events,
            timeout,
            [data, ..stdout],
            stderr,
            stdout_truncated || truncated,
            stderr_truncated,
          )
        framing.Stderr ->
          collect_loop(
            events,
            timeout,
            stdout,
            [data, ..stderr],
            stdout_truncated,
            stderr_truncated || truncated,
          )
      }
    Ok(broker.CallSettled(outcome:)) ->
      Ok(Collected(
        stdout: bit_array.concat(list.reverse(stdout)),
        stderr: bit_array.concat(list.reverse(stderr)),
        stdout_truncated:,
        stderr_truncated:,
        outcome:,
      ))
    Error(Nil) -> Error(Nil)
  }
}

// --- rendering refusals and failures as data -----------------------------

/// The standard in-band outcome for a broker refusal. A policy refusal
/// carries the exact wanted grants in `details` so the runtime can
/// raise an escalation from the recorded result.
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  case refusal {
    broker.PolicyRefused(denial:) ->
      failure("sandbox policy refused the call: " <> denial.reason)
      |> with_details(denial_to_json(denial))
    broker.InvalidPolicy(error:) ->
      failure("sandbox policy invalid: " <> policy_error_text(error))
    broker.BudgetRefused(refusal:) ->
      failure("execution budget refused the call: " <> budget_text(refusal))
    broker.MintRefused(error: _) ->
      failure("the broker could not mint a capability token")

    // Reaching the model at all means the clearance already waited out
    // its whole budget on a full pool (`broker.clear_call`), so this is
    // sustained saturation rather than an ordinary wide batch.
    broker.NoHelper(error:) ->
      failure("no sandbox helper available: " <> checkout_text(error))

    // The strand aborted this operation while the call was still
    // clearing. The synthetic interrupted result is the runtime's to
    // write; this text exists so nothing renders blank if one reaches
    // the model anyway.
    broker.OperationAborted ->
      failure("the operation was aborted before the call was dispatched")
    broker.BrokerUnavailable -> failure("the tool broker is unavailable")
  }
}

/// The standard in-band outcome for an execution failure settlement.
pub fn exec_failure_outcome(failure_value: exec.ExecFailure) -> ToolOutcome {
  failure("execution failed: " <> exec_failure_text(failure_value))
}

/// A short description of an execution failure.
pub fn exec_failure_text(failure_value: exec.ExecFailure) -> String {
  case failure_value {
    exec.NotReady -> "the sandbox helper is not ready"
    exec.HandshakeTimeout -> "the sandbox helper handshake timed out"
    exec.HelperBusy -> "the sandbox helper is busy"
    exec.DegradedHelper(features: _) ->
      "the sandbox helper cannot provide the demanded enforcement"
    exec.DegradedExecution(result: _) ->
      "the execution ran without the demanded enforcement"
    exec.RefusedByHelper(code:, message:) ->
      "the sandbox helper refused (" <> code <> "): " <> message

    // The report names the field that failed to decode, which is the
    // difference between "something is wrong with the helper" and
    // "this helper predates a required frame field" — a diagnosis a
    // reader should not have to reconstruct by bisecting binaries.
    exec.ChannelFault(fault: framing.CorruptFrame(report:)) ->
      "the sandbox channel broke protocol: " <> corruption.describe(report)
    exec.ChannelFault(fault: _) -> "the sandbox channel broke protocol"
    exec.ChannelClosed(status:) ->
      "the sandbox helper exited with status " <> int.to_string(status)
    exec.ProtocolViolation(kind:) ->
      "the sandbox helper sent a forbidden frame: " <> kind
    exec.SendFailed -> "writing to the sandbox helper failed"
    exec.CancelEscalated ->
      "the execution did not stop on cancel and was killed"
    exec.HeartbeatMissed -> "the sandbox helper stopped responding"
    exec.HelperUnresponsive -> "the sandbox helper did not answer"
  }
}

/// A structured denial as JSON: reason, source, and the wanted grants.
pub fn denial_to_json(denial: escalation.Denial) -> JsonValue {
  json.Object([
    #("error", json.String("policy_refused")),
    #("reason", json.String(denial.reason)),
    #("source", json.String(denial_source_text(denial.source))),
    #("wanted", json.Array(list.map(denial.wanted, grant_to_json))),
  ])
}

fn denial_source_text(source: escalation.DenialSource) -> String {
  case source {
    escalation.PolicyDenial -> "policy"
    escalation.ExecutionDenial(enforcement: _) -> "execution"
  }
}

/// One grant as JSON, in the escalation vocabulary.
pub fn grant_to_json(grant: Grant) -> JsonValue {
  case grant {
    policy.GrantWritableRoot(path:) ->
      json.Object([
        #("grant", json.String("writable_root")),
        #("path", json.String(path)),
      ])
    policy.GrantReadableRoot(path:) ->
      json.Object([
        #("grant", json.String("readable_root")),
        #("path", json.String(path)),
      ])
    policy.GrantNetwork(network:) ->
      json.Object([
        #("grant", json.String("network")),
        #("network", network_to_json(network)),
      ])
    policy.GrantEnv(name:) ->
      json.Object([#("grant", json.String("env")), #("name", json.String(name))])
    policy.GrantLimit(field:, value:) ->
      json.Object([
        #("grant", json.String("limit")),
        #("field", json.String(limit_field_text(field))),
        #("value", json.Int(value)),
      ])
    policy.GrantScratch(scratch:) ->
      json.Object([
        #("grant", json.String("scratch")),
        #("scratch", json.String(scratch_text(scratch))),
      ])
  }
}

fn network_to_json(network: policy.NetworkPolicy) -> JsonValue {
  case network {
    policy.NetworkOff -> json.Object([#("mode", json.String("off"))])
    policy.NetworkFull -> json.Object([#("mode", json.String("full"))])
    policy.NetworkProxy(allow:, proxy:) ->
      json.Object([
        #("mode", json.String("proxy")),
        #("allow", json.Array(list.map(allow, json.String))),
        #("proxy", json.String(proxy)),
      ])
  }
}

fn limit_field_text(limit_field: policy.LimitField) -> String {
  case limit_field {
    policy.CpuSeconds -> "cpu_s"
    policy.WallSeconds -> "wall_s"
    policy.MemBytes -> "mem_bytes"
    policy.Pids -> "pids"
    policy.FsizeBytes -> "fsize_bytes"
    policy.OutputBytes -> "output_bytes"
  }
}

fn scratch_text(scratch: policy.Scratch) -> String {
  case scratch {
    policy.ScratchTmpfs -> "tmpfs"
    policy.ScratchPath(path:) -> path
  }
}

fn policy_error_text(error: policy.PolicyError) -> String {
  case error {
    policy.RelativePath(path:) -> "relative path " <> path
    policy.NegativeLimit(field:, value:) ->
      "negative limit "
      <> limit_field_text(field)
      <> "="
      <> int.to_string(value)

    // Naming the layer is the useful part: a caller who asked for a
    // scratch of "/" is reading a refusal from the *policy*, not from
    // the jail, and the reason is Landlock's rather than bubblewrap's.
    policy.ScratchIsRoot ->
      "scratch names the host root, which Landlock cannot narrow"
  }
}

fn budget_text(refusal: budget.Refusal) -> String {
  case refusal {
    budget.OutstandingCapReached(cap:) ->
      "outstanding-effect cap " <> int.to_string(cap) <> " reached"
    budget.DeadlinePassed(deadline_ms:) ->
      "deadline " <> int.to_string(deadline_ms) <> " has passed"
  }
}

fn checkout_text(error: exec.CheckoutError) -> String {
  case error {
    exec.AllBusy(size:) ->
      "all " <> int.to_string(size) <> " helpers are lent out"
    exec.SpawnFailed(error: _) -> "spawning a helper failed"
    exec.PoolUnavailable -> "the sandbox helper pool did not answer"
  }
}
