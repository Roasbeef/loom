//// Physical Compile finalization follows committed native evidence.
////
//// `observe` derives the entire original association and Ready allocation from
//// one resource journal. It checks the committed native phase before reading its
//// immutable payloads: retaining terminal bytes alone does not
//// establish settlement. The captured Observation has no replacement root or
//// identity at finalization, so another invocation cannot supply its allocation.
////
//// `finalize` uses the existing local build finalizer and closed completion codec.
//// Only the original live continuation may call it, exactly once, then commit the
//// completion before reporting success. Observation is copyable historical data,
//// not a linear permission; recovery and queries must never finalize. Source and
//// filesystem custody remain with that continuation, including after cancellation.
//// `bounded_error` changes only outer diagnostic text, never native receipt bytes.
//// `retention` keeps truncation sticky when subsequent stream chunks arrive.

import broker/broker
import broker/dispatch
import broker/enrollment
import broker/framing
import codemode/build
import codemode/compile
import codemode/service_resources
import core/command
import executor/remote/admission
import executor/remote/compile_completion
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal
import executor/remote/wire
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/tool

const diagnostic_bytes = 8000

const truncation_marker = "\n[diagnostics truncated]"

/// Exact committed observation, without preparation or launch permission.
pub opaque type Observation {
  /// All fields come from the same validated resource/native journal association.
  Observation(
    /// Whole original Compile identity, never the independent native UUID.
    original: command.ServiceKey,
    /// Pinned session snapshot from the original resource endpoint.
    enrolled: enrollment.SessionEnrollment,
    /// Admitted literal allocation retained in original Ready.
    locations: service_resources.CompileLocations,
    /// Exact independent native identity from committed association.
    key: identity.RequestKey,
    /// Prepared digest from that same association.
    digest: identity.Digest,
    /// Unchanged canonical terminal bytes named by committed reducer evidence.
    terminal: BitArray,
    /// Ordered stream bytes and actual native outcome, without invented reporting.
    collected: tool.Collected,
  )
}

/// Journal failures retain downstream uncertainty instead of becoming pending.
pub type Error {
  /// Original input, resource association or Ready read failed.
  ResourceError(
    /// Exact resource refusal or unresolved downstream journal disposition.
    reason: resource_journal.Error,
  )

  /// The pinned native endpoint failed; Uncertain must end caller polling.
  NativeJournalError(
    /// Exact native refusal or unresolved downstream journal disposition.
    reason: journal.Error,
  )

  /// Committed association, payload framing or terminal evidence disagrees.
  InvalidEvidence

  /// The existing closed completion constructor refused the captured result.
  InvalidCompletion(
    /// Existing codec failure, without changing its byte limits.
    reason: compile_completion.Error,
  )
}

type Retention {
  Complete
  Truncated
}

type Gathering {
  Gathering(
    ordinal: Int,
    stdout: List(BitArray),
    stderr: List(BitArray),
    stdout_retention: Retention,
    stderr_retention: Retention,
    terminal: Option(BitArray),
  )
}

/// Reads a full original association and Ready before observing native settlement.
/// Missing association is pending. Associated-without-Ready and a committed
/// terminal without exact payload are invalid; payload-before-COMMIT is pending.
/// No error, including an unresolved journal ask, becomes another pending pass.
///
/// ## Examples
///
/// ```gleam
/// compile_observation.observe(resources, original)
/// // -> Ok(Some(observation)) only after exact native terminal COMMIT.
/// ```
pub fn observe(
  resources: resource_journal.Journal,
  original: resource_journal.Input,
) -> Result(Option(Observation), Error) {
  use association <- result.try(
    resource_journal.inspect_native(resources, original)
    |> result.map_error(ResourceError),
  )
  case association {
    resource_journal.Unassociated -> Ok(None)
    resource_journal.Associated(_ref, key, digest, _prepared) -> {
      use status <- result.try(
        resource_journal.inspect(resources, original)
        |> result.map_error(ResourceError),
      )
      use locations <- result.try(ready_locations(status))
      let enrolled = resource_journal.enrolled(resources)
      let endpoint = resource_journal.native_endpoint(resources)
      use material <- result.try(read_native(endpoint, key, digest))
      case material {
        None -> Ok(None)
        Some(#(bytes, collected)) -> {
          Ok(
            Some(Observation(
              original.key,
              enrolled,
              locations,
              key,
              digest,
              bytes,
              collected,
            )),
          )
        }
      }
    }
  }
}

