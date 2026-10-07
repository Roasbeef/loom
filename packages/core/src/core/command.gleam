//// Pure identities for whole physical services and their exact command offers.
////
//// A ServiceKey retains the original managed parent, full registered scope and
//// exact service input contract. Its address excludes content, so changed input
//// finds an existing fence. CommandRef adds only a closed purpose, never a UUID.
//// Native UUID/content custody begins after clearance in the effect layer.
//// Only Compile and Launch are admitted here; system/LSP custody needs its own
//// durable parent and collection witness before it can enter this vocabulary.

import core/corruption
import core/ids
import core/json
import core/remote_tool
import core/workspace
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The whole physical service whose exact request precedes preparation.
pub type ServiceRole {
  /// Preparation, compilation and artifact fingerprinting.
  CompileService

  /// Satellite resources and launch for an admitted artifact.
  LaunchService
}

/// One exact command beneath an already retained physical service.
pub type CommandRole {
  /// The build command beneath CompileService.
  CompileCommand

  /// The satellite command beneath LaunchService.
  SatelliteCommand
}

/// A complete original service identity, containing no execution authority.
pub opaque type ServiceKey {
  ServiceKey(
    /// Immutable predecessor of the sole rewrite; absent for old Original keys.
    predecessor: Option(ServiceKey),
    /// Original runtime parent, including its reserved result entry.
    parent: remote_tool.ToolKey,
    /// Closed whole-service purpose.
    role: ServiceRole,
    /// Original outer child coordinate, independent of content.
    origin: remote_tool.ChildOrigin,
    /// Full administrative scope, including both authority epochs.
    scope: workspace.Scope,
    /// Actual physical operation, validated against the managed parent.
    operation: ids.OpId,
    /// Actual physical step, retaining its exact spelling.
    step: workspace.Step,
    /// Original outer service UUID, distinct from a later native UUID.
    request_id: ids.EntryId,
    /// SHA-256 of canonical exact service input.
    input_digest: String,
    /// Original enrolled registration digest.
    registration_digest: String,
    /// Negotiated source/prelude/seed service contract digest.
    contract_digest: String,
  )
}

/// A deterministic offer address and its closed native child association.
pub opaque type CommandRef {
  CommandRef(
    /// The complete immutable original service identity.
    service: ServiceKey,
    /// A purpose validated against the outer service role.
    role: CommandRole,
    /// The original parent's disjoint native child coordinate.
    native: remote_tool.ChildOrigin,
  )
}

/// Validates complete identity without allocating an ID or granting authority.
/// Physical coordinates are explicit; the managed session and operation agree.
///
/// ## Examples
///
/// `service_key(parent, CompileService, scope, op, step, id, a, b, c)` validates.
pub fn service_key(
  parent: remote_tool.ToolKey,
  role: ServiceRole,
  scope: workspace.Scope,
  operation: ids.OpId,
  step: workspace.Step,
  request_id: ids.EntryId,
  input_digest: String,
  registration_digest: String,
  contract_digest: String,
) -> Result(ServiceKey, String) {
  use Nil <- result.try(digest(input_digest))
  use Nil <- result.try(digest(registration_digest))
  use Nil <- result.try(digest(contract_digest))
  use Nil <- result.try(
    case
      workspace.scope_fields(scope).0 == remote_tool.session(parent)
      && operation == remote_tool.operation(parent)
    {
      True -> Ok(Nil)
      False -> Error("service scope or operation differs from original parent")
    },
  )
  let child_role = case role {
    CompileService -> remote_tool.Compile
    LaunchService -> remote_tool.Launch
  }
  use origin <- result.try(remote_tool.tool_child(parent, child_role))
  Ok(ServiceKey(
    predecessor: None,
    parent:,
    role:,
    origin:,
    scope:,
    operation:,
    step:,
    request_id:,
    input_digest:,
    registration_digest:,
    contract_digest:,
  ))
}

