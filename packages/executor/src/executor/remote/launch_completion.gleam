//// Closed historical Launch evidence, separate from a program's cap outcome.
////
//// A refusal records the original live owner's witnessed exclusion of every
//// possible native dispatch. Retaining that refusal atomically fences preparation
//// and native association, including work after Ready. An absent association, lost
//// reply or timeout supplies no witness; the codec cannot establish that ordering.
//// Native settlement retains the exact independently admitted native identity,
//// Prepared digest and canonical terminal, deriving enforcement from that terminal.
//// Authenticated native journal readback remains the journal consumer's duty.
////
//// Neither variant contains a socket, token, PID, Claim, stream grant or activation
//// authority. A native exit says nothing about the program's cap-protocol outcome,
//// resource cleanup, channel consumption, scope retirement or owner report COMMIT.
//// Unknown work remains unresolved rather than becoming a historical refusal.
////
//// ## Flow
////
//// `refused_before_native` bounds a witnessed historical diagnostic;
//// `settled_native` checks enrollment and exact native correspondence;
//// `decode` applies bounded raw preflight and canonical re-encoding. `check_native`
//// preserves the original scope and operation, while `check_terminal` admits only
//// canonical terminals under 32 KiB. `bound_report` keeps derived Unreported text
//// within the outer string ceiling. `decode_association` uses Admit as identity
//// syntax only, never as an admission event. The unchanged native profile bounds
//// the outer frame to 256 KiB, 2048 nodes, depth 16, containers 128, strings 8 KiB
//// and binaries 128 KiB; diagnostics additionally stop at 8000 UTF-8 bytes.

import broker/broker
import broker/dispatch
import broker/enrollment
import codemode/enforcement
import core/bounded_msgpack
import core/command
import core/ids
import core/json_wire
import core/msgpack as mp
import core/workspace
import executor/remote/identity
import executor/remote/journal_codec
import executor/remote/native
import gleam/bit_array
import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Checked historical Launch data, without authority to dispatch or reconnect.
pub opaque type LaunchCompletion {
  LaunchCompletion(
    /// Complete original enrolled Launch identity, including its full parent.
    original: command.ServiceKey,
    /// Closed observation independent of program outcome and cleanup.
    outcome: Outcome,
    /// Node enforcement derived solely from the retained native terminal.
    enforcement: enforcement.Report,
  )
}

/// A closed historical observation; it cannot represent unfinished work.
pub type LaunchObservation {
  /// The original live owner excluded all native dispatch before retention.
  RefusedBeforeNative(
    /// Bounded diagnostic data, not the live no-dispatch witness itself.
    reason: String,
  )

  /// The exact native terminal settled, independently of cap outcome or cleanup.
  NativeSettled
}

/// Exact association for comparison with the original authenticated native journal.
/// These fields alone do not prove that native admission occurred.
pub type NativeAssociation {
  NativeAssociation(
    /// Actual independently reserved native UUID, complete scope and operation.
    key: identity.RequestKey,
    /// Digest authenticating Prepared, never a digest of the terminal.
    digest: identity.Digest,
    /// Exact canonical terminal bytes retained by the native journal.
    terminal: BitArray,
  )
}

type Outcome {
  Before(reason: String)
  Settled(association: NativeAssociation)
}

/// Malformed historical data or disagreement with its pinned original identity.
pub type Error {
  /// Unsupported, noncanonical or oversized data.
  Invalid

  /// Service role, enrollment, scope or native operation differs.
  Mismatch
}

/// Fixed node report when the original owner witnessed exclusion of dispatch.
pub const before_native_reason = "launch refused before native dispatch"

/// Retains bounded historical refusal data. Before committing this value, the
/// journal consumer must hold the original live no-dispatch witness and commit
/// a fence excluding all subsequent preparation/native association/dispatch.
/// Ready may already exist; absence of association alone proves nothing.
/// This constructor and historical decoding cannot establish that live witness.
///
/// ## Examples
///
/// `launch_completion.refused_before_native(enrolled, original, "clearance refused")`.
pub fn refused_before_native(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
  reason: String,
) -> Result(LaunchCompletion, Error) {
  use Nil <- result.try(check_original(enrolled, original))
  use Nil <- result.try(bound_text(reason, 8000))
  Ok(LaunchCompletion(
    original:,
    outcome: Before(reason),
    enforcement: enforcement.Unreported(before_native_reason),
  ))
}

