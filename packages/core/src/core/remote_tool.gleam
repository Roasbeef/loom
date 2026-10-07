//// Complete logical identity for owner-held remote tool evidence.
////
//// A transport connection never allocates this identity. The runtime supplies
//// its original durable operation, source index and reserved result entry;
//// the owner hashes canonical effective arguments outside this pure module.
//// The address excludes immutable content so changing a digest or result entry
//// finds the original fence and conflicts rather than creating another request.

import core/bounded_msgpack
import core/corruption
import core/ids.{type EntryId, type OpId, type SessionId}
import core/json
import core/json_wire
import core/msgpack as m
import core/workspace
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// A complete tool identity, constructed only after bounded validation.
pub opaque type ToolKey {
  ToolKey(
    session: SessionId,
    operation: OpId,
    step: String,
    source_index: Int,
    argument_digest: String,
    result_entry: EntryId,
  )
}

/// Separates semantic effects from native commands for one admitted capability.
/// The caller derives this purpose after router admission, never from peer data.
pub type CapabilityPurpose {
  /// A whole workspace operation with its own retained completion.
  SemanticWorkspace

  /// A native command whose exact cleared envelope has independent custody.
  NativeCommand
}

/// A child invocation's role, independent of connection generations.
pub type ChildRole {
  /// Physical preparation and compilation for this tool.
  Compile

  /// The sole rewritten physical compilation beneath the original tool.
  CompileRewrite

  /// Satellite or native launch for this tool.
  Launch

  /// The native build command beneath an outer Compile service request.
  CompileCommand

  /// The native command of the sole unused-import rewrite attempt.
  CompileRewriteCommand

  /// The native satellite command beneath an outer Launch service request.
  SatelliteCommand

  /// A newly admitted capability, addressed by its complete logical tuple.
  /// Equal ordinals from different capabilities must never share a row.
  AdmittedCapability(
    /// The bounded name from the trusted admitted router request.
    name: String,
    /// The existing ordinal within this capability, not a global counter.
    ordinal: Int,
    /// The distinct effect whose immutable payload occupies the child row.
    purpose: CapabilityPurpose,
  )

  /// A legacy capability address, retained for existing durable evidence.
  Capability(ordinal: Int)

  /// One semantic workspace invocation, disjoint from physical execution roles.
  Workspace(
    /// The stable ordinal assigned by the admitted caller.
    ordinal: Int,
  )
}

/// The finite native recipes beneath a retained semantic workspace invocation.
pub type WorkspaceCommandPhase {
  /// Reads the current branch.
  GitBranch

  /// Checks whether the retained checkout is a repository.
  GitRepositoryProbe

  /// Reads the original HEAD revision.
  GitRevision

  /// Reads the checkout status.
  GitStatus

  /// Reads unstaged changes.
  GitWorkingTreeDiff

  /// Reads staged changes.
  GitStagedDiff

  /// Reads changes since the retained revision.
  GitSinceRevisionDiff

  /// Reads the retained bounded log query.
  GitLog

  /// Identifies initialization without enabling an unspecified native recipe.
  WorkspaceInitialize
}

/// A child request belongs to a tool or an explicitly named system service.
pub opaque type ChildOrigin {
  ToolChild(key: ToolKey, role: ChildRole)
  SystemChild(session: SessionId, service: String, ordinal: Int)
  WorkspaceCommandChild(parent: ChildOrigin, phase: WorkspaceCommandPhase)
}

/// Complete checked provenance, projected without parsing a logical address.
pub type ChildFields {
  /// The actual parent and disjoint child role.
  ToolFields(key: ToolKey, role: ChildRole)

  /// The actual system coordinates, without a fabricated tool parent.
  SystemFields(session: SessionId, service: String, ordinal: Int)

  /// The complete direct semantic parent and its fixed native phase.
  WorkspaceCommandFields(parent: ChildOrigin, phase: WorkspaceCommandPhase)
}