/// Derives the sole rewrite service from its exact Original predecessor.
/// Scope, parent and budget coordinates cannot change through this constructor.
///
/// ## Examples
///
/// `rewrite_service_key(original, rewrite_id, rewritten_digest)` refuses nesting.
pub fn rewrite_service_key(
  original: ServiceKey,
  request_id: ids.EntryId,
  input_digest: String,
) -> Result(ServiceKey, String) {
  use Nil <- result.try(digest(input_digest))
  use <- bool.guard(
    original.role != CompileService
      || original.predecessor != None
      || request_id == original.request_id,
    Error("rewrite requires a distinct UUID and Original Compile predecessor"),
  )
  use origin <- result.try(remote_tool.tool_child(
    original.parent,
    remote_tool.CompileRewrite,
  ))
  Ok(
    ServiceKey(
      ..original,
      predecessor: Some(original),
      origin:,
      request_id:,
      input_digest:,
    ),
  )
}

/// Projects immutable lineage without granting another compilation attempt.
///
/// ## Examples
///
/// `compile_predecessor(original)` is `None` for all version-1 keys.
pub fn compile_predecessor(key: ServiceKey) -> Option(ServiceKey) {
  key.predecessor
}

/// Accepts only the fixed outer/native pair, without minting another identity.
///
/// ## Examples
///
/// `command_ref(compile_service, SatelliteCommand)` is refused.
pub fn command_ref(
  service: ServiceKey,
  role: CommandRole,
) -> Result(CommandRef, String) {
  use child_role <- result.try(case service.role, role {
    CompileService, CompileCommand -> {
      case service.predecessor {
        None -> Ok(remote_tool.CompileCommand)
        Some(_) -> Ok(remote_tool.CompileRewriteCommand)
      }
    }
    LaunchService, SatelliteCommand -> Ok(remote_tool.SatelliteCommand)
    CompileService, SatelliteCommand | LaunchService, CompileCommand ->
      Error("command role differs from original service purpose")
  })
  use native <- result.try(remote_tool.tool_child(service.parent, child_role))
  Ok(CommandRef(service:, role:, native:))
}

/// Returns the service's original managed parent.
///
/// ## Examples
///
/// `parent(service)` retains source index and result entry.
pub fn parent(service: ServiceKey) -> remote_tool.ToolKey {
  service.parent
}

/// Returns the closed outer purpose admitted by the smart constructor.
///
/// ## Examples
///
/// `service_role(key)` never infers purpose from a peer command.
pub fn service_role(key: ServiceKey) -> ServiceRole {
  key.role
}

/// Returns the exact original outer child.
///
/// ## Examples
///
/// `service_origin(service)` is Compile or Launch, never a native role.
pub fn service_origin(service: ServiceKey) -> remote_tool.ChildOrigin {
  service.origin
}

/// Returns the original outer request UUID.
///
/// ## Examples
///
/// `request_id(service)` is unchanged across reconnects.
pub fn request_id(service: ServiceKey) -> ids.EntryId {
  service.request_id
}

/// Returns the original full scope and physical operation/step.
///
/// ## Examples
///
/// `coordinates(service)` includes both authority epochs.
pub fn coordinates(
  service: ServiceKey,
) -> #(workspace.Scope, ids.OpId, workspace.Step) {
  #(service.scope, service.operation, service.step)
}

/// Returns original input, enrollment and negotiated contract digests.
///
/// ## Examples
///
/// `digests(service)` never substitutes a current registration.
pub fn digests(service: ServiceKey) -> #(String, String, String) {
  #(service.input_digest, service.registration_digest, service.contract_digest)
}

/// Returns the original service retained by a command reference.
///
/// ## Examples
///
/// `service(ref)` grants no send permission.
pub fn service(ref: CommandRef) -> ServiceKey {
  ref.service
}

