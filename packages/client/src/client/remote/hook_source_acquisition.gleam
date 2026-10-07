//// Fixed registered hook inventory acquired through original source custody.
////
//// Original assembly captures OwnerBaseline once and holds it beside one pure
//// FixedBatchPlan outside the bounded observer. Losing that observer cannot
//// replace owner bytes, IDs or the original live-incarnation deadline. A retained
//// manifest is observation only: lookup never supplies live preparation custody.
////
//// `new` pins the original registered actor, enrollment and concrete endpoint.
//// `capture_owner` reads only the configured owner user file. `fixed_batch_plan`
//// preflights the complete manifest and both Read/Text plans without I/O.
//// `acquire` owns lookup, all three retentions and sequential reads in one weft
//// observer. `observe` can reconcile receipts but never prepare missing slots.
//// `decode_batch` reconstructs the two closed read plans and compares canonical
//// metadata; `read_document` promotes only exact text or true FsNotFound.
////
//// Source bodies stay outside SystemIntent metadata and client facts. Parsing
//// uses the existing indexed trust loader after honest acquisition of every
//// position. The accepted eight-MiB post-read ceilings bound retained bodies,
//// not physical read allocation, latency or parser intermediates. Assembly owns
//// its existing four-consumer ceiling and physical service close/join.

import broker/enrollment
import client/daemon/deployment
import client/hookserve
import client/remote/custodian
import client/remote/workspace_client
import core/bounded_msgpack
import core/generation
import core/ids
import core/msgpack as mp
import core/workspace as scope
import executor/remote/beam_endpoint as connection
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/owner_custody as custody
import tools/fs
import tools/tool
import tools/workspace
import weft
import weft/poll

/// Original registered authority and the closed user/project/local inventory.
@internal
pub opaque type Config {
  Config(
    /// Exact actor incarnation; it cannot follow a reopened custodian.
    owner: custodian.Handle,
    /// Original enrollment, compared again before returning sources.
    pin: custody.EnrollmentPin,
    /// Complete original scope, generation and owner-use identity.
    association: generation.GenerationAssociation,
    /// Reviewed first-submit consumer over the selected concrete endpoint.
    workspace: workspace_client.SystemConfig,
    /// Owner home selection, never an executor display label.
    home: Option(String),
    /// Closed labels derived from the original canonical enrollment.
    locations: List(hookserve.Located),
    /// One finite observation allowance within the original plan deadline.
    within_ms: Int,
  )
}

/// One actual owner capture held by assembly across observer loss.
@internal
pub opaque type OwnerBaseline {
  OwnerBaseline(
    /// Association fixes which original assembly captured these bytes.
    association: generation.GenerationAssociation,
    /// Exact configured home selection of that capture.
    home: Option(String),
    /// Omission, actual absence or original complete text and its single hash.
    source: OwnerSource,
  )
}

type OwnerSource {
  Omitted
  Absent
  Captured(text: String, digest: BitArray)
}

/// Pure canonical metadata fixed before the first observer starts.
@internal
pub opaque type FixedBatchPlan {
  FixedBatchPlan(
    /// Complete bounded manifest; no live readback, origin or source body.
    bytes: BitArray,
  )
}

/// Acquisition refuses incomplete sources without inventing absent documents.
@internal
pub type AcquisitionError {
  /// Closed inventory or its complete metadata exceeds the existing profile.
  InvalidInventory

  /// Original owner bytes or home identity do not match the retained manifest.
  OwnerBaselineUnavailable

  /// Preparation could have committed, or some fixed slots remain unavailable.
  PreparationUncertain

  /// One original source position failed acquisition before trust parsing.
  SourceFailure(
    /// Original index, including absent and refused predecessors.
    index: Int,
    /// Exact typed acquisition failure at that position.
    reason: SourceFailure,
  )

  /// The original actor could not supply exact custody or readiness.
  OwnerUnavailable(
    /// Existing custody refusal, never permission to select another owner.
    reason: custody.Error,
  )
}

