//// Fixed Git recipes beneath original semantic workspace custody.
//// The owner reads the retained Invocation, derives its declared finite phase,
//// and compares actual Broker clearance before atomically admitting native bytes.
//// Executable discovery belongs to trusted executor assembly; no owner path probe
//// or arbitrary argv recipe can enter this binding. Initialize remains disabled.

import broker/dispatch
import broker/enrollment
import broker/policy
import client/remote/custodian
import client/remote/native_envelope
import core/generation
import core/ids
import core/msgpack as mp
import core/remote_tool as r
import core/workspace as scope
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/wire
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import storage/owner_custody as custody
import tools/workspace
import tools/workspace_codec

/// Original static capabilities and one trusted executor-resolved Git executable.
@internal
pub opaque type Binding {
  /// Closed static route to the original semantic writer and enrolled recipe.
  Binding(
    /// The actual custodian retaining the original semantic input.
    owner: custodian.Handle,
    /// Exact immutable executor generation and native policy facts.
    enrolled: enrollment.SessionEnrollment,
    /// Original native owner label used in the complete envelope.
    owner_label: String,
    /// Full session and workspace generation coordinates.
    scope: identity.Scope,
    /// Trusted executor-resolved Git executable beneath enrolled roots.
    program: String,
    /// Existing static materializer receiving the complete actual clearance.
    prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
    /// Existing candidate UUID allocator, committed only by original custody.
    mint: fn() -> ids.EntryId,
  )
}

/// Pins the executable beneath an enrolled immutable toolchain region.
/// All arguments, cwd and environment come from retained input and enrollment.
///
/// ## Examples
///
/// `new(owner, enrolled, label, scope, git, prepare, mint)` performs no discovery.
@internal
pub fn new(
  owner: custodian.Handle,
  enrolled: enrollment.SessionEnrollment,
  owner_label: String,
  scope: identity.Scope,
  program: String,
  prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
  mint: fn() -> ids.EntryId,
) -> Result(Binding, custody.Error) {
  let code = enrollment.code_mode_facts(enrolled)
  let #(session, enrolled_binding) =
    scope.scope_fields(enrollment.native_facts(enrolled).scope)
  let #(selector, workspace_epoch, session_epoch) =
    scope.binding_fields(enrolled_binding)
  let #(executor, workspace) = scope.selector_fields(selector)
  use Nil <- result.try(
    require(fn() {
      identity.scope_fields(scope)
      == #(
        ids.session_id_to_string(session),
        workspace,
        executor,
        session_epoch,
        workspace_epoch,
      )
      && owner_label != ""
      && string.byte_size(owner_label) <= 128
      && !string.contains(owner_label, "\u{0000}")
      && string.starts_with(program, "/")
      && !string.contains(program, "\u{0000}")
      && !string.contains(program, "/../")
      && !string.contains(program, "/./")
      && string.byte_size(program) <= 8192
      && list.any(code.toolchain_roots, fn(root) {
        string.starts_with(program, root <> "/")
      })
    }),
  )
  Ok(Binding(owner, enrolled, owner_label, scope, program, prepare, mint))
}

/// Reserves only the actual cleared command for the original retained query.
/// History and exact native retries return no sendable reservation.
///
/// ## Examples
///
/// `reserve(binding, actual)` compares complete parent bytes in the SQLite writer.
@internal
pub fn reserve(
  binding: Binding,
  actual: dispatch.Dispatch,
) -> Result(dispatcher.Reserved, Nil) {
  reserve_checked(binding, actual) |> result.replace_error(Nil)
}