/// Returns the disjoint native coordinate without allocating its UUID.
///
/// ## Examples
///
/// `native_origin(ref)` is CompileCommand or SatelliteCommand.
pub fn native_origin(ref: CommandRef) -> remote_tool.ChildOrigin {
  ref.native
}

/// Returns the deterministic content-independent offer address.
///
/// ## Examples
///
/// Changed service/offer digests still reach `command_address(ref)`.
pub fn command_address(ref: CommandRef) -> String {
  json.to_string(
    json.Array([
      json.String(remote_tool.child_address(ref.service.origin)),
      json.String(command_name(ref.role)),
    ]),
  )
}

/// Validates canonical SHA-256 spelling without claiming a hash was computed.
///
/// ## Examples
///
/// Uppercase or non-hex values return `Error`.
pub fn digest(value: String) -> Result(Nil, String) {
  case
    string.byte_size(value) == 64
    && list.all(string.to_graphemes(value), fn(c) {
      string.contains("0123456789abcdef", c)
    })
  {
    True -> Ok(Nil)
    False -> Error("command digest must be lowercase SHA-256 hex")
  }
}

/// Encodes the complete bounded service identity in a closed versioned shape.
///
/// ## Examples
///
/// `decode_service(encode_service(service)) == Ok(service)`.
pub fn encode_service(service: ServiceKey) -> json.JsonValue {
  case service.predecessor {
    Some(original) ->
      json.Array([
        json.Int(2),
        encode_original_service(original),
        json.String(ids.entry_id_to_string(service.request_id)),
        json.String(service.input_digest),
      ])
    None -> encode_original_service(service)
  }
}

// Version-one bytes stay literal so existing durable addresses remain valid.
fn encode_original_service(service: ServiceKey) -> json.JsonValue {
  let key = service.parent
  let #(index, arguments) = remote_tool.provenance(key)
  let #(session, binding) = workspace.scope_fields(service.scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, workspace_name) = workspace.selector_fields(selector)
  json.Array([
    json.Int(1),
    json.Array([
      json.String(ids.session_id_to_string(remote_tool.session(key))),
      json.String(ids.op_id_to_string(remote_tool.operation(key))),
      json.String(remote_tool.step(key)),
      json.Int(index),
      json.String(arguments),
      json.String(ids.entry_id_to_string(remote_tool.result_entry(key))),
    ]),
    json.String(case service.role {
      CompileService -> "compile"
      LaunchService -> "launch"
    }),
    json.Array([
      json.String(ids.session_id_to_string(session)),
      json.String(executor),
      json.String(workspace_name),
      json.Int(workspace_epoch),
      json.Int(session_epoch),
    ]),
    json.String(ids.op_id_to_string(service.operation)),
    json.String(workspace.step_string(service.step)),
    json.String(ids.entry_id_to_string(service.request_id)),
    json.String(service.input_digest),
    json.String(service.registration_digest),
    json.String(service.contract_digest),
  ])
}

/// Totally decodes the closed service header using its smart constructors.
///
/// ## Examples
///
/// Extra fields, unsupported roles and changed session linkage are refused.
pub fn decode_service(
  value: json.JsonValue,
) -> Result(ServiceKey, corruption.CorruptionReport) {
  decode_service_value(value)
  |> result.map_error(fn(reason) {
    corruption.report(
      at: "core/command.decode_service",
      on: "service",
      expected: reason,
      context: "",
    )
  })
}

fn decode_service_value(value: json.JsonValue) -> Result(ServiceKey, String) {
  case value {
    json.Array([json.Int(2), original, json.String(id), json.String(input)]) -> {
      use predecessor <- result.try(decode_original_service(original))
      use id <- result.try(
        ids.parse_entry_id(id)
        |> result.replace_error("invalid rewrite UUID"),
      )
      rewrite_service_key(predecessor, id, input)
    }
    _ -> decode_original_service(value)
  }
}

