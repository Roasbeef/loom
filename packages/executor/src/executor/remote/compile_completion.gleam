//// Closed historical Compile completion, separate from preparation and custody.
////
//// Success derives an ExecutorArtifact from the original enrolled Compile key,
//// admitted allocation and exact native terminal. No local Artifact or separate
//// report can enter this constructor. Ready supplies locations only; native
//// success and physical fingerprint evidence are independent required inputs.
//// Native key scope and operation agree with the whole service, while its UUID
//// and retained Prepared step belong to independent native admission.
////
//// The frame is [1, complete core ServiceKey, closed outcome]. Native association
//// reuses journal_codec's Admit identity bytes under that complete original scope;
//// this is identity encoding, never an admission event or proof. The native digest
//// names Prepared, not the terminal. Exact canonical terminal bytes are retained,
//// and enforcement.of_call derives the complete report from those bytes.
////
//// Constructors check strings before encoding; the outer scanner bounds 256 KiB,
//// 2048 nodes, depth 16, containers 128, strings 8 KiB and binaries 128 KiB. Native
//// terminals additionally stop at 32 KiB and diagnostics at 8000 UTF-8 bytes.
//// `bound_report` also bounds native-derived Unreported text before retention.
//// Decode pins the full expected key and enrollment, then re-encodes for canonical
//// equality. It recovers historical data, never a resource claim, clearance,
//// live allocation or authority to reissue an artifact. Actual authenticated
//// native journal readback and physical product verification remain caller duties.

import broker/broker
import broker/dispatch
import broker/enrollment
import codemode/build
import codemode/compile
import codemode/enforcement
import codemode/service_resources
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

/// A checked historical outcome whose artifact and report cannot be supplied
/// independently. This value grants no native or resource admission authority.
pub opaque type CompileCompletion {
  CompileCompletion(
    /// Exact original enrolled Compile identity, including the complete parent.
    original: command.ServiceKey,
    /// Closed material from which the public Compiled result was derived.
    outcome: Outcome,
    /// Derived artifact/error and complete enforcement report.
    compiled: compile.Compiled,
  )
}

/// Exact native association for authenticated journal comparison. The presence
/// of these fields alone is not evidence that native admission actually occurred.
pub type NativeAssociation {
  NativeAssociation(
    /// Actual independently reserved native UUID with full scope and operation.
    key: identity.RequestKey,
    /// Digest authenticating retained Prepared, not terminal bytes.
    digest: identity.Digest,
    /// Exact canonical terminal bytes retained by the native journal.
    terminal: BitArray,
  )
}

type Outcome {
  Before(error: compile.CompileError)
  Failed(association: NativeAssociation, error: compile.CompileError)
  Succeeded(
    locations: service_resources.CompileLocations,
    association: NativeAssociation,
    products: compile.BuildProducts,
  )
}

/// A bounded malformed record or a disagreement with its pinned association.
pub type Error {
  /// Unsupported, noncanonical, oversized or unsuccessful purported success.
  Invalid

  /// Identity, enrollment, allocation or native association differs.
  Mismatch
}

/// The fixed explanation for an outcome settled before native submission.
pub const before_native_reason = "compile failed before native submission"

/// Retains an explicit error before native submission, with a fixed Unreported
/// reason and no native association. The caller owns proof that no submit occurred.
///
/// ## Examples
///
/// `failed_before_native(enrolled, key, compile.WorkspaceSetupFailed("mkdir"))`.
pub fn failed_before_native(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
  error: compile.CompileError,
) -> Result(CompileCompletion, Error) {
  use _ <- result.try(check_original(enrolled, original))
  use Nil <- result.try(bound_error(error))
  Ok(CompileCompletion(
    original:,
    outcome: Before(error),
    compiled: compile.Compiled(
      Error(error),
      enforcement.Unreported(before_native_reason),
    ),
  ))
}

/// Retains an error after the exact native terminal and derives its full report.
/// A successful native exit may still fail product fingerprinting/finalization;
/// diagnostics preserve their discriminator without proving causal provenance.
///
/// ## Examples
///
/// `failed_native(enrolled, key, child, digest, terminal, compile.ArtifactIncomplete("beam"))`.
pub fn failed_native(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
  key: identity.RequestKey,
  digest: identity.Digest,
  terminal: BitArray,
  error: compile.CompileError,
) -> Result(CompileCompletion, Error) {
  use _ <- result.try(check_original(enrolled, original))
  use Nil <- result.try(bound_error(error))
  use Nil <- result.try(check_native(original, key))
  use settled <- result.try(check_terminal(terminal))
  let enforcement = report(settled)
  use Nil <- result.try(bound_report(enforcement))
  let association = NativeAssociation(key:, digest:, terminal:)
  Ok(CompileCompletion(
    original:,
    outcome: Failed(association, error),
    compiled: compile.Compiled(Error(error), enforcement),
  ))
}