/// Validates bounds without computing the digest or allocating any identity.
/// The digest must be lowercase SHA-256 hex over core/json canonical bytes.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.key(session, operation, step, index, digest, result_entry)
/// ```
pub fn key(
  session: SessionId,
  operation: OpId,
  step: String,
  source_index: Int,
  argument_digest: String,
  result_entry: EntryId,
) -> Result(ToolKey, String) {
  use _step <- result.try(
    workspace.step(step) |> result.replace_error("invalid remote parent step"),
  )
  use <- bool.guard(
    when: source_index < 0 || source_index > 4095,
    return: Error("remote tool source index is outside its bound"),
  )
  use <- bool.guard(
    when: string.byte_size(argument_digest) != 64,
    return: Error("remote tool argument digest must be SHA-256 hex"),
  )
  use <- bool.guard(
    when: !list.all(string.to_graphemes(argument_digest), fn(char) {
      string.contains("0123456789abcdef", char)
    }),
    return: Error("remote tool argument digest must be lowercase hex"),
  )
  Ok(ToolKey(
    session:,
    operation:,
    step:,
    source_index:,
    argument_digest:,
    result_entry:,
  ))
}

/// Returns the session whose per-session journal must hold this key.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.session(key)
/// ```
pub fn session(key: ToolKey) -> SessionId {
  key.session
}

/// Returns the original operation for broker child clearance.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.operation(key)
/// ```
pub fn operation(key: ToolKey) -> OpId {
  key.operation
}

/// Returns the validated original parent step, without physical child inference.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.step(key)
/// ```
pub fn step(key: ToolKey) -> String {
  key.step
}

/// Returns the original tool position within its source assistant message.
/// This coordinate belongs to provenance, never the broker's pooled ledger key.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.source_index(key) == 2
/// ```
pub fn source_index(key: ToolKey) -> Int {
  key.source_index
}

/// Returns the reserved session result-entry identity for verified collection.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.result_entry(key)
/// ```
pub fn result_entry(key: ToolKey) -> EntryId {
  key.result_entry
}

/// Encodes the logical address without immutable digest and result identity.
/// JSON arrays prevent separator ambiguity in the bounded step name.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.address(key)
/// ```
pub fn address(key: ToolKey) -> String {
  json.to_string(
    json.Array([
      json.String(ids.session_id_to_string(key.session)),
      json.String(ids.op_id_to_string(key.operation)),
      json.String(key.step),
      json.Int(key.source_index),
    ]),
  )
}

/// Encodes every immutable identity component for exact journal comparisons.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.encode(key)
/// ```
pub fn encode(key: ToolKey) -> json.JsonValue {
  json.Array([
    json.String(address(key)),
    json.String(key.argument_digest),
    json.String(ids.entry_id_to_string(key.result_entry)),
  ])
}

/// Constructs a tool child with a bounded invocation ordinal.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.tool_child(key, remote_tool.Launch)
/// ```
pub fn tool_child(
  key: ToolKey,
  role: ChildRole,
) -> Result(ChildOrigin, String) {
  case role {
    Compile
    | CompileRewrite
    | Launch
    | CompileCommand
    | CompileRewriteCommand
    | SatelliteCommand -> Ok(ToolChild(key:, role:))
    Capability(ordinal) | Workspace(ordinal) -> {
      use Nil <- result.try(bounded_ordinal(ordinal))
      Ok(ToolChild(key:, role:))
    }
    AdmittedCapability(name, ordinal, _) -> {
      use Nil <- result.try(bounded_name(name))
      use Nil <- result.try(bounded_ordinal(ordinal))
      Ok(ToolChild(key:, role:))
    }
  }
}

/// Constructs a system origin explicitly, never by inventing a tool operation.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.system_child(session, "lsp", ordinal)
/// ```
pub fn system_child(
  session: SessionId,
  service: String,
  ordinal: Int,
) -> Result(ChildOrigin, String) {
  use Nil <- result.try(bounded_name(service))
  use Nil <- result.try(bounded_ordinal(ordinal))
  Ok(SystemChild(session:, service:, ordinal:))
}