// Only a version-one predecessor is admitted, before any recursive decoding.
fn decode_original_service(
  value: json.JsonValue,
) -> Result(ServiceKey, String) {
  case value {
    json.Array([
      json.Int(1),
      parent_value,
      json.String(role),
      json.Array([
        json.String(session),
        json.String(executor),
        json.String(workspace_name),
        json.Int(workspace_epoch),
        json.Int(session_epoch),
      ]),
      json.String(operation),
      json.String(step),
      json.String(id),
      json.String(input),
      json.String(registration),
      json.String(contract),
    ]) -> {
      use parent <- result.try(decode_parent(parent_value))
      use role <- result.try(parse_service_role(role))
      use scope <- result.try(
        workspace.scope_from_fields(
          session,
          workspace_name,
          executor,
          session_epoch,
          workspace_epoch,
        )
        |> result.replace_error("invalid command scope"),
      )
      use operation <- result.try(
        ids.parse_op_id(operation)
        |> result.replace_error("invalid command op UUID"),
      )
      use step <- result.try(
        workspace.step(step)
        |> result.replace_error("invalid physical command step"),
      )
      use id <- result.try(
        ids.parse_entry_id(id)
        |> result.replace_error("invalid command entry UUID"),
      )
      service_key(
        parent,
        role,
        scope,
        operation,
        step,
        id,
        input,
        registration,
        contract,
      )
    }
    _ -> Error("invalid command service identity")
  }
}

/// Encodes exact service and purpose; the address remains content-independent.
///
/// ## Examples
///
/// `decode_ref(encode_ref(ref)) == Ok(ref)`.
pub fn encode_ref(ref: CommandRef) -> json.JsonValue {
  json.Array([
    json.Int(1),
    encode_service(ref.service),
    json.String(command_name(ref.role)),
  ])
}

/// Totally decodes identity and checks the closed outer/native pairing.
///
/// ## Examples
///
/// A SatelliteCommand under CompileService is refused during decoding.
pub fn decode_ref(
  value: json.JsonValue,
) -> Result(CommandRef, corruption.CorruptionReport) {
  decode_ref_value(value)
  |> result.map_error(fn(reason) {
    corruption.report(
      at: "core/command.decode_ref",
      on: "command",
      expected: reason,
      context: "",
    )
  })
}

fn decode_ref_value(value: json.JsonValue) -> Result(CommandRef, String) {
  case value {
    json.Array([json.Int(1), service_value, json.String(role)]) -> {
      use service <- result.try(decode_service_value(service_value))
      use role <- result.try(case role {
        "compile_command" -> Ok(CompileCommand)
        "satellite_command" -> Ok(SatelliteCommand)
        _ -> Error("invalid command role")
      })
      command_ref(service, role)
    }
    _ -> Error("invalid command reference")
  }
}

fn decode_parent(value: json.JsonValue) -> Result(remote_tool.ToolKey, String) {
  case value {
    json.Array([
      json.String(session),
      json.String(operation),
      json.String(step),
      json.Int(index),
      json.String(digest),
      json.String(entry),
    ]) -> {
      use session <- result.try(
        ids.parse_session_id(session)
        |> result.replace_error("invalid command session UUID"),
      )
      use operation <- result.try(
        ids.parse_op_id(operation)
        |> result.replace_error("invalid command op UUID"),
      )
      use entry <- result.try(
        ids.parse_entry_id(entry)
        |> result.replace_error("invalid command entry UUID"),
      )
      remote_tool.key(session, operation, step, index, digest, entry)
    }
    _ -> Error("invalid command parent identity")
  }
}

fn parse_service_role(role: String) -> Result(ServiceRole, String) {
  case role {
    "compile" -> Ok(CompileService)
    "launch" -> Ok(LaunchService)
    _ -> Error("invalid physical service role")
  }
}

fn command_name(role: CommandRole) -> String {
  case role {
    CompileCommand -> "compile_command"
    SatelliteCommand -> "satellite_command"
  }
}