/// Retains exact canonical native settlement and derives its node enforcement.
/// Every native verdict is data, including helper refusal, timeout and nonzero
/// exit. None is a cap-protocol outcome. Actual native journal readback and exact
/// Prepared/policy/step association validation remain the journal consumer's job.
///
/// ## Examples
///
/// `launch_completion.settled_native(enrolled, original, child, digest, terminal)`.
pub fn settled_native(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
  key: identity.RequestKey,
  digest: identity.Digest,
  terminal: BitArray,
) -> Result(LaunchCompletion, Error) {
  use Nil <- result.try(check_original(enrolled, original))
  use Nil <- result.try(check_native(original, key))
  use settled <- result.try(check_terminal(terminal))
  let enforcement = report(settled)
  use Nil <- result.try(bound_report(enforcement))
  Ok(LaunchCompletion(
    original:,
    outcome: Settled(NativeAssociation(key:, digest:, terminal:)),
    enforcement:,
  ))
}

/// Returns the complete original Launch key for exact historical comparison.
///
/// ## Examples
///
/// `launch_completion.original(completion)` retains the complete parent fields.
pub fn original(completion: LaunchCompletion) -> command.ServiceKey {
  completion.original
}

/// Returns the closed observation without inventing a program outcome.
///
/// ## Examples
///
/// `launch_completion.observation(completion)` returns `NativeSettled` for an exit.
pub fn observation(completion: LaunchCompletion) -> LaunchObservation {
  case completion.outcome {
    Before(reason) -> RefusedBeforeNative(reason)
    Settled(_) -> NativeSettled
  }
}

/// Returns the exact native readback tuple, absent only for witnessed refusal.
/// Historical association grants no native dispatch or reconnect authority.
///
/// ## Examples
///
/// `launch_completion.native_association(completion)` supplies comparison fields.
pub fn native_association(
  completion: LaunchCompletion,
) -> Option(NativeAssociation) {
  case completion.outcome {
    Before(_) -> None
    Settled(association) -> Some(association)
  }
}

/// Returns the node report derived from the native terminal or fixed refusal.
/// This observation establishes neither retirement nor resource cleanup.
///
/// ## Examples
///
/// `launch_completion.enforcement_report(completion)` preserves helper evidence.
pub fn enforcement_report(completion: LaunchCompletion) -> enforcement.Report {
  completion.enforcement
}

/// Encodes checked historical data under the shared native raw preflight bounds.
///
/// ## Examples
///
/// `launch_completion.encode(completion)` returns canonical MessagePack bytes.
pub fn encode(completion: LaunchCompletion) -> Result(BitArray, Error) {
  use bytes <- result.try(
    mp.encode(to_value(completion)) |> result.replace_error(Invalid),
  )
  use _ <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  Ok(bytes)
}

/// Decodes against exact trusted enrollment and full original Launch identity.
/// Raw bounds precede term allocation; full re-encoding refuses noncanonical
/// outer and nested forms. Decoding recovers data, never a live refusal witness.
///
/// ## Examples
///
/// `launch_completion.decode(enrolled, expected, bytes)` refuses a Compile record.
pub fn decode(
  enrolled: enrollment.SessionEnrollment,
  expected: command.ServiceKey,
  bytes: BitArray,
) -> Result(LaunchCompletion, Error) {
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  use completion <- result.try(from_value(enrolled, expected, value))
  use canonical <- result.try(encode(completion))
  use <- bool.guard(canonical != bytes, Error(Invalid))
  Ok(completion)
}

fn check_original(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
) -> Result(Nil, Error) {
  enrollment.launch_paths(enrolled, original)
  |> result.map(fn(_) { Nil })
  |> result.replace_error(Mismatch)
}

fn bound_text(text: String, maximum: Int) -> Result(Nil, Error) {
  case string.byte_size(text) <= maximum {
    True -> Ok(Nil)
    False -> Error(Invalid)
  }
}

fn check_native(
  original: command.ServiceKey,
  key: identity.RequestKey,
) -> Result(Nil, Error) {
  let #(session, workspace, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(identity.key_scope(key))
  use native_scope <- result.try(
    workspace.scope_from_fields(
      session,
      workspace,
      executor,
      session_epoch,
      workspace_epoch,
    )
    |> result.replace_error(Mismatch),
  )
  let #(scope, operation, _) = command.coordinates(original)
  let #(native_operation, _) = identity.key_fields(key)
  case
    native_scope == scope && native_operation == ids.op_id_to_string(operation)
  {
    True -> Ok(Nil)
    False -> Error(Mismatch)
  }
}