/// Derives identity data beneath a direct semantic workspace parent.
/// Storage independently proves that a system parent was actually allocated.
/// The constructor grants no clearance or execution permission.
///
/// ## Examples
///
/// `workspace_command_child(parent, GitStatus)` shares the parent's quota group.
pub fn workspace_command_child(
  parent: ChildOrigin,
  phase: WorkspaceCommandPhase,
) -> Result(ChildOrigin, String) {
  use Nil <- result.try(case parent {
    ToolChild(role: Workspace(_), ..) | SystemChild(..) -> Ok(Nil)
    ToolChild(..) | WorkspaceCommandChild(..) ->
      Error("workspace command requires a direct semantic workspace parent")
  })
  let origin = WorkspaceCommandChild(parent, phase)
  use _ <- result.try(
    encode_child(origin)
    |> result.replace_error("complete child identity exceeds its bound"),
  )
  Ok(origin)
}

/// Returns the child origin's journal session.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.child_session(origin)
/// ```
pub fn child_session(origin: ChildOrigin) -> SessionId {
  case origin {
    ToolChild(key:, ..) -> key.session
    SystemChild(session:, ..) -> session
    WorkspaceCommandChild(parent:, ..) -> child_session(parent)
  }
}

/// Returns a child's tool address, or an explicit system namespace.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.child_parent(origin)
/// ```
pub fn child_parent(origin: ChildOrigin) -> String {
  case origin {
    ToolChild(key:, ..) -> address(key)
    WorkspaceCommandChild(parent:, ..) -> child_parent(parent)
    SystemChild(session:, service:, ..) ->
      json.to_string(
        json.Array([
          json.String("system"),
          json.String(ids.session_id_to_string(session)),
          json.String(service),
        ]),
      )
  }
}

/// Returns the bounded logical child address, independent of connections.
/// Tool addresses exclude immutable content so retries reach the original fence;
/// storage verifies the complete parent ToolKey before reading a child payload.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.child_address(origin)
/// ```
pub fn child_address(origin: ChildOrigin) -> String {
  let role = case origin {
    ToolChild(role: Compile, ..) -> json.Array([json.String("compile")])
    ToolChild(role: CompileRewrite, ..) ->
      json.Array([json.String("compile_unused_import_rewrite")])
    ToolChild(role: Launch, ..) -> json.Array([json.String("launch")])
    ToolChild(role: CompileCommand, ..) ->
      json.Array([json.String("compile_command")])
    ToolChild(role: CompileRewriteCommand, ..) ->
      json.Array([json.String("compile_unused_import_rewrite_command")])
    ToolChild(role: SatelliteCommand, ..) ->
      json.Array([json.String("satellite_command")])
    ToolChild(role: AdmittedCapability(name, ordinal, purpose), ..) -> {
      let purpose = case purpose {
        SemanticWorkspace -> "workspace"
        NativeCommand -> "native"
      }
      json.Array([
        json.String("admitted_cap"),
        json.String(name),
        json.Int(ordinal),
        json.String(purpose),
      ])
    }
    ToolChild(role: Capability(ordinal), ..) ->
      json.Array([json.String("cap"), json.Int(ordinal)])
    ToolChild(role: Workspace(ordinal), ..) ->
      json.Array([json.String("workspace"), json.Int(ordinal)])
    SystemChild(ordinal:, ..) ->
      json.Array([json.String("system"), json.Int(ordinal)])
    WorkspaceCommandChild(parent:, phase:) ->
      json.Array([
        json.String("workspace_command"),
        json.String(child_address(parent)),
        json.String(workspace_command_phase_name(phase)),
      ])
  }
  json.to_string(json.Array([json.String(child_parent(origin)), role]))
}

