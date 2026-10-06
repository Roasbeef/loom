//// Complete logical identity for owner-held remote tool evidence.
////
//// A transport connection never allocates this identity. The runtime supplies
//// its original durable operation, source index and reserved result entry;
//// the owner hashes canonical effective arguments outside this pure module.
//// The address excludes immutable content so changing a digest or result entry
//// finds the original fence and conflicts rather than creating another request.

import core/ids.{type EntryId, type OpId, type SessionId}
import core/json
import core/workspace
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

/// A child request belongs to a tool or an explicitly named system service.
pub opaque type ChildOrigin {
  ToolChild(key: ToolKey, role: ChildRole)
  SystemChild(session: SessionId, service: String, ordinal: Int)
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
    SystemChild(..) -> Error(Nil)
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
    SystemChild(..) -> Error(Nil)
  }
}