fn check_terminal(bytes: BitArray) -> Result(dispatch.Terminal, Error) {
  use Nil <- result.try(case bit_array.byte_size(bytes) <= 32_768 {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  use terminal <- result.try(
    native.decode_terminal(bytes) |> result.replace_error(Invalid),
  )
  use canonical <- result.try(
    native.encode_terminal(terminal) |> result.replace_error(Invalid),
  )
  use Nil <- result.try(case canonical == bytes {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  Ok(terminal)
}

fn report(terminal: dispatch.Terminal) -> enforcement.Report {
  case terminal {
    dispatch.Completed(exit) -> enforcement.of_call(broker.CallExited(exit))
    dispatch.Failed(failure) -> enforcement.of_call(broker.CallFailed(failure))
  }
}

fn bound_report(report: enforcement.Report) -> Result(Nil, Error) {
  case report {
    enforcement.Reported(_, _) -> Ok(Nil)
    enforcement.Unreported(reason) -> bound_text(reason, 8192)
  }
}

fn to_value(completion: LaunchCompletion) -> mp.MsgPackValue {
  let outcome = case completion.outcome {
    Before(reason) -> mp.ArrayValue([mp.IntValue(0), mp.StringValue(reason)])
    Settled(association) ->
      mp.ArrayValue([mp.IntValue(1), association_value(association)])
  }
  mp.ArrayValue([
    mp.IntValue(1),
    mp.StringValue("loom.remote.launch-completion/1"),
    json_wire.of_json(command.encode_service(completion.original)),
    outcome,
  ])
}

fn association_value(association: NativeAssociation) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.BinaryValue(
      journal_codec.encode(journal_codec.Admit(
        association.key,
        association.digest,
      )),
    ),
    mp.BinaryValue(association.terminal),
  ])
}

fn from_value(
  enrolled: enrollment.SessionEnrollment,
  expected: command.ServiceKey,
  value: mp.MsgPackValue,
) -> Result(LaunchCompletion, Error) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("loom.remote.launch-completion/1"),
      key,
      outcome,
    ]) -> {
      use key <- result.try(
        json_wire.to_json(key) |> result.replace_error(Invalid),
      )
      use key <- result.try(
        command.decode_service(key) |> result.replace_error(Invalid),
      )
      use <- bool.guard(key != expected, Error(Mismatch))
      decode_outcome(enrolled, key, outcome)
    }
    _ -> Error(Invalid)
  }
}

fn decode_outcome(
  enrolled: enrollment.SessionEnrollment,
  key: command.ServiceKey,
  value: mp.MsgPackValue,
) -> Result(LaunchCompletion, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0), mp.StringValue(reason)]) ->
      refused_before_native(enrolled, key, reason)
    mp.ArrayValue([mp.IntValue(1), association]) -> {
      use association <- result.try(decode_association(enrolled, association))
      settled_native(
        enrolled,
        key,
        association.key,
        association.digest,
        association.terminal,
      )
    }
    _ -> Error(Invalid)
  }
}

fn decode_association(
  enrolled: enrollment.SessionEnrollment,
  value: mp.MsgPackValue,
) -> Result(NativeAssociation, Error) {
  let #(session, binding) =
    workspace.scope_fields(enrollment.native_facts(enrolled).scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, workspace) = workspace.selector_fields(selector)
  use workspace <- result.try(
    identity.workspace_id(workspace) |> result.replace_error(Invalid),
  )
  use executor <- result.try(
    identity.executor_id(executor) |> result.replace_error(Invalid),
  )
  use session_epoch <- result.try(
    identity.epoch(session_epoch) |> result.replace_error(Invalid),
  )
  use workspace_epoch <- result.try(
    identity.epoch(workspace_epoch) |> result.replace_error(Invalid),
  )
  let scope =
    identity.scope(session, workspace, executor, session_epoch, workspace_epoch)

  // The metadata-bound full scope supplies the part Admit deliberately omits.
  // Reusing this record encodes identity only and does not call a journal reducer.
  case value {
    mp.ArrayValue([mp.BinaryValue(record), mp.BinaryValue(terminal)]) -> {
      use association <- result.try(
        journal_codec.decode(record, scope) |> result.replace_error(Invalid),
      )
      case association {
        journal_codec.Admit(key, digest) ->
          Ok(NativeAssociation(key:, digest:, terminal:))
        journal_codec.Apply(_, _, _) | journal_codec.CloseEpoch ->
          Error(Invalid)
      }
    }
    _ -> Error(Invalid)
  }
}