/// Derives the executor artifact from checked identity, successful native exit
/// and physical BuildProducts. It accepts neither a local Artifact nor a report.
/// Fingerprint spelling is checked here; hashing actual files is the caller's job.
///
/// ## Examples
///
/// `successful(enrolled, key, ready, child, digest, terminal, products)` refuses
/// a cancelled zero exit or a beam directory outside the exact admitted root.
pub fn successful(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
  locations: service_resources.CompileLocations,
  key: identity.RequestKey,
  digest: identity.Digest,
  terminal: BitArray,
  products: compile.BuildProducts,
) -> Result(CompileCompletion, Error) {
  use expected_root <- result.try(check_original(enrolled, original))
  let #(prepared_key, root) = service_resources.compile_fields(locations)
  use <- bool.guard(
    prepared_key != original || root != expected_root,
    Error(Mismatch),
  )
  use Nil <- result.try(check_native(original, key))
  use settled <- result.try(check_terminal(terminal))
  use Nil <- result.try(successful_terminal(settled))

  // Literal allocation equality refuses aliases before deriving artifact identity.
  use Nil <- result.try(bound_text(products.beam_dir, 8192))
  use <- bool.guard(
    products.beam_dir != root <> "/" <> build.beam_directory,
    Error(Mismatch),
  )
  use Nil <- result.try(fingerprint(products.manifest_hash))
  let #(scope, operation, step) = command.coordinates(original)
  let #(input_digest, _, contract_digest) = command.digests(original)
  let issuer = ids.entry_id_to_string(command.request_id(original))
  let artifact =
    compile.ExecutorArtifact(
      scope:,
      operation:,
      step:,
      request_id: issuer,
      request_digest: input_digest,
      artifact_id: issuer,
      contract_digest:,
      entry_module: compile.entry_module,
      manifest_hash: products.manifest_hash,
    )

  // Native digest and native UUID stay in their own association, never substituted
  // for the original input digest and whole-service issuer identifier.
  Ok(CompileCompletion(
    original:,
    outcome: Succeeded(
      locations,
      NativeAssociation(key:, digest:, terminal:),
      products,
    ),
    compiled: compile.Compiled(Ok(artifact), report(settled)),
  ))
}

/// Returns the complete original key for exact journal/request comparison.
///
/// ## Examples
///
/// `original(completion)` retains source index, argument digest and result entry.
pub fn original(completion: CompileCompletion) -> command.ServiceKey {
  completion.original
}

/// Returns exact native association, absent only for an explicit pre-native error.
///
/// ## Examples
///
/// `native_association(completion)` supplies journal readback comparison fields.
pub fn native_association(
  completion: CompileCompletion,
) -> Option(NativeAssociation) {
  case completion.outcome {
    Before(_) -> None
    Failed(association, _) | Succeeded(_, association, _) -> Some(association)
  }
}

/// Returns the derived executor artifact/error and complete enforcement report.
/// Decoded success is historical evidence, not permission to reissue its artifact.
///
/// ## Examples
///
/// `compiled(completion).enforcement` always derives from its native terminal.
pub fn compiled(completion: CompileCompletion) -> compile.Compiled {
  completion.compiled
}

/// Encodes the checked closed outcome with the shared bounded preflight.
/// All variable fields were bounded before constructing this opaque value.
///
/// ## Examples
///
/// `encode(completion)` returns canonical versioned MessagePack bytes.
pub fn encode(completion: CompileCompletion) -> Result(BitArray, Error) {
  use bytes <- result.try(
    mp.encode(to_value(completion)) |> result.replace_error(Invalid),
  )
  use _ <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  Ok(bytes)
}

/// Decodes against trusted enrollment and the exact original expected service.
/// Unknown fields, noncanonical encodings, trailing bytes and extra fields refuse.
///
/// ## Examples
///
/// `decode(enrolled, original(completion), encode(completion) |> result.unwrap(<<>>))`
/// returns the same historical completion.
pub fn decode(
  enrolled: enrollment.SessionEnrollment,
  expected: command.ServiceKey,
  bytes: BitArray,
) -> Result(CompileCompletion, Error) {
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(Invalid),
  )
  use completion <- result.try(from_value(enrolled, expected, value))
  use canonical <- result.try(encode(completion))
  use Nil <- result.try(case canonical == bytes {
    True -> Ok(Nil)
    False -> Error(Invalid)
  })
  Ok(completion)
}