/// Existing semantic failures remain separate from parse and trust refusals.
@internal
pub type SourceFailure {
  /// Fixed observation deadline expired without a complete source bundle.
  ObservationExpired

  /// The bounded observer died without authoritative acquisition evidence.
  ObservationLost

  /// Durable owner receipt was not established.
  ReceiptUncertain

  /// Transmission could have occurred without an exact observed result.
  TransportUncertain

  /// Completion projection or retained identity disagreed.
  InvalidCompletion

  /// Existing service refusal remains typed.
  ReadRefused(reason: workspace.ServiceError)

  /// Existing file refusal remains typed; only FsNotFound means absence.
  FileRefused(reason: workspace.ReadFailure)
}

type Batch {
  Batch(
    operation: ids.OpId,
    request_id: ids.EntryId,
    project: workspace_client.SystemReadPlan,
    local: workspace_client.SystemReadPlan,
    deadline_ms: Int,
  )
}

type Preparation {
  OriginalCandidate(plan: FixedBatchPlan)
  ObservationOnly
}

/// Pins closed inventory from actual original enrollment without reading files.
///
/// ## Examples
///
/// `new(ready, table, endpoint, limits, 5000, home)` starts no observer.
@internal
pub fn new(
  owner: custodian.RegisteredOwner,
  table: deployment.Table,
  endpoint: connection.Config,
  limits: custody.Limits,
  within_ms: Int,
  home: Option(String),
) -> Result(Config, workspace_client.ConfigurationError) {
  use workspace <- result.try(workspace_client.new_system(
    owner,
    table,
    endpoint,
    limits,
    within_ms,
  ))
  let #(original, pin, associated) = custodian.registered_fields(owner)
  let #(_, binding, _, _, _) = custody.enrollment_fields(pin)
  use selected <- result.try(
    deployment.select(table, binding)
    |> result.replace_error(workspace_client.InvalidConfiguration),
  )
  use pinned <- result.try(
    deployment.pinned(selected, pin)
    |> result.replace_error(workspace_client.InvalidConfiguration),
  )
  let root =
    deployment.pin_fields(pinned).1
    |> enrollment.code_mode_facts
    |> fn(code) { code.workspace_root }
  use Nil <- result.try(case home {
    Some(value) ->
      require_configuration(fn() {
        value != "" && !string.contains(value, "\u{0000}")
      })
    None -> Ok(Nil)
  })
  Ok(Config(
    original,
    pin,
    associated,
    workspace,
    home,
    hookserve.locations(home, root),
    within_ms,
  ))
}

fn require_configuration(
  valid: fn() -> Bool,
) -> Result(Nil, workspace_client.ConfigurationError) {
  case valid() {
    True -> Ok(Nil)
    False -> Error(workspace_client.InvalidConfiguration)
  }
}

/// Reads the configured owner user file once, outside acquisition observation.
/// The approved size check follows the real whole-file read. Assembly retains
/// this opaque body until settlement or explicit abandonment.
///
/// ## Examples
///
/// `capture_owner(config)` never opens either executor source label.
@internal
pub fn capture_owner(
  config: Config,
) -> Result(OwnerBaseline, AcquisitionError) {
  use source <- result.try(case config.home {
    None -> Ok(Omitted)
    Some(home) -> capture_user(home <> "/.claude/settings.json")
  })
  Ok(OwnerBaseline(config.association, config.home, source))
}

fn capture_user(path: String) -> Result(OwnerSource, AcquisitionError) {
  case fs.real_filesystem().read(path) {
    Error(tool.FsNotFound(_)) -> Ok(Absent)
    Error(error) ->
      Error(SourceFailure(
        0,
        FileRefused(workspace.FileReadFailed(fs.ReadFailed(error))),
      ))
    Ok(bytes) -> {
      use Nil <- result.try(
        case bit_array.byte_size(bytes) <= fs.max_read_bytes {
          True -> Ok(Nil)
          False ->
            Error(SourceFailure(
              0,
              FileRefused(
                workspace.FileReadFailed(fs.TooLarge(
                  bit_array.byte_size(bytes),
                  fs.max_read_bytes,
                )),
              ),
            ))
        },
      )
      use text <- result.try(
        bit_array.to_string(bytes)
        |> result.replace_error(SourceFailure(
          0,
          FileRefused(workspace.FileReadFailed(fs.NotText)),
        )),
      )
      Ok(Captured(text, bootstrap.sha256(bytes)))
    }
  }
}