/// Exposes collected streams for internal diagnostics without changing receipts.
///
/// ## Examples
///
/// ```gleam
/// compile_observation.collected(observation).stdout
/// // -> Native stdout chunks concatenated in their retained ordinal order.
/// ```
@internal
pub fn collected(observation: Observation) -> tool.Collected {
  observation.collected
}

/// Finalizes the captured allocation once in its original live continuation.
/// This performs filesystem effects; a historical Observation is not permission
/// to call it. The caller owns once-only consumption and durable completion COMMIT.
/// Both successful products and failure preserve exact native binding/reporting.
///
/// ## Examples
///
/// ```gleam
/// compile_observation.finalize(observation)
/// // -> Ok(completion); commit it before publishing the outer result.
/// ```
pub fn finalize(
  observation: Observation,
) -> Result(compile_completion.CompileCompletion, Error) {
  let root = service_resources.compile_fields(observation.locations).1
  let built = build.finalize(root, observation.collected)
  case built.result {
    Ok(products) ->
      compile_completion.successful(
        observation.enrolled,
        observation.original,
        observation.locations,
        observation.key,
        observation.digest,
        observation.terminal,
        products,
      )
      |> result.map_error(InvalidCompletion)
    Error(error) ->
      compile_completion.failed_native(
        observation.enrolled,
        observation.original,
        observation.key,
        observation.digest,
        observation.terminal,
        bounded_error(error),
      )
      |> result.map_error(InvalidCompletion)
  }
}

/// Keeps the error variant while bounding its completed text to 8000 UTF-8 bytes.
/// The visible marker is included in the bound; native output remains unchanged.
/// This also adapts pre-native preparation diagnostics for the same closed codec.
///
/// ## Examples
///
/// ```gleam
/// compile_observation.bounded_error(compile.BuildRejected(diagnostics))
/// // -> BuildRejected with valid UTF-8 and a truncation marker when needed.
/// ```
@internal
pub fn bounded_error(error: compile.CompileError) -> compile.CompileError {
  case error {
    compile.WorkspaceSetupFailed(text) ->
      compile.WorkspaceSetupFailed(bound_text(text))
    compile.BuildRejected(text) -> compile.BuildRejected(bound_text(text))
    compile.BuildUnavailable(text) -> compile.BuildUnavailable(bound_text(text))
    compile.ArtifactIncomplete(text) ->
      compile.ArtifactIncomplete(bound_text(text))
  }
}

fn ready_locations(
  status: resource_journal.Status,
) -> Result(service_resources.CompileLocations, Error) {
  case status {
    resource_journal.Prepared(service_resources.CompileReady(locations))
    | resource_journal.Unknown(Some(service_resources.CompileReady(locations)))
    | resource_journal.Released(Some(service_resources.CompileReady(locations))) ->
      Ok(locations)
    resource_journal.Reserved
    | resource_journal.Prepared(service_resources.LaunchReady(_))
    | resource_journal.Unknown(None)
    | resource_journal.Unknown(Some(service_resources.LaunchReady(_)))
    | resource_journal.Released(None)
    | resource_journal.Released(Some(service_resources.LaunchReady(_))) ->
      Error(InvalidEvidence)
  }
}

fn gather(items: List(payload.Item)) -> Result(Gathering, Error) {
  use _ <- result.try(
    payload.validate_inventory(items) |> result.replace_error(InvalidEvidence),
  )
  list.try_fold(
    items,
    Gathering(0, [], [], Complete, Complete, None),
    gather_item,
  )
}

fn gather_item(
  gathering: Gathering,
  item: payload.Item,
) -> Result(Gathering, Error) {
  case item {
    payload.Output(ordinal, bytes) -> {
      use Nil <- result.try(case ordinal == gathering.ordinal {
        True -> Ok(Nil)
        False -> Error(InvalidEvidence)
      })
      use chunk <- result.try(
        native.decode_output(bytes) |> result.replace_error(InvalidEvidence),
      )
      use canonical <- result.try(
        native.encode_output(chunk) |> result.replace_error(InvalidEvidence),
      )
      use Nil <- result.try(exact_bytes(bytes, canonical))
      Ok(absorb(Gathering(..gathering, ordinal: ordinal + 1), chunk))
    }
    payload.Terminal(bytes) -> Ok(Gathering(..gathering, terminal: Some(bytes)))
    payload.Request(_) | payload.Authority(_) | payload.Cancellation(_) ->
      Ok(gathering)
  }
}

