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
  /// a read, or its writes are idempotent and guarded (fs_edit's
  /// anchors make double-apply impossible — see `tools/fs`).
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

/// The file-system seam: a record of functions over absolute paths.
/// Production uses `fs.real_filesystem` (simplifile); tests substitute
/// an in-memory fake. Tools must resolve paths under the workspace root
/// (`fs.resolve_path`) before calling these.
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
  )
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
/// arrives on the events subject.
pub type Ctx {
  Ctx(
    /// Absolute workspace root; every tool path resolves under it.
    workspace: String,
    /// The operation this tool call belongs to.
    op_id: OpId,
    /// The step id of the producing tool batch.
    step_id: String,
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
  )
}

/// What a tool call produced: content blocks for the model plus
/// machine-readable details, exactly the shape WP-E commits as a
/// `ToolResultMessage`.
///
/// Constructor invariants: `content` is non-empty; `is_error` marks an
/// in-band failure the model should react to, never a harness fault.
pub type ToolOutcome {
  ToolOutcome(
    /// Content blocks, in the core message vocabulary.
    content: List(message.ToolResultBlock),
    /// Machine-readable details under the tool's own details contract.
    details: Option(JsonValue),
    /// Whether this outcome is an in-band failure.
    is_error: Bool,
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
pub type Tool {
  Tool(
    /// Unique tool name as the model calls it.
    name: String,
    /// Model-facing description.
    description: String,
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

/// A name → `Tool` table.
pub opaque type Registry {
  /// Invariant: `tools` is keyed by each tool's `name`.
  Registry(tools: Dict(String, Tool))
}

/// Builds a registry from a tool list. A duplicated name keeps the
/// later tool, mirroring "last registration wins".
///
/// ## Examples
///
/// ```gleam
/// let registry = tool.registry([bash.tool(), grep.tool()])
/// assert tool.names(registry) == ["bash", "grep"]
/// ```
///
pub fn registry(tools: List(Tool)) -> Registry {
  Registry(
    tools: list.fold(tools, dict.new(), fn(table, tool) {
      dict.insert(table, tool.name, tool)
    }),
  )
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
  ToolOutcome(content: [text_block(text)], details: None, is_error: False)
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
  ToolOutcome(content: [text_block(text)], details: None, is_error: True)
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
    broker.NoHelper(error:) ->
      failure("no sandbox helper available: " <> checkout_text(error))
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
    exec.ChannelFault(fault: _) -> "the sandbox channel broke protocol"
    exec.ChannelClosed(status:) ->
      "the sandbox helper exited with status " <> int.to_string(status)
    exec.ProtocolViolation(kind:) ->
      "the sandbox helper sent a forbidden frame: " <> kind
    exec.SendFailed -> "writing to the sandbox helper failed"
    exec.CancelEscalated ->
      "the execution did not stop on cancel and was killed"
    exec.HeartbeatMissed -> "the sandbox helper stopped responding"
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
  }
}