/// Fixes one pure candidate, all original IDs and the absolute deadline.
/// Every complete encoding is checked before any actor or filesystem operation.
///
/// ## Examples
///
/// `fixed_batch_plan(config, baseline, generator, deadline)` writes no metadata.
@internal
pub fn fixed_batch_plan(
  config: Config,
  baseline: OwnerBaseline,
  generator: ids.Generator,
  deadline_ms: Int,
) -> Result(#(FixedBatchPlan, ids.Generator), AcquisitionError) {
  use Nil <- result.try(check_baseline(config, baseline))
  let #(operation, generator) = ids.mint_op(generator)
  let #(batch_id, generator) = ids.mint_entry(generator)
  let #(project_id, generator) = ids.mint_entry(generator)
  let #(local_id, generator) = ids.mint_entry(generator)
  use project <- result.try(make_read(
    config,
    operation,
    project_id,
    "project",
    deadline_ms,
  ))
  use local <- result.try(make_read(
    config,
    operation,
    local_id,
    "local",
    deadline_ms,
  ))
  use bytes <- result.try(encode_batch(
    config,
    baseline,
    Batch(operation, batch_id, project, local, deadline_ms),
  ))
  Ok(#(FixedBatchPlan(bytes), generator))
}

/// Owns original lookup, full preparation and sequential reads in one observer.
/// An indexed hit grants observation only. Retrying with a different candidate
/// cannot replace immutable IDs or renew the fixed original deadline.
///
/// ## Examples
///
/// `acquire(config, baseline, plan)` accepts no generator or deadline input.
@internal
pub fn acquire(
  config: Config,
  baseline: OwnerBaseline,
  plan: FixedBatchPlan,
) -> Result(hookserve.VerifiedSources, AcquisitionError) {
  use batch <- result.try(decode_batch(config, baseline, plan.bytes))
  let remaining =
    int.min(config.within_ms, batch.deadline_ms - poll.monotonic().now())
  bounded_acquisition(config, baseline, OriginalCandidate(plan), remaining)
}

/// Observes only existing fixed metadata and admitted receipts.
/// Missing or partial preparation cannot be filled; idempotent exact receipt
/// retention and acknowledgement remain owned by the existing consumer.
///
/// ## Examples
///
/// `observe(config, baseline)` never mints, retains an intent or submits work.
@internal
pub fn observe(
  config: Config,
  baseline: OwnerBaseline,
) -> Result(hookserve.VerifiedSources, AcquisitionError) {
  use Nil <- result.try(check_baseline(config, baseline))
  bounded_acquisition(config, baseline, ObservationOnly, config.within_ms)
}

fn bounded_acquisition(
  config: Config,
  baseline: OwnerBaseline,
  preparation: Preparation,
  remaining: Int,
) -> Result(hookserve.VerifiedSources, AcquisitionError) {
  use Nil <- result.try(case remaining > 0 {
    True -> Ok(Nil)
    False -> Error(SourceFailure(remote_index(config), ObservationExpired))
  })

  // These projections capture only the original source and its identity. BEAM
  // process copying still copies term wrappers; large binary retention and
  // allocator growth are measured separately by the acquisition controls.
  let source = baseline.source
  let association = baseline.association
  let home = baseline.home
  let task = fn() {
    acquire_original(
      config,
      OwnerBaseline(association, home, source),
      preparation,
    )
  }
  case weft.new([task]) |> weft.deadline(remaining) |> weft.start {
    [weft.Completed(_, sources)] -> Ok(sources)
    [weft.Failed(_, error)] -> Error(error)
    [weft.Abandoned(_)] | [weft.NeverStarted(_)] ->
      Error(SourceFailure(remote_index(config), ObservationExpired))
    _ -> Error(SourceFailure(remote_index(config), ObservationLost))
  }
}

fn acquire_original(
  config: Config,
  baseline: OwnerBaseline,
  preparation: Preparation,
) -> Result(hookserve.VerifiedSources, AcquisitionError) {
  use Nil <- result.try(original_ready(config))
  let lookup =
    custodian.lookup_workspace_administration_intent(
      config.owner,
      batch_address(config),
    )
  use #(batch, project, local) <- result.try(case lookup, preparation {
    Ok(manifest), candidate ->
      observe_preparation(config, baseline, manifest, candidate)
    Error(custody.Missing), OriginalCandidate(plan) ->
      retain_preparation(config, baseline, plan)
    Error(custody.Missing), ObservationOnly -> Error(PreparationUncertain)
    Error(error), _ -> Error(OwnerUnavailable(error))
  })
  use project_text <- result.try(read_document(
    config.workspace,
    batch.project,
    project,
    remote_index(config),
  ))
  use local_text <- result.try(read_document(
    config.workspace,
    batch.local,
    local,
    remote_index(config) + 1,
  ))

  // Retirement during acquisition cannot turn durable historical source bytes
  // into a runnable original bundle. Trust parsing follows the same check.
  use Nil <- result.try(original_ready(config))
  use Nil <- result.try(require(
    fn() { poll.monotonic().now() < batch.deadline_ms },
    SourceFailure(remote_index(config), ObservationExpired),
  ))
  let texts = case baseline.source {
    Omitted -> [project_text, local_text]
    Absent -> [None, project_text, local_text]
    Captured(text, _) -> [Some(text), project_text, local_text]
  }
  let documents =
    list.map(list.zip(config.locations, texts), fn(pair) {
      hookserve.AcquiredDocument(pair.0, pair.1)
    })
  let trust_root = option_trust_root(config.home)
  let sources = hookserve.load_registered(documents, trust_root)

  // Trust reading and parsing spend the original wall too. Observation's outer
  // allowance cannot promote an expired plan after both reads have completed.
  use Nil <- result.try(require(
    fn() { poll.monotonic().now() < batch.deadline_ms },
    SourceFailure(remote_index(config), ObservationExpired),
  ))
  Ok(sources)
}