/// Returns the immutable parent key for tool children and no key for systems.
///
/// ## Examples
///
/// ```gleam
/// // remote_tool.child_tool(origin)
/// ```
pub fn child_tool(origin: ChildOrigin) -> Result(ToolKey, Nil) {
  case origin {
    ToolChild(key:, ..) -> Ok(key)
    SystemChild(..) | WorkspaceCommandChild(..) -> Error(Nil)
  }
}

fn bounded_name(name: String) -> Result(Nil, String) {
  case
    string.byte_size(name) > 0
    && string.byte_size(name) <= 128
    && !string.contains(name, "\u{0000}")
  {
    True -> Ok(Nil)
    False -> Error("remote identity name is empty, oversized or contains NUL")
  }
}

fn bounded_ordinal(ordinal: Int) -> Result(Nil, String) {
  case ordinal >= 0 && ordinal <= 4095 {
    True -> Ok(Nil)
    False -> Error("remote child ordinal is outside its bound")
  }
}

/// Projects immutable source index and canonical argument digest for provenance.
///
/// ## Examples
///
/// `provenance(key)` retains the runtime source rather than allocating a new one.
pub fn provenance(key: ToolKey) -> #(Int, String) {
  #(key.source_index, key.argument_digest)
}

/// Projects a tool child's role while keeping a system origin explicit.
///
/// ## Examples
///
/// `child_role(system_origin)` returns `Error(Nil)`.
pub fn child_role(origin: ChildOrigin) -> Result(ChildRole, Nil) {
  case origin {
    ToolChild(role:, ..) -> Ok(role)
    SystemChild(..) | WorkspaceCommandChild(..) -> Error(Nil)
  }
}

/// Projects the complete typed parent without interpreting its address.
///
/// ## Examples
///
/// `child_fields(system)` returns its original service and ordinal.
pub fn child_fields(origin: ChildOrigin) -> ChildFields {
  case origin {
    ToolChild(key:, role:) -> ToolFields(key, role)
    SystemChild(session:, service:, ordinal:) ->
      SystemFields(session, service, ordinal)
    WorkspaceCommandChild(parent:, phase:) ->
      WorkspaceCommandFields(parent, phase)
  }
}

/// Encodes the complete original child for nested custody headers.
/// Existing logical addresses keep their separate, unchanged spelling.
///
/// ## Examples
///
/// `decode_child_value(child_value(origin)) == Ok(origin)`.
pub fn child_value(origin: ChildOrigin) -> m.MsgPackValue {
  case origin {
    ToolChild(key:, role:) ->
      m.ArrayValue([
        m.IntValue(1),
        m.IntValue(0),
        m.ArrayValue([
          m.StringValue(ids.session_id_to_string(key.session)),
          m.StringValue(ids.op_id_to_string(key.operation)),
          m.StringValue(key.step),
          m.IntValue(key.source_index),
          m.StringValue(key.argument_digest),
          m.StringValue(ids.entry_id_to_string(key.result_entry)),
        ]),
        role_value(role),
      ])
    SystemChild(session:, service:, ordinal:) ->
      m.ArrayValue([
        m.IntValue(1),
        m.IntValue(1),
        m.StringValue(ids.session_id_to_string(session)),
        m.StringValue(service),
        m.IntValue(ordinal),
      ])
    WorkspaceCommandChild(parent:, phase:) ->
      m.ArrayValue([
        m.IntValue(1),
        m.IntValue(2),
        child_value(parent),
        m.StringValue(workspace_command_phase_name(phase)),
      ])
  }
}

/// Encodes one bounded canonical child identity, containing no live authority.
///
/// ## Examples
///
/// `decode_child(encode_child(origin))` preserves every original field.
pub fn encode_child(
  origin: ChildOrigin,
) -> Result(BitArray, corruption.CorruptionReport) {
  use bytes <- result.try(
    m.encode(child_value(origin))
    |> result.map_error(fn(_) { child_corruption("encodable child identity") }),
  )
  use Nil <- result.try(child_size(bytes))
  Ok(bytes)
}

