//// Checked executor-local server placement and closed protocol terminal bytes.
////
//// This module freezes the actual administrative descriptor, registration and
//// resolved jail before owner clearance. It grants no Broker approval, token or
//// launch permission. The service compares the cleared request with this exact
//// plan before admission and again before dispatch; neither argv nor a copied
//// digest can select another server. `checked` constructs the plan, `verify`
//// checks exact materialization, and `lease_matches` binds its original lease.
//// `encode_terminal` and `decode_terminal` keep protocol completeness distinct
//// from native exit and original helper retirement.

import broker/dispatch
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/framing
import broker/policy
import codemode/lsp_host/jail
import core/generation
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/workspace
import executor/remote/deployment
import executor/remote/identity
import executor/remote/lsp_journal
import executor/remote/native
import executor/remote/registration
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/list
import gleam/option.{Some}
import gleam/result

/// Historical closed evidence; none of its variants recreates live startup authority.
pub type Witness {
  /// The actual original helper supplied a native protocol verdict.
  NativeTerminal(
    terminal: dispatch.Terminal,
    disposition: framing.ProtocolDisposition,
  )

  /// The existing dispatcher definitely refused before native startup.
  StartupRefused

  /// The existing pool could not supply its original helper.
  StartupNoHelper

  /// Native startup may have happened; retain the original failure without a handle.
  StartupUnknown(failure: exec.ExecFailure)

  /// The original executor start continuation did not supply its reply.
  StartupReplyLost

  /// Local framing, consumption or close fenced the original attachment.
  LocalProtocolClosed
}

/// Frozen actual placement; only the checked constructor may create this value.
pub opaque type CheckedServerPlan {
  CheckedServerPlan(
    /// Original immutable native registration and its physical canonicalizer.
    registration: registration.Registration,
    /// Exact original profile label, independent of the native request UUID.
    name: String,
    /// Complete resolved jail, including original trusted environment values.
    jail: jail.Jail,
    /// Exact policy which the original owner must clear without narrowing.
    policy: policy.SandboxPolicy,
    /// Exact original full generation scope from the canonical enrollment.
    scope: workspace.Scope,
    /// Descriptor commitment includes the complete actual LSP declarations.
    descriptor: generation.Digest,
    /// SHA-256 of the canonical complete session enrollment bytes.
    enrollment: generation.Digest,
    /// Exact original negotiated compilation contract claim.
    contract: BitArray,
  )
}

/// Constructs a plan from actual administration and already checked placement.
/// Trusted environment lookup runs once here; dispatch never rereads it.
///
/// ## Examples
/// A declaration absent from the original Descriptor cannot construct a plan.
pub fn checked(
  descriptor: deployment.Descriptor,
  registered: registration.Registration,
  placement: jail.Placement,
  session_base: policy.SandboxPolicy,
  reading: fn(String) -> Result(String, Nil),
) -> Result(CheckedServerPlan, Nil) {
  let #(session, _, _, _, _) =
    identity.scope_fields(registration.scope(registered))
  use session <- result.try(
    ids.parse_session_id(session) |> result.replace_error(Nil),
  )
  use enrolled <- result.try(
    deployment.describe(descriptor, session) |> result.replace_error(Nil),
  )
  use facts <- result.try(registration.describe(registered))
  use Nil <- result.try(
    bool.guard(
      !{
        facts == enrollment.native_facts(enrolled)
        && placement.workspace
        == enrollment.code_mode_facts(enrolled).workspace_root
        && list.contains(deployment.lsp_profiles(descriptor), placement.server)
      },
      Error(Nil),
      fn() { Ok(Nil) },
    ),
  )
  let #(bounded_base, _) = policy.compose(facts.ceiling, session_base, [])
  use Nil <- result.try(
    bool.guard(!{ bounded_base == session_base }, Error(Nil), fn() { Ok(Nil) }),
  )
  use built <- result.try(
    jail.policy_for(placement, session_base, reading:)
    |> result.replace_error(Nil),
  )
  let #(cleared, shortfall) = policy.compose(built.base, built.requirements, [])
  use Nil <- result.try(
    bool.guard(
      !{
        shortfall == []
        && cleared.limits.cpu_s == 0
        && cleared.limits.wall_s == 0
        && cleared.limits.output_bytes == 67_108_864
      },
      Error(Nil),
      fn() { Ok(Nil) },
    ),
  )
  use descriptor <- result.try(
    deployment.descriptor_fields(descriptor).3
    |> bit_array.base16_decode
    |> result.replace_error(Nil),
  )
  use descriptor <- result.try(
    generation.digest(descriptor) |> result.replace_error(Nil),
  )
  use encoded <- result.try(
    enrollment.encode(enrolled) |> result.replace_error(Nil),
  )
  use digest <- result.try(
    generation.digest(crypto.hash(crypto.Sha256, encoded))
    |> result.replace_error(Nil),
  )
  use contract <- result.try(
    enrollment.digests(enrolled).1
    |> bit_array.base16_decode
    |> result.replace_error(Nil),
  )
  Ok(CheckedServerPlan(
    registered,
    placement.server.name,
    built,
    cleared,
    facts.scope,
    descriptor,
    digest,
    contract,
  ))
}