fn original_ready(config: Config) -> Result(Nil, AcquisitionError) {
  use ready <- result.try(
    custodian.registered(config.owner) |> result.map_error(OwnerUnavailable),
  )
  case ready {
    custodian.ReadyForActivation(actual) -> {
      let fields = custodian.registered_fields(actual)
      require(
        fn() { fields == #(config.owner, config.pin, config.association) },
        OwnerUnavailable(custody.Conflict),
      )
    }
    custodian.HistoryOnly(_, _) -> Error(OwnerUnavailable(custody.Frozen))
  }
}

fn check_baseline(
  config: Config,
  baseline: OwnerBaseline,
) -> Result(Nil, AcquisitionError) {
  require(
    fn() {
      config.association == baseline.association && config.home == baseline.home
    },
    OwnerBaselineUnavailable,
  )
}

fn batch_address(config: Config) -> String {
  "registered-hooks-source-batch/1/"
  <> ids.entry_id_to_string(generation.association_fields(config.association).2)
}

fn remote_index(config: Config) -> Int {
  case config.home {
    None -> 0
    Some(_) -> 1
  }
}

fn option_trust_root(home: Option(String)) -> Option(String) {
  case home {
    None -> None
    Some(path) -> Some(path <> "/hooktrust")
  }
}

fn baseline_value(baseline: OwnerBaseline) -> mp.MsgPackValue {
  let home = case baseline.home {
    None -> mp.NilValue
    Some(path) -> mp.StringValue(path)
  }
  let source = case baseline.source {
    Omitted -> mp.ArrayValue([mp.StringValue("omitted")])
    Absent -> mp.ArrayValue([mp.StringValue("absent")])
    Captured(_, digest) ->
      mp.ArrayValue([mp.StringValue("text-sha256"), mp.BinaryValue(digest)])
  }
  mp.ArrayValue([home, source])
}

fn make_read(
  config: Config,
  operation: ids.OpId,
  request_id: ids.EntryId,
  slot: String,
  deadline: Int,
) -> Result(workspace_client.SystemReadPlan, AcquisitionError) {
  let relative = case slot {
    "project" -> ".claude/settings.json"
    _ -> ".claude/settings.local.json"
  }
  use path <- result.try(
    scope.relative_path(relative) |> result.replace_error(InvalidInventory),
  )
  use step <- result.try(
    scope.step("registered-hooks:" <> slot)
    |> result.replace_error(InvalidInventory),
  )
  workspace_client.system_read_plan(
    config.workspace,
    batch_address(config) <> "/" <> slot,
    operation,
    step,
    request_id,
    path,
    deadline,
  )
  |> result.replace_error(InvalidInventory)
}

fn encode_batch(
  config: Config,
  baseline: OwnerBaseline,
  batch: Batch,
) -> Result(BitArray, AcquisitionError) {
  use project <- result.try(
    bounded_msgpack.decode(workspace_client.system_read_content(batch.project))
    |> result.replace_error(InvalidInventory),
  )
  use local <- result.try(
    bounded_msgpack.decode(workspace_client.system_read_content(batch.local))
    |> result.replace_error(InvalidInventory),
  )
  let value =
    mp.ArrayValue([
      mp.StringValue("registered-hooks-source-batch/1"),
      generation.association_value(config.association),
      baseline_value(baseline),
      mp.StringValue(ids.op_id_to_string(batch.operation)),
      mp.StringValue(ids.entry_id_to_string(batch.request_id)),
      mp.ArrayValue([
        mp.ArrayValue([mp.StringValue("project-settings"), project]),
        mp.ArrayValue([mp.StringValue("local-settings"), local]),
      ]),
    ])
  use bytes <- result.try(
    mp.encode(value) |> result.replace_error(InvalidInventory),
  )
  use Nil <- result.try(require(
    fn() { bit_array.byte_size(bytes) <= 8192 },
    InvalidInventory,
  ))
  Ok(bytes)
}

fn decode_batch(
  config: Config,
  baseline: OwnerBaseline,
  bytes: BitArray,
) -> Result(Batch, AcquisitionError) {
  use Nil <- result.try(check_baseline(config, baseline))
  use Nil <- result.try(require(
    fn() { bit_array.byte_size(bytes) <= 8192 },
    InvalidInventory,
  ))
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(InvalidInventory),
  )
  use #(operation, request_id, project_value, local_value) <- result.try(
    case value {
      mp.ArrayValue([
        mp.StringValue("registered-hooks-source-batch/1"),
        associated,
        owner_value,
        mp.StringValue(op),
        mp.StringValue(id),
        mp.ArrayValue([
          mp.ArrayValue([mp.StringValue("project-settings"), project]),
          mp.ArrayValue([mp.StringValue("local-settings"), local]),
        ]),
      ]) -> {
        use Nil <- result.try(require(
          fn() {
            associated == generation.association_value(config.association)
          },
          InvalidInventory,
        ))
        use Nil <- result.try(require(
          fn() { owner_value == baseline_value(baseline) },
          OwnerBaselineUnavailable,
        ))
        use operation <- result.try(
          ids.parse_op_id(op) |> result.replace_error(InvalidInventory),
        )
        use request_id <- result.try(
          ids.parse_entry_id(id) |> result.replace_error(InvalidInventory),
        )
        Ok(#(operation, request_id, project, local))
      }
      _ -> Error(InvalidInventory)
    },
  )
  use #(project, deadline) <- result.try(decode_read(
    config,
    operation,
    "project",
    project_value,
  ))
  use #(local, local_deadline) <- result.try(decode_read(
    config,
    operation,
    "local",
    local_value,
  ))
  use Nil <- result.try(require(
    fn() { deadline == local_deadline },
    InvalidInventory,
  ))
  let batch = Batch(operation, request_id, project, local, deadline)
  use canonical <- result.try(encode_batch(config, baseline, batch))
  use Nil <- result.try(require(fn() { canonical == bytes }, InvalidInventory))
  Ok(batch)
}