/// Scans before term allocation and reconstructs through the checked constructors.
///
/// ## Examples
///
/// Nonminimal scalar widths, unknown roles and surplus fields are refused.
pub fn decode_child(
  bytes: BitArray,
) -> Result(ChildOrigin, corruption.CorruptionReport) {
  use Nil <- result.try(child_size(bytes))
  use value <- result.try(bounded_msgpack.decode(bytes))
  use origin <- result.try(decode_child_value(value))
  use canonical <- result.try(encode_child(origin))
  case canonical == bytes {
    True -> Ok(origin)
    False -> Error(child_corruption("canonical complete child identity"))
  }
}

/// Decodes a nested original identity after its enclosing raw preflight.
/// No abbreviated address or current-generation lookup supplies missing fields.
///
/// ## Examples
///
/// A changed tool digest remains part of the decoded complete parent.
pub fn decode_child_value(
  value: m.MsgPackValue,
) -> Result(ChildOrigin, corruption.CorruptionReport) {
  use child <- result.try(
    parse_child(value) |> result.map_error(child_corruption),
  )

  // UUID parsers also accept uppercase input. Reprojection retains one spelling.
  case child_value(child) == value {
    True -> Ok(child)
    False -> Error(child_corruption("canonical complete child identity"))
  }
}

fn parse_child(value: m.MsgPackValue) -> Result(ChildOrigin, String) {
  case value {
    m.ArrayValue([m.IntValue(1), m.IntValue(2), parent, m.StringValue(phase)]) -> {
      // Only direct tags reach the parent parser, so nesting never recurses.
      use Nil <- result.try(case parent {
        m.ArrayValue([m.IntValue(1), m.IntValue(0), _, _])
        | m.ArrayValue([m.IntValue(1), m.IntValue(1), _, _, _]) -> Ok(Nil)
        _ -> Error("workspace command parent must be direct")
      })
      use parent <- result.try(parse_child(parent))
      use phase <- result.try(parse_workspace_command_phase(phase))
      workspace_command_child(parent, phase)
    }
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(0),
      m.ArrayValue([
        m.StringValue(session),
        m.StringValue(operation),
        m.StringValue(step),
        m.IntValue(index),
        m.StringValue(digest),
        m.StringValue(entry),
      ]),
      role,
    ]) -> {
      use session <- result.try(
        ids.parse_session_id(session)
        |> result.replace_error("child session UUIDv7"),
      )
      use operation <- result.try(
        ids.parse_op_id(operation)
        |> result.replace_error("child operation UUIDv7"),
      )
      use entry <- result.try(
        ids.parse_entry_id(entry) |> result.replace_error("child result UUIDv7"),
      )
      use parent <- result.try(key(
        session,
        operation,
        step,
        index,
        digest,
        entry,
      ))
      use role <- result.try(parse_role(role))
      tool_child(parent, role)
    }
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(1),
      m.StringValue(session),
      m.StringValue(service),
      m.IntValue(ordinal),
    ]) -> {
      use session <- result.try(
        ids.parse_session_id(session)
        |> result.replace_error("system session UUIDv7"),
      )
      system_child(session, service, ordinal)
    }
    _ -> Error("versioned complete child identity")
  }
}

fn role_value(role: ChildRole) -> m.MsgPackValue {
  let value = case role {
    Compile -> json.Array([json.String("compile")])
    CompileRewrite -> json.Array([json.String("compile_unused_import_rewrite")])
    Launch -> json.Array([json.String("launch")])
    CompileCommand -> json.Array([json.String("compile_command")])
    CompileRewriteCommand ->
      json.Array([json.String("compile_unused_import_rewrite_command")])
    SatelliteCommand -> json.Array([json.String("satellite_command")])
    Capability(ordinal) -> json.Array([json.String("cap"), json.Int(ordinal)])
    Workspace(ordinal) ->
      json.Array([json.String("workspace"), json.Int(ordinal)])
    AdmittedCapability(name, ordinal, purpose) ->
      json.Array([
        json.String("admitted_cap"),
        json.String(name),
        json.Int(ordinal),
        json.String(case purpose {
          SemanticWorkspace -> "workspace"
          NativeCommand -> "native"
        }),
      ])
  }
  json_wire.of_json(value)
}