fn absorb(gathering: Gathering, chunk: dispatch.Chunk) -> Gathering {
  let incoming = case chunk.truncated {
    True -> Truncated
    False -> Complete
  }
  case chunk.stream {
    framing.Stdout ->
      Gathering(
        ..gathering,
        stdout: [chunk.data, ..gathering.stdout],
        stdout_retention: retention(gathering.stdout_retention, incoming),
      )
    framing.Stderr ->
      Gathering(
        ..gathering,
        stderr: [chunk.data, ..gathering.stderr],
        stderr_retention: retention(gathering.stderr_retention, incoming),
      )
  }
}

fn retention(existing: Retention, incoming: Retention) -> Retention {
  case incoming {
    Truncated -> Truncated
    Complete -> existing
  }
}

fn read_native(
  endpoint: journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> Result(Option(#(BitArray, tool.Collected)), Error) {
  use evidence <- result.try(
    journal.inspect(endpoint, key, digest)
    |> result.map_error(NativeJournalError),
  )
  case admission.phase(evidence) {
    admission.Admitted | admission.LaunchIntent(_) -> Ok(None)
    admission.Terminal(saved, _, _)
    | admission.Refused(saved, _)
    | admission.Retired(saved)
    | admission.RetiredRefusal(saved) -> {
      // A committed terminal phase follows payload retention and its digest is
      // immutable. Reading in this order avoids treating a concurrent commit
      // after an earlier empty payload read as missing committed evidence.
      use items <- result.try(
        journal.payloads(endpoint, key, digest)
        |> result.map_error(NativeJournalError),
      )
      use gathering <- result.try(gather(items))
      use bytes <- result.try(
        gathering.terminal |> option.to_result(InvalidEvidence),
      )
      use actual <- result.try(
        wire.digest(bytes) |> result.replace_error(InvalidEvidence),
      )
      use Nil <- result.try(case actual == saved {
        True -> Ok(Nil)
        False -> Error(InvalidEvidence)
      })
      use collected <- result.try(collection(gathering, bytes))
      Ok(Some(#(bytes, collected)))
    }
  }
}

fn collection(
  gathering: Gathering,
  bytes: BitArray,
) -> Result(tool.Collected, Error) {
  use terminal <- result.try(
    native.decode_terminal(bytes) |> result.replace_error(InvalidEvidence),
  )
  use canonical <- result.try(
    native.encode_terminal(terminal) |> result.replace_error(InvalidEvidence),
  )
  use Nil <- result.try(exact_bytes(bytes, canonical))
  let #(outcome, stdout, stderr) = case terminal {
    dispatch.Completed(result) -> #(
      broker.CallExited(result),
      result.stdout_truncated || gathering.stdout_retention == Truncated,
      result.stderr_truncated || gathering.stderr_retention == Truncated,
    )
    dispatch.Failed(failure) -> #(
      broker.CallFailed(failure),
      gathering.stdout_retention == Truncated,
      gathering.stderr_retention == Truncated,
    )
  }
  Ok(tool.Collected(
    bit_array.concat(list.reverse(gathering.stdout)),
    bit_array.concat(list.reverse(gathering.stderr)),
    stdout,
    stderr,
    outcome,
  ))
}

fn exact_bytes(actual: BitArray, canonical: BitArray) -> Result(Nil, Error) {
  case actual == canonical {
    True -> Ok(Nil)
    False -> Error(InvalidEvidence)
  }
}

fn bound_text(text: String) -> String {
  case string.byte_size(text) <= diagnostic_bytes {
    True -> text
    False -> {
      let maximum = diagnostic_bytes - string.byte_size(truncation_marker)
      let bytes = bit_array.from_string(text)
      utf8_prefix(bytes, maximum) <> truncation_marker
    }
  }
}

fn utf8_prefix(bytes: BitArray, maximum: Int) -> String {
  case bytes {
    <<prefix:bytes-size(maximum), _rest:bits>> -> {
      // A valid source string can end this bounded prefix inside at most one
      // four-byte codepoint. Trim only that suffix rather than scan all output.
      case bit_array.to_string(prefix) {
        Ok(text) -> text
        Error(_) -> utf8_prefix(bytes, maximum - 1)
      }
    }
    _ -> ""
  }
}