fn decode_read(
  config: Config,
  operation: ids.OpId,
  slot: String,
  value: mp.MsgPackValue,
) -> Result(#(workspace_client.SystemReadPlan, Int), AcquisitionError) {
  use #(request_id, deadline) <- result.try(case value {
    mp.ArrayValue([
      mp.StringValue("registered-workspace-read-v1"),
      _,
      _,
      _,
      _,
      _,
      mp.StringValue(id),
      _,
      _,
      mp.IntValue(deadline),
    ]) -> {
      use request_id <- result.try(
        ids.parse_entry_id(id) |> result.replace_error(InvalidInventory),
      )
      Ok(#(request_id, deadline))
    }
    _ -> Error(InvalidInventory)
  })
  use plan <- result.try(make_read(
    config,
    operation,
    request_id,
    slot,
    deadline,
  ))
  use actual <- result.try(
    mp.encode(value) |> result.replace_error(InvalidInventory),
  )
  use Nil <- result.try(require(
    fn() { actual == workspace_client.system_read_content(plan) },
    InvalidInventory,
  ))
  Ok(#(plan, deadline))
}

fn observe_preparation(
  config: Config,
  baseline: OwnerBaseline,
  manifest: custody.IntentReadback,
  candidate: Preparation,
) -> Result(
  #(Batch, custody.IntentReadback, custody.IntentReadback),
  AcquisitionError,
) {
  let bytes = custody.system_intent_fields(manifest).6
  use Nil <- result.try(case candidate {
    OriginalCandidate(plan) ->
      require(fn() { bytes == plan.bytes }, InvalidInventory)
    ObservationOnly -> Ok(Nil)
  })
  use batch <- result.try(decode_batch(config, baseline, bytes))
  use Nil <- result.try(check_manifest(config, batch, manifest, bytes))
  use project <- result.try(lookup_read(config, batch.project))
  use local <- result.try(lookup_read(config, batch.local))
  Ok(#(batch, project, local))
}

fn retain_preparation(
  config: Config,
  baseline: OwnerBaseline,
  plan: FixedBatchPlan,
) -> Result(
  #(Batch, custody.IntentReadback, custody.IntentReadback),
  AcquisitionError,
) {
  use batch <- result.try(decode_batch(config, baseline, plan.bytes))
  use manifest <- result.try(
    custodian.retain_system_intent(
      config.owner,
      batch_address(config),
      custody.WorkspaceAdministration,
      batch.operation,
      "registered-hooks:prepare",
      batch.request_id,
      plan.bytes,
    )
    |> preparation_result,
  )
  use Nil <- result.try(check_manifest(config, batch, manifest, plan.bytes))
  use project <- result.try(retain_read(config, batch.project))
  use local <- result.try(retain_read(config, batch.local))
  Ok(#(batch, project, local))
}

fn check_manifest(
  config: Config,
  batch: Batch,
  manifest: custody.IntentReadback,
  bytes: BitArray,
) -> Result(Nil, AcquisitionError) {
  require(
    fn() {
      custody.system_intent_fields(manifest)
      == #(
        config.association,
        batch_address(config),
        custody.WorkspaceAdministration,
        batch.operation,
        "registered-hooks:prepare",
        batch.request_id,
        bytes,
      )
    },
    InvalidInventory,
  )
}

fn read_coordinates(
  plan: workspace_client.SystemReadPlan,
) -> Result(
  #(String, ids.OpId, String, ids.EntryId, BitArray),
  AcquisitionError,
) {
  let bytes = workspace_client.system_read_content(plan)
  use value <- result.try(
    bounded_msgpack.decode(bytes) |> result.replace_error(InvalidInventory),
  )
  case value {
    mp.ArrayValue([
      _,
      _,
      mp.StringValue(address),
      _,
      mp.StringValue(op),
      mp.StringValue(step),
      mp.StringValue(id),
      _,
      _,
      _,
    ]) -> {
      use operation <- result.try(
        ids.parse_op_id(op) |> result.replace_error(InvalidInventory),
      )
      use request_id <- result.try(
        ids.parse_entry_id(id) |> result.replace_error(InvalidInventory),
      )
      Ok(#(address, operation, step, request_id, bytes))
    }
    _ -> Error(InvalidInventory)
  }
}

fn retain_read(
  config: Config,
  plan: workspace_client.SystemReadPlan,
) -> Result(custody.IntentReadback, AcquisitionError) {
  use #(address, operation, step, request_id, bytes) <- result.try(
    read_coordinates(plan),
  )
  use intent <- result.try(
    custodian.retain_system_intent(
      config.owner,
      address,
      custody.WorkspaceAdministration,
      operation,
      step,
      request_id,
      bytes,
    )
    |> preparation_result,
  )
  use Nil <- result.try(check_read(config, plan, intent))
  Ok(intent)
}

fn lookup_read(
  config: Config,
  plan: workspace_client.SystemReadPlan,
) -> Result(custody.IntentReadback, AcquisitionError) {
  use coordinates <- result.try(read_coordinates(plan))
  use intent <- result.try(
    case
      custodian.lookup_workspace_administration_intent(
        config.owner,
        coordinates.0,
      )
    {
      Ok(value) -> Ok(value)
      Error(custody.Missing) -> Error(PreparationUncertain)
      Error(error) -> Error(OwnerUnavailable(error))
    },
  )
  use Nil <- result.try(check_read(config, plan, intent))
  Ok(intent)
}

fn check_read(
  config: Config,
  plan: workspace_client.SystemReadPlan,
  intent: custody.IntentReadback,
) -> Result(Nil, AcquisitionError) {
  use #(address, operation, step, request_id, bytes) <- result.try(
    read_coordinates(plan),
  )
  require(
    fn() {
      custody.system_intent_fields(intent)
      == #(
        config.association,
        address,
        custody.WorkspaceAdministration,
        operation,
        step,
        request_id,
        bytes,
      )
    },
    InvalidInventory,
  )
}