fn parse_role(value: m.MsgPackValue) -> Result(ChildRole, String) {
  case value {
    m.ArrayValue([m.StringValue("compile")]) -> Ok(Compile)
    m.ArrayValue([m.StringValue("compile_unused_import_rewrite")]) ->
      Ok(CompileRewrite)
    m.ArrayValue([m.StringValue("launch")]) -> Ok(Launch)
    m.ArrayValue([m.StringValue("compile_command")]) -> Ok(CompileCommand)
    m.ArrayValue([m.StringValue("compile_unused_import_rewrite_command")]) ->
      Ok(CompileRewriteCommand)
    m.ArrayValue([m.StringValue("satellite_command")]) -> Ok(SatelliteCommand)
    m.ArrayValue([m.StringValue("cap"), m.IntValue(ordinal)]) ->
      Ok(Capability(ordinal))
    m.ArrayValue([m.StringValue("workspace"), m.IntValue(ordinal)]) ->
      Ok(Workspace(ordinal))
    m.ArrayValue([
      m.StringValue("admitted_cap"),
      m.StringValue(name),
      m.IntValue(ordinal),
      m.StringValue("workspace"),
    ]) -> Ok(AdmittedCapability(name, ordinal, SemanticWorkspace))
    m.ArrayValue([
      m.StringValue("admitted_cap"),
      m.StringValue(name),
      m.IntValue(ordinal),
      m.StringValue("native"),
    ]) -> Ok(AdmittedCapability(name, ordinal, NativeCommand))
    _ -> Error("closed child role")
  }
}

fn child_size(bytes: BitArray) -> Result(Nil, corruption.CorruptionReport) {
  case
    bit_array.bit_size(bytes) > 0
    && bit_array.bit_size(bytes) % 8 == 0
    && bit_array.byte_size(bytes) <= 8192
  {
    True -> Ok(Nil)
    False ->
      Error(child_corruption("complete child identity at most 8192 bytes"))
  }
}

fn child_corruption(expected: String) -> corruption.CorruptionReport {
  corruption.report(
    at: "core/remote_tool.decode_child",
    on: "child",
    expected:,
    context: "",
  )
}

/// Returns the stable closed recipe spelling used in canonical identity bytes.
///
/// ## Examples
///
/// `workspace_command_phase_name(GitStatus)` returns `"git_status"`.
pub fn workspace_command_phase_name(phase: WorkspaceCommandPhase) -> String {
  case phase {
    GitBranch -> "git_branch"
    GitRepositoryProbe -> "git_repository_probe"
    GitRevision -> "git_revision"
    GitStatus -> "git_status"
    GitWorkingTreeDiff -> "git_working_tree_diff"
    GitStagedDiff -> "git_staged_diff"
    GitSinceRevisionDiff -> "git_since_revision_diff"
    GitLog -> "git_log"
    WorkspaceInitialize -> "workspace_initialize"
  }
}

fn parse_workspace_command_phase(
  name: String,
) -> Result(WorkspaceCommandPhase, String) {
  case name {
    "git_branch" -> Ok(GitBranch)
    "git_repository_probe" -> Ok(GitRepositoryProbe)
    "git_revision" -> Ok(GitRevision)
    "git_status" -> Ok(GitStatus)
    "git_working_tree_diff" -> Ok(GitWorkingTreeDiff)
    "git_staged_diff" -> Ok(GitStagedDiff)
    "git_since_revision_diff" -> Ok(GitSinceRevisionDiff)
    "git_log" -> Ok(GitLog)
    "workspace_initialize" -> Ok(WorkspaceInitialize)
    _ -> Error("closed workspace command phase")
  }
}