/// Derives the exact original binding using the configured generation number.
/// Opaque equality checks descriptor and enrollment without exporting DAL fields.
///
/// ## Examples
/// Changing a declaration changes this binding even with identical native roots.
pub fn binding(
  plan: CheckedServerPlan,
  number: Int,
) -> Result(lsp_journal.Binding, Nil) {
  use key <- result.try(
    generation.key(plan.scope, plan.descriptor, number)
    |> result.replace_error(Nil),
  )
  Ok(lsp_journal.binding(key, plan.enrollment))
}

/// Returns only the original scope and immutable physical profile coordinates.
///
/// ## Examples
/// `fields(plan)` supplies the same root and step throughout the lease lifetime.
pub fn fields(
  plan: CheckedServerPlan,
) -> #(identity.Scope, String, String, String) {
  #(
    registration.scope(plan.registration),
    plan.name,
    plan.jail.cwd,
    plan.jail.step_id,
  )
}

/// Retains exact bounded physical metadata before original owner clearance.
/// This offer contains no capability token and cannot dispatch native work.
///
/// ## Examples
/// Repeating an offer preserves its original resolved environment values.
pub fn offer(plan: CheckedServerPlan) -> Result(BitArray, wire.Error) {
  use policy <- result.try(
    policy.encode(plan.policy) |> result.replace_error(wire.Invalid),
  )
  use bytes <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue(plan.name),
        mp.StringValue(plan.jail.cwd),
        mp.StringValue(plan.jail.step_id),
        mp.BinaryValue(
          identity.digest_bytes(registration.digest(plan.registration)),
        ),
        mp.ArrayValue(list.map(plan.jail.argv, mp.StringValue)),
        mp.ArrayValue(
          list.map(plan.jail.env, fn(pair) {
            mp.ArrayValue([mp.StringValue(pair.0), mp.StringValue(pair.1)])
          }),
        ),
        mp.BinaryValue(policy),
      ]),
    ),
  )
  case bit_array.byte_size(bytes) <= 131_072 {
    True -> Ok(bytes)
    False -> Error(wire.Invalid)
  }
}