fn preparation_result(
  value: Result(a, custody.Error),
) -> Result(a, AcquisitionError) {
  case value {
    Ok(value) -> Ok(value)
    Error(custody.Unavailable(_)) -> Error(PreparationUncertain)
    Error(error) -> Error(OwnerUnavailable(error))
  }
}

fn read_document(
  config: workspace_client.SystemConfig,
  plan: workspace_client.SystemReadPlan,
  intent: custody.IntentReadback,
  index: Int,
) -> Result(Option(String), AcquisitionError) {
  use outcome <- result.try(
    workspace_client.invoke_system(config, plan, intent)
    |> result.map_error(fn(error) {
      case error {
        workspace_client.InvalidSystemPlan ->
          SourceFailure(index, InvalidCompletion)
        workspace_client.SystemObservationExpired ->
          SourceFailure(index, ObservationExpired)
        workspace_client.SystemObservationLost ->
          SourceFailure(index, ObservationLost)
        workspace_client.SystemOwnerUnavailable(error) ->
          OwnerUnavailable(error)
      }
    }),
  )
  case outcome {
    workspace_client.Completed(Ok(completed), _) -> {
      case completed.response {
        workspace.ReadCompleted(Ok(workspace.TextRead(text))) -> Ok(Some(text))
        workspace.ReadCompleted(Error(workspace.FileReadFailed(fs.ReadFailed(tool.FsNotFound(
          _,
        ))))) -> Ok(None)
        workspace.ReadCompleted(Error(error)) ->
          Error(SourceFailure(index, FileRefused(error)))
        _ -> Error(SourceFailure(index, InvalidCompletion))
      }
    }
    workspace_client.Completed(Error(error), _) ->
      Error(SourceFailure(index, ReadRefused(error)))
    workspace_client.Pending(_, workspace_client.AwaitingEvidence) ->
      Error(SourceFailure(index, ObservationExpired))
    workspace_client.Pending(_, workspace_client.TransportUncertain) ->
      Error(SourceFailure(index, TransportUncertain))
    workspace_client.Pending(_, workspace_client.ReceiptUncertain) ->
      Error(SourceFailure(index, ReceiptUncertain))
    workspace_client.Cancelled(_) | workspace_client.InvariantFailure(_) ->
      Error(SourceFailure(index, InvalidCompletion))
  }
}

fn require(
  agrees: fn() -> Bool,
  error: AcquisitionError,
) -> Result(Nil, AcquisitionError) {
  case agrees() {
    True -> Ok(Nil)
    False -> Error(error)
  }
}