fn reserve_checked(
  binding: Binding,
  actual: dispatch.Dispatch,
) -> Result(dispatcher.Reserved, custody.Error) {
  use origin <- result.try(option.to_result(
    actual.context.origin,
    custody.Conflict,
  ))
  use parent <- result.try(semantic_origin(origin))
  use stored <- result.try(custodian.child(binding.owner, parent))
  use invocation <- result.try(
    workspace_codec.decode_invocation(stored.1)
    |> result.replace_error(custody.Conflict),
  )
  let #(original_scope, operation, original_step, _, uuid) =
    workspace.invocation_identity(invocation)
  use checked <- result.try(custodian.resolve_semantic_parent(
    binding.owner,
    uuid,
    stored.1,
  ))
  let fields = custody.semantic_parent_fields(checked)
  use Nil <- result.try(
    require(fn() {
      stored.0 == uuid
      && fields.0 == parent
      && fields.1 == uuid
      && original_scope == enrollment.native_facts(binding.enrolled).scope
      && operation == actual.context.operation
      && actual.system_reservation == option.None
    }),
  )
  use phase <- result.try(command_phase(origin, workspace.request(invocation)))
  use argv <- result.try(arguments(phase, workspace.request(invocation)))
  let code = enrollment.code_mode_facts(binding.enrolled)
  let native = enrollment.native_facts(binding.enrolled)
  use actual_policy <- result.try(option.to_result(
    actual.request.policy,
    custody.Conflict,
  ))
  let #(composed, ceiling_narrowings) =
    policy.compose(native.ceiling, actual_policy, [])
  let expected_step =
    scope.step_string(original_step)
    <> ":"
    <> r.workspace_command_phase_name(phase)
  use _ <- result.try(
    scope.step(expected_step) |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(
    require(fn() {
      actual.context.step == expected_step
      && actual.request.argv == [binding.program, ..argv]
      && actual.request.env == [#("PATH", code.build_path)]
      && actual.request.cwd == code.workspace_root
      && actual.request.demand == native.demand
      && ceiling_narrowings == []
      && composed == actual_policy
      && actual.deadline_ms > 0
    }),
  )
  use prepared <- result.try(
    binding.prepare(actual) |> result.replace_error(custody.Conflict),
  )
  use Nil <- result.try(case prepared.lifetime {
    wire.Finite(ms)
      if ms > 0
      && actual_policy.limits.wall_s > 0
      && actual_policy.limits.wall_s * 1000 <= ms
    -> Ok(Nil)
    wire.Finite(_) | wire.Session -> Error(custody.Conflict)
  })
  use Nil <- result.try(
    require(fn() {
      prepared.request == actual.request
      && prepared.step == actual.context.step
      && prepared.stream == wire.Logs
      && string.lowercase(
        bit_array.base16_encode(identity.digest_bytes(prepared.registration)),
      )
      == enrollment.digests(binding.enrolled).0
    }),
  )
  use bytes <- result.try(envelope(
    binding,
    actual.context.operation,
    prepared,
    checked,
    phase,
    actual.deadline_ms,
  ))
  let candidate = binding.mint()
  use stored <- result.try(custodian.reserve_workspace_command(
    binding.owner,
    checked,
    origin,
    candidate,
    bytes,
  ))
  use Nil <- result.try(require(fn() { stored == #(candidate, bytes) }))
  use uuid <- result.try(
    identity.request_id(ids.entry_id_to_string(candidate))
    |> result.replace_error(custody.Conflict),
  )
  Ok(dispatcher.Reserved(
    identity.request_key(binding.scope, actual.context.operation, uuid),
    prepared,
  ))
}

fn semantic_origin(
  origin: r.ChildOrigin,
) -> Result(r.ChildOrigin, custody.Error) {
  case r.child_fields(origin) {
    r.WorkspaceCommandFields(parent, _) -> Ok(parent)
    r.ToolFields(key, r.AdmittedCapability(name, ordinal, r.NativeCommand)) ->
      r.tool_child(
        key,
        r.AdmittedCapability(name, ordinal, r.SemanticWorkspace),
      )
      |> result.replace_error(custody.Conflict)
    r.ToolFields(_, _) | r.SystemFields(_, _, _) -> Error(custody.Conflict)
  }
}

fn command_phase(
  origin: r.ChildOrigin,
  request: workspace.Request,
) -> Result(r.WorkspaceCommandPhase, custody.Error) {
  case r.child_fields(origin) {
    r.WorkspaceCommandFields(_, phase) -> {
      use _ <- result.try(arguments(phase, request))
      Ok(phase)
    }
    r.ToolFields(_, r.AdmittedCapability(_, _, r.NativeCommand)) ->
      case request {
        workspace.Git(workspace.CurrentBranch) -> Ok(r.GitBranch)
        workspace.Git(workspace.CurrentRevision) -> Ok(r.GitRevision)
        workspace.Git(workspace.Status) -> Ok(r.GitStatus)
        workspace.Git(workspace.Diff(workspace.WorkingTree)) ->
          Ok(r.GitWorkingTreeDiff)
        workspace.Git(workspace.Diff(workspace.Staged)) -> Ok(r.GitStagedDiff)
        workspace.Git(workspace.Diff(workspace.SinceRevision(_))) ->
          Ok(r.GitSinceRevisionDiff)
        workspace.Git(workspace.Log(_)) -> Ok(r.GitLog)
        _ -> Error(custody.Conflict)
      }
    r.ToolFields(_, _) | r.SystemFields(_, _, _) -> Error(custody.Conflict)
  }
}

fn arguments(
  phase: r.WorkspaceCommandPhase,
  request: workspace.Request,
) -> Result(List(String), custody.Error) {
  case phase, request {
    r.GitBranch, workspace.Git(workspace.CurrentBranch) ->
      Ok(["rev-parse", "--abbrev-ref", "HEAD"])
    r.GitRepositoryProbe, workspace.Git(workspace.CurrentRevision) ->
      Ok(["rev-parse", "--is-inside-work-tree"])
    r.GitRevision, workspace.Git(workspace.CurrentRevision) ->
      Ok(["rev-parse", "--verify", "--quiet", "HEAD"])
    r.GitStatus, workspace.Git(workspace.Status) ->
      Ok(["status", "--porcelain"])
    r.GitWorkingTreeDiff, workspace.Git(workspace.Diff(workspace.WorkingTree))
    -> Ok(["diff"])
    r.GitStagedDiff, workspace.Git(workspace.Diff(workspace.Staged)) ->
      Ok(["diff", "--cached"])
    r.GitSinceRevisionDiff,
      workspace.Git(workspace.Diff(workspace.SinceRevision(revision)))
    -> Ok(["diff", workspace.revision_string(revision), "--"])
    r.GitLog, workspace.Git(workspace.Log(limit)) ->
      Ok([
        "log",
        "--max-count=" <> int.to_string(limit),
        "--pretty=format:%H %s",
      ])
    _, _ -> Error(custody.Conflict)
  }
}

fn envelope(
  binding: Binding,
  operation: ids.OpId,
  prepared: wire.Prepared,
  parent: custody.SemanticParent,
  phase: r.WorkspaceCommandPhase,
  deadline_ms: Int,
) -> Result(BitArray, custody.Error) {
  use native <- result.try(
    native_envelope.encode_cleared(
      binding.owner_label,
      binding.scope,
      operation,
      prepared,
      deadline_ms,
    )
    |> result.replace_error(custody.Conflict),
  )
  let #(origin, uuid, digest, associated) =
    custody.semantic_parent_fields(parent)
  use original <- result.try(
    r.encode_child(origin) |> result.replace_error(custody.Conflict),
  )
  use associated <- result.try(
    generation.encode_association(associated)
    |> result.replace_error(custody.Conflict),
  )
  use bytes <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("workspace-native"),
        mp.BinaryValue(original),
        mp.StringValue(ids.entry_id_to_string(uuid)),
        mp.BinaryValue(digest),
        mp.StringValue(r.workspace_command_phase_name(phase)),
        mp.BinaryValue(associated),
        mp.BinaryValue(native),
      ]),
    )
    |> result.replace_error(custody.Conflict),
  )
  require(fn() { bit_array.byte_size(bytes) <= 131_072 })
  |> result.replace(bytes)
}

/// Retains ordered receipt bytes only after full original envelope comparison.
///
/// ## Examples
///
/// `receive(binding, origin, key, digest, outputs, terminal)` grants no replay.
@internal
pub fn receive(
  binding: Binding,
  origin: r.ChildOrigin,
  key: identity.RequestKey,
  digest: identity.Digest,
  outputs: List(BitArray),
  terminal: BitArray,
) -> Result(Nil, Nil) {
  let checked = {
    use parent <- result.try(semantic_origin(origin))
    use stored <- result.try(custodian.child(binding.owner, origin))
    use Nil <- result.try(
      require(fn() { bit_array.byte_size(stored.1) <= 131_072 }),
    )
    use value <- result.try(
      wire.decode_value(stored.1) |> result.replace_error(custody.Conflict),
    )
    use fields <- result.try(case value {
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("workspace-native"),
        mp.BinaryValue(original),
        mp.StringValue(uuid),
        mp.BinaryValue(input_digest),
        mp.StringValue(phase),
        mp.BinaryValue(associated),
        mp.BinaryValue(native),
      ]) -> Ok(#(original, uuid, input_digest, phase, associated, native))
      _ -> Error(custody.Conflict)
    })
    use original <- result.try(
      r.decode_child(fields.0) |> result.replace_error(custody.Conflict),
    )
    use semantic <- result.try(custodian.semantic_evidence(
      binding.owner,
      original,
    ))
    use invocation <- result.try(
      workspace_codec.decode_invocation(semantic.1)
      |> result.replace_error(custody.Conflict),
    )
    use phase <- result.try(command_phase(origin, workspace.request(invocation)))
    use associated <- result.try(
      generation.decode_association(fields.4)
      |> result.replace_error(custody.Conflict),
    )
    use retained <- result.try(custodian.child_generation(binding.owner, origin))
    use prepared <- result.try(
      native_envelope.decode_cleared(
        binding.owner_label,
        binding.scope,
        fields.5,
      )
      |> result.replace_error(custody.Conflict),
    )
    use expected <- result.try(
      wire.prepared_digest(prepared.1) |> result.replace_error(custody.Conflict),
    )
    use Nil <- result.try(
      require(fn() {
        parent == original
        && ids.entry_id_to_string(semantic.0) == fields.1
        && semantic.2 == fields.2
        && semantic.3 == associated
        && fields.3 == r.workspace_command_phase_name(phase)
        && retained == associated
        && identity.key_scope(key) == binding.scope
        && identity.key_fields(key)
        == #(ids.op_id_to_string(prepared.0), ids.entry_id_to_string(stored.0))
        && digest == expected
      }),
    )
    use receipt <- result.try(custodian.receipt(outputs, terminal))
    use Nil <- result.try(custodian.receive_child(
      binding.owner,
      origin,
      stored.0,
      receipt,
    ))
    use readback <- result.try(custodian.receipt_generation(
      binding.owner,
      origin,
      stored.0,
    ))
    require(fn() { readback == #(receipt, retained) })
  }
  checked |> result.replace_error(Nil)
}

/// Recognizes the explicit wrapper; capability routing needs retained evidence.
///
/// ## Examples
///
/// `is_origin(derived)` keeps this family out of generic child admission.
@internal
pub fn is_origin(origin: r.ChildOrigin) -> Bool {
  case r.child_fields(origin) {
    r.WorkspaceCommandFields(_, _) -> True
    r.ToolFields(_, _) | r.SystemFields(_, _, _) -> False
  }
}

fn require(agrees: fn() -> Bool) -> Result(Nil, custody.Error) {
  case agrees() {
    True -> Ok(Nil)
    False -> Error(custody.Conflict)
  }
}