fn check_original(
  enrolled: enrollment.SessionEnrollment,
  original: command.ServiceKey,
) -> Result(String, Error) {
  enrollment.compile_path(enrolled, original) |> result.replace_error(Mismatch)
}

fn bound_error(error: compile.CompileError) -> Result(Nil, Error) {
  let text = case error {
    compile.WorkspaceSetupFailed(reason)
    | compile.BuildUnavailable(reason)
    | compile.ArtifactIncomplete(reason) -> reason
    compile.BuildRejected(diagnostics) -> diagnostics
  }
  bound_text(text, 8000)
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

fn successful_terminal(terminal: dispatch.Terminal) -> Result(Nil, Error) {
  case terminal {
    dispatch.Completed(exit)
      if exit.code == 0 && exit.signal == 0 && !exit.timed_out && !exit.cancelled
    -> Ok(Nil)
    dispatch.Completed(_) | dispatch.Failed(_) -> Error(Invalid)
  }
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

fn fingerprint(hash: String) -> Result(Nil, Error) {
  use Nil <- result.try(bound_text(hash, 71))
  case string.starts_with(hash, "sha256-") {
    True ->
      command.digest(string.drop_start(hash, 7))
      |> result.replace_error(Invalid)
    False -> Error(Invalid)
  }
}

fn to_value(completion: CompileCompletion) -> mp.MsgPackValue {
  let outcome = case completion.outcome {
    Before(error) -> mp.ArrayValue([mp.IntValue(0), error_value(error)])
    Failed(association, error) ->
      mp.ArrayValue([
        mp.IntValue(1),
        association_value(association),
        error_value(error),
      ])
    Succeeded(locations, association, products) ->
      mp.ArrayValue([
        mp.IntValue(2),
        mp.StringValue(service_resources.compile_fields(locations).1),
        association_value(association),
        mp.StringValue(products.beam_dir),
        mp.StringValue(products.manifest_hash),
      ])
  }
  mp.ArrayValue([
    mp.IntValue(1),
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

fn error_value(error: compile.CompileError) -> mp.MsgPackValue {
  let #(tag, text) = case error {
    compile.WorkspaceSetupFailed(reason) -> #(0, reason)
    compile.BuildRejected(diagnostics) -> #(1, diagnostics)
    compile.BuildUnavailable(reason) -> #(2, reason)
    compile.ArtifactIncomplete(reason) -> #(3, reason)
  }
  mp.ArrayValue([mp.IntValue(tag), mp.StringValue(text)])
}

fn from_value(
  enrolled: enrollment.SessionEnrollment,
  expected: command.ServiceKey,
  value: mp.MsgPackValue,
) -> Result(CompileCompletion, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(1), key, outcome]) -> {
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
) -> Result(CompileCompletion, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0), error]) -> {
      use error <- result.try(decode_error(error))
      failed_before_native(enrolled, key, error)
    }
    mp.ArrayValue([mp.IntValue(1), association, error]) -> {
      use error <- result.try(decode_error(error))
      use association <- result.try(decode_association(enrolled, association))
      failed_native(
        enrolled,
        key,
        association.key,
        association.digest,
        association.terminal,
        error,
      )
    }
    mp.ArrayValue([
      mp.IntValue(2),
      mp.StringValue(root),
      association,
      mp.StringValue(beam),
      mp.StringValue(hash),
    ]) -> {
      use locations <- result.try(
        service_resources.admit_compile_locations(enrolled, key, root)
        |> result.replace_error(Mismatch),
      )
      use association <- result.try(decode_association(enrolled, association))
      successful(
        enrolled,
        key,
        locations,
        association.key,
        association.digest,
        association.terminal,
        compile.BuildProducts(beam, hash),
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

fn decode_error(value: mp.MsgPackValue) -> Result(compile.CompileError, Error) {
  case value {
    mp.ArrayValue([mp.IntValue(0), mp.StringValue(text)]) ->
      Ok(compile.WorkspaceSetupFailed(text))
    mp.ArrayValue([mp.IntValue(1), mp.StringValue(text)]) ->
      Ok(compile.BuildRejected(text))
    mp.ArrayValue([mp.IntValue(2), mp.StringValue(text)]) ->
      Ok(compile.BuildUnavailable(text))
    mp.ArrayValue([mp.IntValue(3), mp.StringValue(text)]) ->
      Ok(compile.ArtifactIncomplete(text))
    _ -> Error(Invalid)
  }
}