/// Checks exact original owner-cleared materialization without rewriting it.
/// The original owner Broker remains responsible for capability and budget
/// clearance; this comparison cannot manufacture a valid helper token.
///
/// ## Examples
/// Changed environment bytes or a log-stream request fail before native writes.
pub fn verify(
  plan: CheckedServerPlan,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> Result(Nil, Nil) {
  use Nil <- result.try(registration.verify(plan.registration, key, prepared))
  bool.guard(
    !{
      prepared.step == plan.jail.step_id
      && prepared.lifetime == wire.Session
      && prepared.stream == wire.ProtocolStream
      && prepared.request.argv == plan.jail.argv
      && prepared.request.env == plan.jail.env
      && prepared.request.cwd == plan.jail.cwd
      && prepared.request.policy == Some(plan.policy)
    },
    Error(Nil),
    fn() { Ok(Nil) },
  )
}

/// Checks the full original lease input against the frozen physical plan.
/// The closed header was already checked by core's constructor and the DAL.
///
/// ## Examples
/// A different profile or root cannot reuse this lease's request digest.
pub fn lease_matches(
  plan: CheckedServerPlan,
  lease: id.LspServiceKey,
) -> Result(Nil, Nil) {
  case id.lease_value(lease) {
    mp.ArrayValue([
      _,
      _,
      scope,
      _,
      _,
      mp.StringValue(step),
      mp.StringValue(request),
      mp.BinaryValue(digest),
      _,
      mp.BinaryValue(contract),
      _,
      _,
    ]) -> {
      use request <- result.try(
        ids.parse_entry_id(request) |> result.replace_error(Nil),
      )
      use input <- result.try(
        lsp_journal.lease_input(plan.name, plan.jail.cwd, request)
        |> result.replace_error(Nil),
      )
      bool.guard(
        !{
          scope == scope_value(registration.scope(plan.registration))
          && contract == plan.contract
          && step == plan.jail.step_id
          && digest == crypto.hash(crypto.Sha256, input)
        },
        Error(Nil),
        fn() { Ok(Nil) },
      )
    }
    _ -> Error(Nil)
  }
}

/// Encodes one bounded native terminal together with protocol completeness.
///
/// ## Examples
/// A successful exit with ProtocolFailed remains a failed protocol witness.
pub fn encode_terminal(
  terminal: dispatch.Terminal,
  disposition: framing.ProtocolDisposition,
) -> Result(BitArray, wire.Error) {
  use terminal <- result.try(native.encode_terminal(terminal))
  let tag = case disposition {
    framing.ProtocolComplete -> 0
    framing.ProtocolFailed -> 1
  }
  use bytes <- result.try(
    wire.encode_value(
      mp.ArrayValue([mp.IntValue(1), mp.BinaryValue(terminal), mp.IntValue(tag)]),
    ),
  )
  case bit_array.byte_size(bytes) <= 32_768 {
    True -> Ok(bytes)
    False -> Error(wire.Invalid)
  }
}

/// Totally decodes the original closed terminal; it grants no retirement proof.
///
/// ## Examples
/// Unknown protocol tags refuse the entire witness without prefix success.
pub fn decode_terminal(
  bytes: BitArray,
) -> Result(#(dispatch.Terminal, framing.ProtocolDisposition), wire.Error) {
  use <- bool.guard(bit_array.byte_size(bytes) > 32_768, Error(wire.Invalid))
  use value <- result.try(wire.decode_value(bytes))
  case value {
    mp.ArrayValue([mp.IntValue(1), mp.BinaryValue(terminal), mp.IntValue(tag)])
      if tag == 0 || tag == 1
    -> {
      use terminal <- result.try(native.decode_terminal(terminal))
      let disposition = case tag {
        0 -> framing.ProtocolComplete
        _ -> framing.ProtocolFailed
      }
      use canonical <- result.try(encode_terminal(terminal, disposition))
      case canonical == bytes {
        True -> Ok(#(terminal, disposition))
        False -> Error(wire.Invalid)
      }
    }
    _ -> Error(wire.Invalid)
  }
}

/// Encodes the original start outcome without manufacturing a native terminal.
/// Refusal stores its closed dispatcher category; possibly-started custody keeps
/// the exact native failure codec, while a missing reply remains its own tag.
///
/// ## Examples
/// A definite startup refusal and a lost original reply never decode alike.
@internal
pub fn encode_start_failure(
  failure: local.ProtocolStartFailure,
) -> Result(BitArray, wire.Error) {
  let value = case failure {
    local.ProtocolNotStarted(dispatch.NotStarted) -> Ok(#(0, mp.NilValue))
    local.ProtocolNotStarted(dispatch.NoHelper(_)) -> Ok(#(1, mp.NilValue))
    local.ProtocolStartUnknown(_, failure) -> {
      use bytes <- result.map(native.encode_terminal(dispatch.Failed(failure)))
      #(2, mp.BinaryValue(bytes))
    }
    local.ProtocolStartReplyLost -> Ok(#(3, mp.NilValue))
  }
  use pair <- result.try(value)
  use bytes <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(2),
        mp.IntValue(pair.0),
        pair.1,
      ]),
    ),
  )
  use <- bool.guard(bit_array.byte_size(bytes) > 32_768, Error(wire.Invalid))
  Ok(bytes)
}

/// Encodes local protocol closure without claiming a native terminal or retirement.
/// Original malformed consumption, exhausted credit and abandonment cannot retain
/// a successful prefix. Native retirement remains its separate original observer.
///
/// ## Examples
/// This local-failure tag cannot decode as a native ProtocolTerminal.
@internal
pub fn encode_local_closure() -> Result(BitArray, wire.Error) {
  wire.encode_value(mp.ArrayValue([mp.IntValue(3), mp.IntValue(0)]))
}

/// Totally reads immutable evidence without fabricating an original native handle.
///
/// ## Examples
/// `decode_witness(bytes)` distinguishes startup refusal from protocol failure.
@internal
pub fn decode_witness(bytes: BitArray) -> Result(Witness, wire.Error) {
  use <- bool.guard(bit_array.byte_size(bytes) > 32_768, Error(wire.Invalid))
  use value <- result.try(wire.decode_value(bytes))
  use canonical <- result.try(wire.encode_value(value))
  use <- bool.guard(canonical != bytes, Error(wire.Invalid))
  case value {
    mp.ArrayValue([mp.IntValue(1), _, _]) -> {
      use pair <- result.map(decode_terminal(bytes))
      NativeTerminal(pair.0, pair.1)
    }
    mp.ArrayValue([mp.IntValue(2), mp.IntValue(0), mp.NilValue]) ->
      Ok(StartupRefused)
    mp.ArrayValue([mp.IntValue(2), mp.IntValue(1), mp.NilValue]) ->
      Ok(StartupNoHelper)
    mp.ArrayValue([mp.IntValue(2), mp.IntValue(2), mp.BinaryValue(failure)]) -> {
      use terminal <- result.try(native.decode_terminal(failure))
      case terminal {
        dispatch.Failed(failure) -> Ok(StartupUnknown(failure))
        dispatch.Completed(_) -> Error(wire.Invalid)
      }
    }
    mp.ArrayValue([mp.IntValue(2), mp.IntValue(3), mp.NilValue]) ->
      Ok(StartupReplyLost)
    mp.ArrayValue([mp.IntValue(3), mp.IntValue(0)]) -> Ok(LocalProtocolClosed)
    _ -> Error(wire.Invalid)
  }
}

fn scope_value(scope: identity.Scope) -> mp.MsgPackValue {
  let #(session, workspace, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(scope)
  mp.ArrayValue([
    mp.StringValue(session),
    mp.StringValue(executor),
    mp.StringValue(workspace),
    mp.IntValue(workspace_epoch),
    mp.IntValue(session_epoch),
  ])
}
